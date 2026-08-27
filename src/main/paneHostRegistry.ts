import type { WebContents } from 'electron'

/**
 * Core's registry of which WebContents currently hosts each externally
 * controllable pane. One map answers two distinct questions for
 * externalControl.ts: `hasPaneHost` is the *authorization* check (may this
 * pane id originate control requests at all), `getPaneHost` is the *routing*
 * lookup (which renderer to relay a request to). A content type registers a
 * pane when its backing resource goes live and deregisters on disposal;
 * nothing here mentions ptys or any other content specifics. Deliberately
 * Electron-free apart from the erased type import, so this module stays
 * cycle-proof and unit-testable (see closeBlockers.ts for the pattern).
 */
const hosts = new Map<string, WebContents>()

/**
 * Registers (or, on a remount, re-points) the host for `paneId` and returns
 * the disposer that undoes it. Registering an id again *replaces* the
 * mapping — a reattach is routine, not a conflict. The disposer removes only
 * the mapping it created: once a replacement has landed, a stale disposer is
 * a no-op, so dispose-after-reattach ordering can't drop a live pane.
 */
export function registerPaneHost(paneId: string, webContents: WebContents): () => void {
  hosts.set(paneId, webContents)
  return () => {
    if (hosts.get(paneId) === webContents) hosts.delete(paneId)
  }
}

/**
 * Whether `paneId` may originate control requests — the caller-identity check
 * behind every request (see handleRequest in externalControl.ts).
 * Deliberately registration-only, with no isDestroyed() check: relay does its
 * own destroyed check, and this is a security boundary whose observable
 * behavior must not drift.
 */
export function hasPaneHost(paneId: string): boolean {
  return hosts.has(paneId)
}

/** The WebContents currently hosting `paneId`, if any — relay routing. */
export function getPaneHost(paneId: string): WebContents | undefined {
  return hosts.get(paneId)
}

/** Drops every mapping — see src/main/e2e.ts's reset. */
export function resetPaneHostsForTests(): void {
  hosts.clear()
}
