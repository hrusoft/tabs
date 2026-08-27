import { existsSync } from 'node:fs'
import { homedir } from 'node:os'
import { app, type WebContents } from 'electron'
import { type IPty, spawn } from 'node-pty'
import {
  type CloseBlocker,
  type ForegroundProcess,
  getForegroundProcess as getForegroundProcessOf,
  getForegroundProcessSync as getForegroundProcessSyncOf,
  getProcessCwd,
  getProcessCwdSync
} from '../../../main/plugin/api'
import { TerminalMethod, terminalDataEvent, terminalExitEvent } from '../shared/ipc'
import { terminalMainCtx } from './pluginContext'

/**
 * Login-shell candidates tried when `$SHELL` isn't set, in preference order.
 * Only macOS/Linux are in scope (see README); resolveShell just falls back to
 * the last candidate if neither exists.
 */
const DEFAULT_SHELLS = ['/bin/zsh', '/bin/bash']

/** Injectable seams so this pure-ish helper is unit-testable without touching the real fs/env. */
interface ResolveShellDeps {
  env?: NodeJS.ProcessEnv
  exists?: (path: string) => boolean
}

/** Resolves the shell to launch: `$SHELL` if set, else the first existing default shell. */
export function resolveShell({
  env = process.env,
  exists = existsSync
}: ResolveShellDeps = {}): string {
  if (env.SHELL) return env.SHELL
  return DEFAULT_SHELLS.find(exists) ?? DEFAULT_SHELLS[DEFAULT_SHELLS.length - 1]!
}

/** Expands a leading `~` the way a real shell would (node-pty's `cwd` does no shell expansion). */
export function resolveCwd(cwd: string | undefined): string {
  if (!cwd || cwd === '~') return homedir()
  if (cwd.startsWith('~/')) return `${homedir()}${cwd.slice(1)}`
  return cwd
}

interface TerminalEntry {
  pty: IPty
  webContents: WebContents
  unregisterHost: () => void
}

/** Main-process registry of live pty processes, keyed by the leaf ContentNode's id. */
const terminals = new Map<string, TerminalEntry>()

/**
 * Creates (or reattaches to) the pty for `id` and returns its OS pid.
 *
 * Idempotent by design: if a live pty is already registered for `id` this is
 * a no-op that just returns its existing pid instead of killing and
 * respawning it. This is what makes moving a terminal's tab to another pane
 * safe — dragging a tab remounts the React component tree at the new
 * location (unmount then mount), and the renderer calls `create` again on
 * every mount. Without this idempotency, that remount would kill a perfectly
 * live shell just because its tab moved. The renderer is still free to reset
 * its own xterm.js view on every mount (that's the accepted "reattach"
 * model: the process survives a move, the visible scrollback doesn't).
 */
function createTerminal(
  webContents: WebContents,
  id: string,
  cwd: string | undefined,
  cols: number,
  rows: number
): number {
  const existing = terminals.get(id)
  if (existing) {
    // Keep forwarding data to whichever webContents just asked to attach,
    // and re-point the pane-host registry the same way.
    existing.webContents = webContents
    existing.unregisterHost = terminalMainCtx.get().registerPaneHost(id, webContents)
    return existing.pty.pid
  }

  const shell = resolveShell()
  const pty = spawn(shell, ['-l'], {
    // `name` is how node-pty sets the child's TERM, *overwriting* whatever
    // was inherited (unixTerminal.js: `env.TERM = opt.name || env.TERM || ...`).
    // TERM and COLORTERM together are what a TUI reads to pick its colour
    // depth (chalk/supports-color/Ink all do), and the damage of understating
    // them is unrecoverable: a program that believes it has 16 colours
    // quantises its own 24-bit escapes down before xterm.js ever sees them,
    // so no theme or renderer option can bring the colour back. xterm.js
    // renders the full 24-bit range, so claiming it here is accurate rather
    // than optimistic — this deliberately overrides the inherited value.
    name: 'xterm-256color',
    cols,
    rows,
    cwd: resolveCwd(cwd),
    // COLORTERM has to be stated rather than inherited: a macOS GUI app
    // launched from Finder/Dock/Spotlight gets no login-shell environment at
    // all, so main's own process.env very likely has none (Terminal.app sets
    // it for every session it starts, which is why the same TUI looks right
    // there and washed out here).
    //
    // TABS_CONTROL_SOCKET/TABS_PANE_ID let a CLI process running in this pane
    // (e.g. an agent's `tabs-ctl` skill call, see externalControl.ts) reach
    // the app and identify itself as this pane. Their presence is also the
    // "am I running inside Tabs" gate the bundled skill checks before doing
    // anything (see resources/skills/tabs/SKILL.md).
    //
    // TERM_PROGRAM names the embedding terminal, the way every major
    // emulator does (Apple_Terminal, iTerm.app, WezTerm, ghostty) — programs
    // key real behavior off it (Claude Code, for one, picks its notification
    // channel from it). Stated after the spread for the same reason as
    // COLORTERM, but in the opposite direction: a dev `electron .` launched
    // from another terminal *does* inherit that terminal's identity, and
    // passing it through would misattribute every pane. The version rides
    // along so the pair can never disagree about which program they describe.
    env: {
      ...process.env,
      COLORTERM: 'truecolor',
      TERM_PROGRAM: 'Tabs',
      TERM_PROGRAM_VERSION: app.getVersion(),
      TABS_CONTROL_SOCKET: terminalMainCtx.get().controlSocketPath(),
      TABS_PANE_ID: id
    }
  })

  terminals.set(id, {
    pty,
    webContents,
    unregisterHost: terminalMainCtx.get().registerPaneHost(id, webContents)
  })

  // Both handlers swallow exceptions: node-pty can deliver them during final
  // app shutdown, where an escaping throw aborts the whole process (SIGABRT)
  // instead of surfacing as an error — see CLAUDE.md's before-quit gotcha.
  pty.onData((data) => {
    try {
      const entry = terminals.get(id)
      if (entry && !entry.webContents.isDestroyed())
        terminalMainCtx.get().ipc.emit(entry.webContents, terminalDataEvent(id), data)
    } catch {
      // Unreachable renderer, most likely app shutdown mid-flight — not fatal.
    }
  })

  pty.onExit(() => {
    try {
      const entry = terminals.get(id)
      terminals.delete(id)
      // A self-exiting shell must also stop passing the control caller check.
      entry?.unregisterHost()
      if (entry && !entry.webContents.isDestroyed())
        terminalMainCtx.get().ipc.emit(entry.webContents, terminalExitEvent(id))
    } catch {
      // Unreachable renderer, most likely app shutdown mid-flight — not fatal.
    }
  })

  return pty.pid
}

function writeTerminal(id: string, data: string): void {
  terminals.get(id)?.pty.write(data)
}

function resizeTerminal(id: string, cols: number, rows: number): void {
  if (cols <= 0 || rows <= 0) return
  terminals.get(id)?.pty.resize(cols, rows)
}

/** Every id with a currently-live pty — e.g. so a caller can ask each one for its cwd without walking any tree. */
export function listTerminalIds(): string[] {
  return [...terminals.keys()]
}

/**
 * Best-effort live working directory of the shell behind `id`'s pty.
 * `config.cwd` is only where the pty was spawned — the shell's own `cd`s
 * never update it — so "where the shell is now" has to come from the OS (see
 * processProbe.ts). Undefined when `id` isn't a live pty or the lookup fails.
 */
export async function getTerminalCwd(id: string): Promise<string | undefined> {
  const pid = terminals.get(id)?.pty.pid
  return pid === undefined ? undefined : getProcessCwd(pid)
}

/** Synchronous twin of `getTerminalCwd` for the quit path, which cannot await (see CLAUDE.md's before-quit gotcha). */
export function getTerminalCwdSync(id: string): string | undefined {
  const pid = terminals.get(id)?.pty.pid
  return pid === undefined ? undefined : getProcessCwdSync(pid)
}

/**
 * Whether something other than an idle shell prompt currently owns `id`'s
 * terminal — see processProbe.ts's getForegroundProcess. Undefined when
 * idle, unknown, or not a live pty: all "nothing to warn about".
 */
async function getForegroundProcess(id: string): Promise<ForegroundProcess | undefined> {
  const pid = terminals.get(id)?.pty.pid
  return pid === undefined ? undefined : getForegroundProcessOf(pid)
}

/** Synchronous twin of `getForegroundProcess`, for the quit path. */
function getForegroundProcessSync(id: string): ForegroundProcess | undefined {
  const pid = terminals.get(id)?.pty.pid
  return pid === undefined ? undefined : getForegroundProcessSyncOf(pid)
}

/** Every live terminal with something other than an idle shell prompt in its foreground — what the terminal reports as quit blockers. */
function listRunningTerminals(): CloseBlocker[] {
  const running: CloseBlocker[] = []
  for (const id of terminals.keys()) {
    const info = getForegroundProcessSync(id)
    if (info) running.push(info)
  }
  return running
}

/** Kills the pty for `id` and removes it from the registry. Safe to call twice or on an unknown id. */
function disposeTerminal(id: string): void {
  const entry = terminals.get(id)
  if (!entry) return
  terminals.delete(id)
  entry.unregisterHost()
  try {
    entry.pty.kill()
  } catch {
    // Already exited/killed — dispose must be idempotent, so swallow this.
  }
}

/** Kills every remaining pty; called on app quit so nothing is left orphaned. */
export function disposeAllTerminals(): void {
  for (const id of [...terminals.keys()]) disposeTerminal(id)
}

/** Wires the terminal's bridge methods — the main half of renderer/terminalBridge.ts. Nothing but IPC. */
export function registerTerminalIpc(): void {
  const { ipc } = terminalMainCtx.get()
  ipc.handle(TerminalMethod.create, (event, id, cwd, cols, rows) =>
    createTerminal(
      event.sender,
      id as string,
      cwd as string | undefined,
      cols as number,
      rows as number
    )
  )
  ipc.on(TerminalMethod.write, (_event, id, data) => writeTerminal(id as string, data as string))
  ipc.on(TerminalMethod.resize, (_event, id, cols, rows) =>
    resizeTerminal(id as string, cols as number, rows as number)
  )
  ipc.handle(TerminalMethod.dispose, (_event, id) => disposeTerminal(id as string))
  ipc.handle(TerminalMethod.getCwd, (_event, id) => getTerminalCwd(id as string))
}

/**
 * Terminals are what block a close/quit here: a pane with a live foreground
 * process (not just an idle prompt) is work the user should be warned about
 * destroying (see closeBlockers.ts). Its own registration, not part of the
 * IPC wiring — the provider is a capability, not a bridge method.
 */
export function registerTerminalCloseBlockers(): void {
  terminalMainCtx.get().registerCloseBlockerProvider({
    // Ids that aren't live ptys probe to undefined and drop out — the
    // provider ignores leaves it doesn't own, per the provider contract.
    collectBlockers: async (ids) => {
      const results = await Promise.all(ids.map((id) => getForegroundProcess(id)))
      return results.filter((info) => info !== undefined)
    },
    listBlockersSync: () => listRunningTerminals()
  })
}
