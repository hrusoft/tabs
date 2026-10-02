/**
 * `CloseBlocker`/`CloseBlockerProvider` — the pure contract a content type's
 * "would closing this destroy live work?" provider satisfies. The
 * registry itself (`registerCloseBlockerProvider`, `collectCloseBlockers`,
 * `collectCloseBlockersSync`) is stateful and stays core-owned, in
 * `src/main/closeBlockers.ts`, which imports these types back. Already
 * Electron-free here for the same reason it was in the original file: the
 * dialogs themselves live in closeDialogs.ts, so this half stays
 * cycle-proof and unit-testable.
 */

/** One thing still doing work — what the confirmation dialogs list. */
export interface CloseBlocker {
  command: string | undefined
}

export interface CloseBlockerProvider {
  /**
   * Blockers among `ids` (leaf ContentNode ids of the subtree being closed).
   * Ids the provider doesn't own must be ignored, not errors.
   */
  collectBlockers(ids: string[]): Promise<CloseBlocker[]>
  /**
   * Every blocker across this provider's own live resources, for quit. Must
   * come from the provider's registry, never a layout walk — the layout is a
   * forest, and a walk would miss floating panes — and must be fully
   * synchronous: it runs inside `before-quit`, whose no-async discipline is
   * documented in CLAUDE.md's before-quit gotcha.
   */
  listBlockersSync(): CloseBlocker[]
}
