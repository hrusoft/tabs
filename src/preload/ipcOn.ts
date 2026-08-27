import { ipcRenderer } from 'electron'

/**
 * Subscribes `listener` to an IPC channel, dropping the event arg; returns the
 * unsubscriber.
 *
 * Its own module because every namespace needs it and the namespaces now live
 * in separate files — core's in index.ts, each content type's in its package's preload/ entry.
 */
export function on<Args extends unknown[]>(
  channel: string,
  listener: (...args: Args) => void
): () => void {
  const wrapped = (_event: Electron.IpcRendererEvent, ...args: Args): void => listener(...args)
  ipcRenderer.on(channel, wrapped)
  return () => ipcRenderer.removeListener(channel, wrapped)
}
