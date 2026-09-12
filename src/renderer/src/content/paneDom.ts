import type { NodeId } from '@shared/model/types'
import { PANE_ATTR } from '@shared/paneDomAttrs'

/**
 * A pane's on-screen rect, measured from the live DOM by the `data-dock-id`
 * attribute every pane div carries (see `Pane`) — or null when it has no place
 * on screen (a hidden tab's content, which is mounted but zero-sized).
 */
export function paneDomRect(nodeId: NodeId): DOMRect | null {
  const el = document.querySelector<HTMLElement>(`[${PANE_ATTR.dock}="${CSS.escape(nodeId)}"]`)
  const rect = el?.getBoundingClientRect()
  return rect && rect.width > 0 && rect.height > 0 ? rect : null
}

/**
 * Whether keyboard focus currently sits inside `nodeId`'s own chrome bar —
 * the `.pane-header` (or tab strip) stamped with `data-pane-drag-id`. A
 * content type's `PaneHandle.focus` asks this before taking the keyboard: a
 * click on a pane's own header control (an address bar, a path input)
 * activates the pane too, and the content must not yank focus off whatever
 * the user just chose there.
 */
export function focusIsInPaneChrome(nodeId: NodeId): boolean {
  return document.activeElement?.closest(`[${PANE_ATTR.paneDrag}="${nodeId}"]`) != null
}
