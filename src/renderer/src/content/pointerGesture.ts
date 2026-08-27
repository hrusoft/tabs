/**
 * The one flag core raises on `<body>` while a pointer-driven gesture is in
 * flight, so content that would otherwise swallow the pointer can neutralize
 * itself for the gesture's duration.
 *
 * It exists for a measured `<webview>` fact. A guest is a separate
 * WebContents, and the embedder hit-tests the `<webview>` element and routes
 * the raw input there, so the moment the pointer crosses into a guest the host
 * window stops receiving `pointermove` — and, the damaging half, never sees
 * the `pointerup`. Nothing announces it: no `pointercancel`, no
 * `lostpointercapture`, no `blur`. A gesture that ends over a guest therefore
 * never learns it ended (see `dragController`'s own recovery for what that
 * costs).
 *
 * Core only raises the flag. What has to react to it is a per-type concern —
 * a window with no browser panes has nothing to neutralize — so the rule
 * itself lives with the type that needs it, in the browser package's own CSS.
 *
 * Owner-keyed rather than a bare add/remove because the flag has two
 * independent owners (pane/tab drags in `dragController`, window move/resize
 * in `floatingDrag`) which can be armed at the same time; one finishing must
 * not strip the flag from another still in flight. A `Set` rather than a
 * counter so both halves stay idempotent — an unbalanced `begin` would
 * otherwise leave every guest permanently inert, which is a worse failure than
 * the one this prevents.
 */
const GESTURE_CLASS = 'pointer-gesture'

/** Which gesture owners are currently in flight. */
const owners = new Set<string>()

export function beginPointerGesture(owner: string): void {
  owners.add(owner)
  document.body.classList.add(GESTURE_CLASS)
}

export function endPointerGesture(owner: string): void {
  owners.delete(owner)
  if (owners.size === 0) document.body.classList.remove(GESTURE_CLASS)
}

/** What a gesture owner supplies to `armPointerGesture`: its own semantics, nothing of the lifecycle. */
export interface PointerGestureHandlers {
  /** A move by the gesture's own pointer, with the primary button still held. */
  onMove(event: PointerEvent): void
  /** The gesture's own pointer released — commit. The listeners are already gone. */
  onRelease(event: PointerEvent): void
  /** The gesture ended without a release — restore. The listeners are already gone. */
  onCancel(): void
}

/**
 * The pointer-gesture lifecycle both owners share, stated once: the four
 * window listeners, the flag above, and the three rules for ending without a
 * drop. Returns the teardown, for an owner that ends its own session (a drop,
 * a competing gesture) — idempotent, like the flag.
 *
 * The rules, each measured rather than assumed:
 * - Only the pointer that armed the gesture counts; a second pointer pressing
 *   mid-gesture is ignored, like a native drag session.
 * - A `pointermove` with the primary button no longer held is the only
 *   evidence of a release the host never saw — it landed in a `<webview>`
 *   guest (the flag above exists to prevent exactly that), on native chrome
 *   (the traffic lights, an app-region drag strip), or outside the window.
 *   No event announces it. Cancelled rather than committed at the last known
 *   target: where the release actually happened is precisely what was lost,
 *   and a session left armed is actively destructive — it refuses every later
 *   gesture for the life of the window, and the next unrelated click's
 *   pointerup lands as a drop of the stale subject wherever the pointer
 *   happens to be.
 * - Escape cancels, registered in the capture phase so a focused terminal
 *   inside the thing being dragged can't eat the key first — the same reason
 *   spatialNav registers its chord listener that way.
 */
export function armPointerGesture(
  owner: string,
  pointerId: number,
  handlers: PointerGestureHandlers
): () => void {
  const teardown = (): void => {
    window.removeEventListener('pointermove', onMove)
    window.removeEventListener('pointerup', onUp)
    window.removeEventListener('pointercancel', onCancel)
    window.removeEventListener('keydown', onKeyDown, true)
    endPointerGesture(owner)
  }
  const cancel = (): void => {
    teardown()
    handlers.onCancel()
  }
  const onMove = (event: PointerEvent): void => {
    if (event.pointerId !== pointerId) return
    if ((event.buttons & 1) === 0) {
      cancel()
      return
    }
    handlers.onMove(event)
  }
  const onUp = (event: PointerEvent): void => {
    if (event.pointerId !== pointerId) return
    teardown()
    handlers.onRelease(event)
  }
  const onCancel = (event: PointerEvent): void => {
    if (event.pointerId === pointerId) cancel()
  }
  const onKeyDown = (event: KeyboardEvent): void => {
    if (event.key === 'Escape') cancel()
  }
  beginPointerGesture(owner)
  window.addEventListener('pointermove', onMove)
  window.addEventListener('pointerup', onUp)
  window.addEventListener('pointercancel', onCancel)
  window.addEventListener('keydown', onKeyDown, true)
  return teardown
}
