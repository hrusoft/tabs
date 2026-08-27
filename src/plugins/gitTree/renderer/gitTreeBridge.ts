import { GitTreeMethod } from '../shared/ipc'
import type { GitCommitResult, GitLogResult } from '../shared/types'
import { gitTreeCtx } from './pluginContext'

/**
 * The git tree's typed client over the generic content bridge — the renderer
 * is sandboxed and has no `node:child_process`, so every `git` invocation
 * happens in main (main/git.ts) and arrives here as data. The result casts
 * are this package's own narrowing, sound because both ends of every method
 * are this package's code (see the terminal's terminalBridge.ts, the same
 * pattern with the same rationale).
 *
 * Every method resolves; none reject. A directory that isn't a repo, a
 * missing `git`, an empty repo — all ordinary states, classified main-side
 * into `GitFailure` values the pane renders as sentences (see ../shared/types.ts).
 */
export const gitTreeBridge = {
  /**
   * A page of history for the repo containing `dir`, newest first, together
   * with where HEAD is. `skip` pages backwards through the same log rather
   * than re-reading it, so "Load more" costs one `git log` per press.
   */
  log: (dir: string, limit: number, skip: number): Promise<GitLogResult> =>
    gitTreeCtx.get().ipc.invoke(GitTreeMethod.log, dir, limit, skip) as Promise<GitLogResult>,
  /** Everything the detail panel shows for one commit: full message, author, and the files it touched. */
  commit: (dir: string, hash: string): Promise<GitCommitResult> =>
    gitTreeCtx.get().ipc.invoke(GitTreeMethod.commit, dir, hash) as Promise<GitCommitResult>,
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
    >
}
