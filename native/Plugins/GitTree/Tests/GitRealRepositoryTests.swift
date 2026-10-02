import Foundation
import Testing

// Against real repositories, as the Electron app's `main/__tests__/git.test.ts`
// does (names kept), plus the premises of `e2e/git-tree.spec.ts` that are
// about what git answers (built like `e2e/helpers/gitRepo.ts`: pinned
// identity and dates). Case ids are docs/GIT-TREE.md's.

/// A temporary repository, removed when the test's value goes away.
final class TempRepo {
    let dir: String
    /// The whole environment for our git runs: the process's own, with HOME
    /// pointing into the scratch directory (the user's global config can't
    /// interfere) and a pinned identity.
    let environment: [String: String]

    init(prefix: String = "tabs-git-test-", initialize: Bool = true) {
        let base = URL(filePath: NSTemporaryDirectory()).appending(path: "\(prefix)\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        // Resolved: /var is a symlink to /private/var, and git reports the resolved form.
        dir = base.path.withCString { path in
            guard let resolved = realpath(path, nil) else { return base.path }
            defer { free(resolved) }
            return String(cString: resolved)
        }
        let home = dir + "-home"
        try? FileManager.default.createDirectory(atPath: home, withIntermediateDirectories: true)
        var env = ProcessInfo.processInfo.environment
        env["HOME"] = home
        env["GIT_CONFIG_NOSYSTEM"] = "1"
        env["GIT_AUTHOR_NAME"] = "Ann Example"
        env["GIT_AUTHOR_EMAIL"] = "ann@example.com"
        env["GIT_COMMITTER_NAME"] = "Ann Example"
        env["GIT_COMMITTER_EMAIL"] = "ann@example.com"
        environment = env
        if initialize { git("init", "-q", "-b", "main") }
    }

    deinit {
        try? FileManager.default.removeItem(atPath: dir)
        try? FileManager.default.removeItem(atPath: dir + "-home")
    }

    var reader: Git { Git(environment: environment) }

    /// Runs git synchronously with a pinned date; returns trimmed stdout, nil on failure.
    @discardableResult
    func git(_ args: String..., date: String = "2026-01-01T00:00:00+00:00") -> String? {
        run(args, date: date)
    }

    @discardableResult
    func run(_ args: [String], date: String = "2026-01-01T00:00:00+00:00") -> String? {
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/env")
        process.arguments = ["git"] + args
        process.currentDirectoryURL = URL(filePath: dir)
        var env = environment
        env["GIT_AUTHOR_DATE"] = date
        env["GIT_COMMITTER_DATE"] = date
        process.environment = env
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func write(_ path: String, _ text: String) {
        let url = URL(filePath: dir).appending(path: path)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? text.write(to: url, atomically: true, encoding: .utf8)
    }

    func read(_ path: String) -> String { (try? String(contentsOfFile: dir + "/" + path, encoding: .utf8)) ?? "" }

    /// `createRepoWithMerge`: root, on feature, on main, merge feature (--no-ff).
    static func withMerge() -> TempRepo {
        let repo = TempRepo(prefix: "tabs-git-merge-")
        repo.write("root.txt", "root\n")
        repo.git("add", "-A")
        repo.git("commit", "-q", "-m", "root commit")
        repo.git("checkout", "-q", "-b", "feature")
        repo.write("feature.txt", "feature\n")
        repo.git("add", "-A", date: "2026-01-02T00:00:00+00:00")
        repo.git("commit", "-q", "-m", "on feature", date: "2026-01-02T00:00:00+00:00")
        repo.git("checkout", "-q", "main")
        repo.write("main.txt", "main\nsecond line\n")
        repo.git("add", "-A", date: "2026-01-03T00:00:00+00:00")
        repo.git("commit", "-q", "-m", "on main", date: "2026-01-03T00:00:00+00:00")
        repo.git("merge", "-q", "--no-ff", "feature", "-m", "merge feature", date: "2026-01-04T00:00:00+00:00")
        return repo
    }

    /// `createRepoWithBranches`: main (1 commit), local feature (+1), remote-only ref (+1), and a tag.
    static func withBranches() -> TempRepo {
        let repo = TempRepo(prefix: "tabs-git-branches-")
        repo.git("remote", "add", "origin", "https://example.invalid/repo.git")
        repo.write("root.txt", "root\n")
        repo.git("add", "-A")
        repo.git("commit", "-q", "-m", "root commit")
        repo.git("checkout", "-q", "-b", "feature")
        repo.write("feature.txt", "feature\n")
        repo.git("add", "-A", date: "2026-01-02T00:00:00+00:00")
        repo.git("commit", "-q", "-m", "on feature", date: "2026-01-02T00:00:00+00:00")
        repo.git("checkout", "-q", "main")
        repo.git("checkout", "-q", "-b", "remote-only")
        repo.write("remote.txt", "remote\n")
        repo.git("add", "-A", date: "2026-01-03T00:00:00+00:00")
        repo.git("commit", "-q", "-m", "on remote-only", date: "2026-01-03T00:00:00+00:00")
        repo.git("update-ref", "refs/remotes/origin/remote-only", "remote-only")
        repo.git("checkout", "-q", "main")
        repo.git("branch", "-D", "remote-only")
        // A tag on an otherwise unreachable commit: no scope may show it.
        repo.git("checkout", "-q", "--detach")
        repo.write("tagged.txt", "tagged\n")
        repo.git("add", "-A", date: "2026-01-04T00:00:00+00:00")
        repo.git("commit", "-q", "-m", "only tagged", date: "2026-01-04T00:00:00+00:00")
        repo.git("tag", "v-orphan")
        repo.git("checkout", "-q", "main")
        return repo
    }
}

// MARK: - git.test.ts

/// The Electron test's fixture: one commit with `orig.txt`.
private func initialRepo() -> TempRepo {
    let repo = TempRepo()
    repo.write("orig.txt", "one\ntwo\n")
    repo.git("add", ".")
    repo.git("commit", "-q", "-m", "initial")
    return repo
}

private func changedPaths(_ repo: TempRepo) async throws -> [String] {
    try await repo.reader.readWorkingTreeChanges(repo.dir).get().files.map(\.path).sorted()
}

/// P-6
@Suite("readWorkingTreeChanges") struct ReadWorkingTreeChangesTests {
    @Test("names an untracked path with a space verbatim, with its real line count") func untrackedWithSpace() async throws {
        let repo = initialRepo()
        repo.write("a b.txt", "x\ny\nz\n")
        let detail = try await repo.reader.readWorkingTreeChanges(repo.dir).get()
        #expect(detail.files == [ChangedFile(path: "a b.txt", insertions: 3, deletions: 0)])
    }

    @Test("lists an untracked directory's files, not the directory") func untrackedDirectory() async throws {
        let repo = initialRepo()
        repo.write("d/one.txt", "a\n")
        repo.write("d/two.txt", "b\n")
        #expect(try await changedPaths(repo) == ["d/one.txt", "d/two.txt"])
    }

    @Test("lists a staged rename once, as the deletion and the new path") func stagedRename() async throws {
        let repo = initialRepo()
        repo.git("mv", "orig.txt", "renamed.txt")
        #expect(try await changedPaths(repo) == ["orig.txt", "renamed.txt"])
    }

    @Test func isShapedLikeACommitsDetailWithHeadAsItsParent() async throws {
        let repo = initialRepo()
        repo.write("orig.txt", "one\n")
        let detail = try await repo.reader.readWorkingTreeChanges(repo.dir).get()
        #expect(detail.hash == uncommittedChangesHash)
        #expect(detail.message == "Uncommitted changes")
        #expect(detail.parents == [repo.git("rev-parse", "HEAD")!])
        #expect(detail.files == [ChangedFile(path: "orig.txt", insertions: 0, deletions: 1)])
    }
}

/// C-11
@Suite("branchesAtCommit") struct BranchesAtCommitTests {
    @Test("reports the one local branch at the initial commit") func oneLocal() async throws {
        let repo = initialRepo()
        let initialBranch = repo.git("rev-parse", "--abbrev-ref", "HEAD")!
        let head = repo.git("rev-parse", "HEAD")!
        let result = try await repo.reader.branchesAtCommit(repo.dir, hash: head).get()
        #expect(result.local == [initialBranch])
        #expect(result.remotes == [])
        #expect(result.allLocalBranches == [initialBranch])
    }

    @Test("reports every local branch when several point at the same commit") func severalLocal() async throws {
        let repo = initialRepo()
        let initialBranch = repo.git("rev-parse", "--abbrev-ref", "HEAD")!
        let head = repo.git("rev-parse", "HEAD")!
        repo.git("branch", "stable")
        let result = try await repo.reader.branchesAtCommit(repo.dir, hash: head).get()
        #expect(result.local.sorted() == [initialBranch, "stable"].sorted())
    }

    @Test("reports a commit reachable only through a remote-tracking ref, matched against the real configured remote")
    func remoteOnly() async throws {
        let repo = initialRepo()
        repo.git("remote", "add", "origin", "https://example.invalid/repo.git")
        let initialBranch = repo.git("rev-parse", "--abbrev-ref", "HEAD")!
        repo.git("checkout", "-q", "-b", "feature")
        repo.write("feature.txt", "x\n")
        repo.git("add", "-A")
        repo.git("commit", "-q", "-m", "on feature")
        let featureHead = repo.git("rev-parse", "HEAD")!
        repo.git("update-ref", "refs/remotes/origin/feature-x", "feature")
        repo.git("checkout", "-q", initialBranch)
        repo.git("branch", "-D", "feature")
        let result = try await repo.reader.branchesAtCommit(repo.dir, hash: featureHead).get()
        #expect(result.local == [])
        #expect(result.remotes == [RemoteRefInfo(remote: "origin", name: "feature-x", ref: "origin/feature-x")])
        #expect(result.allLocalBranches == [initialBranch])
    }

    @Test("excludes refs/remotes/origin/HEAD, the remote symref, as its own fake branch") func excludesRemoteHead() async throws {
        let repo = initialRepo()
        repo.git("remote", "add", "origin", "https://example.invalid/repo.git")
        let head = repo.git("rev-parse", "HEAD")!
        repo.git("update-ref", "refs/remotes/origin/main-mirror", head)
        repo.git("symbolic-ref", "refs/remotes/origin/HEAD", "refs/remotes/origin/main-mirror")
        let refs = try await repo.reader.branchesAtCommit(repo.dir, hash: head).get().remotes.map(\.ref)
        #expect(refs.contains("origin/main-mirror"))
        #expect(!refs.contains("origin/HEAD"))
    }

    @Test("reports no branch at all for a commit no ref points at") func noBranch() async throws {
        let repo = initialRepo()
        repo.write("orig.txt", "one\ntwo\nthree\n")
        repo.git("commit", "-q", "-am", "second commit")
        let first = repo.git("rev-parse", "HEAD~1")!
        let result = try await repo.reader.branchesAtCommit(repo.dir, hash: first).get()
        #expect(result.local == [])
        #expect(result.remotes == [])
    }
}

/// C-11
@Suite("checkout") struct CheckoutRealTests {
    @Test("switches to a local branch") func switchesToLocal() async throws {
        let repo = initialRepo()
        let initialBranch = repo.git("rev-parse", "--abbrev-ref", "HEAD")!
        repo.git("checkout", "-q", "-b", "feature")
        repo.write("feature.txt", "x\n")
        repo.git("add", "-A")
        repo.git("commit", "-q", "-m", "on feature")
        repo.git("checkout", "-q", initialBranch)
        let result = await repo.reader.checkout(repo.dir, .branch(name: "feature"))
        #expect((try? result.get()) != nil)
        #expect(repo.git("rev-parse", "--abbrev-ref", "HEAD") == "feature")
    }

    @Test("creates a local tracking branch from a remote-tracking-only ref") func createsTracking() async throws {
        let repo = initialRepo()
        repo.git("remote", "add", "origin", "https://example.invalid/repo.git")
        let initialBranch = repo.git("rev-parse", "--abbrev-ref", "HEAD")!
        repo.git("checkout", "-q", "-b", "feature")
        repo.write("feature.txt", "x\n")
        repo.git("add", "-A")
        repo.git("commit", "-q", "-m", "on feature")
        repo.git("update-ref", "refs/remotes/origin/feature-x", "feature")
        repo.git("checkout", "-q", initialBranch)
        repo.git("branch", "-D", "feature")
        let result = await repo.reader.checkout(
            repo.dir, .remoteBranch(RemoteRefInfo(remote: "origin", name: "feature-x", ref: "origin/feature-x")))
        #expect((try? result.get()) != nil)
        #expect(repo.git("rev-parse", "--abbrev-ref", "HEAD") == "feature-x")
        #expect(repo.git("rev-parse", "--abbrev-ref", "feature-x@{u}") == "origin/feature-x")
    }

    @Test("detaches HEAD at a bare commit hash") func detaches() async throws {
        let repo = initialRepo()
        repo.write("orig.txt", "one\ntwo\nthree\n")
        repo.git("commit", "-q", "-am", "second commit")
        let first = repo.git("rev-parse", "HEAD~1")!
        let result = await repo.reader.checkout(repo.dir, .commit(hash: first))
        #expect((try? result.get()) != nil)
        #expect(repo.git("rev-parse", "HEAD") == first)
        #expect(repo.git("symbolic-ref", "-q", "HEAD") == nil)
    }

    @Test("refuses a checkout that would overwrite uncommitted changes, leaves HEAD untouched, and keeps the full refusal text")
    func refusesDirty() async throws {
        let repo = initialRepo()
        let initialBranch = repo.git("rev-parse", "--abbrev-ref", "HEAD")!
        repo.git("checkout", "-q", "-b", "feature")
        repo.write("orig.txt", "one\ntwo\non feature\n")
        repo.git("commit", "-q", "-am", "diverge on feature")
        repo.git("checkout", "-q", initialBranch)
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
        #expect(repo.git("rev-parse", "--abbrev-ref", "HEAD") == initialBranch)
        #expect(repo.read("orig.txt").contains("local edit, uncommitted"))
    }

    @Test(
        "refuses to create a tracking branch whose name collides with an existing local branch elsewhere — the real behavior decideCheckout filters around"
    )
    func refusesCollision() async throws {
        let repo = initialRepo()
        repo.git("remote", "add", "origin", "https://example.invalid/repo.git")
        repo.git("update-ref", "refs/remotes/origin/feature", repo.git("rev-parse", "HEAD")!)
        repo.git("branch", "feature")
        let result = await repo.reader.checkout(
            repo.dir, .remoteBranch(RemoteRefInfo(remote: "origin", name: "feature", ref: "origin/feature")))
        guard case .failure(let error) = result else {
            Issue.record("expected a refusal")
            return
        }
        #expect((error.detail ?? "").contains("a branch named 'feature' already exists"))
    }
}

// MARK: - e2e/git-tree.spec.ts premises

@Suite struct ReadLogRealTests {
    /// H-1, R-2: "renders a real merge as a two-lane graph, newest first".
    @Test("renders a real merge as a two-lane graph, newest first") func merge() async throws {
        let repo = TempRepo.withMerge()
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
        let repo = TempRepo.withMerge()
        let log = try await repo.reader.readLog(repo.dir, limit: 500, skip: 0, branchScope: .all).get()
        #expect(log.head == .branch(name: "main"))
        let root = repo.git("rev-list", "--max-parents=0", "HEAD")!
        repo.git("checkout", "-q", "--detach", root)
        let detached = try await repo.reader.readLog(repo.dir, limit: 500, skip: 0, branchScope: .all).get()
        #expect(detached.head == .detached(hash: root))
    }

    /// H-10: hasMore from asking for one more.
    @Test func pagesWithHasMore() async throws {
        let repo = TempRepo.withMerge()
        let first = try await repo.reader.readLog(repo.dir, limit: 2, skip: 0, branchScope: .all).get()
        #expect(first.commits.count == 2)
        #expect(first.hasMore)
        let second = try await repo.reader.readLog(repo.dir, limit: 2, skip: 2, branchScope: .all).get()
        #expect(second.commits.map(\.subject) == ["on feature", "root commit"])
        #expect(!second.hasMore)
    }

    /// P-1, P-2: "shows a real commit's files, with counts from git itself".
    @Test("shows a real commit’s files, with counts from git itself") func commitFiles() async throws {
        let repo = TempRepo.withMerge()
        let hash = repo.git("rev-parse", "main~1")!  // on main
        let detail = try await repo.reader.readCommit(repo.dir, hash: hash).get()
        #expect(detail.message == "on main")
        #expect(detail.author == "Ann Example")
        #expect(detail.authorEmail == "ann@example.com")
        #expect(detail.files == [ChangedFile(path: "main.txt", insertions: 2, deletions: 0)])
    }

    /// P-3: "a merge commit still lists the files it brought in".
    @Test("a merge commit still lists the files it brought in") func mergeFiles() async throws {
        let repo = TempRepo.withMerge()
        let detail = try await repo.reader.readCommit(repo.dir, hash: repo.git("rev-parse", "HEAD")!).get()
        #expect(detail.parents.count == 2)
        #expect(detail.files.map(\.path) == ["feature.txt"])
    }

    /// P-3: "a root commit lists its files rather than coming back empty".
    @Test("a root commit lists its files rather than coming back empty") func rootFiles() async throws {
        let repo = TempRepo.withMerge()
        let root = repo.git("rev-list", "--max-parents=0", "HEAD")!
        let detail = try await repo.reader.readCommit(repo.dir, hash: root).get()
        #expect(detail.parents == [])
        #expect(detail.files == [ChangedFile(path: "root.txt", insertions: 1, deletions: 0)])
    }

    @Test func aBinaryFileHasNoCounts() async throws {
        let repo = TempRepo()
        try Data([0, 1, 2, 3]).write(to: URL(filePath: repo.dir + "/blob.bin"))
        repo.git("add", "-A")
        repo.git("commit", "-q", "-m", "binary")
        let detail = try await repo.reader.readCommit(repo.dir, hash: repo.git("rev-parse", "HEAD")!).get()
        #expect(detail.files == [ChangedFile(path: "blob.bin", insertions: nil, deletions: nil)])
    }

    /// E-1: "a directory that is not a repository says so, and stays usable".
    @Test("a directory that is not a repository says so, and stays usable") func notARepo() async throws {
        let plain = TempRepo(prefix: "tabs-git-plain-", initialize: false)
        let result = await plain.reader.readLog(plain.dir, limit: 500, skip: 0, branchScope: .all)
        guard case .failure(let error) = result else {
            Issue.record("expected a failure")
            return
        }
        #expect(error.reason == .notARepo(path: plain.dir))
    }

    /// E-2: "a repository with no commits is told apart from a non-repository".
    @Test("a repository with no commits is told apart from a non-repository") func noCommits() async throws {
        let empty = TempRepo(prefix: "tabs-git-empty-")
        for scope in [GitBranchScope.local, .all] {
            let result = await empty.reader.readLog(empty.dir, limit: 500, skip: 0, branchScope: scope)
            guard case .failure(let error) = result else {
                Issue.record("expected a failure for \(scope)")
                continue
            }
            #expect(error.reason == .noCommits(root: empty.dir))
        }
        // An Electron quirk, kept: `git log HEAD` on an unborn branch fails
        // outright, so the current-branch scope shows git's own words.
        let current = await empty.reader.readLog(empty.dir, limit: 500, skip: 0, branchScope: .current)
        guard case .failure(let error) = current, case .failed(let message) = error.reason else {
            Issue.record("expected git's own failure")
            return
        }
        #expect(message.contains("ambiguous argument 'HEAD'"))
    }

    /// E-4: "a directory that does not exist says so, not that git is missing".
    @Test("a directory that does not exist says so, not that git is missing") func noSuchDirectory() async throws {
        let repo = TempRepo()
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
        let repo = TempRepo()
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
        let repo = TempRepo()
        repo.write("staged.txt", "a\nb\n")
        repo.git("add", "-A")
        let log = try await repo.reader.readLog(repo.dir, limit: 500, skip: 0, branchScope: .all).get()
        #expect(log.commits.isEmpty)
        #expect(log.hasUncommittedChanges)
        let detail = try await repo.reader.readWorkingTreeChanges(repo.dir).get()
        #expect(detail.parents == [])
        #expect(detail.files == [ChangedFile(path: "staged.txt", insertions: 2, deletions: 0)])
    }

    /// H-4: "uncommitted changes appear as a row connected into the graph, and disappear once resolved".
    @Test("uncommitted changes appear as a row connected into the graph, and disappear once resolved") func dirtyThenClean() async throws {
        let repo = TempRepo.withMerge()
        repo.write("root.txt", "changed\n")
        #expect(try await repo.reader.readLog(repo.dir, limit: 500, skip: 0, branchScope: .all).get().hasUncommittedChanges)
        // Only the first page asks.
        #expect(try await !repo.reader.readLog(repo.dir, limit: 500, skip: 1, branchScope: .all).get().hasUncommittedChanges)
        repo.git("checkout", "--", "root.txt")
        #expect(try await !repo.reader.readLog(repo.dir, limit: 500, skip: 0, branchScope: .all).get().hasUncommittedChanges)
    }

    /// B-2: "the branch filter narrows and widens which commits are shown, against real refs".
    @Test("the branch filter narrows and widens which commits are shown, against real refs") func branchScopes() async throws {
        let repo = TempRepo.withBranches()
        let current = try await repo.reader.readLog(repo.dir, limit: 500, skip: 0, branchScope: .current).get()
        #expect(current.commits.map(\.subject) == ["root commit"])
        let local = try await repo.reader.readLog(repo.dir, limit: 500, skip: 0, branchScope: .local).get()
        #expect(Set(local.commits.map(\.subject)) == ["root commit", "on feature"])
        let all = try await repo.reader.readLog(repo.dir, limit: 500, skip: 0, branchScope: .all).get()
        #expect(Set(all.commits.map(\.subject)) == ["root commit", "on feature", "on remote-only"])
    }

    /// D-4: the default directory is the app's own when it's a repository, else home.
    @Test @MainActor func defaultDirectoryPrefersARepositoryElseHome() async {
        let repo = TempRepo.withMerge()
        let plain = TempRepo(prefix: "tabs-git-plain-", initialize: false)
        let inRepo = GitRepositorySource(environment: repo.environment, appDirectory: repo.dir, home: "/home/ann")
        #expect(await inRepo.defaultDirectory() == repo.dir)
        let notRepo = GitRepositorySource(environment: repo.environment, appDirectory: plain.dir, home: "/home/ann")
        #expect(await notRepo.defaultDirectory() == "/home/ann")
        let gone = GitRepositorySource(environment: repo.environment, appDirectory: nil, home: "/home/ann")
        #expect(await gone.defaultDirectory() == "/home/ann")
    }
}
