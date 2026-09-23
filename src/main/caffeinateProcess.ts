import type { ChildProcess } from 'node:child_process'

/**
 * The one live `caffeinate(8)` process reference, and the operations on it
 * that need nothing else — no Electron, no menu rebuild, no IPC. Its own
 * module for the same reason `shortcutCapture.ts` is: `caffeinate.ts` (the
 * orchestration — spawning, broadcasting state changes, IPC registration)
 * imports `applyMenu` from `menu.ts`, and `menu.ts` needs to read whether a
 * process is running and be able to stop one — importing either straight
 * from `caffeinate.ts` would be a cycle. Reading and stopping live here
 * instead, which neither side of that edge needs to import the other for.
 */

let current: ChildProcess | null = null

/** The live process, or null — for caffeinate.ts's own spawn/exit bookkeeping. */
export function caffeinateProcess(): ChildProcess | null {
  return current
}

/** Sets the live process reference — for caffeinate.ts's own spawn/exit bookkeeping. */
export function setCaffeinateProcess(child: ChildProcess | null): void {
  current = child
}

/** True while the managed process is running. The single source of truth every other surface (menu label, cup button, dialog gating) reads from. */
export function isCaffeinateRunning(): boolean {
  return current !== null
}

/**
 * The OS pid of the managed process, or undefined if none is running.
 * e2e-only surface (exposed through `__tabsE2e`, see main/e2e.ts): a test
 * proving "quitting the app stops the process" has to check the real OS
 * process by its specific pid, never by name — CLAUDE.md's "several
 * checkouts at once" entry is exactly why a name-based check (`pgrep -f
 * caffeinate`) would be a machine-global lie on any Mac already running an
 * unrelated caffeinate.
 */
export function currentCaffeinatePid(): number | undefined {
  return current?.pid
}

/**
 * Stops the managed process, if one is running. Signal-only: the actual
 * "not running any more" broadcast happens once the process really exits,
 * from caffeinate.ts's own `exit` handler — not assumed here.
 */
export function stopCaffeinate(): void {
  current?.kill()
}

/**
 * A plain signal send on an *already-spawned* handle — not a fork, so it
 * carries none of the "spawning a child from before-quit" shutdown hazard
 * CLAUDE.md documents (that hazard is specifically about forking *new*
 * processes, e.g. lsof, during teardown). `current` is nulled synchronously
 * here, before the async `exit` event this triggers can ever fire, so
 * caffeinate.ts's exit handler's identity guard turns that event into a
 * no-op once torn down.
 */
export function killCaffeinateSync(): void {
  current?.kill()
  current = null
}

/** e2e only: kills any process left running from a previous test — mutable main-process state (see main/e2e.ts's reset). */
export function resetCaffeinateForTests(): void {
  killCaffeinateSync()
}
