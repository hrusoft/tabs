/**
 * The one bit menu.ts and shortcuts.ts must agree on without importing each
 * other: whether a Settings window is currently recording a new combination
 * (see shortcuts.ts for why recording requires suspending the menu at all).
 * Its own one-value module, like platform.ts and e2eHidden.ts — menu.ts reads
 * it while building, shortcuts.ts writes it from the arm/disarm IPC and then
 * calls menu.ts's applyMenu directly, so neither module imports the other.
 */

let captureOwner: number | null = null

/** True while a window is recording a combination — buildMenu omits accelerators when it is. */
export function isShortcutCaptureActive(): boolean {
  return captureOwner !== null
}

export function shortcutCaptureOwner(): number | null {
  return captureOwner
}

export function setShortcutCaptureOwner(id: number | null): void {
  captureOwner = id
}
