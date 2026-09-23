import type { BrowserWindow } from 'electron'
import { restorableWindowIds } from './layout'
import { createWindow, getPaneTreeWindows } from './windows'

/**
 * Opens every pane-tree window the layout has to restore, or one fresh
 * window when there is none, and returns them — at boot, and whenever every
 * window has closed and one is needed again (a macOS reactivate, File →
 * Caffeinate…, File → New Window), where the last one closed comes back (see
 * layout.ts). Its
 * own module so menu.ts can reach it; windows.ts knows nothing of
 * persistence.
 */
export function openPaneTreeWindows(): BrowserWindow[] {
  const ids = restorableWindowIds()
  if (ids.length === 0) return [createWindow()]
  return ids.map((id) => createWindow(id))
}

/**
 * File → New Window. A fresh, empty window beside the open ones — or, with
 * none open (macOS keeps the app running after the last one closes), what a
 * reactivate brings back: the last window closed, with its layout (on fresh
 * shells — its own ended with it). A fresh window there would replace that
 * kept layout, when every other way back to a window (the Dock, File →
 * Caffeinate…) restores it.
 */
export function openNewWindow(): void {
  if (getPaneTreeWindows().size === 0) openPaneTreeWindows()
  else createWindow()
}
