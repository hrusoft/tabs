import Darwin
import Foundation
import Testing

// Against real repositories: what git answers, in repositories built with a
// pinned identity and dates. Case ids are docs/GIT-TREE.md's.
//
// Tests run at once, so building a repository never holds a Swift
// concurrency thread (git is waited for on a dispatch queue: a pool of
// blocked threads would stall every test's timers), and as little git runs as
// can: a repository tests only read is built once per test process and
// shared (`SharedRepo`), and a test that changes one gets a clone of it (an
// APFS clone, no process at all).

/// A temporary repository (or a plain directory), removed when the test's
/// value goes away; a shared one lives as long as the test process.
final class TempRepo: Sendable {
    let dir: String
    /// The whole environment for our git runs: the process's own, with HOME
    /// pointing into the scratch directory (the user's global config can't
    /// interfere) and a pinned identity.
    let environment: [String: String]
    private let isShared: Bool

    static let date = "2026-01-01T00:00:00+00:00"

    /// An empty directory (`initialized` makes it a repository), or with
    /// `cloning`, a copy of that repository: same history, same working tree.
    init(prefix: String = "tabs-git-test-", cloning template: TempRepo? = nil, shared: Bool = false) throws {
        let parent = shared ? SharedRepo.root : TestTemporary.root.path
        let base = URL(filePath: parent).appending(path: "\(prefix)\(UUID().uuidString)").path
        if let template {
            try FileManager.default.copyItem(atPath: template.dir, toPath: base)
        } else {
            try FileManager.default.createDirectory(atPath: base, withIntermediateDirectories: true)
        }
        // Resolved: /var is a symlink to /private/var, and git reports the resolved form.
        dir = base.withCString { path in
            guard let resolved = realpath(path, nil) else { return base }
            defer { free(resolved) }
            return String(cString: resolved)
        }
        let home = dir + "-home"
        try FileManager.default.createDirectory(atPath: home, withIntermediateDirectories: true)
        var env = ProcessInfo.processInfo.environment
        env["HOME"] = home
        env["GIT_CONFIG_NOSYSTEM"] = "1"
        env["GIT_AUTHOR_NAME"] = "Ann Example"
        env["GIT_AUTHOR_EMAIL"] = "ann@example.com"
        env["GIT_COMMITTER_NAME"] = "Ann Example"
        env["GIT_COMMITTER_EMAIL"] = "ann@example.com"
        environment = env
        isShared = shared
    }

    /// A new repository (`git init`, on `main`), nothing committed.
    static func initialized(prefix: String = "tabs-git-test-", shared: Bool = false) async throws -> TempRepo {
        let repo = try TempRepo(prefix: prefix, shared: shared)
        await repo.git("init", "-q", "-b", "main")
        return repo
    }

    /// A repository of its own, cloned from a shared one (to change it).
    static func clone(of shared: Task<TempRepo, any Error>) async throws -> TempRepo {
        try TempRepo(cloning: try await shared.value)
    }

    deinit {
        guard !isShared else { return }
        try? FileManager.default.removeItem(atPath: dir)
        try? FileManager.default.removeItem(atPath: dir + "-home")
    }

    var reader: Git { Git(environment: environment) }

    /// Runs git with a pinned date; returns trimmed stdout, nil on failure.
    @discardableResult
    func git(_ args: String..., date: String = TempRepo.date) async -> String? {
        await run(args, date: date)
    }

    /// Runs git, waited for on a dispatch queue (never on a Swift concurrency thread).
    @discardableResult
    func run(_ args: [String], date: String = TempRepo.date) async -> String? {
        var env = environment
        env["GIT_AUTHOR_DATE"] = date
        env["GIT_COMMITTER_DATE"] = date
        let (dir, environment) = (dir, env)
        return await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                continuation.resume(returning: runGit(args, in: dir, environment: environment))
            }
        }
    }

    func write(_ path: String, _ text: String) {
        let url = URL(filePath: dir).appending(path: path)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? text.write(to: url, atomically: true, encoding: .utf8)
    }

    func read(_ path: String) -> String { (try? String(contentsOfFile: dir + "/" + path, encoding: .utf8)) ?? "" }
}

/// The git `/usr/bin/env git` would run, looked up once: the first on `PATH`,
/// or, for the developer tools' `/usr/bin/git` (a shim that runs `xcrun` on
/// every call), the git it forwards to.
private let gitExecutable: String = {
    let path = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin"
    let first = path.split(separator: ":").map { "\($0)/git" }.first { FileManager.default.isExecutableFile(atPath: $0) } ?? "/usr/bin/git"
    guard first == "/usr/bin/git", let forwarded = runProcess("/usr/bin/xcrun", ["--find", "git"], in: "/", environment: nil),
        FileManager.default.isExecutableFile(atPath: forwarded)
    else { return first }
    return forwarded
}()

/// Runs git to completion (blocking: call it on a dispatch queue); trimmed stdout, nil on failure.
private func runGit(_ args: [String], in dir: String, environment: [String: String]) -> String? {
    runProcess(gitExecutable, args, in: dir, environment: environment)
}

private func runProcess(_ executable: String, _ args: [String], in dir: String, environment: [String: String]?) -> String? {
    let process = Process()
    process.executableURL = URL(filePath: executable)
    process.arguments = args
    process.currentDirectoryURL = URL(filePath: dir)
    if let environment { process.environment = environment }
    let out = Pipe()
    process.standardOutput = out
    process.standardError = FileHandle.nullDevice
    do { try process.run() } catch { return nil }
    let data = out.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else { return nil }
    return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
}

/// Repositories built once per test process, in a directory removed when it
/// exits. Read them as they are; clone one (`TempRepo.clone(of:)`) to change it.
enum SharedRepo {
    static let root = TestTemporary.directory("git-shared").path

    /// Nothing committed.
    static let empty = Task { try await TempRepo.initialized(prefix: "empty-", shared: true) }

    /// One commit with `orig.txt`.
    static let initial = Task {
        let repo = try await TempRepo.initialized(prefix: "initial-", shared: true)
        repo.write("orig.txt", "one\ntwo\n")
        await repo.git("add", ".")
        await repo.git("commit", "-q", "-m", "initial")
        return repo
    }

    /// Root, on feature, on main, merge feature (--no-ff).
    static let merge = Task {
        let repo = try await TempRepo.initialized(prefix: "merge-", shared: true)
        repo.write("root.txt", "root\n")
        await repo.git("add", "-A")
        await repo.git("commit", "-q", "-m", "root commit")
        await repo.git("checkout", "-q", "-b", "feature")
        repo.write("feature.txt", "feature\n")
        await repo.git("add", "-A", date: "2026-01-02T00:00:00+00:00")
        await repo.git("commit", "-q", "-m", "on feature", date: "2026-01-02T00:00:00+00:00")
        await repo.git("checkout", "-q", "main")
        repo.write("main.txt", "main\nsecond line\n")
        await repo.git("add", "-A", date: "2026-01-03T00:00:00+00:00")
        await repo.git("commit", "-q", "-m", "on main", date: "2026-01-03T00:00:00+00:00")
        await repo.git("merge", "-q", "--no-ff", "feature", "-m", "merge feature", date: "2026-01-04T00:00:00+00:00")
        return repo
    }

    /// Main (1 commit), local feature (+1), remote-only ref (+1), and a tag.
    static let branches = Task {
        let repo = try await TempRepo.initialized(prefix: "branches-", shared: true)
        await repo.git("remote", "add", "origin", "https://example.invalid/repo.git")
        repo.write("root.txt", "root\n")
        await repo.git("add", "-A")
        await repo.git("commit", "-q", "-m", "root commit")
        await repo.git("checkout", "-q", "-b", "feature")
        repo.write("feature.txt", "feature\n")
        await repo.git("add", "-A", date: "2026-01-02T00:00:00+00:00")
        await repo.git("commit", "-q", "-m", "on feature", date: "2026-01-02T00:00:00+00:00")
        await repo.git("checkout", "-q", "main")
        await repo.git("checkout", "-q", "-b", "remote-only")
        repo.write("remote.txt", "remote\n")
        await repo.git("add", "-A", date: "2026-01-03T00:00:00+00:00")
        await repo.git("commit", "-q", "-m", "on remote-only", date: "2026-01-03T00:00:00+00:00")
        await repo.git("update-ref", "refs/remotes/origin/remote-only", "remote-only")
        await repo.git("checkout", "-q", "main")
        await repo.git("branch", "-D", "remote-only")
        // A tag on an otherwise unreachable commit: no scope may show it.
        await repo.git("checkout", "-q", "--detach")
        repo.write("tagged.txt", "tagged\n")
        await repo.git("add", "-A", date: "2026-01-04T00:00:00+00:00")
        await repo.git("commit", "-q", "-m", "only tagged", date: "2026-01-04T00:00:00+00:00")
        await repo.git("tag", "v-orphan")
        await repo.git("checkout", "-q", "main")
        return repo
    }
}

// MARK: - The working tree, refs and checkout

/// A repository of its own with one commit with `orig.txt`.
private func initialRepo() async throws -> TempRepo {
    try await TempRepo.clone(of: SharedRepo.initial)
}

private func changedPaths(_ repo: TempRepo) async throws -> [String] {
    try await repo.reader.readWorkingTreeChanges(repo.dir).get().files.map(\.path).sorted()
}

/// P-6
@Suite("readWorkingTreeChanges") struct ReadWorkingTreeChangesTests {
    @Test("names an untracked path with a space verbatim, with its real line count") func untrackedWithSpace() async throws {
        let repo = try await initialRepo()
        repo.write("a b.txt", "x\ny\nz\n")
        let detail = try await repo.reader.readWorkingTreeChanges(repo.dir).get()
        #expect(detail.files == [ChangedFile(path: "a b.txt", insertions: 3, deletions: 0, readFromDisk: true)])
    }

    @Test("counts an untracked file from the repository's root when the pane is on a subdirectory") func fromASubdirectory()
        async throws
    {
        let repo = try await initialRepo()
        repo.write("sub/kept.txt", "kept\n")
        await repo.git("add", "-A")
        await repo.git("commit", "-q", "-m", "sub")
        repo.write("top.txt", "a\nb\n")
        let detail = try await repo.reader.readWorkingTreeChanges(repo.dir + "/sub").get()
        #expect(detail.files == [ChangedFile(path: "top.txt", insertions: 2, deletions: 0, readFromDisk: true)])
    }

    @Test("lists an untracked directory's files, not the directory") func untrackedDirectory() async throws {
        let repo = try await initialRepo()
        repo.write("d/one.txt", "a\n")
        repo.write("d/two.txt", "b\n")
        #expect(try await changedPaths(repo) == ["d/one.txt", "d/two.txt"])
    }

    @Test("lists a staged rename once, as the deletion and the new path") func stagedRename() async throws {
        let repo = try await initialRepo()
        await repo.git("mv", "orig.txt", "renamed.txt")
        #expect(try await changedPaths(repo) == ["orig.txt", "renamed.txt"])
    }

    @Test func isShapedLikeACommitsDetailWithHeadAsItsParent() async throws {
        let repo = try await initialRepo()
        repo.write("orig.txt", "one\n")
        let detail = try await repo.reader.readWorkingTreeChanges(repo.dir).get()
        #expect(detail.hash == uncommittedChangesHash)
        #expect(detail.message == "Uncommitted changes")
        let head = try #require(await repo.git("rev-parse", "HEAD"))
        #expect(detail.parents == [head])
        #expect(detail.files == [ChangedFile(path: "orig.txt", insertions: 0, deletions: 1)])
    }
}

/// C-11
@Suite("branchesAtCommit") struct BranchesAtCommitTests {
    @Test("reports the one local branch at the initial commit") func oneLocal() async throws {
        let repo = try await SharedRepo.initial.value
        let initialBranch = try #require(await repo.git("rev-parse", "--abbrev-ref", "HEAD"))
        let head = try #require(await repo.git("rev-parse", "HEAD"))
        let result = try await repo.reader.branchesAtCommit(repo.dir, hash: head).get()
        #expect(result.local == [initialBranch])
        #expect(result.remotes == [])
        #expect(result.allLocalBranches == [initialBranch])
    }

    @Test("reports every local branch when several point at the same commit") func severalLocal() async throws {
        let repo = try await initialRepo()
        let initialBranch = try #require(await repo.git("rev-parse", "--abbrev-ref", "HEAD"))
        let head = try #require(await repo.git("rev-parse", "HEAD"))
        await repo.git("branch", "stable")
        let result = try await repo.reader.branchesAtCommit(repo.dir, hash: head).get()
        #expect(result.local.sorted() == [initialBranch, "stable"].sorted())
    }

    @Test("reports a commit reachable only through a remote-tracking ref, matched against the real configured remote")
    func remoteOnly() async throws {
        let repo = try await initialRepo()
        await repo.git("remote", "add", "origin", "https://example.invalid/repo.git")
        let initialBranch = try #require(await repo.git("rev-parse", "--abbrev-ref", "HEAD"))
        await repo.git("checkout", "-q", "-b", "feature")
        repo.write("feature.txt", "x\n")
        await repo.git("add", "-A")
        await repo.git("commit", "-q", "-m", "on feature")
        let featureHead = try #require(await repo.git("rev-parse", "HEAD"))
        await repo.git("update-ref", "refs/remotes/origin/feature-x", "feature")
        await repo.git("checkout", "-q", initialBranch)
        await repo.git("branch", "-D", "feature")
        let result = try await repo.reader.branchesAtCommit(repo.dir, hash: featureHead).get()
        #expect(result.local == [])
        #expect(result.remotes == [RemoteRefInfo(remote: "origin", name: "feature-x", ref: "origin/feature-x")])
        #expect(result.allLocalBranches == [initialBranch])
    }

    @Test("excludes refs/remotes/origin/HEAD, the remote symref, as its own fake branch") func excludesRemoteHead() async throws {
        let repo = try await initialRepo()
        await repo.git("remote", "add", "origin", "https://example.invalid/repo.git")
        let head = try #require(await repo.git("rev-parse", "HEAD"))
        await repo.git("update-ref", "refs/remotes/origin/main-mirror", head)
        await repo.git("symbolic-ref", "refs/remotes/origin/HEAD", "refs/remotes/origin/main-mirror")
        let refs = try await repo.reader.branchesAtCommit(repo.dir, hash: head).get().remotes.map(\.ref)
        #expect(refs.contains("origin/main-mirror"))
        #expect(!refs.contains("origin/HEAD"))
    }

    @Test("reports no branch at all for a commit no ref points at") func noBranch() async throws {
        let repo = try await initialRepo()
        repo.write("orig.txt", "one\ntwo\nthree\n")
        await repo.git("commit", "-q", "-am", "second commit")
        let first = try #require(await repo.git("rev-parse", "HEAD~1"))
        let result = try await repo.reader.branchesAtCommit(repo.dir, hash: first).get()
        #expect(result.local == [])
        #expect(result.remotes == [])
    }
}

/// C-11
@Suite("checkout") struct CheckoutRealTests {
    @Test("switches to a local branch") func switchesToLocal() async throws {
        let repo = try await initialRepo()
        let initialBranch = try #require(await repo.git("rev-parse", "--abbrev-ref", "HEAD"))
        await repo.git("checkout", "-q", "-b", "feature")
        repo.write("feature.txt", "x\n")
        await repo.git("add", "-A")
        await repo.git("commit", "-q", "-m", "on feature")
        await repo.git("checkout", "-q", initialBranch)
        let result = await repo.reader.checkout(repo.dir, .branch(name: "feature"))
        #expect((try? result.get()) != nil)
        #expect(await repo.git("rev-parse", "--abbrev-ref", "HEAD") == "feature")
    }

    @Test("creates a local tracking branch from a remote-tracking-only ref") func createsTracking() async throws {
        let repo = try await initialRepo()
        await repo.git("remote", "add", "origin", "https://example.invalid/repo.git")
        let initialBranch = try #require(await repo.git("rev-parse", "--abbrev-ref", "HEAD"))
        await repo.git("checkout", "-q", "-b", "feature")
        repo.write("feature.txt", "x\n")
        await repo.git("add", "-A")
        await repo.git("commit", "-q", "-m", "on feature")
        await repo.git("update-ref", "refs/remotes/origin/feature-x", "feature")
        await repo.git("checkout", "-q", initialBranch)
        await repo.git("branch", "-D", "feature")
        let result = await repo.reader.checkout(
            repo.dir, .remoteBranch(RemoteRefInfo(remote: "origin", name: "feature-x", ref: "origin/feature-x")))
        #expect((try? result.get()) != nil)
        #expect(await repo.git("rev-parse", "--abbrev-ref", "HEAD") == "feature-x")
        #expect(await repo.git("rev-parse", "--abbrev-ref", "feature-x@{u}") == "origin/feature-x")
    }

    @Test("detaches HEAD at a bare commit hash") func detaches() async throws {
        let repo = try await initialRepo()
        repo.write("orig.txt", "one\ntwo\nthree\n")
        await repo.git("commit", "-q", "-am", "second commit")
        let first = try #require(await repo.git("rev-parse", "HEAD~1"))
        let result = await repo.reader.checkout(repo.dir, .commit(hash: first))
        #expect((try? result.get()) != nil)
        #expect(await repo.git("rev-parse", "HEAD") == first)
        #expect(await repo.git("symbolic-ref", "-q", "HEAD") == nil)
    }

    @Test("refuses a checkout that would overwrite uncommitted changes, leaves HEAD untouched, and keeps the full refusal text")
    func refusesDirty() async throws {
        let repo = try await initialRepo()
        let initialBranch = try #require(await repo.git("rev-parse", "--abbrev-ref", "HEAD"))
        await repo.git("checkout", "-q", "-b", "feature")
        repo.write("orig.txt", "one\ntwo\non feature\n")
        await repo.git("commit", "-q", "-am", "diverge on feature")
        await repo.git("checkout", "-q", initialBranch)
        repo.write("orig.txt", "one\ntwo\nlocal edit, uncommitted\n")
        let result = await repo.reader.checkout(repo.dir, .branch(name: "feature"))
        guard case .failure(let error) = result else {
            Issue.record("expected a refusal")
            return
        }
        guard case .failed = error.reason else {
            Issue.record("expected failed, got \(error.reason)")
            return
        }
        let detail = error.detail ?? ""
        #expect(detail.contains("overwritten by checkout"))
        #expect(detail.contains("orig.txt"))
        #expect(detail.contains("Please commit your changes or stash them"))
        #expect(await repo.git("rev-parse", "--abbrev-ref", "HEAD") == initialBranch)
        #expect(repo.read("orig.txt").contains("local edit, uncommitted"))
    }

    @Test(
        "refuses to create a tracking branch whose name collides with an existing local branch elsewhere — the real behavior decideCheckout filters around"
    )
    func refusesCollision() async throws {
        let repo = try await initialRepo()
        await repo.git("remote", "add", "origin", "https://example.invalid/repo.git")
        let head = try #require(await repo.git("rev-parse", "HEAD"))
        await repo.git("update-ref", "refs/remotes/origin/feature", head)
        await repo.git("branch", "feature")
        let result = await repo.reader.checkout(
            repo.dir, .remoteBranch(RemoteRefInfo(remote: "origin", name: "feature", ref: "origin/feature")))
        guard case .failure(let error) = result else {
            Issue.record("expected a refusal")
            return
        }
        #expect((error.detail ?? "").contains("a branch named 'feature' already exists"))
    }
}

// MARK: - One file's diff

/// A repository of its own with `long.txt` (30 numbered lines), then a
/// commit changing line 15.
private func longFileRepo() async throws -> (repo: TempRepo, head: String) {
    let repo = try await TempRepo.initialized()
    repo.write("long.txt", (1...30).map { "line \($0)\n" }.joined())
    await repo.git("add", "-A")
    await repo.git("commit", "-q", "-m", "long")
    repo.write("long.txt", (1...30).map { $0 == 15 ? "LINE 15\n" : "line \($0)\n" }.joined())
    await repo.git("commit", "-q", "-am", "change 15")
    return (repo, try #require(await repo.git("rev-parse", "HEAD")))
}

/// The file `path` as the commit's detail lists it, read from `dir`.
private func listedFile(_ repo: TempRepo, _ hash: String, _ path: String, dir: String? = nil) async throws -> ChangedFile {
    let detail = try await repo.reader.readCommit(dir ?? repo.dir, hash: hash).get()
    return try #require(detail.files.first { $0.path == path })
}

private func commitDiff(_ repo: TempRepo, _ hash: String, _ path: String) async throws -> FileDiff {
    try await repo.reader.readCommitFileDiff(repo.dir, hash: hash, file: try await listedFile(repo, hash, path)).get()
}

/// P-12, P-15
@Suite("file diffs") struct FileDiffRealTests {
    @Test("a commit's file: 5 lines of context each side, numbered, and its first parent's file for the hidden runs")
    func commitFile() async throws {
        let (repo, head) = try await longFileRepo()
        let diff = try await commitDiff(repo, head, "long.txt")
        #expect(diff.hunks.count == 1)
        let lines = try #require(diff.hunks.first?.lines)
        #expect(lines.first == FileDiff.Line(kind: .context, text: "line 10", old: 10, new: 10))
        #expect(lines.filter { $0.kind == .removed } == [FileDiff.Line(kind: .removed, text: "line 15", old: 15)])
        #expect(lines.filter { $0.kind == .added } == [FileDiff.Line(kind: .added, text: "LINE 15", new: 15)])
        #expect(lines.last == FileDiff.Line(kind: .context, text: "line 20", old: 20, new: 20))
        #expect(diff.base == (1...30).map { "line \($0)" })
        #expect(diff.gaps.map(\.count) == [9, 10])
    }

    @Test("the user's colors, external diff tool and context setting never reach the panel") func ignoresTheUsersDiffConfig() async throws {
        let (repo, head) = try await longFileRepo()
        await repo.git("config", "color.ui", "always")
        await repo.git("config", "diff.external", "/usr/bin/false")
        await repo.git("config", "diff.context", "1")
        let diff = try await commitDiff(repo, head, "long.txt")
        let lines = try #require(diff.hunks.first?.lines)
        #expect(!lines.contains { $0.text.contains("\u{1b}") })
        #expect(lines.count == 12, "5 unchanged lines either side of the two changed")
    }

    /// P-18
    @Test("a renamed file: both paths, its row as git prints it, its diff pairing them") func rename() async throws {
        let repo = try await TempRepo.initialized()
        repo.write("src/old/a.txt", (1...10).map { "a\($0)\n" }.joined())
        repo.write("dir/b.txt", (1...10).map { "b\($0)\n" }.joined())
        await repo.git("add", "-A")
        await repo.git("commit", "-q", "-m", "files")
        try FileManager.default.removeItem(atPath: repo.dir + "/src/old/a.txt")
        repo.write("src/new/a.txt", (1...10).map { $0 == 5 ? "A5\n" : "a\($0)\n" }.joined())
        try FileManager.default.moveItem(atPath: repo.dir + "/dir/b.txt", toPath: repo.dir + "/dir/c.txt")
        await repo.git("add", "-A")
        await repo.git("commit", "-q", "-m", "renames")
        let head = try #require(await repo.git("rev-parse", "HEAD"))
        let detail = try await repo.reader.readCommit(repo.dir, hash: head).get()
        #expect(detail.files.map(\.path).sorted() == ["dir/c.txt", "src/new/a.txt"])
        #expect(detail.files.first { $0.path == "src/new/a.txt" }?.oldPath == "src/old/a.txt")
        let printed = try #require(await repo.git("show", "--numstat", "--format=", "HEAD"))
        let gitsLabels = printed.split(separator: "\n").map { $0.split(separator: "\t", maxSplits: 2).last.map(String.init) ?? "" }
        #expect(detail.files.map(\.displayPath).sorted() == gitsLabels.sorted())

        let changed = try await commitDiff(repo, head, "src/new/a.txt")
        #expect(changed.hunks.count == 1)
        #expect(changed.hunks.first?.lines.contains(FileDiff.Line(kind: .added, text: "A5", new: 5)) == true)
        #expect(changed.base?.count == 10, "the old path's file")
        let moved = try await commitDiff(repo, head, "dir/c.txt")
        #expect(moved.hunks.isEmpty && !moved.binary, "a pure rename changes no lines")
    }

    @Test("a root commit's file is every line added, with no old file") func rootCommit() async throws {
        let repo = try await SharedRepo.merge.value
        let root = try #require(await repo.git("rev-list", "--max-parents=0", "HEAD"))
        let diff = try await commitDiff(repo, root, "root.txt")
        #expect(diff.hunks.first?.lines == [FileDiff.Line(kind: .added, text: "root", new: 1)])
        #expect(diff.base == nil)
        #expect(diff.gaps.isEmpty)
    }

    @Test("a merge's file is against its first parent") func merge() async throws {
        let repo = try await SharedRepo.merge.value
        let head = try #require(await repo.git("rev-parse", "HEAD"))
        let diff = try await commitDiff(repo, head, "feature.txt")
        #expect(diff.hunks.first?.lines == [FileDiff.Line(kind: .added, text: "feature", new: 1)])
    }

    @Test("a deleted file is every line removed, and nothing hidden") func deleted() async throws {
        let repo = try await initialRepo()
        await repo.git("rm", "-q", "orig.txt")
        await repo.git("commit", "-q", "-m", "delete")
        let head = try #require(await repo.git("rev-parse", "HEAD"))
        let diff = try await commitDiff(repo, head, "orig.txt")
        #expect(diff.hunks.first?.lines.map(\.kind) == [.removed, .removed])
        #expect(diff.rows(revealed: []).count == 2)
    }

    /// P-13
    @Test("a binary file and a mode change have no lines") func binaryAndMode() async throws {
        let repo = try await initialRepo()
        FileManager.default.createFile(atPath: repo.dir + "/i.bin", contents: Data([0, 1, 2]))
        await repo.git("add", "-A")
        await repo.git("commit", "-q", "-m", "binary")
        FileManager.default.createFile(atPath: repo.dir + "/i.bin", contents: Data([0, 1, 3]))
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: repo.dir + "/orig.txt")
        await repo.git("commit", "-q", "-am", "change")
        let head = try #require(await repo.git("rev-parse", "HEAD"))
        #expect(try await commitDiff(repo, head, "i.bin").binary)
        let mode = try await commitDiff(repo, head, "orig.txt")
        #expect(mode.hunks.isEmpty && !mode.binary)
    }

    @Test("a name with a space, a glob character or non-ASCII is that file, not a pattern") func literalNames() async throws {
        let repo = try await TempRepo.initialized()
        let names = ["a*.txt", "ab.txt", "é [x].txt"]
        for (index, name) in names.enumerated() { repo.write(name, "\(index)\n") }
        await repo.git("add", "-A")
        await repo.git("commit", "-q", "-m", "names")
        for (index, name) in names.enumerated() { repo.write(name, "changed \(index)\n") }
        await repo.git("commit", "-q", "-am", "change")
        let head = try #require(await repo.git("rev-parse", "HEAD"))
        for (index, name) in names.enumerated() {
            let diff = try await commitDiff(repo, head, name)
            #expect(
                diff.hunks.map(\.lines) == [
                    [
                        FileDiff.Line(kind: .removed, text: "\(index)", old: 1),
                        FileDiff.Line(kind: .added, text: "changed \(index)", new: 1),
                    ]
                ], "\(name)")
        }
    }

    @Test("a CRLF file's lines are its lines, without the CR") func crlf() async throws {
        let repo = try await TempRepo.initialized()
        repo.write("dos.txt", "one\r\ntwo\r\nthree\r\n")
        await repo.git("add", "-A")
        await repo.git("commit", "-q", "-m", "dos")
        repo.write("dos.txt", "one\r\nTWO\r\nthree\r\n")
        await repo.git("commit", "-q", "-am", "change")
        let head = try #require(await repo.git("rev-parse", "HEAD"))
        let diff = try await commitDiff(repo, head, "dos.txt")
        #expect(diff.hunks.first?.lines.map(\.text) == ["one", "two", "TWO", "three"])
        #expect(diff.base == ["one", "two", "three"])
    }

    @Test("a pane on a subdirectory: the files are named from the root, and read from there") func fromASubdirectory() async throws {
        let (repo, head) = try await longFileRepo()
        repo.write("sub/kept.txt", "kept\n")
        await repo.git("add", "-A")
        await repo.git("commit", "-q", "-m", "sub")
        let file = try await listedFile(repo, head, "long.txt", dir: repo.dir + "/sub")
        let diff = try await repo.reader.readCommitFileDiff(repo.dir, hash: head, file: file).get()
        #expect(diff.hunks.count == 1)
    }

    @Test("the working tree: a tracked file against HEAD, with HEAD's file for the hidden runs") func workingTreeTracked() async throws {
        let (repo, _) = try await longFileRepo()
        repo.write("long.txt", (1...30).map { $0 == 3 ? "THREE\n" : $0 == 15 ? "LINE 15\n" : "line \($0)\n" }.joined())
        let file = try #require(try await repo.reader.readWorkingTreeChanges(repo.dir).get().files.first)
        #expect(!file.readFromDisk)
        let diff = try await repo.reader.readWorkingTreeFileDiff(repo.dir, file: file).get()
        #expect(
            diff.hunks.first?.lines.filter { $0.kind != .context } == [
                FileDiff.Line(kind: .removed, text: "line 3", old: 3), FileDiff.Line(kind: .added, text: "THREE", new: 3),
            ])
        #expect(diff.base?[14] == "LINE 15", "HEAD's file")
    }

    @Test("a staged new file is added against HEAD, with no old file") func workingTreeStagedNew() async throws {
        let repo = try await initialRepo()
        repo.write("new.txt", "n\n")
        await repo.git("add", "new.txt")
        let file = try #require(try await repo.reader.readWorkingTreeChanges(repo.dir).get().files.first)
        #expect(!file.readFromDisk)
        let diff = try await repo.reader.readWorkingTreeFileDiff(repo.dir, file: file).get()
        #expect(diff.hunks.first?.lines == [FileDiff.Line(kind: .added, text: "n", new: 1)])
        #expect(diff.base == nil)
    }

    @Test("an untracked file, and any with no commits yet, is read off disk: every line added") func workingTreeOffDisk() async throws {
        let repo = try await initialRepo()
        repo.write("new.txt", "x\ny")
        let file = try #require(try await repo.reader.readWorkingTreeChanges(repo.dir).get().files.first)
        #expect(file.readFromDisk)
        let diff = try await repo.reader.readWorkingTreeFileDiff(repo.dir, file: file).get()
        #expect(
            diff.hunks.first?.lines == [
                FileDiff.Line(kind: .added, text: "x", new: 1), FileDiff.Line(kind: .added, text: "y", new: 2),
                FileDiff.Line(kind: .note, text: "\\ No newline at end of file"),
            ])

        let empty = try await TempRepo.clone(of: SharedRepo.empty)
        empty.write("staged.txt", "a\n")
        await empty.git("add", "-A")
        let staged = try #require(try await empty.reader.readWorkingTreeChanges(empty.dir).get().files.first)
        #expect(staged.readFromDisk)
        #expect(try await empty.reader.readWorkingTreeFileDiff(empty.dir, file: staged).get().hunks.first?.lines.count == 1)
    }
}

// MARK: - Reading the log

@Suite struct ReadLogRealTests {
    /// H-1, R-2: "renders a real merge as a two-lane graph, newest first".
    @Test("renders a real merge as a two-lane graph, newest first") func merge() async throws {
        let repo = try await SharedRepo.merge.value
        let log = try await repo.reader.readLog(repo.dir, limit: 500, skip: 0, branchScope: .all).get()
        #expect(log.commits.map(\.subject) == ["merge feature", "on main", "on feature", "root commit"])
        #expect(log.commits[0].parents.count == 2)
        #expect(log.commits[0].refs.contains("HEAD") && log.commits[0].refs.contains("main"))
        #expect(assignLanes(log.commits).laneCount == 2)
        #expect(log.root == repo.dir)
        #expect(!log.hasMore)
        #expect(!log.hasUncommittedChanges)
    }

    /// B-4: "reads the branch HEAD is on".
    @Test("reads the branch HEAD is on") func head() async throws {
        let repo = try await TempRepo.clone(of: SharedRepo.merge)
        let log = try await repo.reader.readLog(repo.dir, limit: 500, skip: 0, branchScope: .all).get()
        #expect(log.head == .branch(name: "main"))
        let root = try #require(await repo.git("rev-list", "--max-parents=0", "HEAD"))
        await repo.git("checkout", "-q", "--detach", root)
        let detached = try await repo.reader.readLog(repo.dir, limit: 500, skip: 0, branchScope: .all).get()
        #expect(detached.head == .detached(hash: root))
    }

    /// H-10: hasMore from asking for one more.
    @Test func pagesWithHasMore() async throws {
        let repo = try await SharedRepo.merge.value
        let first = try await repo.reader.readLog(repo.dir, limit: 2, skip: 0, branchScope: .all).get()
        #expect(first.commits.count == 2)
        #expect(first.hasMore)
        let second = try await repo.reader.readLog(repo.dir, limit: 2, skip: 2, branchScope: .all).get()
        #expect(second.commits.map(\.subject) == ["on feature", "root commit"])
        #expect(!second.hasMore)
    }

    /// P-1, P-2: "shows a real commit's files, with counts from git itself".
    @Test("shows a real commit’s files, with counts from git itself") func commitFiles() async throws {
        let repo = try await SharedRepo.merge.value
        let hash = try #require(await repo.git("rev-parse", "main~1"))  // on main
        let detail = try await repo.reader.readCommit(repo.dir, hash: hash).get()
        #expect(detail.message == "on main")
        #expect(detail.author == "Ann Example")
        #expect(detail.authorEmail == "ann@example.com")
        #expect(detail.files == [ChangedFile(path: "main.txt", insertions: 2, deletions: 0)])
    }

    /// P-3: "a merge commit still lists the files it brought in".
    @Test("a merge commit still lists the files it brought in") func mergeFiles() async throws {
        let repo = try await SharedRepo.merge.value
        let head = try #require(await repo.git("rev-parse", "HEAD"))
        let detail = try await repo.reader.readCommit(repo.dir, hash: head).get()
        #expect(detail.parents.count == 2)
        #expect(detail.files.map(\.path) == ["feature.txt"])
    }

    /// P-3: "a root commit lists its files rather than coming back empty".
    @Test("a root commit lists its files rather than coming back empty") func rootFiles() async throws {
        let repo = try await SharedRepo.merge.value
        let root = try #require(await repo.git("rev-list", "--max-parents=0", "HEAD"))
        let detail = try await repo.reader.readCommit(repo.dir, hash: root).get()
        #expect(detail.parents == [])
        #expect(detail.files == [ChangedFile(path: "root.txt", insertions: 1, deletions: 0)])
    }

    @Test func aBinaryFileHasNoCounts() async throws {
        let repo = try await TempRepo.clone(of: SharedRepo.empty)
        try Data([0, 1, 2, 3]).write(to: URL(filePath: repo.dir + "/blob.bin"))
        await repo.git("add", "-A")
        await repo.git("commit", "-q", "-m", "binary")
        let head = try #require(await repo.git("rev-parse", "HEAD"))
        let detail = try await repo.reader.readCommit(repo.dir, hash: head).get()
        #expect(detail.files == [ChangedFile(path: "blob.bin", insertions: nil, deletions: nil)])
    }

    /// E-1: "a directory that is not a repository says so, and stays usable".
    @Test("a directory that is not a repository says so, and stays usable") func notARepo() async throws {
        let plain = try TempRepo(prefix: "tabs-git-plain-")
        let result = await plain.reader.readLog(plain.dir, limit: 500, skip: 0, branchScope: .all)
        guard case .failure(let error) = result else {
            Issue.record("expected a failure")
            return
        }
        #expect(error.reason == .notARepo(path: plain.dir))
    }

    /// E-2: "a repository with no commits is told apart from a non-repository".
    @Test("a repository with no commits is told apart from a non-repository") func noCommits() async throws {
        let empty = try await SharedRepo.empty.value
        for scope in [GitBranchScope.local, .all] {
            let result = await empty.reader.readLog(empty.dir, limit: 500, skip: 0, branchScope: scope)
            guard case .failure(let error) = result else {
                Issue.record("expected a failure for \(scope)")
                continue
            }
            #expect(error.reason == .noCommits(root: empty.dir))
        }
        // `git log HEAD` on an unborn branch fails outright, so the
        // current-branch scope shows git's own words.
        let current = await empty.reader.readLog(empty.dir, limit: 500, skip: 0, branchScope: .current)
        guard case .failure(let error) = current, case .failed(let message) = error.reason else {
            Issue.record("expected git's own failure")
            return
        }
        #expect(message.contains("ambiguous argument 'HEAD'"))
    }

    /// E-4: "a directory that does not exist says so, not that git is missing".
    @Test("a directory that does not exist says so, not that git is missing") func noSuchDirectory() async throws {
        let repo = try await SharedRepo.empty.value
        let missing = repo.dir + "/does/not/exist"
        let result = await repo.reader.readLog(missing, limit: 500, skip: 0, branchScope: .all)
        guard case .failure(let error) = result else {
            Issue.record("expected a failure")
            return
        }
        #expect(error.reason == .noSuchDirectory(path: missing))
    }

    /// E-3: git missing names itself.
    @Test func aMissingGitNamesItself() async throws {
        let repo = try await SharedRepo.empty.value
        var env = repo.environment
        env["PATH"] = repo.dir + "/no-bin-here"
        let result = await Git(environment: env).readLog(repo.dir, limit: 500, skip: 0, branchScope: .all)
        guard case .failure(let error) = result else {
            Issue.record("expected a failure")
            return
        }
        #expect(error.reason == .gitMissing)
    }

    /// H-4, P-6: "a repository with no commits but a staged file shows a
    /// selectable working-tree row, not the no-commits notice".
    @Test("a repository with no commits but a staged file shows a selectable working-tree row, not the no-commits notice")
    func noCommitsButStaged() async throws {
        let repo = try await TempRepo.clone(of: SharedRepo.empty)
        repo.write("staged.txt", "a\nb\n")
        await repo.git("add", "-A")
        let log = try await repo.reader.readLog(repo.dir, limit: 500, skip: 0, branchScope: .all).get()
        #expect(log.commits.isEmpty)
        #expect(log.hasUncommittedChanges)
        let detail = try await repo.reader.readWorkingTreeChanges(repo.dir).get()
        #expect(detail.parents == [])
        #expect(detail.files == [ChangedFile(path: "staged.txt", insertions: 2, deletions: 0, readFromDisk: true)])
    }

    /// H-4: "uncommitted changes appear as a row connected into the graph, and disappear once resolved".
    @Test("uncommitted changes appear as a row connected into the graph, and disappear once resolved") func dirtyThenClean() async throws {
        let repo = try await TempRepo.clone(of: SharedRepo.merge)
        repo.write("root.txt", "changed\n")
        #expect(try await repo.reader.readLog(repo.dir, limit: 500, skip: 0, branchScope: .all).get().hasUncommittedChanges)
        // Only the first page asks.
        #expect(try await !repo.reader.readLog(repo.dir, limit: 500, skip: 1, branchScope: .all).get().hasUncommittedChanges)
        await repo.git("checkout", "--", "root.txt")
        #expect(try await !repo.reader.readLog(repo.dir, limit: 500, skip: 0, branchScope: .all).get().hasUncommittedChanges)
    }

    /// B-2: "the branch filter narrows and widens which commits are shown, against real refs".
    @Test("the branch filter narrows and widens which commits are shown, against real refs") func branchScopes() async throws {
        let repo = try await SharedRepo.branches.value
        let current = try await repo.reader.readLog(repo.dir, limit: 500, skip: 0, branchScope: .current).get()
        #expect(current.commits.map(\.subject) == ["root commit"])
        let local = try await repo.reader.readLog(repo.dir, limit: 500, skip: 0, branchScope: .local).get()
        #expect(Set(local.commits.map(\.subject)) == ["root commit", "on feature"])
        let all = try await repo.reader.readLog(repo.dir, limit: 500, skip: 0, branchScope: .all).get()
        #expect(Set(all.commits.map(\.subject)) == ["root commit", "on feature", "on remote-only"])
    }

    /// D-4: the default directory is the app's own when it's a repository, else home.
    @Test @MainActor func defaultDirectoryPrefersARepositoryElseHome() async throws {
        let repo = try await SharedRepo.merge.value
        let plain = try TempRepo(prefix: "tabs-git-plain-")
        let inRepo = GitRepositorySource(environment: repo.environment, appDirectory: repo.dir, home: "/home/ann")
        #expect(await inRepo.defaultDirectory() == repo.dir)
        let notRepo = GitRepositorySource(environment: repo.environment, appDirectory: plain.dir, home: "/home/ann")
        #expect(await notRepo.defaultDirectory() == "/home/ann")
        let gone = GitRepositorySource(environment: repo.environment, appDirectory: nil, home: "/home/ann")
        #expect(await gone.defaultDirectory() == "/home/ann")
    }
}

// MARK: - Files off disk

/// P-6, P-12: a file read off disk, a chunk at a time: binary by git's rule,
/// its lines counted as git counts them, its diff's first lines kept.
@Suite struct DiskFileTests {
    private let dir = TestTemporary.directory("disk-files")

    /// 11 bytes a line, numbered from 1.
    private func numbered(_ count: Int, terminated: Bool = true) -> String {
        (1...count).map { String(format: "line %05d", $0) }.joined(separator: "\n") + (terminated ? "\n" : "")
    }

    private func write(_ name: String, _ data: Data) throws {
        try data.write(to: dir.appending(path: name))
    }

    private func unknown(_ name: String) -> ChangedFile {
        ChangedFile(path: name, insertions: nil, deletions: nil, readFromDisk: true)
    }

    @Test("binary is a NUL in the first 8000 bytes, and only there") func binaryByGitsRule() throws {
        var early = Data(repeating: 0x61, count: 9000)
        early[7999] = 0
        var late = Data(repeating: 0x61, count: 9000)
        late[8000] = 0
        try write("early", early)
        try write("late", late)
        #expect(Git.fileStatsFromDisk(dir.path, "early") == unknown("early"))
        #expect(try Git.diffFromDisk(dir.path, "early").get() == FileDiff(binary: true))
        #expect(Git.fileStatsFromDisk(dir.path, "late") == ChangedFile(path: "late", insertions: 1, deletions: 0, readFromDisk: true))
        #expect(try Git.diffFromDisk(dir.path, "late").get().binary == false)
    }

    @Test("lines are counted across chunks, as git counts them") func linesAcrossChunks() throws {
        let long = numbered(20_000)
        #expect(long.utf8.count > 3 * Git.diskChunk)
        try write("long", Data(long.utf8))
        #expect(Git.fileStatsFromDisk(dir.path, "long").insertions == 20_000)
        try write("unterminated", Data(numbered(20_000, terminated: false).utf8))
        #expect(Git.fileStatsFromDisk(dir.path, "unterminated").insertions == 20_000)
        // A newline as a chunk's last byte, then one more line.
        try write("edge", Data((String(repeating: "x", count: Git.diskChunk - 1) + "\ny").utf8))
        #expect(Git.fileStatsFromDisk(dir.path, "edge").insertions == 2)
        try write("empty", Data())
        #expect(Git.fileStatsFromDisk(dir.path, "empty").insertions == 0)
        #expect(Git.fileStatsFromDisk(dir.path, "missing") == unknown("missing"))
        try FileManager.default.createDirectory(at: dir.appending(path: "folder"), withIntermediateDirectories: false)
        #expect(Git.fileStatsFromDisk(dir.path, "folder") == unknown("folder"))
    }

    @Test("a long file's diff keeps its first 2,000 lines, read across chunks") func longDiff() throws {
        try write("long", Data(numbered(20_000).utf8))
        let diff = try Git.diffFromDisk(dir.path, "long").get()
        let hunk = try #require(diff.hunks.first)
        #expect(diff.truncated)
        #expect(hunk.newCount == 20_000)
        #expect(hunk.lines.count == Git.diffLineCap)
        #expect(hunk.lines.first == FileDiff.Line(kind: .added, text: "line 00001", new: 1))
        #expect(hunk.lines.last == FileDiff.Line(kind: .added, text: "line 02000", new: 2000))
        // Exactly the cap, unterminated: every line, then the note.
        try write("capped", Data(numbered(Git.diffLineCap, terminated: false).utf8))
        let whole = try Git.diffFromDisk(dir.path, "capped").get()
        #expect(!whole.truncated)
        #expect(whole.hunks.first?.lines.count == Git.diffLineCap + 1)
        #expect(whole.hunks.first?.lines.last == FileDiff.Line(kind: .note, text: "\\ No newline at end of file"))
        try write("empty", Data())
        #expect(try Git.diffFromDisk(dir.path, "empty").get() == FileDiff())
    }

    @Test("a read goes no further than its limit, and says the file goes on") func limit() throws {
        try write("lines", Data(numbered(100).utf8))
        let path = dir.appending(path: "lines").path
        let cut = try #require(Git.readDiskFile(path, keepLines: 2, limit: 110))
        #expect(cut.cut)
        #expect(cut.lineCount == 10)
        #expect(cut.head == Data("line 00001\nline 00002\n".utf8))
        let whole = try #require(Git.readDiskFile(path, limit: 1_100))
        #expect(!whole.cut)
        #expect(whole.lineCount == 100)
        #expect(whole.head.isEmpty, "no lines kept unless asked for")
    }
}

// MARK: - The runner

/// E-7: a run always answers, whatever the process does with its output or
/// with SIGTERM. Driven with `/bin/sh`, standing in for a git whose hook
/// misbehaves, or a git that won't stop.
@Suite struct GitProcessTests {
    private func sh(_ script: String, timeout: Duration, drainGrace: Duration = GitProcess.drainGrace) async -> (
        outcome: GitProcess.Outcome, elapsed: Duration
    ) {
        let clock = ContinuousClock()
        let start = clock.now
        let outcome = await GitProcess.run(
            executable: "/bin/sh", arguments: ["-c", script], directory: "/", environment: ProcessInfo.processInfo.environment,
            timeout: timeout, maxBuffer: Git.maxBuffer, drainGrace: drainGrace)
        return (outcome, start.duration(to: clock.now))
    }

    /// The grace after an exit counts only once the pipes are quiet: output
    /// still waiting in a pipe when it ends, its reader not yet run (a loaded
    /// machine), is read, not dropped. No grace at all makes every run hit
    /// that moment; answering at the grace regardless lost the file list of
    /// a commit's detail under `make test`.
    @Test("an exit's whole output is answered, however late its reader runs") func outputWaitingAtTheGrace() async throws {
        let expected = (1...2_000).map { "\($0)\n" }.joined()
        let outcomes = await withTaskGroup(of: GitProcess.Outcome.self) { group in
            for _ in 0..<40 { group.addTask { await sh("seq 1 2000; seq 1 2000 >&2", timeout: .seconds(20), drainGrace: .zero).outcome } }
            return await group.reduce(into: []) { $0.append($1) }
        }
        for outcome in outcomes {
            guard case .exited(let status, let stdout, let stderr) = outcome else {
                Issue.record("expected an exit, got \(outcome)")
                continue
            }
            #expect(status == 0)
            #expect(stdout == expected, "stdout: \(stdout.count) of \(expected.count) bytes")
            #expect(stderr == expected, "stderr: \(stderr.count) of \(expected.count) bytes")
        }
    }

    /// A post-checkout hook that puts a job in the background without
    /// redirecting its output: the job holds stderr after git has exited.
    @Test("an exit is answered soon, though a job it left running still holds stderr") func aBackgroundJobHoldingStderr() async throws {
        let (outcome, elapsed) = await sh("sleep 30 >/dev/null & echo $!; echo said >&2; exit 3", timeout: .seconds(20))
        guard case .exited(let status, let stdout, let stderr) = outcome else {
            Issue.record("expected an exit, got \(outcome)")
            return
        }
        let job = try #require(pid_t(stdout.trimmingCharacters(in: .whitespacesAndNewlines)))
        defer { kill(job, SIGKILL) }
        #expect(kill(job, 0) == 0, "the job is still running, holding stderr")
        #expect(status == 3)
        #expect(stderr == "said\n")
        #expect(elapsed < .seconds(10), "answered \(elapsed) in: not when the job ends (30 s), nor at the timeout (20 s)")
    }

    /// A process that won't stop for SIGTERM (git stuck in I/O stops for
    /// neither): answered at the timeout, then killed.
    @Test("a process ignoring SIGTERM is answered at the timeout, then killed") @MainActor func aProcessIgnoringSigterm() async throws {
        let (outcome, elapsed) = await sh("trap '' TERM; echo $$ >&2; exec sleep 30", timeout: .seconds(2))
        guard case .timedOut(let stderr) = outcome else {
            Issue.record("expected a timeout, got \(outcome)")
            return
        }
        let pid = try #require(pid_t(stderr.trimmingCharacters(in: .whitespacesAndNewlines)))
        #expect(elapsed < .seconds(8), "answered \(elapsed) in: at the timeout (2 s), not when the process ends (30 s)")
        let killed = await eventually(timeout: .seconds(15)) { kill(pid, 0) != 0 }
        if !killed { kill(pid, SIGKILL) }
        #expect(killed, "killed after SIGTERM's grace")
    }
}
