import { findNode, findParent, findTab, neighbourOf } from './tree'
import type { ContentNode, NodeId, SplitDirection, TabsContent } from './types'
import { isSplit, isTabs } from './types'

export type NavDirection = 'left' | 'right' | 'up' | 'down'

/** Plain rect (a DOMRect works) so this module stays DOM-free and node-testable. */
export interface NavRect {
  left: number
  top: number
  right: number
  bottom: number
}

/** A candidate may sit this far "behind" the current pane's edge (borders overlap by a pixel or two). */
const EDGE_EPS = 2
/** Candidates whose distance along the axis differs by no more than this count as the same column/row. */
const TIE_EPS = 4

/** A candidate reduced to what the shared proximity rule compares. */
interface ScoredCandidate {
  id: NodeId
  /** Position along the axis of travel — smaller is nearer, whatever it measures. */
  metric: number
  cross: number
}

/**
 * Among `scored`, the candidate nearest along its metric (a spread within
 * TIE_EPS counts as tied), and among those the one whose cross-axis position
 * is closest to `current`'s own. This is the proximity rule
 * `pickSpatialTarget` and `pickWrapTarget` share — extracted so the tie
 * window and the cross-axis preference can't drift between the arrow move
 * and the wrap that deliberately mirrors it; each caller keeps only its own
 * metric and final tiebreak.
 */
function nearestByCross(
  current: NavRect,
  scored: ScoredCandidate[],
  direction: NavDirection,
  tiebreak: (a: ScoredCandidate, b: ScoredCandidate) => number
): NodeId | null {
  if (scored.length === 0) return null
  const nearest = Math.min(...scored.map((candidate) => candidate.metric))
  const sameRank = scored.filter((candidate) => candidate.metric - nearest <= TIE_EPS)
  const currentCross = crossOf(current, direction)
  sameRank.sort(
    (a, b) => Math.abs(a.cross - currentCross) - Math.abs(b.cross - currentCross) || tiebreak(a, b)
  )
  return sameRank[0]!.id
}

/**
 * The pane focus moves to for an arrow press: the nearest candidate in
 * `direction` from `current`, and among the nearest column/row the one whose
 * cross-axis position is closest to `current`'s own — so moving right from
 * the bottom row stays in the bottom row instead of always jumping to the
 * topmost candidate. Null when nothing lies in that direction.
 */
export function pickSpatialTarget(
  current: NavRect,
  candidates: Array<{ id: NodeId; rect: NavRect }>,
  direction: NavDirection
): NodeId | null {
  const eligible = candidates
    .map(({ id, rect }) => {
      const { distance, cross } = score(current, rect, direction)
      return { id, metric: distance, cross }
    })
    .filter((candidate) => candidate.metric >= -EDGE_EPS)
  return nearestByCross(current, eligible, direction, (a, b) => a.metric - b.metric)
}

/** The coordinate used to compare position along the axis perpendicular to `direction`. */
function crossOf(rect: NavRect, direction: NavDirection): number {
  return direction === 'left' || direction === 'right' ? rect.top : rect.left
}

/** How far past the current pane's leading edge a rect starts, and its cross-axis tie-break key. */
function score(
  current: NavRect,
  rect: NavRect,
  direction: NavDirection
): { distance: number; cross: number } {
  const cross = crossOf(rect, direction)
  switch (direction) {
    case 'right':
      return { distance: rect.left - current.right, cross }
    case 'left':
      return { distance: current.left - rect.right, cross }
    case 'down':
      return { distance: rect.top - current.bottom, cross }
    case 'up':
      return { distance: current.top - rect.bottom, cross }
  }
}

/**
 * The pane that receives focus when navigation enters `node` moving in
 * `direction` — the one nearest the edge the movement crossed: entering
 * rightward lands on the leftmost pane, downward on the topmost, and so on,
 * so repeated presses keep walking in one direction seamlessly. Only a split
 * laid out along the axis of travel is entered from its far side; in every
 * other split all children touch the entry edge equally and the first child
 * wins the topmost/leftmost tie. Tab groups descend into their visible tab.
 * `direction` is optional for callers with no directional intent (e.g.
 * clicking a tab) — a split then always takes its first child.
 */
export function entryPaneId(node: ContentNode, direction?: NavDirection): NodeId {
  if (isSplit(node)) {
    const fromFarSide =
      direction != null &&
      ((direction === 'left' && node.direction === 'horizontal') ||
        (direction === 'up' && node.direction === 'vertical'))
    return entryPaneId(node.children[fromFarSide ? node.children.length - 1 : 0]!, direction)
  }
  if (isTabs(node)) {
    // Falling back to the first tab keeps a stale activeTabId from parking
    // focus on the group node itself; only a group with no tabs at all (which
    // `normalize` never leaves behind) has nothing to descend into.
    const active = node.tabs.find((tab) => tab.id === node.activeTabId) ?? node.tabs[0]
    return active ? entryPaneId(active.content, direction) : node.id
  }
  return node.id
}

/**
 * Every tab activation needed to make `id` visible on screen, innermost
 * first — one step per ancestor tab between the node and the root, since the
 * node may sit in a tab inside a tab and revealing it means winning at every
 * level. The inverse of `entryPaneId` ("which pane does entering this subtree
 * land on"). Empty when the node is already visible at every level, or absent
 * from the tree. Collected against one snapshot of the tree, so a caller can
 * apply the steps in sequence even though each activation replaces the tree.
 */
export function ancestorTabSteps(
  root: ContentNode,
  id: NodeId
): Array<{ groupId: NodeId; tabId: NodeId }> {
  const walk = (node: ContentNode): Array<{ groupId: NodeId; tabId: NodeId }> | null => {
    if (node.id === id) return []
    if (isTabs(node)) {
      for (const tab of node.tabs) {
        const found = walk(tab.content)
        if (found) return [...found, { groupId: node.id, tabId: tab.id }]
      }
    } else if (isSplit(node)) {
      for (const child of node.children) {
        const found = walk(child)
        if (found) return found
      }
    }
    return null
  }
  return walk(root) ?? []
}

/**
 * The pane to focus after closing `closedId` (removed from `oldRoot`, giving
 * `newRoot`) — the closest sibling that survived, not the tree's global
 * first pane. Both the split and the tab case take `neighbourOf`'s
 * right-then-left convention — the same one `withTabRemoved` applies to the
 * group's own activeTabId, now stated once in tree.ts. Null
 * when there's no sibling to land on — `closedId` was the whole tree, or the
 * sole tab of its group (which `normalize` collapses in place to a fresh
 * empty leaf one level up) — either way the caller's default fallback
 * (`firstPaneId` of the new root) is already correct.
 */
export function focusAfterClose(
  oldRoot: ContentNode,
  newRoot: ContentNode,
  closedId: NodeId
): NodeId | null {
  const ref = findParent(oldRoot, closedId)
  if (!ref) return null

  if (ref.kind === 'split') {
    const { parent, index } = ref
    const sibling = neighbourOf(parent.children, index)
    return sibling ? entryPaneId(sibling) : null
  }

  const { parent: group, tab } = ref
  const index = group.tabs.findIndex((t) => t.id === tab.id)
  const neighbor = neighbourOf(group.tabs, index)
  if (neighbor) return entryPaneId(neighbor.content)

  // `closedId` was the sole tab in `group`: the group collapses in place to
  // a fresh empty leaf (normalizeTabs). Find the ancestor one level up —
  // whose own id/position this specific close never disturbs — and read
  // off whatever now occupies the group's old slot under it.
  const outerRef = findParent(oldRoot, group.id)
  if (!outerRef) return newRoot.id // the group itself was the root
  if (outerRef.kind === 'split') {
    const outerNode = findNode(newRoot, outerRef.parent.id)
    return outerNode && isSplit(outerNode) ? outerNode.children[outerRef.index]!.id : null
  }
  return findTab(newRoot, outerRef.tab.id)?.tab.content.id ?? null
}

/**
 * The pane to wrap to when nothing lies in `direction` and no enclosing tab
 * group can cycle: among the panes furthest toward the opposite edge
 * (leftmost for a rightward wrap, topmost for a downward one, ...), the one
 * whose cross-axis position is closest to `current`'s own — mirroring
 * `pickSpatialTarget` so wrapping feels like the same proximity-based move,
 * just continuing from the other edge. Null when there are no other panes.
 */
export function pickWrapTarget(
  current: NavRect,
  candidates: Array<{ id: NodeId; rect: NavRect }>,
  direction: NavDirection
): NodeId | null {
  const edge = (rect: NavRect): number => {
    switch (direction) {
      case 'right':
        return rect.left
      case 'left':
        return -rect.right
      case 'down':
        return rect.top
      case 'up':
        return -rect.bottom
    }
  }
  const scored = candidates.map((c) => ({
    id: c.id,
    metric: edge(c.rect),
    cross: crossOf(c.rect, direction)
  }))
  return nearestByCross(current, scored, direction, (a, b) => a.cross - b.cross)
}

/** Where an arrow press sends focus, before the exact pane inside is resolved. */
export interface NavTarget {
  /** The subtree focus moves into — resolve a pane inside it with `entryPaneId`. */
  node: ContentNode
  /** Set when reaching `node` means switching to another tab first. */
  tabSwitch: { groupId: NodeId; tabId: NodeId } | null
  /** True when nothing lay in `direction` and the outermost container along that axis wrapped around instead. */
  wrapped: boolean
}

/** Modulo that also handles stepping back off the front of the list. */
function wrapIndex(index: number, length: number): number {
  return ((index % length) + length) % length
}

/**
 * The tab `index + step` in `group`, wrapping around its ends. Null for a
 * group with nothing to cycle. Callers use `wrapped` to tell an actual step
 * from a wrap they should only take as a last resort.
 */
function tabTarget(group: TabsContent, index: number, step: number): NavTarget | null {
  if (group.tabs.length < 2) return null
  const next = Math.max(0, index) + step
  const wrapped = next < 0 || next >= group.tabs.length
  const tab = group.tabs[wrapped ? wrapIndex(next, group.tabs.length) : next]!
  return { node: tab.content, tabSwitch: { groupId: group.id, tabId: tab.id }, wrapped }
}

/**
 * Where an arrow press moves focus, walking *up* from `paneId` one ancestor
 * at a time rather than looking for the nearest pane on screen — so a move
 * always crosses exactly one boundary of the layout hierarchy, in order:
 *
 * - a split laid out along the pressed axis hands over its next child;
 * - a tab boundary is one step for left/right (the next/previous tab), taken
 *   *before* the group's own sibling, so a pane at the edge of a group walks
 *   through the rest of the group before leaving it;
 * - a tab boundary is transparent for up/down, which therefore only ever move
 *   between panes actually visible on screen — vertical navigation never
 *   reveals a hidden tab;
 * - anything else (a split across the pressed axis, a single-tab group) is
 *   transparent too, and the walk continues above it.
 *
 * Reaching the root without a step wraps the *outermost* container along the
 * pressed axis around — that is the ancestor whose own edge the press ran
 * into, so it's the one that should loop. Null when even that doesn't exist,
 * leaving the caller free to fall back on geometry.
 *
 * Purely a function of the tree, the active pane and the direction: pressing
 * the same key from the same pane always gives the same answer.
 */
export function navTarget(
  root: ContentNode,
  paneId: NodeId,
  direction: NavDirection
): NavTarget | null {
  const axis: SplitDirection =
    direction === 'left' || direction === 'right' ? 'horizontal' : 'vertical'
  const step = direction === 'right' || direction === 'down' ? 1 : -1
  const start = findNode(root, paneId)
  if (!start) return null

  // A tab group can be the active pane itself (clicking its own chrome rather
  // than its content), and then cycles its tabs exactly as the content inside
  // it would.
  let wrap =
    axis === 'horizontal' && isTabs(start)
      ? tabTarget(
          start,
          start.tabs.findIndex((tab) => tab.id === start.activeTabId),
          step
        )
      : null
  if (wrap && !wrap.wrapped) return wrap

  let node: ContentNode | null = start
  while (node) {
    const ref = findParent(root, node.id)
    if (!ref) break
    if (ref.kind === 'split') {
      if (ref.parent.direction === axis && ref.parent.children.length > 1) {
        const sibling = ref.parent.children[ref.index + step]
        if (sibling) return { node: sibling, tabSwitch: null, wrapped: false }
        wrap = {
          node: ref.parent.children[wrapIndex(ref.index + step, ref.parent.children.length)]!,
          tabSwitch: null,
          wrapped: true
        }
      }
      node = ref.parent
    } else {
      if (axis === 'horizontal') {
        const group = ref.parent
        const found = tabTarget(
          group,
          group.tabs.findIndex((tab) => tab.id === ref.tab.id),
          step
        )
        if (found && !found.wrapped) return found
        if (found) wrap = found
      }
      node = ref.parent
    }
  }
  // Later assignments won as the walk climbed, so this is the outermost
  // container that could wrap.
  return wrap
}
