import type { NodeId } from '@shared/model/types'
import type { RefObject } from 'react'
import type { GroupImperativeHandle } from 'react-resizable-panels'

export interface RegisteredSplitGroup {
  groupRef: RefObject<GroupImperativeHandle | null>
  elRef: RefObject<HTMLDivElement | null>
  /**
   * This split's own children, in the same order as its `sizes` array — kept
   * live (assigned during render, not just in an effect) so a cross-split
   * reader can convert `groupRef.current.getLayout()`'s `{panelId: percent}`
   * map back into a positional `sizes` array matching applyBoundaryAtPixel's
   * `index` convention. `getLayout()` alone can't provide this ordering.
   */
  childIdsRef: RefObject<NodeId[]>
}

/**
 * Every currently-mounted split, keyed by its node id — the only way to
 * reach another split's live `<Group>` handle and move it imperatively
 * (see mirrorClusterMembers in SplitRenderer.tsx). `<Group defaultLayout>`
 * is uncontrolled: writing a new size into the layout store doesn't move an
 * already-mounted group, only that group's own groupRef.setLayout does.
 */
const registry = new Map<NodeId, RegisteredSplitGroup>()

export function registerSplitGroup(id: NodeId, entry: RegisteredSplitGroup): void {
  registry.set(id, entry)
}

export function unregisterSplitGroup(id: NodeId): void {
  registry.delete(id)
}

export function getSplitGroup(id: NodeId): RegisteredSplitGroup | undefined {
  return registry.get(id)
}

// react-resizable-panels notifies a Group's onLayoutChange synchronously and
// inline on every mutable-state write — including one caused by another
// Group's imperative setLayout call, not just native pointer input. So a
// split that mirrors a delta into another aligned split via setLayout
// synchronously re-enters that other split's own onLayoutChange, nested on
// the call stack. Two mutually-aligned splits that are both natively
// co-dragged in one gesture would otherwise each try to mirror into the
// other, recursing back and forth with no structural bound on depth. This
// flag makes it a no-op instead: a split whose layout changed only because
// another split's handler pushed a value into it does nothing this tick —
// it's a passive recipient, not a fresh mirror source.
let mirrorDepth = 0

export function isMirrorApplyInProgress(): boolean {
  return mirrorDepth > 0
}

export function withMirrorApply<T>(fn: () => T): T {
  mirrorDepth++
  try {
    return fn()
  } finally {
    mirrorDepth--
  }
}

// Whether the drag reaching a split's onLayoutChange this tick is one leg of
// a genuine multi-group native intersection (react-resizable-panels froze
// several groups' separators into the same pointer gesture because they
// geometrically meet at one point — see the module doc in SplitRenderer.tsx)
// or an ordinary single-group drag that merely happens, by coincidence, to
// currently sit at the same pixel as some unrelated separator elsewhere
// (e.g. two freshly-created, independently-adjustable splits that both
// default to an even 50/50 division land on the same x purely by
// construction, never having been snapped together). Cluster mirroring must
// only ever extend the FIRST kind — extending the second would silently
// drag an untouched, merely-coincidental separator along for a plain solo
// resize, which is surprising and was reported as breaking the self-snap
// feature (a lone drag snapping onto a stationary target must never move
// that target).
//
// The two can't be told apart by geometry or by which group's onLayoutChange
// is executing right now, because the library's per-group notifications for
// one native pointermove are synchronous but sequential, not simultaneous —
// whichever group's callback runs first in that pass has no way to see
// whether a sibling's callback, due later in the very same pass, will also
// fire. So this defers the answer by one tick: every split reports itself
// here on every tick it's part of an active drag; a microtask (which never
// runs until the whole synchronous batch of same-event callbacks has
// finished — including every group matchingHitRegions() froze together)
// settles that tick's full roster before the *next* tick can possibly ask.
// SplitRenderer only consults wasCoDraggedLastTick() starting on a gesture's
// second tick, by which point the answer always reflects a fully-settled
// prior tick, never a partial, still-being-populated one.
let tickParticipants = new Set<NodeId>()
let tickResolved = new Set<NodeId>()
let tickFinalizeScheduled = false

export function reportGestureTick(splitId: NodeId): void {
  tickParticipants.add(splitId)
  if (!tickFinalizeScheduled) {
    tickFinalizeScheduled = true
    queueMicrotask(() => {
      tickResolved = tickParticipants
      tickParticipants = new Set()
      tickFinalizeScheduled = false
    })
  }
}

export function wasCoDraggedLastTick(): boolean {
  return tickResolved.size >= 2
}
