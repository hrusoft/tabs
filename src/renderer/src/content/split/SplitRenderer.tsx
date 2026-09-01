import {
  applyBoundaryAtPixel,
  boundaryPixelPosition,
  computeSnappedSizes,
  SEPARATOR_ALIGNMENT_THRESHOLD_PX
} from '@shared/model/separatorSnap'
import { MIN_PANE_SIZE } from '@shared/model/tree'
import type { NodeId, SplitContent } from '@shared/model/types'
import { Fragment, useEffect, useRef } from 'react'
import {
  Group,
  type GroupImperativeHandle,
  type Layout,
  Panel,
  Separator
} from 'react-resizable-panels'
import type { ContentRendererProps } from '../../core/registry/registry'
import { useLayoutStore } from '../../core/store/layoutStore'
import { useSettingsStore } from '../../core/store/settingsStore'
import { ContentView } from '../ContentView'
import { markSplitResizeActive, markSplitResizeReleased } from '../dragController'
import {
  getSplitGroup,
  isMirrorApplyInProgress,
  registerSplitGroup,
  reportGestureTick,
  unregisterSplitGroup,
  wasCoDraggedLastTick,
  withMirrorApply
} from './separatorRegistry'

// The drag clamp react-resizable-panels enforces, derived from the same
// constant normalizeSizes clamps persisted/programmatic sizes to — the two
// must agree or a drag could produce a size the model immediately repairs.
const MIN_PANE_SIZE_PERCENT: `${number}%` = `${MIN_PANE_SIZE * 100}%`

/**
 * The two directions of the only conversion this file does: react-resizable-
 * panels speaks a `{panelId: percent}` map, the model speaks positional ratios
 * summing to 1. Both the ×100 and the ordering are the convention
 * `RegisteredSplitGroup.childIdsRef` exists to preserve, and getting either
 * backwards is silent rather than loud — a ratio 100× off just clamps at
 * MIN_PANE_SIZE, i.e. a separator that quietly stops moving.
 */
function sizesFromLayout(layout: Layout, childIds: NodeId[]): number[] {
  return childIds.map((id) => (layout[id] ?? 0) / 100)
}

function layoutFromSizes(childIds: NodeId[], sizes: number[]): Layout {
  return Object.fromEntries(childIds.map((id, index) => [id, (sizes[index] ?? 0) * 100]))
}

/** One other split whose separator was aligned with this drag's own at the moment it started. */
interface ClusterMember {
  splitId: NodeId
  /** Which of the member's own separators (its `sizes` boundary index) this is. */
  childIndex: number
  /**
   * This member's own absolute page-pixel position when the cluster was
   * discovered. Deliberately NOT paired with a cached container rect —
   * unlike `initialPx` (a page coordinate, stable regardless of later
   * layout), a member's container geometry must be re-measured fresh on
   * every tick in mirrorClusterMembers. A member nested inside a pane whose
   * size is itself changing as a side effect of this same drag (e.g. a
   * split nested inside one side of the primary drag's own two panes) would
   * otherwise have its ratio computed against a stale, increasingly-wrong
   * container width — visibly "detaching" from the cursor (freezing, often
   * via the MIN_PANE_SIZE clamp on a bogus out-of-range ratio) while the
   * natively-dragged separators keep tracking correctly.
   */
  initialPx: number
}

/** A live drag gesture on this split's separator `index`, and the other splits moving with it. */
interface DragGesture {
  index: number
  initialPx: number
  members: ClusterMember[]
}

export function SplitRenderer({
  node,
  cornerLeft,
  cornerRight
}: ContentRendererProps<SplitContent>) {
  const resizeSplit = useLayoutStore((state) => state.resizeSplit)
  // Remount the group when the pane set changes so defaultLayout reseeds;
  // plain drag-resizes keep the same key and stay uncontrolled.
  const paneKey = node.children.map((child) => child.id).join('|')

  const groupRef = useRef<GroupImperativeHandle | null>(null)
  const groupElRef = useRef<HTMLDivElement | null>(null)
  const isHorizontal = node.direction === 'horizontal'

  /**
   * Which of *this* split's own two corner flags (received from above) a
   * given child inherits — see ContentRendererProps.cornerLeft/cornerRight.
   * A horizontal split lays children side by side, each spanning the full
   * height: only the first (leftmost) can ever own the left corner, only the
   * last (rightmost) the right — never both on one child unless there's only
   * one, and never on a middle child of 3+, which touches neither. A
   * vertical split stacks children full-width: everything but the last
   * touches no bottom corner at all, and the last owns both, since it alone
   * spans the full width down at the actual bottom edge.
   */
  function childCorners(index: number): { cornerLeft: boolean; cornerRight: boolean } {
    const isFirst = index === 0
    const isLast = index === node.children.length - 1
    return isHorizontal
      ? { cornerLeft: isFirst && cornerLeft === true, cornerRight: isLast && cornerRight === true }
      : { cornerLeft: isLast && cornerLeft === true, cornerRight: isLast && cornerRight === true }
  }

  // Kept live every render (not just in an effect) so a cross-split reader
  // — via the registry, mid-gesture — always sees this split's current
  // child order, which never changes mid-drag but must never be stale.
  const childIdsRef = useRef<NodeId[]>([])
  childIdsRef.current = node.children.map((child) => child.id)

  useEffect(() => {
    registerSplitGroup(node.id, { groupRef, elRef: groupElRef, childIdsRef })
    return () => unregisterSplitGroup(node.id)
  }, [node.id])

  // Cleared whenever no drag is in progress (see onLayoutChange), so a new
  // gesture always rediscovers its cluster fresh rather than reusing stale
  // members from a previous drag.
  const gestureRef = useRef<DragGesture | null>(null)

  // Whether this gesture has already completed an onLayoutChange tick.
  // Cluster discovery only starts on the second, once wasCoDraggedLastTick()
  // can answer for certain whether the first was a genuine multi-group native
  // intersection — see separatorRegistry's reportGestureTick. Set at the end
  // of the tick, so the tick that sets it isn't itself treated as the second.
  const hadPriorTickRef = useRef(false)

  /**
   * Which separator moved, found by diffing the live (unsnapped) sizes
   * against node.sizes — the last value committed to the store, which stays
   * put for the whole gesture since only the eventual onLayoutChanged commits
   * it. A plain drag only ever changes the two children adjacent to the
   * dragged separator (everything else in the split holds still), so exactly
   * one adjacent pair differing identifies both the separator and, for free,
   * rules out a native pointerdown/index tracking approach: the pointerdown
   * that starts a drag almost always lands on the neighboring PANE, not the
   * ~0px-wide separator element itself (confirmed empirically — the library
   * does its own geometric hit-testing rather than relying on where the
   * event's native target landed), so there is no reliable DOM event to hang
   * "which separator is this" off of. Null when the changed set isn't a
   * clean adjacent pair (e.g. a min-size clamp cascaded into a third pane) —
   * snapping just sits out that tick rather than guess.
   */
  function draggedIndex(sizes: number[]): number | null {
    const changed: number[] = []
    sizes.forEach((size, i) => {
      if (Math.abs(size - (node.sizes[i] ?? 0)) > 1e-4) changed.push(i)
    })
    return changed.length === 2 && changed[1] === changed[0]! + 1 ? changed[1]! : null
  }

  /** One candidate separator, with the single measurement every caller wants of it. */
  interface SeparatorProbe {
    el: HTMLElement
    /** Its current position along this split's resize axis. */
    pos: number
  }

  /**
   * Every OTHER split's separators of the same orientation, currently on
   * screen — the pool both self-snap and cluster discovery draw candidates
   * from. Measured here rather than by each caller: this runs on every
   * pointer-driven tick of a drag, and both callers want exactly this number,
   * so returning the elements alone had every one of them read back through a
   * second `getBoundingClientRect()` pass.
   *
   * A separator is deliberately 0-width/0-height along its own resize axis
   * (see the .split-separator rule in global.css), so "is this one actually on
   * screen" has to check the CROSS axis instead — the main axis is ~0 by
   * design even for a fully visible separator.
   */
  function otherSeparators(): SeparatorProbe[] {
    const probes: SeparatorProbe[] = []
    for (const el of document.querySelectorAll<HTMLElement>('.split-separator')) {
      if (el.dataset.splitId === node.id || el.dataset.splitDirection !== node.direction) continue
      const rect = el.getBoundingClientRect()
      if ((isHorizontal ? rect.height : rect.width) <= 0) continue
      probes.push({ el, pos: isHorizontal ? rect.left : rect.top })
    }
    return probes
  }

  interface BoundaryContext {
    index: number
    containerStart: number
    containerLength: number
  }

  interface DragContext extends BoundaryContext {
    sizes: number[]
  }

  /**
   * Overrides the live drag's own layout with a snapped one when the dragged
   * separator's pixel position lands close to another separator's — one
   * belonging to a different split, anywhere currently rendered — via
   * groupRef.setLayout. A no-op whenever nothing is within
   * SEPARATOR_SNAP_THRESHOLD_PX.
   */
  function maybeSnap({ sizes, index, containerStart, containerLength }: DragContext): void {
    const snapped = computeSnappedSizes({
      sizes,
      index,
      containerStart,
      containerLength,
      candidates: otherSeparators().map((probe) => probe.pos)
    })
    if (!snapped) return
    withMirrorApply(() => {
      groupRef.current?.setLayout(layoutFromSizes(childIdsRef.current, snapped))
    })
  }

  /**
   * The other splits whose separator (same orientation) currently sits
   * within SEPARATOR_ALIGNMENT_THRESHOLD_PX of this drag's own pre-drag
   * position — i.e. the "aligned cluster" this gesture should carry along.
   * Unconditional — unlike maybeSnap's snap-toward-alignment convenience,
   * this doesn't check the snapResizeSeparators setting; already-aligned
   * separators move together purely by virtue of their current geometry.
   * Only called once wasCoDraggedLastTick() has confirmed this gesture is a
   * genuine multi-group native intersection (see mirrorClusterMembers and
   * separatorRegistry's module doc) — otherwise a merely-coincidental
   * alignment (e.g. two independent even splits that both default to 50/50)
   * would get treated as an established cluster from a plain solo drag.
   * Resolved once per gesture, from each candidate's own
   * `data-split-id`/`data-separator-index` and the separatorRegistry (which
   * is how another split's live groupRef/container is reached — the store
   * can't move an already-mounted, uncontrolled Group).
   */
  function discoverCluster(
    index: number,
    containerStart: number,
    containerLength: number
  ): DragGesture {
    const initialPx = boundaryPixelPosition({
      sizes: node.sizes,
      index,
      containerStart,
      containerLength
    })

    const members: ClusterMember[] = []
    for (const { el, pos } of otherSeparators()) {
      if (Math.abs(pos - initialPx) > SEPARATOR_ALIGNMENT_THRESHOLD_PX) continue

      const splitId = el.dataset.splitId as NodeId
      const childIndex = Number(el.dataset.separatorIndex)
      if (!getSplitGroup(splitId) || Number.isNaN(childIndex)) continue

      members.push({ splitId, childIndex, initialPx: pos })
    }

    return { index, initialPx, members }
  }

  /**
   * Carries this gesture's pixel delta into every cluster member, moving
   * each to `member.initialPx + deltaPx` — a plain shift, not a fresh
   * "nearest candidate" snap, since the alignment was already established
   * when the cluster was discovered. Runs after maybeSnap so the delta
   * reflects this split's own post-self-snap live position.
   */
  function mirrorClusterMembers({ index, containerStart, containerLength }: BoundaryContext): void {
    if (!gestureRef.current) {
      // Only discover starting on the gesture's second tick, once
      // wasCoDraggedLastTick() can answer for certain — see its doc comment
      // and the module doc above. Skipping tick one here (rather than
      // discovering early and just gating the result) means the first tick
      // never even measures candidates for a solo drag, avoiding any risk of
      // caching a coincidental one before the real answer is known.
      if (!hadPriorTickRef.current || !wasCoDraggedLastTick()) return
      gestureRef.current = discoverCluster(index, containerStart, containerLength)
    }
    const gesture = gestureRef.current
    if (gesture.members.length === 0) return

    const ownLayout = groupRef.current?.getLayout()
    if (!ownLayout) return
    const currentPx = boundaryPixelPosition({
      sizes: sizesFromLayout(ownLayout, childIdsRef.current),
      index: gesture.index,
      containerStart,
      containerLength
    })
    const deltaPx = currentPx - gesture.initialPx

    for (const member of gesture.members) {
      const memberGroup = getSplitGroup(member.splitId)
      const memberEl = memberGroup?.elRef.current
      const memberLayout = memberGroup?.groupRef.current?.getLayout()
      if (!memberGroup || !memberEl || !memberLayout) continue

      // Measured fresh every tick, not cached from discovery — see the
      // comment on ClusterMember.
      const memberRect = memberEl.getBoundingClientRect()
      const memberChildIds = memberGroup.childIdsRef.current
      const applied = applyBoundaryAtPixel({
        sizes: sizesFromLayout(memberLayout, memberChildIds),
        index: member.childIndex,
        containerStart: isHorizontal ? memberRect.left : memberRect.top,
        containerLength: isHorizontal ? memberRect.width : memberRect.height,
        targetPx: member.initialPx + deltaPx
      })
      if (!applied) continue

      withMirrorApply(() => {
        memberGroup.groupRef.current?.setLayout(layoutFromSizes(memberChildIds, applied))
      })
    }
  }

  /** Commits every cluster member's current (mirrored) sizes to the store, mirroring the primary's own onLayoutChanged commit below. */
  function commitClusterMembers(): void {
    const gesture = gestureRef.current
    gestureRef.current = null
    hadPriorTickRef.current = false
    if (!gesture) return

    for (const member of gesture.members) {
      const memberGroup = getSplitGroup(member.splitId)
      const memberLayout = memberGroup?.groupRef.current?.getLayout()
      if (!memberGroup || !memberLayout) continue
      resizeSplit(member.splitId, sizesFromLayout(memberLayout, memberGroup.childIdsRef.current))
    }
  }

  return (
    <Group
      key={paneKey}
      className="split-view"
      orientation={node.direction}
      defaultLayout={layoutFromSizes(childIdsRef.current, node.sizes)}
      elementRef={(el) => {
        groupElRef.current = el
      }}
      groupRef={groupRef}
      // Neither callback carries the drag itself (the library exposes no
      // onDragStart/onDragEnd) — markSplitResizeActive synthesizes the live
      // signal (isSplitResizing) so the resize exclusively owns the pointer
      // gesture, and markSplitResizeReleased makes the click settling the
      // release act on nothing.
      onLayoutChange={(layout) => {
        // A layout change caused by this split's OWN maybeSnap/mirror
        // setLayout call, not fresh pointer input — nothing to do, and
        // recursing back into snap/mirror here would just re-derive the
        // same target (or, for a mutually-aligned pair of natively-dragged
        // splits, chase each other back and forth). See separatorRegistry's
        // withMirrorApply.
        if (isMirrorApplyInProgress()) return
        markSplitResizeActive()

        const containerEl = groupElRef.current
        if (!containerEl) return
        const sizes = sizesFromLayout(layout, childIdsRef.current)
        const index = draggedIndex(sizes)
        if (index == null) {
          // A single tick's worth of ambiguity mid-gesture (e.g. a fast,
          // jerky pointer move whose delta pushed a third pane past its own
          // MIN_PANE_SIZE in the same tick as the intended pair — see
          // draggedIndex) — NOT the same as no drag being in progress.
          // Deliberately does not clear gestureRef/tickCountRef: the only
          // real gesture boundary is release (commitClusterMembers, below).
          // Wiping an established cluster here would be unrecoverable —
          // rediscovery anchors to node.sizes, the pre-drag baseline that
          // never changes mid-gesture, so by "some point" into a real drag
          // both the primary and any already-mirrored members have moved
          // well outside SEPARATOR_ALIGNMENT_THRESHOLD_PX of that anchor and
          // could never be found again, while native dragging (driven
          // entirely by the library, oblivious to any of this) keeps right
          // on going — the separator "detaches" for the rest of the gesture.
          // Simply sitting out this one tick lets the next valid tick resume
          // from the same established gesture.
          return
        }

        const rect = containerEl.getBoundingClientRect()
        const containerStart = isHorizontal ? rect.left : rect.top
        const containerLength = isHorizontal ? rect.width : rect.height

        // Snap-toward-alignment is the opt-in convenience the setting
        // controls; carrying an already-aligned cluster along together is
        // not — see discoverCluster's doc comment.
        if (useSettingsStore.getState().snapResizeSeparators) {
          maybeSnap({ sizes, index, containerStart, containerLength })
        }
        reportGestureTick(node.id)
        mirrorClusterMembers({ index, containerStart, containerLength })
        hadPriorTickRef.current = true
      }}
      onLayoutChanged={(layout, meta) => {
        if (!meta.isUserInteraction) return
        resizeSplit(node.id, sizesFromLayout(layout, childIdsRef.current))
        commitClusterMembers()
        markSplitResizeReleased()
      }}
      // A click only reaches the group itself when it landed on the group's
      // own chrome — a separator, or the gap around a panel — because every
      // click inside a child pane is stopped by that pane. Left to bubble, it
      // would activate the pane *containing* this split (a tab group, say),
      // moving the active highlight off the pane the user is working in just
      // because they resized it.
      onClick={(event) => event.stopPropagation()}
    >
      {node.children.map((child, index) => (
        <Fragment key={child.id}>
          {index > 0 && (
            <Separator
              className="split-separator"
              // react-resizable-panels focuses the separator from a
              // document-capture pointerdown listener, so its own arrow-key
              // resize can work — which yanks DOM focus out of the active
              // pane's terminal or webview on every drag, leaving it on an
              // unstyled div where typing goes nowhere and plain arrows
              // resize the split again. A div with no tabindex simply isn't
              // focusable, so that .focus() becomes a no-op and focus never
              // moves at all — not even momentarily, so a TUI with focus
              // reporting on never sees a spurious FocusLost/FocusGained
              // mid-drag. Tab-to-separator keyboard resize goes with it,
              // deliberately: nothing styles separator focus, so it was
              // invisible either way. It has to come off the element rather
              // than through a prop — SeparatorProps omits tabIndex, and the
              // library hard-codes it after spreading the props it was given.
              //
              // The dataset tags are for snapping and cluster mirroring (see
              // maybeSnap/discoverCluster): they let a *different* split's
              // drag find this separator by id/orientation/index, to compare
              // positions against and — via separatorRegistry — move.
              elementRef={(el) => {
                if (!el) return
                el.removeAttribute('tabindex')
                el.dataset.splitId = node.id
                el.dataset.splitDirection = node.direction
                el.dataset.separatorIndex = String(index)
              }}
            />
          )}
          <Panel id={child.id} className="split-pane" minSize={MIN_PANE_SIZE_PERCENT}>
            <ContentView node={child} {...childCorners(index)} />
          </Panel>
        </Fragment>
      ))}
    </Group>
  )
}
