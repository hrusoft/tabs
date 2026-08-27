/**
 * The terminal package's bridge vocabulary: method names its main entry
 * registers (`ctx.ipc.handle`/`ctx.ipc.on`) and its renderer client calls,
 * and the per-pane event names main emits. Channel strings no longer exist
 * here — the generic bridge derives them (`plugin:terminal:…`, see
 * shared/plugin/bridge.ts), so main and the renderer agree by construction
 * rather than by keeping two literals in sync.
 */
export const TerminalMethod = {
  create: 'create',
  write: 'write',
  resize: 'resize',
  dispose: 'dispose',
  getCwd: 'getCwd'
} as const

/** Per-terminal output stream (`data:<leaf id>`). */
export function terminalDataEvent(id: string): string {
  return `data:${id}`
}

/** Per-terminal exit notification (`exit:<leaf id>`). */
export function terminalExitEvent(id: string): string {
  return `exit:${id}`
}
