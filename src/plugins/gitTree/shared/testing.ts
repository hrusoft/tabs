import type { CheckoutTarget } from './checkoutTargets'
import type { Commit, CommitDetail, GitBranchScope, GitFailure } from './types'

/**
 * What a test can drive on the git tree type's fake bridge (its testing/fakeApi.ts).
 *
 * Unlike the terminal's fake (inert, because no non-Electron tier renders a
 * terminal) this one is genuinely driven: the git tree's renderer is ordinary
 * React over this bridge, so the jsdom tier mounts the real component and
 * scripts what git "answers" — which is what lets keyboard navigation, the
 * detail panel and every failure state be tested without a repo on disk.
 *
 * Real `git` against a real repository is the Electron tier's job
 * (e2e/git-tree.spec.ts); this fake deliberately cannot stand in for it.
 */
export interface GitTreeFakeHandle {
  /** Makes every subsequent `log()` answer with these commits, as a repo rooted at `root`. */
  setGitTreeLog(
    commits: Commit[],
    options?: { root?: string; hasMore?: boolean; hasUncommittedChanges?: boolean }
  ): void
  /** Makes every subsequent `log()` fail this way instead. */
  setGitTreeFailure(reason: GitFailure): void
  /** Answers `commit()` for one hash. Anything unset falls back to a detail synthesized from the log entry. */
  setGitTreeCommitDetail(hash: string, detail: CommitDetail): void
  /** Answers `workingTree()` — the working tree's own uncommitted-state detail. Defaults to an empty file list under the message "Uncommitted changes". */
  setGitTreeWorkingTreeDetail(detail: CommitDetail): void
  /** What `defaultDirectory()` resolves to — the directory a pane with no configured cwd adopts. */
  setGitTreeDefaultDirectory(dir: string): void
  /** What the next `chooseDirectory()` resolves to. Undefined (the initial value) is "the user cancelled". */
  setGitTreeChosenDirectory(dir: string | undefined): void
  /** Directories `log()` has been called with, oldest first — how a test sees which repo the pane is actually reading. */
  gitTreeLogCalls(): string[]
  /** Branch scopes `log()` has been called with, oldest first — how a test sees which filter the pane actually asked for. */
  gitTreeLogScopes(): GitBranchScope[]
  /** Every hash a detail has been read for, oldest first — `commit()`'s hash, or `UNCOMMITTED_CHANGES_HASH` for `workingTree()`. How a test sees the pane asking for detail it would show. */
  gitTreeDetailReads(): string[]

  // --- Checking out a commit or branch ---

  /**
   * What `branchesAtCommit(hash)` answers. Unset hashes answer with every
   * list empty (no branch at all — the "detached HEAD" path), matching what
   * a commit with no ref pointing at it looks like for real.
   */
  setGitTreeBranchesAtCommit(
    hash: string,
    refs: { local?: string[]; remotes?: string[]; allLocalBranches?: string[] }
  ): void
  /** Makes every subsequent `checkout()` fail this way instead of succeeding. `detail`, when given, is what a real refusal's full stderr would carry (see GitCheckoutResult's own comment). Undefined clears it, back to succeeding. */
  setGitTreeCheckoutFailure(reason: GitFailure | undefined, detail?: string): void
  /**
   * Holds every `checkout()` call's promise unresolved until
   * `releaseGitTreeCheckout()` is called — what a test uses to fire a second
   * trigger while the first is still in flight, and assert the renderer's own
   * single-checkout-at-a-time guard (not this fake) is what stopped it.
   */
  setGitTreeCheckoutGate(held: boolean): void
  /** Resolves every `checkout()` call currently held by the gate above. A no-op if the gate is off or nothing is pending. */
  releaseGitTreeCheckout(): void
  /** Every target `checkout()` has actually been called with, oldest first. */
  gitTreeCheckoutCalls(): CheckoutTarget[]
  /** Every hash `branchesAtCommit()` has actually been called with, oldest first — how a test sees the read really did happen fresh at trigger time. */
  gitTreeBranchesAtCommitCalls(): string[]
  /**
   * Makes every subsequent `branchesAtCommit()` reject with `error` instead
   * of resolving — simulating an IPC invoke failure (main reloading mid-call,
   * say), the one path checkout's "must not fail silently" contract still
   * has to cover on top of the ordinary `GitFailure` values every other
   * method answers with. Undefined clears it, back to resolving normally.
   */
  setGitTreeBranchesAtCommitRejection(error: Error | undefined): void
}
