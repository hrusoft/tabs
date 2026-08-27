import { join } from 'node:path'
import { app } from 'electron'

/**
 * Naming scheme of the external control Unix socket. externalControl.ts
 * listens on it and sweeps stale ones at startup; terminal.ts injects it into
 * every pty's env as TABS_CONTROL_SOCKET. Builder and parser live together so
 * `control-<pid>.sock` is defined in exactly one place.
 *
 * **Per-boot on purpose** — the pid in the name is the instance coupling.
 * The path a pty carries in TABS_CONTROL_SOCKET names exactly the process
 * that spawned it: a second instance sharing this userData dir listens on
 * its own path instead of silently stealing this one (the old fixed name
 * was unlinked by whichever instance started last, rerouting every existing
 * terminal's control calls to the wrong app), and a shell or orphaned agent
 * surviving a restart dead-ends at a dead socket instead of reaching the
 * next boot — where persisted layout ids would otherwise let it pass the
 * caller check. Stale files are swept at startup (see externalControl.ts).
 */
export function controlSocketPath(): string {
  return join(app.getPath('userData'), `control-${process.pid}.sock`)
}

/** The pid embedded in a control-socket filename, or undefined when `name` isn't one — the sweep's inverse of controlSocketPath. */
export function parseControlSocketPid(name: string): number | undefined {
  const match = /^control-(\d+)\.sock$/.exec(name)
  return match ? Number(match[1]) : undefined
}
