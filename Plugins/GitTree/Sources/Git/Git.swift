import Foundation
import os

/// Reading a repository by running the user's `git`.
///
/// `git` rather than a library: no dependency, and the user's own git (their
/// config, their `includeIf` rules) is the one whose answer they expect.
///
/// Two rules hold everywhere here.
///
/// **Asynchronous, always.** Nothing blocks the main thread, and nothing runs
/// at quit: the plugin has nothing to flush and no process to tear down.
///
/// **Never a throw.** Every failure (git missing, not a repository, an empty
/// repository, a hash that doesn't exist) comes back as a `GitError`, because
/// all of them are ordinary states for a pane to be in.
struct Git: Sendable {
    /// The environment every invocation runs with: the pane's
    /// `childEnvironment`, never this process's own (`setenv` is every plugin's).
    var environment: [String: String]

    /// How long one invocation may take: past it the call fails at once, and
    /// git is stopped (SIGTERM, then SIGKILL: `GitProcess`). A repository on a
    /// stalled network mount, or a hook that never ends, must not wedge a pane.
    static let timeout: Duration = .seconds(10)
    /// Output cap per invocation. A 5,000-file merge lands far under this.
    static let maxBuffer = 32 * 1024 * 1024
    /// Files listed for one commit. A vendored-dependency bump can touch tens
    /// of thousands; past this the list stops being readable and becomes a
    /// drawing cost, so it's cut and the panel says so.
    static let fileCap = 500
    /// How many lines of a checkout refusal to keep: generous for the file
    /// lists git's dirty-tree message gives, bounded against a pathological one.
    static let checkoutErrorMaxLines = 20

    /// Field separator: ASCII unit separator, which no ref name, path or
    /// subject line can contain.
    static let sep: Character = "\u{1f}"

    /// Args every invocation carries. `core.quotePath=false` keeps non-ASCII
    /// paths as raw UTF-8 instead of octal escapes; `--no-pager` because a
    /// pager on a non-tty is useless, and saying so costs nothing.
    static let baseArgs = ["-c", "core.quotePath=false", "--no-pager"]

    init(environment: [String: String]) {
        self.environment = environment
    }

    struct Output: Sendable {
        var stdout: String
    }

    /// One `git` invocation in `cwd`, every failure mapped to a `GitFailure`.
    ///
    /// Classified on stderr text, which is all git offers: exit codes are 1 or
    /// 128 for nearly everything. The phrases matched ("not a git repository",
    /// "does not have any commits yet") have been stable for over a decade;
    /// anything unrecognized becomes `failed` with git's own words.
    ///
    /// The raw stderr rides along on every failure as `detail`; only
    /// `checkout` keeps it.
    func run(_ cwd: String, _ args: [String]) async -> Result<Output, GitError> {
        var env = environment
        // A repository's hooks and config must not be able to prompt: an
        // editor or credential helper waiting on stdin would hang the call
        // until the timeout.
        env["GIT_TERMINAL_PROMPT"] = "0"
        env["GIT_OPTIONAL_LOCKS"] = "0"
        let fullArgs = Self.baseArgs + args
        // "No git binary" and "no such cwd" (the path bar writes whatever was
        // typed) are told apart by a stat: "git isn't installed" is wrong for
        // a typo.
        guard let executable = Self.findExecutable("git", path: env["PATH"]) else {
            return .failure(GitError(Self.pathExists(cwd) ? .gitMissing : .noSuchDirectory(path: cwd), detail: ""))
        }
        guard Self.pathExists(cwd) else {
            return .failure(GitError(.noSuchDirectory(path: cwd), detail: ""))
        }
        let result = await GitProcess.run(
            executable: executable, arguments: fullArgs, directory: cwd, environment: env,
            timeout: Self.timeout, maxBuffer: Self.maxBuffer)
        switch result {
        case .exited(0, let stdout, _):
            return .success(Output(stdout: stdout))
        case .exited(_, _, let stderr):
            let trimmed = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            return .failure(
                GitError(
                    Self.classify(stderr: stderr, message: "Command failed: git \(fullArgs.joined(separator: " "))", cwd: cwd),
                    detail: trimmed))
        case .launchFailed(let message):
            return .failure(GitError(.failed(message: Self.firstLine(message)), detail: ""))
        case .timedOut(let stderr), .overflowed(let stderr):
            let trimmed = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            let command = "Command failed: git \(fullArgs.joined(separator: " "))"
            let message = result.isOverflow ? "\(command) (more than \(Self.maxBuffer / (1024 * 1024)) MB of output)" : command
            return .failure(GitError(Self.classify(stderr: stderr, message: message, cwd: cwd), detail: trimmed))
        }
    }

    static func classify(stderr: String, message fallback: String, cwd: String) -> GitFailure {
        let message = stderr.isEmpty ? fallback : stderr
        let lower = message.lowercased()
        if lower.contains("not a git repository") { return .notARepo(path: cwd) }
        // A freshly `git init`ed directory: `rev-parse --show-toplevel`
        // succeeds and only `log` fails. Told apart from not-a-repo on purpose.
        if lower.contains("does not have any commits yet") || lower.contains("bad default revision") {
            return .noCommits(root: cwd)
        }
        return .failed(message: firstLine(message))
    }

    static func firstLine(_ text: String) -> String {
        let line = text.split(separator: "\n", omittingEmptySubsequences: false)
            .first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        return (line.map(String.init) ?? "git failed").trimmingCharacters(in: .whitespaces)
    }

    static func pathExists(_ path: String) -> Bool {
        FileManager.default.fileExists(atPath: path)
    }

    /// The first executable `name` along `path` (a default PATH when unset).
    static func findExecutable(_ name: String, path: String?) -> String? {
        let directories = (path ?? "/usr/bin:/bin:/usr/sbin:/sbin").split(separator: ":")
        for directory in directories where !directory.isEmpty {
            let candidate = "\(directory)/\(name)"
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }

    // MARK: Reads

    /// The repository root containing `dir`, or why there isn't one.
    func repoRoot(_ dir: String) async -> Result<String, GitError> {
        await run(dir, ["rev-parse", "--show-toplevel"]).map { $0.stdout.trimmingCharacters(in: .whitespacesAndNewlines) }
    }

    /// Ref names pointing at a commit, out of `%D`. `%D` renders the current
    /// branch as `HEAD -> main`, one decoration describing two things; split so
    /// the pane can badge HEAD without parsing an arrow.
    static func parseRefs(_ decoration: String) -> [String] {
        var refs: [String] = []
        for part in decoration.components(separatedBy: ", ") {
            let ref = part.trimmingCharacters(in: .whitespacesAndNewlines)
            if ref.isEmpty { continue }
            if ref.hasPrefix("HEAD -> ") {
                refs.append("HEAD")
                refs.append(String(ref.dropFirst("HEAD -> ".count)))
                continue
            }
            refs.append(ref)
        }
        return refs
    }

    static let logFormat = ["%H", "%P", "%an", "%aI", "%D", "%s"].joined(separator: "%x1f")

    static func parseLogLine(_ line: String) -> Commit? {
        let fields = line.split(separator: sep, omittingEmptySubsequences: false).map(String.init)
        guard fields.count >= 6 else { return nil }
        return Commit(
            hash: fields[0],
            // A root commit has an empty %P, which splitting would turn into [""].
            parents: fields[1].isEmpty ? [] : fields[1].components(separatedBy: " "),
            author: fields[2],
            date: fields[3],
            refs: parseRefs(fields[4]),
            subject: fields[5])
    }

    /// Where HEAD is. `symbolic-ref` fails exactly when it's detached.
    func readHead(_ dir: String) async -> GitHead {
        if case .success(let branch) = await run(dir, ["symbolic-ref", "--quiet", "--short", "HEAD"]) {
            return .branch(name: branch.stdout.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        let hash = await run(dir, ["rev-parse", "HEAD"])
        return .detached(hash: (try? hash.get().stdout.trimmingCharacters(in: .whitespacesAndNewlines)) ?? "HEAD")
    }

    /// The `git log` ref-selection args for each scope.
    static func scopeArgs(_ scope: GitBranchScope) -> [String] {
        switch scope {
        case .current: ["HEAD"]
        case .local: ["--branches"]
        case .all: ["--branches", "--remotes"]
        }
    }

    /// A page of history, scoped to `branchScope`. Real ref-reachable history
    /// rather than `--first-parent` (that would be a list wearing a gutter);
    /// `--date-order` keeps rows in the order a reader expects while staying a
    /// valid topological order for lane assignment.
    ///
    /// `hasMore` comes from asking for one commit more than wanted: git stops
    /// walking once it has that many, whereas counting walks the whole DAG.
    func readLog(_ dir: String, limit: Int, skip: Int, branchScope: GitBranchScope) async -> GitLogResult {
        // Independent invocations, run concurrently: git finds the repository
        // from `dir` as well as from the root.
        async let root = repoRoot(dir)
        async let result = run(
            dir,
            ["log"] + Self.scopeArgs(branchScope) + [
                "--date-order", "--parents", "--max-count=\(limit + 1)", "--skip=\(skip)", "--pretty=format:\(Self.logFormat)",
            ])
        async let head = readHead(dir)
        // Only the first page asks about the working tree: Load more keeps the
        // list's answer, and `status` (walking the whole tree and index) is the
        // most expensive call here. Submodules are ignored: a submodule pointer
        // that drifted isn't a change to this repository's own tree.
        async let status: Result<Output, GitError>? = skip == 0 ? run(dir, ["status", "--porcelain", "--ignore-submodules"]) : nil
        let (rootResult, logResult, headValue, statusResult) = await (root, result, head, status)

        let rootPath: String
        switch rootResult {
        case .failure(let error): return .failure(GitError(error.reason))
        case .success(let path): rootPath = path
        }
        // Best effort: a failed status just means nothing to report.
        let dirty = (try? statusResult?.get())?.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        let output: Output
        switch logResult {
        case .failure(let error):
            // `log` is where an empty repository fails: aim the failure at the
            // root that did resolve rather than at the directory asked about.
            if case .noCommits = error.reason { return .failure(GitError(.noCommits(root: rootPath))) }
            return .failure(GitError(error.reason))
        case .success(let value): output = value
        }

        let commits = output.stdout.split(separator: "\n").compactMap { Self.parseLogLine(String($0)) }

        // An empty repository, detected here rather than from stderr: a bare
        // `git log` in a fresh repository fails with "does not have any commits
        // yet", but a ref-reachable log (any of the three scopes) succeeds with
        // no output. Zero commits on the first page means "no commits yet",
        // unless the tree is dirty: then its row is something real to show.
        if skip == 0 && commits.isEmpty && !dirty {
            return .failure(GitError(.noCommits(root: rootPath)))
        }

        let hasMore = commits.count > limit
        return .success(
            GitLog(
                root: rootPath, head: headValue, commits: hasMore ? Array(commits.prefix(limit)) : commits, hasMore: hasMore,
                hasUncommittedChanges: dirty))
    }

    /// `--numstat` records into changed files, newline- or NUL-separated.
    /// Binary files read `-\t-\t<path>`: nil counts, since "binary" and
    /// "changed nothing" are different facts. With `-z` a rename or copy has
    /// an empty path and names its old and new paths in the next two records:
    /// the real paths, where the newline form only has git's display string.
    static func parseNumstat(_ stdout: String, separator: Character = "\n") -> (files: [ChangedFile], truncated: Bool) {
        var files: [ChangedFile] = []
        var truncated = false
        let records = stdout.split(separator: separator, omittingEmptySubsequences: false)
        var index = 0
        while index < records.count {
            let line = records[index]
            index += 1
            if line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { continue }
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            if fields.count < 3 { continue }
            var path = fields[2...].joined(separator: "\t")
            var oldPath: String?
            if separator == "\0", path.isEmpty, index + 1 < records.count {
                oldPath = String(records[index])
                path = String(records[index + 1])
                index += 2
            }
            if files.count >= fileCap {
                truncated = true
                break
            }
            files.append(
                ChangedFile(
                    path: path, insertions: fields[0] == "-" ? nil : parseLeadingInt(fields[0]),
                    deletions: fields[1] == "-" ? nil : parseLeadingInt(fields[1]), oldPath: oldPath))
        }
        return (files, truncated)
    }

    /// The leading digits as a number, nil if there are none.
    private static func parseLeadingInt(_ text: String) -> Int? {
        let digits = text.trimmingCharacters(in: .whitespacesAndNewlines).prefix { $0.isASCII && $0.isNumber }
        return Int(digits)
    }

    static let detailFormat = ["%H", "%P", "%an", "%ae", "%aI", "%D"].joined(separator: "%x1f")

    /// One commit in full. Two invocations, deliberately: `%B` holds newlines,
    /// so one `show --numstat` with the body would interleave a multi-line
    /// field with the line-oriented numstat block.
    ///
    /// `-m --first-parent` makes it work for every shape: a plain
    /// `show --numstat` prints nothing at all for a merge, and root commits
    /// diff against the empty tree either way. `-z` for a rename's real paths.
    func readCommit(_ dir: String, hash: String) async -> GitCommitResult {
        async let meta = run(dir, ["show", "--no-patch", "--format=\(Self.detailFormat)%x1f%B", hash])
        async let numstat = run(dir, ["show", "--numstat", "-z", "--format=", "-m", "--first-parent", hash])
        let (metaResult, numstatResult) = await (meta, numstat)
        let output: Output
        switch metaResult {
        case .failure(let error): return .failure(GitError(error.reason))
        case .success(let value): output = value
        }
        // The message is the last field, and %B keeps whatever is in it, so
        // everything past the sixth separator is message, joined back.
        let fields = output.stdout.split(separator: Self.sep, omittingEmptySubsequences: false).map(String.init)
        guard fields.count >= 7 else { return .failure(GitError(.failed(message: "Could not read commit \(hash)"))) }
        var message = fields[6...].joined(separator: String(Self.sep))
        while message.hasSuffix("\n") { message.removeLast() }
        let parsed = (try? numstatResult.get()).map { Self.parseNumstat($0.stdout, separator: "\0") } ?? (files: [], truncated: false)
        return .success(
            CommitDetail(
                hash: fields[0], parents: fields[1].isEmpty ? [] : fields[1].components(separatedBy: " "), author: fields[2],
                authorEmail: fields[3], date: fields[4], refs: Self.parseRefs(fields[5]), message: message, files: parsed.files,
                filesTruncated: parsed.truncated))
    }

    /// Paths out of `git status --porcelain -z`: `XY <path>` records, where a
    /// rename or copy is followed by one more record with its original path
    /// (skipped). `-z` keeps paths verbatim; without it porcelain quotes any
    /// path with a space, even with `core.quotePath=false`.
    static func parseStatusPaths(_ stdout: String) -> [String] {
        var paths: [String] = []
        let records = stdout.split(separator: "\0", omittingEmptySubsequences: false).map(String.init)
        var i = 0
        while i < records.count {
            let record = records[i]
            if record.count > 3 {
                paths.append(String(record.dropFirst(3)))
                if record.first == "R" || record.first == "C" { i += 1 }
            }
            i += 1
        }
        return paths
    }

    /// One file's stats read off disk, for the working-tree files a tracked
    /// diff has nothing to compare against (untracked, or anything when the
    /// repository has no commits yet). Every line is an insertion. Binary by
    /// git's own rule, so it gets nil counts. `root` is the repository's:
    /// status names paths from there.
    static func fileStatsFromDisk(_ root: String, _ relativePath: String) -> ChangedFile {
        // Unreadable (deleted, or renamed between the status read and this
        // one): the same "unknown" a binary file gets, not a false zero.
        guard let file = readDiskFile((root as NSString).appendingPathComponent(relativePath)), !file.binary else {
            return ChangedFile(path: relativePath, insertions: nil, deletions: nil, readFromDisk: true)
        }
        return ChangedFile(path: relativePath, insertions: file.lineCount, deletions: 0, readFromDisk: true)
    }

    /// Everything the working tree's uncommitted state touched, shaped like a
    /// commit's detail: tracked changes (staged and unstaged together) from one
    /// `git diff --numstat HEAD`, untracked files counted off disk. With no
    /// commits yet HEAD doesn't resolve, so every status entry is read from
    /// disk.
    func readWorkingTreeChanges(_ dir: String) async -> GitCommitResult {
        async let root = repoRoot(dir)
        async let head = run(dir, ["rev-parse", "HEAD"])
        // `-uall` lists an untracked directory's files, not the directory.
        async let status = run(dir, ["status", "--porcelain", "-z", "--untracked-files=all", "--ignore-submodules"])
        // `--no-renames` names a staged rename by the path status uses, not
        // `old => new`, which would list the file twice.
        async let numstat = run(dir, ["diff", "--numstat", "-z", "--no-renames", "HEAD"])
        let (rootResult, headResult, statusResult, numstatResult) = await (root, head, status, numstat)
        let rootPath: String
        switch rootResult {
        case .failure(let error): return .failure(GitError(error.reason))
        case .success(let path): rootPath = path
        }

        let tracked = (try? numstatResult.get()).map { Self.parseNumstat($0.stdout, separator: "\0") } ?? (files: [], truncated: false)
        let trackedPaths = Set(tracked.files.map(\.path))
        let statusPaths = (try? statusResult.get()).map { Self.parseStatusPaths($0.stdout) } ?? []
        let remaining = statusPaths.filter { !trackedPaths.contains($0) }
        let budget = max(Self.fileCap - tracked.files.count, 0)
        let extra = remaining.prefix(budget).map { Self.fileStatsFromDisk(rootPath, $0) }
        let headHash = try? headResult.get().stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return .success(
            CommitDetail(
                hash: uncommittedChangesHash, parents: headHash.map { [$0] } ?? [], author: "", authorEmail: "", date: "",
                refs: [], message: "Uncommitted changes", files: tracked.files + extra,
                filesTruncated: tracked.truncated || remaining.count > extra.count))
    }

    // MARK: One file's diff

    /// Lines of a diff the panel keeps for one file: a generated file's
    /// diff can run to hundreds of thousands, and past this it stops being
    /// readable and becomes a drawing cost.
    static let diffLineCap = 2000
    /// Characters kept of one line (a minified file's single line).
    static let diffLineLength = 1000
    /// Unchanged lines shown around each change.
    static let diffContext = 5

    /// What every diff read carries: the patch alone, without the user's
    /// colors, external diff tool or textconv filters (the panel parses git's
    /// own patch, and a binary file's row already says "binary").
    static let patchArgs = ["--patch", "--no-color", "--no-ext-diff", "--no-textconv", "-U\(diffContext)"]

    /// One file of a commit, against its first parent (as its stats are), and
    /// the old file's lines for the unchanged runs between hunks. A rename
    /// names both paths, so git pairs them. Run from the root: pathspecs are
    /// relative to git's directory, the files' paths to the root.
    /// `--literal-pathspecs`: a `*` or `[` in a name is that character.
    func readCommitFileDiff(_ root: String, hash: String, file: ChangedFile) async -> GitFileDiffResult {
        let paths = (file.oldPath.map { [$0] } ?? []) + [file.path]
        async let patch = run(
            root, ["--literal-pathspecs", "show", "--format="] + Self.patchArgs + ["-m", "--first-parent", hash, "--"] + paths)
        // The first parent's file: none for a root commit or an added file.
        async let base = run(root, ["cat-file", "blob", "\(hash)^1:\(file.oldPath ?? file.path)"])
        return Self.fileDiff(patch: await patch, base: await base)
    }

    /// One file of the uncommitted changes, as `readWorkingTreeChanges`
    /// counted it: tracked against HEAD, or off disk (every line added).
    func readWorkingTreeFileDiff(_ root: String, file: ChangedFile) async -> GitFileDiffResult {
        if file.readFromDisk { return Self.diffFromDisk(root, file.path) }
        async let patch = run(root, ["--literal-pathspecs", "diff"] + Self.patchArgs + ["--no-renames", "HEAD", "--", file.path])
        async let base = run(root, ["cat-file", "blob", "HEAD:\(file.path)"])
        return Self.fileDiff(patch: await patch, base: await base)
    }

    /// The patch parsed, with the old file's lines when there's one.
    private static func fileDiff(patch: Result<Output, GitError>, base: Result<Output, GitError>) -> GitFileDiffResult {
        switch patch {
        case .failure(let error): return .failure(GitError(error.reason))
        case .success(let output):
            var diff = parsePatch(output.stdout)
            diff.base = (try? base.get()).map { fileLines($0.stdout) }
            return .success(diff)
        }
    }

    /// git's unified patch for one file: the header lines (up to the first
    /// `@@`, and again after any later `diff `) skipped, but for `Binary
    /// files … differ`; every hunk line numbered from its header; cut at
    /// `diffLineCap` lines.
    static func parsePatch(_ stdout: String) -> FileDiff {
        var diff = FileDiff()
        var inHunk = false
        var old = 0
        var new = 0
        var count = 0
        for record in records(stdout) {
            let line = withoutCR(record)
            if line.hasPrefix("@@") {
                guard let header = parseHunkHeader(line) else {
                    inHunk = false
                    continue
                }
                if count >= diffLineCap {
                    diff.truncated = true
                    break
                }
                diff.hunks.append(
                    FileDiff.Hunk(
                        oldStart: header.oldStart, oldCount: header.oldCount, newStart: header.newStart, newCount: header.newCount,
                        lines: []))
                (old, new) = (header.oldStart, header.newStart)
                inHunk = true
                continue
            }
            guard inHunk, !line.hasPrefix("diff ") else {
                inHunk = false
                if line.hasPrefix("Binary files ") && line.hasSuffix(" differ") { diff.binary = true }
                continue
            }
            let kind: FileDiff.Kind
            switch line.first {
            case " ": kind = .context
            case "+": kind = .added
            case "-": kind = .removed
            case "\\": kind = .note
            // The patch's trailing newline, or anything git adds that isn't a line.
            default: continue
            }
            if count >= diffLineCap {
                diff.truncated = true
                break
            }
            count += 1
            var entry = FileDiff.Line(kind: kind, text: displayLine(kind == .note ? line : line.dropFirst()))
            switch kind {
            case .context:
                (entry.old, entry.new) = (old, new)
                old += 1
                new += 1
            case .added:
                entry.new = new
                new += 1
            case .removed:
                entry.old = old
                old += 1
            case .note: break
            }
            diff.hunks[diff.hunks.count - 1].lines.append(entry)
        }
        return diff
    }

    /// `@@ -a,b +c,d @@ …`: a count left out is 1.
    static func parseHunkHeader(_ line: Substring) -> (oldStart: Int, oldCount: Int, newStart: Int, newCount: Int)? {
        let parts = line.split(separator: " ")
        guard parts.count >= 3, parts[0] == "@@", parts[1].hasPrefix("-"), parts[2].hasPrefix("+") else { return nil }
        func range(_ text: Substring) -> (Int, Int)? {
            let numbers = text.dropFirst().split(separator: ",", omittingEmptySubsequences: false)
            guard let start = numbers.first.flatMap({ Int($0) }) else { return nil }
            guard numbers.count > 1 else { return (start, 1) }
            return Int(numbers[1]).map { (start, $0) }
        }
        guard let old = range(parts[1]), let new = range(parts[2]) else { return nil }
        return (old.0, old.1, new.0, new.1)
    }

    /// A line as the panel keeps it: at most `diffLineLength` characters.
    private static func displayLine(_ text: Substring) -> String {
        text.count > diffLineLength ? String(text.prefix(diffLineLength)) + "…" : String(text)
    }

    /// A file's text as lines, as git counts them: a trailing newline ends
    /// the last line rather than starting another; a CR before a newline
    /// isn't shown.
    static func fileLines(_ text: String) -> [String] {
        var lines = Array(records(text))
        if lines.last?.isEmpty == true { lines.removeLast() }
        return lines.map { displayLine(withoutCR($0)) }
    }

    /// `text` split at each newline, read as it's asked for (a patch cut at
    /// `diffLineCap` lines reads no further). On the scalar: Swift reads
    /// `\r\n` as one Character, so a Character split would never break a
    /// CRLF file's lines.
    private static func records(_ text: String) -> UnfoldSequence<Substring, Substring?> {
        sequence(state: Optional(text[...])) { rest in
            guard let current = rest else { return nil }
            guard let newline = current.utf8.firstIndex(of: UInt8(ascii: "\n")) else {
                rest = nil
                return current
            }
            rest = current[current.utf8.index(after: newline)...]
            return current[..<newline]
        }
    }

    /// `record` without the CR that ends a CRLF line.
    private static func withoutCR(_ record: Substring) -> Substring {
        record.utf8.last == UInt8(ascii: "\r") ? record[..<record.utf8.index(before: record.utf8.endIndex)] : record
    }

    /// An untracked file (or any, with no commits yet) as a diff: the whole
    /// file added, binary by git's rule (`binaryProbe`). Its first
    /// `diffLineCap` lines are kept, and no more of it is read than git may
    /// print for a tracked file's diff (`maxBuffer`).
    static func diffFromDisk(_ root: String, _ relativePath: String) -> GitFileDiffResult {
        let path = (root as NSString).appendingPathComponent(relativePath)
        guard let file = readDiskFile(path, keepLines: diffLineCap, limit: maxBuffer) else {
            return .failure(GitError(.failed(message: "Couldn’t read \(relativePath).")))
        }
        if file.binary { return .success(FileDiff(binary: true)) }
        guard file.lineCount > 0 else { return .success(FileDiff()) }
        let kept = fileLines(String(decoding: file.head, as: UTF8.self))
        let truncated = file.cut || file.lineCount > kept.count
        var hunk = FileDiff.Hunk(
            oldStart: 0, oldCount: 0, newStart: 1, newCount: file.lineCount,
            lines: kept.enumerated().map { FileDiff.Line(kind: .added, text: $1, new: $0 + 1) })
        if !file.endsWithNewline && !truncated {
            hunk.lines.append(FileDiff.Line(kind: .note, text: "\\ No newline at end of file"))
        }
        return .success(FileDiff(hunks: [hunk], truncated: truncated))
    }

    /// Whether `dir` is inside a work tree: only to pick a starting directory.
    func isRepo(_ dir: String) async -> Bool {
        if case .success = await repoRoot(dir) { true } else { false }
    }

    /// `for-each-ref --format` takes the separator byte literally (it doesn't
    /// interpret `%x1f`, unlike `--pretty=format:`).
    static let forEachRefFormat = "%(objectname)\u{1f}%(refname)"

    /// The raw refs behind the checkout decision: the local and
    /// remote-tracking branches at `hash`, and every local branch. One
    /// `for-each-ref` over both namespaces instead of `%D` (which interleaves
    /// local, remote-tracking, HEAD and tags). `<remote>/HEAD`, the remote's
    /// default-branch pointer, is skipped: it would double-list as a fake
    /// branch. `git remote` runs alongside so remote refs split against real
    /// remote names; if it fails, `splitRemoteRef` guesses.
    func branchesAtCommit(_ dir: String, hash: String) async -> GitBranchesAtCommitResult {
        async let refs = run(dir, ["for-each-ref", "--format=\(Self.forEachRefFormat)", "--sort=refname", "refs/heads", "refs/remotes"])
        async let remoteNames = run(dir, ["remote"])
        let (refsResult, namesResult) = await (refs, remoteNames)
        let output: Output
        switch refsResult {
        case .failure(let error): return .failure(GitError(error.reason))
        case .success(let value): output = value
        }
        var local: [String] = []
        var remoteRefs: [String] = []
        var allLocalBranches: [String] = []
        for line in output.stdout.split(separator: "\n") where !line.trimmingCharacters(in: .whitespaces).isEmpty {
            let parts = line.split(separator: Self.sep, omittingEmptySubsequences: false).map(String.init)
            let objectName = parts.first ?? ""
            let refname = parts.count > 1 ? parts[1] : ""
            if refname.hasPrefix("refs/heads/") {
                let name = String(refname.dropFirst("refs/heads/".count))
                allLocalBranches.append(name)
                if objectName == hash { local.append(name) }
            } else if refname.hasPrefix("refs/remotes/") {
                let rest = String(refname.dropFirst("refs/remotes/".count))
                if rest.hasSuffix("/HEAD") { continue }
                if objectName == hash { remoteRefs.append(rest) }
            }
        }
        let names =
            (try? namesResult.get())?.stdout.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty } ?? []
        return .success(
            BranchesAtCommit(
                local: local, remotes: remoteRefs.map { splitRemoteRef($0, remoteNames: names) }, allLocalBranches: allLocalBranches))
    }

    /// `text` unchanged within `maxLines`, else its first lines and a count of
    /// what was cut.
    static func capLines(_ text: String, _ maxLines: Int) -> String {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        if lines.count <= maxLines { return text }
        let hidden = lines.count - maxLines
        return lines.prefix(maxLines).joined(separator: "\n") + "\n… (\(hidden) more line\(hidden == 1 ? "" : "s"))"
    }

    /// The `git switch` invocation for one target.
    static func checkoutArgs(_ target: CheckoutTarget) -> [String] {
        switch target {
        case .branch(let name): ["switch", name]
        // `--track` spelled out rather than left to `branch.autoSetupMerge`,
        // the user's own setting to have changed.
        case .remoteBranch(let info): ["switch", "-c", info.name, "--track", info.ref]
        case .commit(let hash): ["switch", "--detach", hash]
        }
    }

    /// Checks out `target`. `git switch` rather than `checkout`: every target
    /// is an exact ref already, and `switch <name>` can never be mistaken for a
    /// path. Needs git 2.23+; an older git fails through the ordinary path. A
    /// refusal (changes in the way, a name that exists) is an ordinary outcome;
    /// its `detail` is git's full stderr, capped.
    func checkout(_ dir: String, _ target: CheckoutTarget) async -> GitCheckoutResult {
        switch await run(dir, Self.checkoutArgs(target)) {
        case .success: return .success(())
        case .failure(let error):
            let stderr = error.detail ?? ""
            return .failure(GitError(error.reason, detail: stderr.isEmpty ? nil : Self.capLines(stderr, Self.checkoutErrorMaxLines)))
        }
    }
}

// MARK: - Files off disk

extension Git {
    /// git's rule for a binary file: a NUL in its first 8000 bytes.
    static let binaryProbe = 8000
    /// How much of a file read off disk is held at once.
    static let diskChunk = 64 * 1024

    /// A working-tree file as read off disk.
    struct DiskFile: Equatable {
        /// By git's rule (`binaryProbe`); nothing else is read then.
        var binary = false
        /// Its lines as git counts them: a trailing newline ends the last line
        /// rather than starting another.
        var lineCount = 0
        /// Its first lines' bytes, newlines included: as many as were asked for.
        var head = Data()
        var endsWithNewline = false
        /// It goes on past the bytes read.
        var cut = false
    }

    /// Reads the file at `path` a chunk at a time (`diskChunk`), holding no
    /// more than one chunk and its first `keepLines` lines, and no further
    /// than `limit` bytes. nil when it can't be read.
    static func readDiskFile(_ path: String, keepLines: Int = 0, limit: Int = .max) -> DiskFile? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        var file = DiskFile()
        var read = 0
        var newlines = 0
        var kept = 0
        var last: UInt8?
        while read < limit {
            let chunk: Data
            do {
                // A directory opens, and fails here.
                guard let next = try handle.read(upToCount: min(diskChunk, limit - read)), !next.isEmpty else { break }
                chunk = next
            } catch {
                return nil
            }
            if read < binaryProbe, chunk.prefix(binaryProbe - read).contains(0) { return DiskFile(binary: true) }
            if kept < keepLines {
                // Up to and including the newline that ends the last line kept.
                var end = chunk.startIndex
                while kept < keepLines, let newline = chunk[end...].firstIndex(of: 0x0a) {
                    kept += 1
                    end = chunk.index(after: newline)
                }
                file.head.append(chunk[chunk.startIndex..<(kept < keepLines ? chunk.endIndex : end)])
            }
            newlines += newlineCount(chunk)
            read += chunk.count
            last = chunk.last
        }
        if read >= limit, let more = try? handle.read(upToCount: 1), !more.isEmpty { file.cut = true }
        file.endsWithNewline = last == 0x0a
        file.lineCount = newlines + (last == nil || file.endsWithNewline ? 0 : 1)
        return file
    }

    private static func newlineCount(_ data: Data) -> Int {
        data.withUnsafeBytes { bytes in
            guard var cursor = bytes.baseAddress else { return 0 }
            let end = cursor + bytes.count
            var count = 0
            while cursor < end, let newline = memchr(cursor, 0x0a, end - cursor) {
                count += 1
                cursor = UnsafeRawPointer(newline) + 1
            }
            return count
        }
    }
}
