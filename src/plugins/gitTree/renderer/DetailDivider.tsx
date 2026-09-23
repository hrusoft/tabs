import { useRef } from 'react'
import { type DetailSplit, resolveDetailDrag } from './detailSplit'

/** A drag in progress — a ref, since nothing about being mid-gesture needs a re-render of its own. */
interface DividerDrag {
  pointerId: number
  startY: number
  /** How far the divider's top edge sat above the body's bottom when the drag began: the detail panel's height, or the collapsed bar's. */
  startHeight: number
  bodyHeight: number
  /** The split the gesture began from — what a collapse keeps the open fraction of. */
  origin: DetailSplit
  latest: DetailSplit
}

/**
 * The divider between the commit list and the detail panel: drag it to resize
 * the two, below the details' minimum to collapse them, and back up from the
 * bottom to reopen them. See detailSplit.ts for the rules, and gitTree.css for
 * why it is zero-height while the details are open.
 *
 * Hand-rolled rather than a react-resizable-panels `Group`, because that
 * library hit-tests globally: a pointerdown collects *every* mounted
 * separator's band under the pointer and drags all of them, so a collapsed
 * divider at the pane's bottom and a core split separator just below the pane
 * would move together. This one yields instead — the library claims a press
 * in its own band with `preventDefault` from a document capture listener,
 * which runs before this handler, so `defaultPrevented` means "that press
 * resizes the split, not the details".
 *
 * Pointer capture keeps the drag following a pointer that leaves the pane, the
 * same mechanism core split separators ride. A release this element never
 * sees (over a `<webview>` guest, say) shows up as a move with the button no
 * longer held, and ends the drag where it was last shown — safe here in a way
 * it isn't for a pane drop, since a resize destroys nothing. Only the release
 * reaches the pane's config; every frame before it is `onPreview`, local to
 * the renderer.
 *
 * Not focusable, like core split separators (see SplitRenderer's comment on
 * its own): a press here must leave the keyboard on the commit list, which is
 * also why `mousedown` is cancelled — that, not `pointerdown`, is what moves
 * focus and starts a text selection. And so hidden from assistive technology
 * rather than given the `separator` role: that role with a value is a
 * splitter, a focusable widget operated from the keyboard, and announcing one
 * that no keyboard can reach would be a control that can't be used.
 */
export function DetailDivider({
  split,
  onPreview,
  onCommit
}: {
  split: DetailSplit
  onPreview(split: DetailSplit): void
  onCommit(split: DetailSplit): void
}) {
  const drag = useRef<DividerDrag | null>(null)

  const finish = (): void => {
    const current = drag.current
    if (!current) return
    drag.current = null
    onCommit(current.latest)
  }

  return (
    <div
      className={
        split.collapsed ? 'git-tree-divider git-tree-divider-collapsed' : 'git-tree-divider'
      }
      data-testid="git-tree-divider"
      data-collapsed={split.collapsed || undefined}
      aria-hidden="true"
      onMouseDown={(event) => event.preventDefault()}
      onPointerDown={(event) => {
        if (event.defaultPrevented || event.button !== 0 || drag.current) return
        const body = event.currentTarget.parentElement
        if (!body) return
        const bodyRect = body.getBoundingClientRect()
        drag.current = {
          pointerId: event.pointerId,
          startY: event.clientY,
          startHeight: bodyRect.bottom - event.currentTarget.getBoundingClientRect().top,
          bodyHeight: bodyRect.height,
          origin: split,
          latest: split
        }
        // Optional-called: jsdom has no pointer capture.
        event.currentTarget.setPointerCapture?.(event.pointerId)
      }}
      onPointerMove={(event) => {
        const current = drag.current
        if (!current || event.pointerId !== current.pointerId) return
        if ((event.buttons & 1) === 0) {
          finish()
          return
        }
        const next = resolveDetailDrag(
          current.startHeight + current.startY - event.clientY,
          current.bodyHeight,
          current.origin
        )
        if (
          next.collapsed === current.latest.collapsed &&
          next.fraction === current.latest.fraction
        ) {
          return
        }
        current.latest = next
        onPreview(next)
      }}
      onPointerUp={(event) => {
        if (drag.current?.pointerId === event.pointerId) finish()
      }}
      // Fires after every release too, by which point `finish` has already
      // run and this is a no-op; it matters only when capture ends without
      // one (a pointercancel).
      onLostPointerCapture={finish}
    />
  )
}
