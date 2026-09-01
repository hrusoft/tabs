import type { FloatRect } from '@shared/model/floating'
import { DEFAULT_FLOAT_RECT } from '@shared/model/floating'
import type { NodeId } from '@shared/model/types'
import { useLayoutStore } from '../../core/store/layoutStore'
import { paneDomRect } from '../paneDom'

/**
 * Where each node's window sat the last time it was pinned back, so unpinning
 * the same pane again returns it to where the user put it rather than back
 * over its docked slot. Session-only and deliberately not persisted: it is a
 * convenience, not layout state, and a restart legitimately starts over.
 *
 * Never evicted on pane close (a node id closed for good has no future unpin
 * to inform, but nothing here is told a close happened without a new
 * coupling back onto layoutStore, which every other writer here avoids), so
 * it is bounded instead — the same oldest-first-eviction shape as
 * networkBodyCapture.ts's PENDING_CAP, sized generously since an entry is
 * only a node id and four numbers.
 */
const LAST_RECTS_CAP = 200
const lastRects = new Map<NodeId, FloatRect>()

function rememberRect(nodeId: NodeId, rect: FloatRect): void {
  lastRects.delete(nodeId) // re-inserts at the end, keeping insertion order recency-ordered
  if (lastRects.size >= LAST_RECTS_CAP) {
    const oldest = lastRects.keys().next().value
    if (oldest !== undefined) lastRects.delete(oldest)
  }
  lastRects.set(nodeId, rect)
}

/**
 * Unpins the pane `nodeId` into a floating window. The window opens over the
 * pane's own place on screen so it reads as lifting off the layout in place;
 * `originId` names the node to measure when the pane itself has no rect of
 * its own (a backgrounded tab's content, which is mounted but hidden). A pane
 * with no measurable slot at all opens at the model's default geometry — the
 * store clamps it into view.
 *
 * Deliberately NOT subject to the `newUnpinnedPanePosition` setting, which
 * governs where a newly *created* unpinned pane spawns (see
 * `placeNewUnpinnedPane` in ../placement.ts). Unpinning creates no pane, it
 * relocates one, and a corner would break the lift-off-in-place reading that
 * e2e/browser/floating.spec.ts asserts. The decisive reason is `lastRects`
 * above: a pane unpinned, re-pinned and unpinned again returns to where the
 * *user* dragged it, so a default position could only either override that
 * memory — destroying a real feature — or be shadowed by it, i.e. apply to the
 * first unpin of a pane and silently stop applying to the second. A setting
 * that works once is worse than one that never claimed to.
 */
export function unpinPaneAt(nodeId: NodeId, originId: NodeId = nodeId): void {
  const rect = lastRects.get(nodeId) ?? paneRect(nodeId) ?? paneRect(originId) ?? DEFAULT_FLOAT_RECT
  useLayoutStore.getState().unpinPane(nodeId, rect)
}

/** Pins a floating window back, remembering where it sat first. */
export function repinFloatingWindow(floatId: NodeId): void {
  const state = useLayoutStore.getState()
  const entry = state.floating.find((candidate) => candidate.id === floatId)
  if (entry) rememberRect(entry.content.id, entry.rect)
  state.repinPane(floatId)
}

/** Test-only: clears the session's re-unpin memory (see renderApp's resetStores). */
export function resetUnpinMemoryForTests(): void {
  lastRects.clear()
}

/** A pane's on-screen rect as a FloatRect, or null when it has no place on screen. */
function paneRect(nodeId: NodeId): FloatRect | null {
  const rect = paneDomRect(nodeId)
  return rect ? { x: rect.left, y: rect.top, width: rect.width, height: rect.height } : null
}
