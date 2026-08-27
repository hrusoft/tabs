import { app, BrowserWindow } from 'electron'
import { IpcChannel } from '../shared/ipc'
import { onRendererMessage } from './ipcListeners'
import { getSettings } from './settings'

/**
 * Wires the one-way `bell:ring` channel the renderer fires whenever an
 * xterm.js terminal's onBell fires (see TerminalRenderer.tsx). Bounces the
 * Dock icon — macOS only (`app.dock` is undefined elsewhere), and only
 * while the app's own window isn't focused: a focused window already shows
 * the flashing in-pane bell, so bouncing the Dock too would just be noise.
 * Re-checks `enableBellIndicator` here too — defense in depth mirroring the
 * renderer's own gate, the way layout.ts re-checks `persistLayoutOnExit`
 * rather than trusting the renderer alone.
 */
export function registerBellIpc(): void {
  onRendererMessage(IpcChannel.bellRing, (event) => {
    if (!getSettings().enableBellIndicator) return
    if (process.platform !== 'darwin') return
    const window = BrowserWindow.fromWebContents(event.sender)
    if (window?.isFocused()) return
    app.dock?.bounce('informational')
  })
}
