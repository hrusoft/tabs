import {
  canDockPane,
  canDockTab,
  canMovePaneToTabs,
  canMoveTabToTabs,
  findNode,
  findParent,
  findTab
} from '@shared/model/tree'
import type { ContentNode, DockZone, NodeId } from '@shared/model/types'
import { isTabs } from '@shared/model/types'
import { PANE_ATTR } from '@shared/paneDomAttrs'
import type { PointerEvent as ReactPointerEvent } from 'react'
import type { DragSubject, DropTarget } from '../core/store/dragStore'
import { useDragStore } from '../core/store/dragStore'
import { ownerRootOf, splitsDockedRootOutOfItself, useLayoutStore } from '../core/store/layoutStore'
import { armPointerGesture } from './pointerGesture'

/** Pointer movement past this many pixels turns a press into a drag. */
const DRAG_THRESHOLD_PX = 5

/** This module's name in the shared gesture flag — see pointerGesture.ts. */
const GESTURE_OWNER = 'pane-drag'

/** Finder-style delay before hovering a tab in another bar previews it. */
const SPRING_LOAD_DELAY_MS = 550

/** Within this fraction of a pane's width/height, hovering targets an edge dock zone. */
const EDGE_ZONE_FRACTION = 0.25

/**
 * Within this (narrower) fraction of a tab GROUP's own width/height, hovering
 * inside a tab targets the group itself rather than the tab's own content —
 * the "split this whole group out" gesture, demoted to a thin band right at
 * the group's true edge so the wider band inside it can mean "split within
 * this tab" instead (see `resolveDockTarget`).
 */
const GROUP_EDGE_ZONE_FRACTION = 0.1

/**
 * How long the ghost takes to fly back after a targetless release. The single
 * source of the duration: DragOverlay sets it as the ghost's inline
 * `transition-duration`, so the CSS transition cannot drift from the cleanup
 * timer below (which runs a beat after the transition ends).
 */
export const FLY_BACK_MS = 180

interface Session {
  subject: DragSubject
  title: string
  startX: number
  startY: number
  engaged: boolean
  /** Ends the shared gesture lifecycle — see armPointerGesture. */
  release: () => void
}

// Module-scoped: only one pointer-driven drag can be in flight at a time,
// like a native drag session.
let session: Session | null = null
let springTimer: ReturnType<typeof setTimeout> | null = null
let springKey: string | null = null
let returnTimer: ReturnType<typeof setTimeout> | null = null

function swallowSettlingClick(event: MouseEvent): void {
  event.stopPropagation()
  event.preventDefault()
}

/**
 * Makes the synthetic `click` that follows a gesture-ending pointerup act on
 * nothing, by swallowing it at window capture — ahead of every other
 * listener, React's root included. Enforced once here, where the gesture
 * state lives, rather than by a guard in each click handler: the per-handler
 * shape covered only the handlers that remembered to check, and left e.g. a
 * tab's close button still acting on the click that settled a resize.
 *
 * Armed for exactly one tick. The settling click (when there is one)
 * dispatches in the same input sequence as its pointerup, ahead of queued
 * timers — the ordering the self-clearing flags this replaced relied on — so
 * the same-tick disarm can't miss it, while a release that produces no click
 * doesn't leave the swallow lying in wait for the user's next real one.
 */
function armSettlingClickSwallow(): void {
  window.addEventListener('click', swallowSettlingClick, { capture: true, once: true })
  setTimeout(() => {
    window.removeEventListener('click', swallowSettlingClick, { capture: true })
  }, 0)
}

// True while a split separator is being resized. react-resizable-panels
// exposes no onDragStart/onDragEnd of its own, so this is synthesized from
// `onLayoutChange`, which fires synchronously on every pointer-driven move.
// The setter self-clears via a same-tick setTimeout, so a layout change from
// some other, non-pointer source can never wedge this true — see
// SplitRenderer.tsx, the only caller.
let resizingSplit = false

export function markSplitResizeActive(): void {
  resizingSplit = true
  setTimeout(() => {
    resizingSplit = false
  }, 0)
}

/** The release half: the click settling a resize must not act on anything. */
export function markSplitResizeReleased(): void {
  armSettlingClickSwallow()
}

/**
 * True while a split resize owns the pointer gesture. Consulted so no other
 * pointer-driven interaction — activating a pane, starting a pane/tab drag —
 * can act at the same time.
 */
export function isSplitResizing(): boolean {
  return resizingSplit
}

export function startTabDrag(
  event: ReactPointerEvent<HTMLElement>,
  tabId: NodeId,
  groupId: NodeId,
  title: string
): void {
  armSession(event, { kind: 'tab', tabId, sourceGroupId: groupId }, title)
}

/** A pane drag, entered from its header. The caller decides whether the pane may travel. */
export function startPaneDrag(
  event: ReactPointerEvent<HTMLElement>,
  paneId: NodeId,
  title: string
): void {
  armSession(event, { kind: 'pane', paneId }, title)
}

function armSession(
  event: ReactPointerEvent<HTMLElement>,
  subject: DragSubject,
  title: string
): void {
  if (event.button !== 0) return
  // One gesture at a time, like a native drag session: a second pointer
  // pressing mid-drag is ignored rather than overwriting the live session.
  if (session) return
  // A resize drag exclusively owns the pointer gesture until it's released —
  // see isSplitResizing.
  if (isSplitResizing()) return
  // A new press interrupts an in-flight fly-back; without this the stale
  // timer would clear the fresh drag mid-gesture.
  if (returnTimer !== null) {
    clearTimeout(returnTimer)
    returnTimer = null
    useDragStore.getState().endDrag()
  }
  // Armed on the press rather than on engagement: a fast enough flick can
  // cross the threshold with a single move whose destination already lies
  // inside a guest, and that move is exactly the one the host would never
  // receive (see pointerGesture.ts). The lifecycle — the listeners, the
  // lost-release recovery, Escape — is the shared one; only what a move and
  // a drop *mean* is this module's.
  session = {
    subject,
    title,
    startX: event.clientX,
    startY: event.clientY,
    engaged: false,
    release: armPointerGesture(GESTURE_OWNER, event.pointerId, {
      onMove: onPointerMove,
      onRelease: onPointerUp,
      onCancel: abortSession
    })
  }
}

function onPointerMove(event: PointerEvent): void {
  if (!session) return

  // The separator's hit area can overlap a pane header enough that the same
  // pointerdown armed both a resize and this session (see isSplitResizing).
  // react-resizable-panels' own onLayoutChange for this move always runs
  // first — it's a document-level listener, which beats this window-level
  // one in bubble order — so this is guaranteed to see a resize that claimed
  // the same event, even on the very first move past the drag threshold.
  if (isSplitResizing()) {
    abortSession()
    return
  }

  if (!session.engaged) {
    const dx = event.clientX - session.startX
    const dy = event.clientY - session.startY
    if (Math.hypot(dx, dy) < DRAG_THRESHOLD_PX) return
    session.engaged = true
    useDragStore.getState().beginDrag(session.subject, session.title, event.clientX, event.clientY)
  }

  useDragStore.getState().setPointer(event.clientX, event.clientY)
  updateHoverTarget(event.clientX, event.clientY)
}

/**
 * The tree this drag happens in: the docked layout, or the floating window
 * the dragged thing lives in. Every target lookup resolves against it, so a
 * drag can neither escape its window nor reach into one — a floating pane is
 * moved as a window, not docked, and a docked pane has no business landing
 * inside one. Resolved once per pointer move and threaded down — `ownerRootOf`
 * walks every tree, too much to repeat per target check at pointer frequency.
 */
function subjectRoot(): ContentNode {
  const state = useLayoutStore.getState()
  if (!session) return state.root
  const subject = session.subject
  return ownerRootOf(state, subject.kind === 'tab' ? subject.tabId : subject.paneId)
}

/**
 * The content subtree travelling with the drag — a tab's content or the pane
 * node itself. Nothing inside it is a valid drop target: the drop would nest
 * the dragged thing into itself.
 */
function draggedSubtree(root: ContentNode): ContentNode | null {
  if (!session) return null
  if (session.subject.kind === 'tab') {
    return findTab(root, session.subject.tabId)?.tab.content ?? null
  }
  return findNode(root, session.subject.paneId)
}

/**
 * Re-resolves the drop target from scratch on every move, via the DOM under
 * the pointer — not a target computed once at drag start — because spring
 * loading can reveal new tab bars/panes mid-drag.
 *
 * Precedence: tab bars first, then edge dock zones, then empty panes, then
 * center docking. Edge zones must beat the empty-pane target because a blank
 * tab's empty content covers its whole pane — checked the other way round,
 * such panes could never be edge-docked onto.
 */
function updateHoverTarget(x: number, y: number): void {
  if (!session) return
  const root = subjectRoot()
  const el = document.elementFromPoint(x, y)
  const tabEl = (el?.closest(`[${PANE_ATTR.dropTab}]`) ?? null) as HTMLElement | null
  const barEl = (el?.closest(`[${PANE_ATTR.dropGroup}]`) ?? null) as HTMLElement | null

  // A bar the drop couldn't land on — inside the dragged subtree, or one
  // that would collapse the moment the pane detaches — isn't a target, so
  // hovering it falls through to the (equally declined) dock resolution.
  const barId = (barEl?.getAttribute(PANE_ATTR.dropGroup) ?? null) as NodeId | null
  const barAccepts =
    barId !== null &&
    (session.subject.kind === 'pane'
      ? canMovePaneToTabs(root, session.subject.paneId, barId)
      : canMoveTabToTabs(root, session.subject.tabId, barId))
  const validBarId = barAccepts ? barId : null

  // Deliberately not gated on `validBarId`: revealing a tab is not a drop, so
  // a bar that declines the drag can still be spring-loaded — see
  // `maybeSpringLoad`, which owns that call and finds the group from the model
  // rather than from the bar under the pointer.
  const hoveredTabId = (tabEl?.getAttribute(PANE_ATTR.dropTab) ?? null) as NodeId | null
  if (hoveredTabId !== null) maybeSpringLoad(root, hoveredTabId)
  else clearSpringLoad()

  if (tabEl && validBarId) {
    const rect = tabEl.getBoundingClientRect()
    const side: 'before' | 'after' = x < rect.left + rect.width / 2 ? 'before' : 'after'
    setTarget({
      kind: 'tab-bar',
      groupId: validBarId,
      index: computeDropIndex(root, validBarId, hoveredTabId, side)
    })
    return
  }

  if (validBarId) {
    setTarget({
      kind: 'tab-bar',
      groupId: validBarId,
      index: computeDropIndex(root, validBarId, null, 'after')
    })
    return
  }

  const dock = resolveDockTarget(root, el, x, y)
  if (dock && dock.zone !== 'center') {
    setTarget(dock)
    return
  }

  const emptyEl = (el?.closest(`[${PANE_ATTR.dropEmptyPane}]`) ?? null) as HTMLElement | null
  if (emptyEl) {
    const paneId = emptyEl.getAttribute(PANE_ATTR.dropEmptyPane) as NodeId
    // Resolved here, not at the top of the move handler: this is a full tree
    // walk, and every pointer frame outside this rarely-reached branch was
    // paying for it — the same reasoning subjectRoot() documents.
    const subtree = draggedSubtree(root)
    // An empty pane inside the dragged subtree is not a real target — the
    // drop would no-op — so don't tease it with a highlight. Nor is one in
    // another tree: unlike the dock and tab-bar branches above, whose
    // `can*` predicates already refuse a target they can't find, this branch
    // has no model check of its own, so a hovered empty pane in a floating
    // window would light up and then do nothing on release.
    if (findNode(root, paneId) && (!subtree || !findNode(subtree, paneId))) {
      setTarget({ kind: 'empty-pane', paneId })
      return
    }
  }

  setTarget(dock)
}

/**
 * The dock target for the pane under the pointer. Hovering a tab's own
 * content normally docks relative to that content directly — an edge zone
 * there splits *within* the tab, leaving the rest of its group untouched —
 * except in a thin band right at the enclosing group's true outer edge,
 * which docks relative to the whole group instead (splitting it out as a
 * sibling). Pane nesting mirrors the tree, and splits are never wrapped in a
 * Pane, so the group is found by walking the DOM panes and the model upward
 * in lockstep, stopping at a split child or the root. Zones that the
 * subject's canDock check declines resolve to no target, so no preview is
 * shown and a drop there is a no-op.
 */
function resolveDockTarget(
  root: ContentNode,
  el: Element | null,
  x: number,
  y: number
): Extract<DropTarget, { kind: 'dock' }> | null {
  const subject = session?.subject
  if (!subject) return null
  const innerEl = (el?.closest(`[${PANE_ATTR.dock}]`) ?? null) as HTMLElement | null
  if (!innerEl) return null

  let groupEl: HTMLElement | null = innerEl
  while (groupEl) {
    const ref = findParent(root, groupEl.getAttribute(PANE_ATTR.dock) as NodeId)
    if (ref?.kind !== 'tab') break
    groupEl = (groupEl.parentElement?.closest(`[${PANE_ATTR.dock}]`) ?? null) as HTMLElement | null
  }

  const dockedRoot = useLayoutStore.getState().root
  const dockedRootId = dockedRoot.id

  const dock = (
    paneEl: HTMLElement,
    zone: DockZone
  ): Extract<DropTarget, { kind: 'dock' }> | null => {
    const targetId = paneEl.getAttribute(PANE_ATTR.dock) as NodeId
    // The docked root has no edge zones — it cannot be split out of itself,
    // having no parent slot to leave the rest behind in. The store's own
    // refusal is the authority; asking it here as well is what makes the outer
    // band of the whole window show no preview, rather than previewing a drop
    // that would then do nothing. `center` is unaffected: there it means
    // "become a top-level tab".
    if (splitsDockedRootOutOfItself(dockedRoot, targetId, zone)) return null
    const allowed =
      subject.kind === 'tab'
        ? canDockTab(root, subject.tabId, targetId, zone)
        : canDockPane(root, subject.paneId, targetId, zone)
    return allowed ? { kind: 'dock', targetId, zone } : null
  }

  if (!groupEl) return null

  if (groupEl === innerEl) {
    return dock(innerEl, zoneWithin(innerEl.getBoundingClientRect(), x, y))
  }

  const groupZone = zoneWithin(groupEl.getBoundingClientRect(), x, y, GROUP_EDGE_ZONE_FRACTION)
  if (groupZone !== 'center') return dock(groupEl, groupZone)
  const innerZone = zoneWithin(innerEl.getBoundingClientRect(), x, y)
  if (innerZone !== 'center') return dock(innerEl, innerZone)
  // True center normally means "merge into the enclosing group" — but the
  // docked root is a degenerate case of that: every top-level tab is already
  // root's own direct peer, so targeting root here would just ask to re-add
  // the dragged tab to the bar it's already in, which canDockTab declines as
  // a no-op. What the gesture is actually asking for is "nest into the
  // specific top-level tab hovered": promote that tab's own content into a
  // new two-tab group, the same outcome any bare leaf's center already
  // produces elsewhere.
  return dock(groupEl.getAttribute(PANE_ATTR.dock) === dockedRootId ? innerEl : groupEl, 'center')
}

/** The nearest edge when the pointer sits within the edge band, else center. */
function zoneWithin(rect: DOMRect, x: number, y: number, fraction = EDGE_ZONE_FRACTION): DockZone {
  if (rect.width <= 0 || rect.height <= 0) return 'center'
  const rx = (x - rect.left) / rect.width
  const ry = (y - rect.top) / rect.height
  const edges: Array<[number, DockZone]> = [
    [rx, 'left'],
    [1 - rx, 'right'],
    [ry, 'top'],
    [1 - ry, 'bottom']
  ]
  const [distance, zone] = edges.reduce((a, b) => (b[0] < a[0] ? b : a))
  return distance < fraction ? zone : 'center'
}

function setTarget(target: DropTarget | null): void {
  useDragStore.getState().setTarget(target)
}

/**
 * The bar the drag departs from: a tab's own group, or the group whose tab
 * holds the dragged pane. That tab leaves with the drop, so the bar's index
 * math excludes it.
 */
function homeBarTab(root: ContentNode): { groupId: NodeId; tabId: NodeId } | null {
  if (!session) return null
  if (session.subject.kind === 'tab') {
    return { groupId: session.subject.sourceGroupId, tabId: session.subject.tabId }
  }
  const ref = findParent(root, session.subject.paneId)
  return ref?.kind === 'tab' ? { groupId: ref.parent.id, tabId: ref.tab.id } : null
}

/** Index (in terms of the target group's tabs with the departing tab removed) to insert at. */
function computeDropIndex(
  root: ContentNode,
  groupId: NodeId,
  hoveredTabId: NodeId | null,
  side: 'before' | 'after'
): number {
  const node = findNode(root, groupId)
  const ids = node && isTabs(node) ? node.tabs.map((tab) => tab.id) : []
  const home = homeBarTab(root)
  const departingTabId = home?.groupId === groupId ? home.tabId : null
  const withoutDragged = ids.filter((id) => id !== departingTabId)
  if (hoveredTabId === null) return withoutDragged.length
  const at = withoutDragged.indexOf(hoveredTabId)
  if (at === -1) return withoutDragged.length
  return side === 'before' ? at : at + 1
}

/**
 * Finder-style reveal: holding the drag over some other tab opens it, so its
 * content becomes hoverable and can be docked into.
 *
 * Asked independently of whether the hovered *bar* would accept the drop,
 * because they are different questions — and conflating them cost the gesture
 * its most obvious case. Two tabs holding one pane each: dragging tab 2's
 * pane onto tab 1's label is refused as a bar drop, since detaching the pane
 * collapses its tab and re-adding it to the same bar changes nothing (see
 * `canMovePaneToTabs`). Gating the reveal on that refusal left tab 1 shut, so
 * its content — a perfectly legal dock target — could never be reached at
 * all. So the eligibility rules are this function's own:
 *
 * - Never the tab already driving the drag. For a tab drag that's its own
 *   label; for a pane drag, the tab holding the pane is already the open one.
 *   A DIFFERENT sibling in the same bar is fair game — hiding the dragged
 *   tab's former content underneath doesn't hide the drag itself, which is
 *   the separate ghost overlay following the pointer.
 * - Only a tab in the drag's own tree. A docked drag passing over a floating
 *   window's bar (or the reverse) can never land there, so opening a tab in
 *   it would rearrange a window the gesture has no business touching.
 * - Never a tab inside the dragged subtree. That travels with the drag, so
 *   revealing it rearranges the thing being dragged and exposes no target.
 */
function maybeSpringLoad(root: ContentNode, hoveredTabId: NodeId): void {
  if (!session) return
  if (springKey === hoveredTabId) return
  clearSpringLoad()
  // Set even when ineligible, so the checks below — one of which is a full
  // tree walk — run once per tab entered rather than once per pointer frame.
  springKey = hoveredTabId
  const ref = findTab(root, hoveredTabId)
  if (!ref || hoveredTabId === homeBarTab(root)?.tabId) return
  const subtree = draggedSubtree(root)
  if (subtree && findTab(subtree, hoveredTabId)) return
  const groupId = ref.group.id
  springTimer = setTimeout(() => {
    useLayoutStore.getState().activateTab(groupId, hoveredTabId)
    springTimer = null
  }, SPRING_LOAD_DELAY_MS)
}

function clearSpringLoad(): void {
  if (springTimer !== null) {
    clearTimeout(springTimer)
    springTimer = null
  }
  springKey = null
}

function onPointerUp(): void {
  if (!session) return

  let flyBack = false
  if (session.engaged) {
    const target = useDragStore.getState().drag?.target ?? null
    const subject = session.subject
    const layout = useLayoutStore.getState()
    if (target?.kind === 'tab-bar') {
      if (subject.kind === 'tab') layout.moveTab(subject.tabId, target.groupId, target.index)
      else layout.movePaneToTabs(subject.paneId, target.groupId, target.index)
    } else if (target?.kind === 'empty-pane') {
      // For a pane, landing on a placeholder is a center dock: take the slot.
      if (subject.kind === 'tab') layout.moveTab(subject.tabId, target.paneId)
      else layout.dockPane(subject.paneId, target.paneId, 'center')
    } else if (target?.kind === 'dock') {
      if (subject.kind === 'tab') layout.dockTab(subject.tabId, target.targetId, target.zone)
      else layout.dockPane(subject.paneId, target.targetId, target.zone)
    } else {
      // Nothing was previewed, so nothing happens: the ghost flies home.
      flyBack = true
    }
    // The click following this pointerup lands on whatever the drop released
    // over — acting on it would activate something the user only dropped on.
    armSettlingClickSwallow()
  }

  teardownSession()
  if (flyBack) startFlyBack()
  else useDragStore.getState().endDrag()
}

/**
 * Sends the ghost gliding back to the drag's source — the tab (still in
 * place, rendered dimmed) or the pane's header — then clears the drag. A
 * timer rather than `transitionend` ends the fly-back, so a missed
 * transition can't strand the ghost.
 */
function startFlyBack(): void {
  const drag = useDragStore.getState().drag
  const sourceEl = drag
    ? document.querySelector(
        drag.subject.kind === 'tab'
          ? `[${PANE_ATTR.dropTab}="${CSS.escape(drag.subject.tabId)}"]`
          : `[${PANE_ATTR.paneDrag}="${CSS.escape(drag.subject.paneId)}"]`
      )
    : null
  if (!drag || !sourceEl) {
    useDragStore.getState().endDrag()
    return
  }
  const rect = sourceEl.getBoundingClientRect()
  useDragStore.getState().startReturn(rect.left, rect.top)
  returnTimer = setTimeout(() => {
    returnTimer = null
    useDragStore.getState().endDrag()
  }, FLY_BACK_MS + 40)
}

/**
 * The one way a session ends without a drop: tear the listeners down and, if
 * the drag had engaged (ghost shown, store live), settle the store. endDrag
 * on a never-engaged session would be a no-op, but gating keeps the store
 * untouched for a press that never became a drag.
 */
function abortSession(): void {
  if (!session) return
  const wasEngaged = session.engaged
  teardownSession()
  if (wasEngaged) useDragStore.getState().endDrag()
}

/** Detaches the gesture's listeners and bookkeeping; the drag store is settled separately. */
function teardownSession(): void {
  session?.release()
  clearSpringLoad()
  session = null
}
