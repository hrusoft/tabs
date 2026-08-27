import { mkdirSync, unlinkSync, writeFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { app } from 'electron'

/**
 * The default writer behind `saveLayout` and `saveSettings`: creates the
 * parent directory if it's missing, then writes.
 *
 * The mkdir is not paranoia. The userData directory can genuinely be gone
 * under a live app — an e2e fixture deleting the throwaway `--user-data-dir`
 * of an app it thought had exited is the case that surfaced this — and the
 * next debounced save then hits ENOENT.
 */
function writeJsonFile(path: string, data: string): void {
  mkdirSync(dirname(path), { recursive: true })
  writeFileSync(path, data)
}

/**
 * Runs a persistence write so that no failure can escape. A save that can't
 * reach the disk is a degraded save, never a reason to kill the app: the
 * in-memory state is still correct and the next write may well succeed.
 *
 * Where these writes run is what makes an escaping throw so expensive.
 * `saveLayout` is called from inside a synchronous `ipcMain.on` listener, so
 * a throw propagates through `IpcMainImpl.emit` into Electron's own C++
 * dispatch rather than to any JS caller that could catch it — an uncaught
 * main-process exception, which Electron answers with a native "A JavaScript
 * error occurred in the main process" modal. `saveSettings` runs from a
 * debounce timer, where an uncaught throw is equally fatal, and both run
 * again from `before-quit`, where CLAUDE.md's before-quit gotcha documents a
 * throw during shutdown reaching node-addon-api's unsafe rethrow path and
 * aborting the process outright. Under E2E_HIDDEN the resulting dialog has no
 * parent window, so it renders on screen and nothing — Playwright included —
 * can click it.
 *
 * Deliberately scoped to these writers rather than installed as a global
 * `process.on('uncaughtException')` handler in main: a catch-all would hide
 * every real main-process bug behind the same silence. Don't "improve" it
 * into one.
 */
function persistQuietly(what: string, write: () => void): void {
  try {
    write()
  } catch (error) {
    console.error(`[tabs] failed to save ${what}:`, error)
  }
}

// ---------------------------------------------------------------------------
// The JSON-file-store plumbing layout.ts and settings.ts share. Each store
// keeps what genuinely differs — its load normalization (the two try-scopes
// are deliberately different, see each loader) and its set-handler semantics —
// and takes everything mechanical from here, so the two can't drift apart in
// the parts that must behave identically.
// ---------------------------------------------------------------------------

/** Injectable seams so the fs-touching load logic is unit-testable without a real file. */
export interface JsonReadDeps {
  path?: string
  readFile?: (path: string) => string
}

export interface JsonWriteDeps {
  path?: string
  writeFile?: (path: string, data: string) => void
}

/** Where `fileName` lives in the app's userData directory. */
export function userDataPath(fileName: string): string {
  return join(app.getPath('userData'), fileName)
}

/**
 * The save both stores use: pretty-printed JSON through `persistQuietly`, on
 * the default writer unless a test injects one. Callers spell the path
 * `deps.path ?? theirPath()` so the userData lookup only runs when no
 * explicit path was supplied — unit tests run outside a real Electron app.
 */
export function saveJsonQuietly(
  what: string,
  path: string,
  data: unknown,
  writeFile: (path: string, data: string) => void = writeJsonFile
): void {
  persistQuietly(what, () => writeFile(path, JSON.stringify(data, null, 2)))
}

/** Best-effort unlink for the e2e resets. */
export function removeQuietly(path: string): void {
  try {
    unlinkSync(path)
  } catch {
    // Never written, or already gone — either way there's nothing to clear.
  }
}
