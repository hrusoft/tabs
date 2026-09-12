/**
 * The git tree content type's wire shapes — what main reads out of `git` and
 * hands the renderer.
 *
 * Process-agnostic like everything under src/shared: no DOM, no React, no
 * Electron, and no `node:child_process` either. Main's git.ts produces these;
 * the renderer consumes them; ./graph.ts turns the commit list into rows.
 */

/**
 * The sentinel `Commit.hash` for the working tree's own uncommitted state.
 *
 * The renderer prepends a synthetic `Commit` carrying this hash to the real
 * list whenever the working tree is dirty (see GitTreeRenderer.tsx), rather
 * than rendering it as a separate decorative element — that is what lets
 * `assignLanes` connect it into the real graph (as an ordinary parent/child
 * edge into the newest real commit) and what lets every other mechanism that
 * already operates on `Commit[]` — selection, keyboard nav, the detail-panel
 * fetch — handle it for free, with no special-casing of its own. `''` is safe
 * as a sentinel because a real git hash is never empty.
 */
export const UNCOMMITTED_CHANGES_HASH = ''

/** One commit, as `git log --parents` reports it. */
export interface Commit {
  /** Full 40-character hash. Abbreviated only for display. */
  hash: string
  /**
   * Parent hashes in git's own order: `parents[0]` is the first parent (the
   * branch this commit was made on), the rest are merged-in branches. Empty
   * for a root commit — a repo can have several.
   */
  parents: string[]
  author: string
  /** Author date, ISO 8601 with offset (`%aI`). */
  date: string
  /**
   * Ref names pointing here, already split out of `%D` — 'main',
   * 'origin/main', 'HEAD', 'tag: v1'. Empty for the overwhelming majority of
   * commits.
   */
  refs: string[]
  /** First line of the message (`%s`). */
  subject: string
}

/**
 * One file a commit touched. Counts come from `--numstat`, which reports `-`
 * for a binary file rather than a number — hence `null` rather than 0, so the
 * UI can say "binary" instead of claiming zero lines changed.
 */
export interface ChangedFile {
  path: string
  insertions: number | null
  deletions: number | null
}

/** Everything the detail panel shows for the selected commit. */
export interface CommitDetail {
  hash: string
  parents: string[]
  author: string
  authorEmail: string
  date: string
  refs: string[]
  /** Full message, subject line included (`%B`), trailing newlines trimmed. */
  message: string
  files: ChangedFile[]
  /** True when `files` was cut at the per-commit cap (see git.ts's FILE_CAP). */
  filesTruncated: boolean
}

/**
 * Why a git read produced nothing usable. Every one of these is a state the
 * pane renders as a sentence, never as a thrown error: a pane pointed at a
 * directory that stopped being a repo is an ordinary thing to look at, not a
 * failure.
 *
 * `no-commits` is deliberately distinct from `not-a-repo` — a freshly `git
 * init`ed directory answers `rev-parse --show-toplevel` happily and only
 * fails at `log`, so conflating them would tell a user their brand-new repo
 * isn't one.
 *
 * `no-such-directory` is deliberately distinct from `git-missing` — both
 * surface as `ENOENT` from the spawn itself, but one means "there's no git
 * binary on PATH" and the other means "the path you typed doesn't exist",
 * and only one of those is about git at all (see git.ts's `classify`).
 */
export type GitFailure =
  | { kind: 'git-missing' }
  | { kind: 'no-such-directory'; path: string }
  | { kind: 'not-a-repo'; path: string }
  | { kind: 'no-commits'; root: string }
  | { kind: 'failed'; message: string }

/**
 * Which refs a page of history is scoped to — the git tree pane's branch
 * filter. `current` is `git log HEAD` (nothing else named); `local` is
 * `--branches` (every `refs/heads/*`); `all` is `--branches --remotes` (local
 * plus remote-tracking branches — tags are deliberately excluded, since the
 * filter is about branches, not every ref that happens to exist).
 */
export type GitBranchScope = 'current' | 'local' | 'all'

/**
 * A page of history. `hasMore` is "the log had at least one commit past this
 * page", which git answers for free if you ask for one more than you intend
 * to show (see git.ts) — no second `rev-list --count` over the whole DAG.
 *
 * `hasUncommittedChanges` is whether the working tree has anything staged or
 * unstaged (including untracked files) — a `git status --porcelain` question,
 * independent of which commits `commits` holds. The renderer turns it into a
 * synthetic `Commit` (see `UNCOMMITTED_CHANGES_HASH`) prepended above the
 * newest real one.
 */
export type GitLogResult =
  | {
      ok: true
      root: string
      head: GitHead
      commits: Commit[]
      hasMore: boolean
      hasUncommittedChanges: boolean
    }
  | { ok: false; reason: GitFailure }

/**
 * Where HEAD is. `detached` is a normal state to be in (a checked-out tag, a
 * bisect, a submodule), so it is a variant rather than a missing branch name.
 */
export type GitHead = { kind: 'branch'; name: string } | { kind: 'detached'; hash: string }

export type GitCommitResult = { ok: true; detail: CommitDetail } | { ok: false; reason: GitFailure }
