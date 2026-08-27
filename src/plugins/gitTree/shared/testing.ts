import type { Commit, CommitDetail, GitFailure } from './types'

/**
 * What a test can drive on the git tree type's faked `window.api` namespace.
 *
 * Unlike the terminal's fake (inert, because no non-Electron tier renders a
 * terminal) this one is genuinely driven: the git tree's renderer is ordinary
 * React over this bridge, so the jsdom tier mounts the real component and
 * scripts what git "answers" — which is what lets keyboard navigation, the
 * detail panel and all four failure states be tested without a repo on disk.
 *
 * Real `git` against a real repository is the Electron tier's job
 * (e2e/git-tree.spec.ts); this fake deliberately cannot stand in for it.
 */
export interface GitTreeFakeHandle {
  /** Makes every subsequent `log()` answer with these commits, as a repo rooted at `root`. */
  setGitTreeLog(commits: Commit[], options?: { root?: string; hasMore?: boolean }): void
  /** Makes every subsequent `log()` fail this way instead. */
  setGitTreeFailure(reason: GitFailure): void
  /** Answers `commit()` for one hash. Anything unset falls back to a detail synthesized from the log entry. */
  setGitTreeCommitDetail(hash: string, detail: CommitDetail): void
  /** What `defaultDirectory()` resolves to — the directory a pane with no configured cwd adopts. */
  setGitTreeDefaultDirectory(dir: string): void
  /** What the next `chooseDirectory()` resolves to. Undefined (the initial value) is "the user cancelled". */
  setGitTreeChosenDirectory(dir: string | undefined): void
  /** Directories `log()` has been called with, oldest first — how a test sees which repo the pane is actually reading. */
  gitTreeLogCalls(): string[]
}
