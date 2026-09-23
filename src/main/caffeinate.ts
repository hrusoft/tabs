import { spawn } from 'node:child_process'
import type { CaffeinateFlags } from '../shared/api'
import { IpcChannel } from '../shared/ipc'
import { argsFor } from './caffeinateArgs'
import {
  caffeinateProcess,
  isCaffeinateRunning,
  setCaffeinateProcess,
  stopCaffeinate
} from './caffeinateProcess'
import { onRendererMessage, registerSyncGetter } from './ipcListeners'
import { forEachLiveWindow } from './liveWindows'
import { applyMenu } from './menu'

/**
 * The orchestration around the app's one managed `caffeinate(8)` process:
 * starting it, broadcasting state changes, and the IPC surface the renderer
 * calls. The live process reference itself, the running check, and stopping
 * one all live in `caffeinateProcess.ts` instead — see its own module
 * comment for why (menu.ts needs both of those and this module needs
 * menu.ts's `applyMenu`, so they can't live here without a cycle).
 *
 * Core, not a content type: caffeinate isn't scoped to any pane, the same
 * reason bell.ts/fonts.ts are core namespaces rather than plugin packages.
 */

/** macOS only — the binary doesn't exist elsewhere, and the whole feature is hidden off darwin (see menu.ts). */
const CAFFEINATE_BIN = '/usr/bin/caffeinate'

/** Broadcasts the new running state to every live window, and rebuilds the menu — its label is computed live from `isCaffeinateRunning()`. */
function broadcastRunning(running: boolean): void {
  forEachLiveWindow((window) => {
    window.webContents.send(IpcChannel.caffeinateRunningChanged, running)
  })
  applyMenu()
}

/**
 * Starts the managed process with `flags`, watching this process's own pid
 * (see argsFor's `-w`) so a crash or a SIGKILL — which never runs
 * `before-quit` — can't leave it running forever; a normal quit's
 * `killCaffeinateSync` is the prompt path, `-w` is the backstop. A no-op if
 * one is already running, and a no-op entirely off macOS (defensive: the
 * File-menu item that reaches this is already hidden there — see menu.ts).
 */
export function startCaffeinate(flags: CaffeinateFlags): void {
  if (process.platform !== 'darwin') return
  if (caffeinateProcess()) return
  const child = spawn(CAFFEINATE_BIN, argsFor(flags, process.pid), { stdio: 'ignore' })
  setCaffeinateProcess(child)
  // Guarded and wrapped the same way createTerminal's pty exit/data callbacks
  // are (see CLAUDE.md's before-quit gotcha): `caffeinateProcess() === child`
  // is false once this process has already been superseded or nulled out (by
  // Decaf, by killCaffeinateSync at quit, or by a reset between e2e tests),
  // so a callback arriving late — including one firing after the window it
  // would broadcast to has started tearing down — simply does nothing
  // instead of reaching for a destroyed webContents.
  const onExit = (): void => {
    try {
      if (caffeinateProcess() !== child) return
      setCaffeinateProcess(null)
      broadcastRunning(false)
    } catch (error) {
      console.error('[tabs] caffeinate exit handling threw:', error)
    }
  }
  child.on('exit', onExit)
  child.on('error', onExit)
  broadcastRunning(true)
}

/** Registers the caffeinate half of window.api: start/stop/isRunningSync/onRunningChanged/onOpenDialog. */
export function registerCaffeinateIpc(): void {
  onRendererMessage(IpcChannel.caffeinateStart, (_event, flags: CaffeinateFlags) =>
    startCaffeinate(flags)
  )
  onRendererMessage(IpcChannel.caffeinateStop, () => stopCaffeinate())
  registerSyncGetter(IpcChannel.caffeinateIsRunningSync, () => isCaffeinateRunning())
}
