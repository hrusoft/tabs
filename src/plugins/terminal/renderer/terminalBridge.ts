import { TerminalMethod, terminalDataEvent, terminalExitEvent } from '../shared/ipc'
import { terminalCtx } from './pluginContext'

/**
 * The terminal's typed client over the generic content bridge — the renderer
 * never imports `node-pty` (a native module); it only ever talks to the main
 * process's pty registry through these calls, whose other half is the
 * package's main entry (main/terminal.ts) registering the same method names.
 *
 * The result casts are this package's own narrowing, sound for the same
 * reason the settings accessor's is: both ends of every method are this
 * package's code, registered and called under names only it uses. This is
 * where `window.api.terminal`'s types went when the per-type bridge
 * namespaces became one generic surface.
 */
export const terminalBridge = {
  /** Spawns (or reattaches to) the pty for `id`, returning its OS pid. */
  create: (id: string, cwd: string | undefined, cols: number, rows: number): Promise<number> =>
    terminalCtx.get().ipc.invoke(TerminalMethod.create, id, cwd, cols, rows) as Promise<number>,
  write: (id: string, data: string): void => {
    terminalCtx.get().ipc.send(TerminalMethod.write, id, data)
  },
  resize: (id: string, cols: number, rows: number): void => {
    terminalCtx.get().ipc.send(TerminalMethod.resize, id, cols, rows)
  },
  /** Kills the pty for `id` and removes it from the main-process registry. Idempotent. */
  dispose: (id: string): Promise<void> =>
    terminalCtx.get().ipc.invoke(TerminalMethod.dispose, id) as Promise<void>,
  /** Best-effort live cwd of the shell process backing `id`, looked up via the OS. Undefined if unknown. */
  getCwd: (id: string): Promise<string | undefined> =>
    terminalCtx.get().ipc.invoke(TerminalMethod.getCwd, id) as Promise<string | undefined>,
  /** Subscribes to output; returns an unsubscribe function. */
  onData: (id: string, callback: (data: string) => void): (() => void) =>
    terminalCtx.get().ipc.on(terminalDataEvent(id), callback as (...args: unknown[]) => void),
  /** Subscribes to the pty exiting on its own (e.g. the user typed `exit`). */
  onExit: (id: string, callback: () => void): (() => void) =>
    terminalCtx.get().ipc.on(terminalExitEvent(id), callback)
}
