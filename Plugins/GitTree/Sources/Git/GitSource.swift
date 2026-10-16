import Foundation
import TabsPluginSDK

/// What a git tree pane asks for. Every call answers; none throws: failures
/// are `GitError` values the pane shows as sentences.
///
/// A protocol so tests and the visual capture can script what git "answers"
/// (`ScriptedGitSource`), while real git against a real repository is the
/// end-to-end tier's job.
@MainActor
protocol GitSource: AnyObject {
    /// A page of history for the repository containing `dir`, newest first,
    /// with where HEAD is.
    func log(_ dir: String, limit: Int, skip: Int, scope: GitBranchScope) async -> GitLogResult
    /// Everything the detail panel shows for one commit.
    func commit(_ dir: String, hash: String) async -> GitCommitResult
    /// The same shape of detail for the working tree's uncommitted state.
    func workingTree(_ dir: String) async -> GitCommitResult
    /// One file's diff in a commit's detail (`hash` `""`: the working tree's),
    /// read from the repository's `root`.
    func fileDiff(_ root: String, hash: String, file: ChangedFile) async -> GitFileDiffResult
    /// Where a pane with no directory of its own starts.
    func defaultDirectory() async -> String
    /// The refs behind the checkout decision, read fresh.
    func branchesAtCommit(_ dir: String, hash: String) async -> GitBranchesAtCommitResult
    func checkout(_ dir: String, _ target: CheckoutTarget) async -> GitCheckoutResult
}

/// The real thing: `git` in the pane's environment.
@MainActor
final class GitRepositorySource: GitSource {
    private let git: Git
    private let appDirectory: String?
    private let home: String

    /// `appDirectory` is the app's own working directory (nil if it was
    /// deleted), `home` the user's home.
    init(environment: [String: String], appDirectory: String?, home: String) {
        git = Git(environment: environment)
        self.appDirectory = appDirectory
        self.home = home
    }

    func log(_ dir: String, limit: Int, skip: Int, scope: GitBranchScope) async -> GitLogResult {
        await git.readLog(dir, limit: limit, skip: skip, branchScope: scope)
    }

    func commit(_ dir: String, hash: String) async -> GitCommitResult { await git.readCommit(dir, hash: hash) }

    func workingTree(_ dir: String) async -> GitCommitResult { await git.readWorkingTreeChanges(dir) }

    func fileDiff(_ root: String, hash: String, file: ChangedFile) async -> GitFileDiffResult {
        hash == uncommittedChangesHash
            ? await git.readWorkingTreeFileDiff(root, file: file) : await git.readCommitFileDiff(root, hash: hash, file: file)
    }

    /// The fallback when creation inherited no directory: the app's own
    /// working directory when it's inside a repository (launched from a shell,
    /// it's where the user was standing), else home (launched from Finder it's
    /// `/`), where the pane shows its notice and the path bar.
    func defaultDirectory() async -> String {
        guard let appDirectory else { return home }
        return await git.isRepo(appDirectory) ? appDirectory : home
    }

    func branchesAtCommit(_ dir: String, hash: String) async -> GitBranchesAtCommitResult {
        await git.branchesAtCommit(dir, hash: hash)
    }

    func checkout(_ dir: String, _ target: CheckoutTarget) async -> GitCheckoutResult { await git.checkout(dir, target) }
}

#if DEBUG
/// A scripted git, for the plugin's tests and the Debug visual capture. Every
/// log call answers from the same script (whatever the directory), and every
/// call is recorded so a test can see what the pane asked for.
@MainActor
final class ScriptedGitSource: GitSource {
    var commits: [Commit] = []
    var root = "/repo"
    var hasMore = false
    var hasUncommittedChanges = false
    var failure: GitFailure?
    var defaultDirectoryAnswer = "/repo"
    var head: GitHead = .branch(name: "main")
    var details: [String: CommitDetail] = [:]
    var workingTreeDetail = CommitDetail(
        hash: uncommittedChangesHash, parents: [], author: "", authorEmail: "", date: "", refs: [],
        message: "Uncommitted changes", files: [], filesTruncated: false)
    var branchesAtCommitAnswers: [String: BranchesAtCommit] = [:]
    var checkoutFailure: GitError?
    /// Makes every ref read fail this way (a checkout must still not fail
    /// silently).
    var branchesAtCommitFailure: GitFailure?
    /// What every checkout passes through.
    let checkoutGate = Gate()
    /// Each file's diff, by detail hash (`""`: the working tree) then path;
    /// an unset one fails.
    var fileDiffs: [String: [String: FileDiff]] = [:]
    /// What every file diff read passes through.
    let fileDiffGate = Gate()

    private(set) var logCalls: [String] = []
    private(set) var logScopes: [GitBranchScope] = []
    private(set) var logSkips: [Int] = []
    private(set) var detailReads: [String] = []
    private(set) var branchesAtCommitCalls: [String] = []
    private(set) var checkoutCalls: [CheckoutTarget] = []
    /// Every file diff asked for: the root, the detail's hash and the file.
    private(set) var fileDiffReads: [(root: String, hash: String, file: ChangedFile)] = []

    /// A call passes at once (after a yield), or while held, waits until
    /// `release()`.
    @MainActor
    final class Gate {
        var isHeld = false
        private var waiting: [CheckedContinuation<Void, Never>] = []

        func pass() async {
            if isHeld {
                await withCheckedContinuation { waiting.append($0) }
            } else {
                await Task.yield()
            }
        }

        func release() {
            let pending = waiting
            waiting = []
            for continuation in pending { continuation.resume() }
        }
    }

    init() {}

    /// The next reads answer these commits, from `root`.
    func setLog(_ commits: [Commit], root: String? = nil, hasMore: Bool = false, hasUncommittedChanges: Bool = false) {
        self.commits = commits
        failure = nil
        if let root { self.root = root }
        self.hasMore = hasMore
        self.hasUncommittedChanges = hasUncommittedChanges
    }

    /// An unset hash's detail is synthesized from its log entry.
    private func detail(for hash: String) -> CommitDetail? {
        if let explicit = details[hash] { return explicit }
        guard let commit = commits.first(where: { $0.hash == hash }) else { return nil }
        return CommitDetail(
            hash: commit.hash, parents: commit.parents, author: commit.author,
            authorEmail: "\(commit.author.lowercased())@example.com", date: commit.date, refs: commit.refs,
            message: commit.subject, files: [], filesTruncated: false)
    }

    func log(_ dir: String, limit: Int, skip: Int, scope: GitBranchScope) async -> GitLogResult {
        logCalls.append(dir)
        logScopes.append(scope)
        logSkips.append(skip)
        await Task.yield()
        if let failure { return .failure(GitError(failure)) }
        let page = Array(commits.dropFirst(skip).prefix(limit))
        return .success(
            GitLog(
                root: root, head: head, commits: page, hasMore: hasMore || skip + limit < commits.count,
                hasUncommittedChanges: hasUncommittedChanges))
    }

    func commit(_ dir: String, hash: String) async -> GitCommitResult {
        detailReads.append(hash)
        await Task.yield()
        if let failure { return .failure(GitError(failure)) }
        guard let detail = detail(for: hash) else { return .failure(GitError(.failed(message: "no such commit \(hash)"))) }
        return .success(detail)
    }

    func workingTree(_ dir: String) async -> GitCommitResult {
        detailReads.append(uncommittedChangesHash)
        await Task.yield()
        if let failure { return .failure(GitError(failure)) }
        return .success(workingTreeDetail)
    }

    func fileDiff(_ root: String, hash: String, file: ChangedFile) async -> GitFileDiffResult {
        fileDiffReads.append((root, hash, file))
        await fileDiffGate.pass()
        guard let diff = fileDiffs[hash]?[file.path] else {
            return .failure(GitError(.failed(message: "no diff for \(file.path)")))
        }
        return .success(diff)
    }

    func defaultDirectory() async -> String {
        await Task.yield()
        return defaultDirectoryAnswer
    }

    func branchesAtCommit(_ dir: String, hash: String) async -> GitBranchesAtCommitResult {
        branchesAtCommitCalls.append(hash)
        await Task.yield()
        if let branchesAtCommitFailure { return .failure(GitError(branchesAtCommitFailure)) }
        return .success(branchesAtCommitAnswers[hash] ?? BranchesAtCommit(local: [], remotes: [], allLocalBranches: []))
    }

    func checkout(_ dir: String, _ target: CheckoutTarget) async -> GitCheckoutResult {
        checkoutCalls.append(target)
        await checkoutGate.pass()
        if let checkoutFailure { return .failure(checkoutFailure) }
        switch target {
        case .commit(let hash): head = .detached(hash: hash)
        case .branch(let name): head = .branch(name: name)
        case .remoteBranch(let info): head = .branch(name: info.name)
        }
        return .success(())
    }
}
#endif
