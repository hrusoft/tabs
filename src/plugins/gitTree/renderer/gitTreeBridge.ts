import type { CheckoutTarget } from '../shared/checkoutTargets'
import { GitTreeMethod } from '../shared/ipc'
import type {
  GitBranchesAtCommitResult,
  GitBranchScope,
  GitCheckoutResult,
  GitCommitResult,
  GitFailure,
  GitLogResult
} from '../shared/types'
import { gitTreeCtx } from './pluginContext'

/**
 * Invokes a method that answers with a result value, folding a rejected IPC
 * hop (main reloading mid-call, say) into the same failure value main
 * answers with. Main's handlers never reject; this is what makes the whole
 * round trip never reject, once here rather than at each caller.
 */
function invokeResult<T>(
  method: string,
  ...args: unknown[]
): Promise<T | { ok: false; reason: GitFailure }> {
  return (gitTreeCtx.get().ipc.invoke(method, ...args) as Promise<T>).catch((error: unknown) => ({
    ok: false as const,
    reason: {
      kind: 'failed' as const,
      message: error instanceof Error ? error.message : String(error)
    }
  }))
}

/**
 * The git tree's typed client over the generic content bridge — the renderer
 * is sandboxed and has no `node:child_process`, so every `git` invocation
 * happens in main (main/git.ts) and arrives here as data. The result casts
 * are this package's own narrowing, sound because both ends of every method
 * are this package's code (see the terminal's terminalBridge.ts, the same
 * pattern with the same rationale).
 *
 * Every result-typed method resolves; none reject (see `invokeResult`). A
 * directory that isn't a repo, a missing `git`, an empty repo — all ordinary
 * states, classified main-side into `GitFailure` values the pane renders as
 * sentences (see ../shared/types.ts).
 */
export const gitTreeBridge = {
  /**
   * A page of history for the repo containing `dir`, newest first, together
   * with where HEAD is. `skip` pages backwards through the same log rather
   * than re-reading it, so "Load more" costs one `git log` per press.
   * `branchScope` is the pane's branch filter (see `GitBranchScope`).
   */
  log: (
    dir: string,
    limit: number,
    skip: number,
    branchScope: GitBranchScope
  ): Promise<GitLogResult> =>
    invokeResult<GitLogResult>(GitTreeMethod.log, dir, limit, skip, branchScope),
  /** Everything the detail panel shows for one commit: full message, author, and the files it touched. */
  commit: (dir: string, hash: string): Promise<GitCommitResult> =>
    invokeResult<GitCommitResult>(GitTreeMethod.commit, dir, hash),
  /**
   * The same shape of detail, for the working tree's own uncommitted state
   * rather than a real commit — what answers a selection on the synthetic row
   * (`UNCOMMITTED_CHANGES_HASH`) the renderer prepends when the tree is dirty.
   */
  workingTree: (dir: string): Promise<GitCommitResult> =>
    invokeResult<GitCommitResult>(GitTreeMethod.workingTree, dir),
  /**
   * Where a pane with no directory of its own should start looking — the
   * fallback for when creation inherited nothing (see CLAUDE.md's
   * cwd-inheritance entry).
   */
  defaultDirectory: (): Promise<string> =>
    gitTreeCtx.get().ipc.invoke(GitTreeMethod.defaultDirectory) as Promise<string>,
  /**
   * Asks the user to pick a directory, starting at `current`. Resolves
   * undefined if they cancel — and always under E2E_HIDDEN, where a native
   * dialog would be unclickable and would hang the run (see the handler in
   * main, and CLAUDE.md's dialog gotcha).
   */
  chooseDirectory: (current: string | undefined): Promise<string | undefined> =>
    gitTreeCtx.get().ipc.invoke(GitTreeMethod.chooseDirectory, current) as Promise<
      string | undefined
    >,
  /**
   * The refs behind the checkout decision, read fresh — never the log's own
   * `%D` decorations, which mix local, remote-tracking, HEAD and tag names
   * into one ambiguous string and may in any case be stale by the time a
   * trigger fires (see git.ts's own comment).
   */
  branchesAtCommit: (dir: string, hash: string): Promise<GitBranchesAtCommitResult> =>
    invokeResult<GitBranchesAtCommitResult>(GitTreeMethod.branchesAtCommit, dir, hash),
  /** Checks out `target` — a local branch, a remote-tracking branch (creating a local tracking branch), or a bare commit (detached HEAD). */
  checkout: (dir: string, target: CheckoutTarget): Promise<GitCheckoutResult> =>
    invokeResult<GitCheckoutResult>(GitTreeMethod.checkout, dir, target)
}
