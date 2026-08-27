import { BrowserWindow } from 'electron'

/**
 * Runs `fn` over every window that is still alive. Three modules broadcast to
 * all windows (settings mirroring, theme repaints, ownership changes), and
 * most of them do it from inside a synchronous `ipcMain.on` listener — where
 * dereferencing a destroyed window throws, and a throw is the native error
 * modal persist.ts documents. The liveness guard is stated once here so no
 * broadcaster can touch a window before checking it.
 */
export function forEachLiveWindow(fn: (win: BrowserWindow) => void): void {
  for (const win of BrowserWindow.getAllWindows()) {
    if (!win.isDestroyed()) fn(win)
  }
}
