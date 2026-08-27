import { type IpcMainEvent, ipcMain } from 'electron'

/**
 * The one home for main's `ipcMain.on` registrations. `ipcMain.on` dispatches
 * synchronously and, unlike `handle`, has no rejection channel: a throw
 * escaping a listener propagates into Electron's own dispatch as an uncaught
 * main-process exception — the native "A JavaScript error occurred" modal
 * persist.ts documents, unclickable under E2E_HIDDEN. So every listener is
 * wrapped here, once, rather than each registration remembering to guard
 * itself (four did, four didn't, before this existed). Packages get the same
 * wrapper through their context's `ipc.on`.
 */
export function onRendererMessage<Args extends unknown[]>(
  channel: string,
  listener: (event: IpcMainEvent, ...args: Args) => void
): void {
  ipcMain.on(channel, (event, ...args) => {
    try {
      listener(event, ...(args as Args))
    } catch (error) {
      console.error(`[tabs] listener for "${channel}" threw:`, error)
    }
  })
}

/**
 * Registers the main half of an `ipcRenderer.sendSync` getter. Synchronous on
 * purpose, everywhere it appears: each of these feeds a renderer store that
 * reads at module-eval time so the first render already reflects persisted
 * state — an async invoke + hydrate-in-effect flashes defaults for a frame
 * and lets an early user action be overwritten by the late response (see
 * settingsStore.ts / layoutStore.ts).
 */
export function registerSyncGetter(channel: string, value: () => unknown): void {
  onRendererMessage(channel, (event) => {
    event.returnValue = value()
  })
}
