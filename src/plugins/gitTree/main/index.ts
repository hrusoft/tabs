import { app, BrowserWindow, dialog } from 'electron'
import { e2eHidden, type MainPluginContext, type MainPluginModule } from '../../../main/plugin/api'
import { GitTreeMethod } from '../shared/ipc'
import type { GitCommitResult, GitLogResult } from '../shared/types'
import { isRepo, readCommit, readLog } from './git'

/**
 * The git tree content type's main-process contributions: four IPC handlers
 * and nothing else.
 *
 * Notably absent, and each absence is a decision rather than an omission:
 *
 * - **No `onQuitSync`.** This type owns no OS resource and has nothing to
 *   flush, so it adds not one child process to the shutdown path — which
 *   CLAUDE.md's before-quit gotcha, four incidents long, is entirely about.
 * - **No `resetForTests`.** It holds no mutable state at all: every read
 *   shells out fresh, and nothing is keyed by pane id. The moment a cache is
 *   added this stops being true and a reset becomes mandatory, or the cache
 *   leaks into whichever later e2e test happens to notice.
 * - **No `windowPreferences` / `wireWindow`.** Nothing here needs a window
 *   capability; the pane is ordinary DOM.
 */

/**
 * Where a pane with no directory of its own should start looking.
 *
 * The fallback for when creation inherited nothing: an origin with a
 * directory to offer already put it in `cwd` via `deriveConfig` (see
 * CLAUDE.md's cwd-inheritance entry), so this answers only when that path
 * yielded nothing.
 *
 * The app's own working directory first, when it is a repo. That is a real
 * notion rather than a lucky guess: launched from a shell (`electron .`, or
 * the packaged binary run by path) it is the directory the user was standing
 * in, which is very often exactly the repo they meant. Launched from
 * Finder/Dock it is `/`, which is not a repo, so this falls through to the
 * home directory and the pane opens its chooser instead of an error.
 */
async function defaultDirectory(): Promise<string> {
  let cwd: string
  try {
    cwd = process.cwd()
  } catch {
    // The process's working directory can be deleted out from under it.
    return app.getPath('home')
  }
  return (await isRepo(cwd)) ? cwd : app.getPath('home')
}

function registerGitTreeIpc(ipc: MainPluginContext['ipc']): void {
  ipc.handle(
    GitTreeMethod.log,
    (_event, dir, limit, skip): Promise<GitLogResult> =>
      readLog(dir as string, limit as number, skip as number)
  )

  ipc.handle(
    GitTreeMethod.commit,
    (_event, dir, hash): Promise<GitCommitResult> => readCommit(dir as string, hash as string)
  )

  ipc.handle(GitTreeMethod.defaultDirectory, (): Promise<string> => defaultDirectory())

  /**
   * The directory picker behind the pane's browse button.
   *
   * **The `e2eHidden` bail is the first line, and that is not stylistic** —
   * this package is one of the five branch sites implementing core's
   * never-a-native-dialog-in-front-of-Playwright rule; `main/e2eHidden.ts` is
   * where that rule and its consequence (a hung worker, not a failed test)
   * are stated.
   *
   * Answering "cancelled" costs the suite nothing, because the picker is only
   * ever a convenience here: the pane's path bar is the real control and is
   * what the e2e tests drive, so every consequence of changing directory stays
   * covered. Only the OS dialog itself goes untested.
   */
  ipc.handle(GitTreeMethod.chooseDirectory, async (event, current): Promise<string | undefined> => {
    if (e2eHidden) return undefined
    const window = BrowserWindow.fromWebContents(event.sender)
    const options: Electron.OpenDialogOptions = {
      title: 'Choose a repository',
      properties: ['openDirectory'],
      ...(current ? { defaultPath: current as string } : {})
    }
    // Parented to the asking window where there is one, so it opens as a
    // sheet on the window being acted on rather than as a loose alert.
    const result = window
      ? await dialog.showOpenDialog(window, options)
      : await dialog.showOpenDialog(options)
    return result.canceled ? undefined : result.filePaths[0]
  })
}

/** The git tree package's main-process entry: the IPC above, and no lifecycle hooks at all. */
export function activate(ctx: MainPluginContext): MainPluginModule {
  registerGitTreeIpc(ctx.ipc)
  return {}
}
