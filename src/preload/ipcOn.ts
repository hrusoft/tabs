import { ipcRenderer } from 'electron'

/**
 * Subscribes `listener` to an IPC channel, dropping the event arg; returns the
 * unsubscriber.
 *
 * Its own module from when each content type had a preload namespace file of
 * its own; today index.ts is the only importer — packages ship no preload code
 * at all, speaking through the generic content bridge instead (see
 * shared/plugin/bridge.ts).
 */
export function on<Args extends unknown[]>(
  channel: string,
  listener: (...args: Args) => void
): () => void {
  const wrapped = (_event: Electron.IpcRendererEvent, ...args: Args): void => listener(...args)
  ipcRenderer.on(channel, wrapped)
  return () => ipcRenderer.removeListener(channel, wrapped)
}
