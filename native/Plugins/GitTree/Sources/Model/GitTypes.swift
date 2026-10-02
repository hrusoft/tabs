import Foundation

// The git tree's shapes: what `Git` reads out of `git` and the pane shows.
// Ported from the Electron app's `packages/plugin-gitTree/shared/types.ts`,
// shape for shape. `Graph.swift` turns the commit list into rows.

/// The sentinel `Commit.hash` for the working tree's own uncommitted state.
///
/// The pane prepends a synthetic `Commit` carrying this hash to the real list
/// whenever the working tree is dirty, rather than drawing it as a separate
/// decoration. That lets `assignLanes` connect it into the real graph (as an
/// ordinary edge into the newest real commit), and lets everything that works
/// on `[Commit]` (selection, keyboard nav, the detail read) handle it with no
/// special case. `""` is safe as a sentinel because a real hash is never empty.
let uncommittedChangesHash = ""

/// One commit, as `git log --parents` reports it.
struct Commit: Equatable, Sendable, Codable {
    /// Full 40-character hash. Abbreviated only for display.
    var hash: String
    /// Parent hashes in git's order: `parents[0]` is the first parent (the
    /// branch this commit was made on), the rest are merged-in branches.
    /// Empty for a root commit (a repository can have several).
    var parents: [String]
    var author: String
    /// Author date, ISO 8601 with offset (`%aI`).
    var date: String
    /// Ref names pointing here, split out of `%D`: 'main', 'origin/main',
    /// 'HEAD', 'tag: v1'. Empty for most commits.
    var refs: [String]
    /// First line of the message (`%s`).
    var subject: String
}

/// One file a commit touched. Counts come from `--numstat`, which reports `-`
/// for a binary file instead of a number: hence nil rather than 0, so the pane
/// can say "binary" instead of claiming zero lines changed.
struct ChangedFile: Equatable, Sendable, Codable {
    var path: String
    var insertions: Int?
    var deletions: Int?
}

/// Everything the detail panel shows for the selected commit.
struct CommitDetail: Equatable, Sendable, Codable {
    var hash: String
    var parents: [String]
    var author: String
    var authorEmail: String
    var date: String
    var refs: [String]
    /// Full message, subject line included (`%B`), trailing newlines trimmed.
    var message: String
    var files: [ChangedFile]
    /// True when `files` was cut at the per-commit cap (`Git.fileCap`).
    var filesTruncated: Bool
}

/// Why a git read produced nothing usable. Each is a state the pane shows as a
/// sentence, never a thrown error: a pane pointed at a directory that stopped
/// being a repository is an ordinary thing to look at.
///
/// `noCommits` is distinct from `notARepo`: a freshly `git init`ed directory
/// answers `rev-parse --show-toplevel` happily and only fails at `log`, and
/// conflating them would tell a user their brand-new repository isn't one.
///
/// `noSuchDirectory` is distinct from `gitMissing`: both surface as ENOENT from
/// the spawn, but only one of them is about git at all (see `Git.classify`).
enum GitFailure: Equatable, Sendable {
    case gitMissing
    case noSuchDirectory(path: String)
    case notARepo(path: String)
    case noCommits(root: String)
    case failed(message: String)
}

/// Which refs a page of history is scoped to: the pane's branch filter.
/// `current` is `git log HEAD`; `local` is `--branches` (every `refs/heads/*`);
/// `all` is `--branches --remotes`. Tags are deliberately left out: the filter
/// is about branches.
enum GitBranchScope: String, CaseIterable, Sendable, Codable {
    case current, local, all
}

/// Where HEAD is. Detached is a normal state (a checked-out tag, a bisect), so
/// it's a case rather than a missing branch name.
enum GitHead: Equatable, Sendable {
    case branch(name: String)
    case detached(hash: String)
}

/// A page of history. `hasMore` is "the log had at least one commit past this
/// page", which git answers for free when asked for one more than shown.
///
/// `hasUncommittedChanges` is whether the working tree has anything staged or
/// unstaged (untracked files included): a `git status --porcelain` question,
/// independent of which commits are in `commits`.
struct GitLog: Equatable, Sendable {
    var root: String
    var head: GitHead
    var commits: [Commit]
    var hasMore: Bool
    var hasUncommittedChanges: Bool
}

typealias GitLogResult = Result<GitLog, GitError>
typealias GitCommitResult = Result<CommitDetail, GitError>

/// The raw refs behind the checkout decision, for one commit: local branch
/// names there, remote-tracking refs there (already split against the
/// repository's real remotes), and every local branch name in the repository
/// wherever it points (to drop a remote candidate that would collide with one).
///
/// Always a fresh read, never the log's own `%D` decorations: those mix local,
/// remote-tracking, HEAD and tags into one ambiguous list, and may be older
/// than the click that asked.
struct BranchesAtCommit: Equatable, Sendable {
    var local: [String]
    var remotes: [RemoteRefInfo]
    var allLocalBranches: [String]
}

typealias GitBranchesAtCommitResult = Result<BranchesAtCommit, GitError>

/// A failure, and for a checkout, git's complete stderr (trimmed, capped) next
/// to the one line `GitFailure.failed` carries: a checkout refusal is usually
/// the most actionable text git prints anywhere in this pane (which files
/// would be overwritten, what to do), and cutting it to one line would throw
/// that away. Every other caller keeps the one-line form.
struct GitError: Error, Equatable, Sendable {
    var reason: GitFailure
    var detail: String?

    init(_ reason: GitFailure, detail: String? = nil) {
        self.reason = reason
        self.detail = detail
    }
}

typealias GitCheckoutResult = Result<Void, GitError>
