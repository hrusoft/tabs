/**
 * The boundary for a UI-triggered action nothing awaits — header buttons,
 * pane shortcuts, palette commits, the empty pane's toolbar. These paths can
 * genuinely reject (`deriveConfig`'s contract is that a rejection aborts the
 * creation, and the terminal's hook is a real IPC round trip), and a bare
 * `void promise` turns that into an unhandled rejection with no attribution —
 * a button press that does nothing. A rejection becomes a report, never a
 * silent no-op: the same boundary dispatchFocus draws around a pane handle.
 *
 * Applied by the *dispatchers* (HeaderButton's click, the shortcut table's
 * subscription, the palette's select), not by each handler: a handler is free
 * to be sync or async, and a new async one cannot opt out of the report by
 * forgetting to wrap itself.
 */
/** A UI handler: sync, or async with its rejection reported by `fireAndReport`. */
export type UiAction = () => unknown

export function fireAndReport(action: UiAction): void {
  const result = action()
  if (result instanceof Promise) {
    result.catch((error) => {
      console.error('[tabs] async UI action failed:', error)
    })
  }
}
