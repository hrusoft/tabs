import { createLeaf, createTab } from './factories'
import { createId } from './ids'
import type { TabTitler } from './tree'
import {
  addTab,
  findNode,
  findParent,
  findTab,
  MIN_PANE_SIZE,
  normalize,
  openContent,
  resizeSplit,
  splitContent,
  withPaneDetached
} from './tree'
import type { ContentNode, NodeId, SplitDirection } from './types'
import { EMPTY_TYPE, isPlausibleNode, isSplit, isTabs } from './types'

/**
 * Free-floating panes: a subtree lifted out of the docked layout into a window
 * drawn over it, moved and resized directly rather than by the tree. The
 * docked layout and each floating window are separate `ContentNode` trees —
 * every operation in `tree.ts` applies to one of them, never across two.
 *
 * Nothing here touches the DOM: geometry arrives as plain numbers (the
 * renderer measures), matching the rest of `src/shared`.
 */

/** Viewport-space geometry of a floating window, in CSS pixels. */
export interface FloatRect {
  x: number
  y: number
  width: number
  height: number
}

/**
 * Where a floating pane came from, so re-pinning can put it back. Deliberately
 * over-determined: it records both the container the pane lived in (an exact
 * restore for as long as that container survives) and the siblings it sat
 * between (the fallback for when it doesn't). Detaching the pane is *itself*
 * the most common reason its container stops existing — floating one child of
 * a two-child split unwraps that split immediately (see `normalizeSplit`) — so
 * an anchor that only knew its container would fail on the very first round
 * trip a user tries. Sibling ids stay good because tree operations relocate
 * nodes by reference and never rebuild them, so a sibling still on screen is
 * still under the same id however the layout was rearranged around it.
 */
export type FloatAnchor =
  | {
      kind: 'split'
      /** The split it was a child of, and that split's axis. */
      splitId: NodeId
      direction: SplitDirection
      /** Its slot among the split's children, and the fraction of the split it held. */
      index: number
      size: number
      /** The children immediately before/after it — absent (or an explicit undefined) at either end. */
      beforeId?: NodeId | undefined
      afterId?: NodeId | undefined
    }
  | {
      kind: 'tab'
      /** The group whose tab held it. */
      groupId: NodeId
      index: number
      /** The tab's own title, which a derived label can't recover after a user rename. */
      title: string
      beforeTabId?: NodeId | undefined
      afterTabId?: NodeId | undefined
    }
  /** It was the whole docked layout; the root is a placeholder waiting for it back. */
  | { kind: 'root' }

/** One floating window: a subtree, where it sits on screen, and where it came from. */
export interface FloatingPane {
  /**
   * Identity of the *window*, minted once at unpin and never reassigned —
   * deliberately not `content.id`, which changes whenever an operation
   * replaces the subtree's root node (clearing the pane, promoting it into a
   * group). React keys, gesture sessions and the z-order list all hang off
   * this, and none of them should churn when the content does.
   */
  id: NodeId
  content: ContentNode
  rect: FloatRect
  anchor: FloatAnchor
}

/**
 * Smallest a floating window may be dragged or resized to, in CSS pixels.
 * The stylesheet deliberately declares no matching minimum — the gesture
 * clamp here is the single enforcement point, so nothing can disagree with
 * it.
 */
export const MIN_FLOAT_SIZE = { width: 240, height: 120 }

/** How much of a window must stay inside the viewport, so it can never be lost off an edge. */
const FLOAT_KEEP_ON_SCREEN = 80

/**
 * Geometry for a window with no better answer — a saved rect that was
 * unusable, or an unpinned pane with no measurable slot. Never applied blind:
 * the renderer clamps every rect against the real viewport on mount, which is
 * the only place the viewport is known.
 */
export const DEFAULT_FLOAT_RECT: FloatRect = { x: 48, y: 48, width: 640, height: 400 }

/**
 * Gap, in CSS pixels, kept between a freshly spawned unpinned pane and the
 * edges of the pane it spawned from (see `spawnRectIn` below, and its one
 * caller `spawnRect` in content/placement.ts).
 *
 * Beside the other float geometry rather than in that renderer module because
 * e2e/browser/floating.spec.ts asserts the resulting offsets: `src/shared` is
 * reachable from the Playwright tier and `src/renderer` is not, so keeping it
 * there left the spec restating the literal with a "matches …" comment doing a
 * compiler's job.
 */
export const NEW_PANE_SPAWN_SPACING = 16

// ---------------------------------------------------------------------------
// Spawn placement
// ---------------------------------------------------------------------------

/** The 3x3 grid's bands down the origin pane, top to bottom. */
const SPAWN_ROWS = ['top', 'middle', 'bottom'] as const
/** …and across it, left to right. The one axis the picker itself needs, for its arrow-key row stride. */
export const SPAWN_COLUMNS = ['left', 'center', 'right'] as const

type SpawnRow = (typeof SPAWN_ROWS)[number]
type SpawnColumn = (typeof SPAWN_COLUMNS)[number]

/**
 * Which section of the pane it spawned from a newly created unpinned pane
 * lands in — the `newUnpinnedPanePosition` setting's value, and the cell the
 * Settings window's 3x3 picker paints.
 *
 * A template-literal union over the two axis arrays rather than nine
 * hand-written members: the picker renders its grid by iterating those same
 * arrays, so the control and the type cannot come to disagree about which
 * positions exist.
 */
export type NewPaneSpawnPosition = `${SpawnRow}-${SpawnColumn}`

/** All nine, in reading order — which is also the picker's DOM order. */
export const NEW_PANE_SPAWN_POSITIONS: readonly NewPaneSpawnPosition[] = SPAWN_ROWS.flatMap((row) =>
  SPAWN_COLUMNS.map((column): NewPaneSpawnPosition => `${row}-${column}`)
)

/**
 * The corner every new unpinned pane used before the setting existed, so the
 * shipped default makes the upgrade a behavioural no-op — the same reasoning
 * as `colorTheme: 'dark'`.
 */
export const DEFAULT_NEW_PANE_SPAWN_POSITION: NewPaneSpawnPosition = 'top-right'

/**
 * Whatever a settings.json holds, as a position that can actually be placed
 * with. Tolerated at read rather than sanitized at load, which is the contract
 * `getTheme` already gives `colorTheme` (migrateSettings validates only the
 * two settings whose malformed shapes could throw). Both readers go through
 * here — the placement itself and the Settings picker — so a hand-edited
 * garbage value spawns at the default *and* shows the default cell selected,
 * rather than leaving the control looking broken.
 */
export function resolveSpawnPosition(value: unknown): NewPaneSpawnPosition {
  const known = NEW_PANE_SPAWN_POSITIONS.find((position) => position === value)
  return known ?? DEFAULT_NEW_PANE_SPAWN_POSITION
}

/** 0 = against the leading edge, 1 = the trailing edge, 0.5 = centered. */
const ROW_FRACTION: Record<SpawnRow, number> = { top: 0, middle: 0.5, bottom: 1 }
const COLUMN_FRACTION: Record<SpawnColumn, number> = { left: 0, center: 0.5, right: 1 }

/**
 * Geometry for a freshly spawned unpinned pane: `position`'s section of
 * `origin`'s on-screen rect. Sized off the origin pane too (capped at the
 * model's default size), so a spawn over a small pane doesn't request a window
 * bigger than what it's spawning next to.
 *
 * One formula covers all nine positions, applied per axis independently:
 *
 *     start + SPACING + f * (originSize - windowSize - 2 * SPACING)
 *
 * At f=0/f=1 that insets the window from that edge by the spawn spacing, so it
 * reads as lifting out of that corner rather than covering it; at f=0.5 the
 * two insets cancel algebraically and it lands exactly centered. Writing the
 * nine cases out separately instead is what produces the picker whose corners
 * are inset and whose centers are quietly off by half a spacing.
 *
 * The bracketed term goes NEGATIVE when the origin pane is smaller than
 * MIN_FLOAT_SIZE plus the two insets, i.e. when the window has to be bigger
 * than the pane it spawns over; the window then overhangs the *leading* edge
 * instead of sitting inside. Deliberately not guarded with a `max(0, …)`:
 * that would collapse all nine positions onto the top-left inset for a small
 * pane, which is a worse answer than an honest overhang, and this is exactly
 * what the single hardcoded top-right spawn did before the setting existed.
 * `clampRect` keeps the window reachable on screen either way.
 */
export function spawnRectIn(origin: FloatRect, position: NewPaneSpawnPosition): FloatRect {
  // The union's own shape guarantees exactly one hyphen and two known halves.
  const [row, column] = position.split('-') as [SpawnRow, SpawnColumn]
  const width = spawnSize(origin.width, DEFAULT_FLOAT_RECT.width, MIN_FLOAT_SIZE.width)
  const height = spawnSize(origin.height, DEFAULT_FLOAT_RECT.height, MIN_FLOAT_SIZE.height)
  return {
    x: spawnOffset(origin.x, origin.width, width, COLUMN_FRACTION[column]),
    y: spawnOffset(origin.y, origin.height, height, ROW_FRACTION[row]),
    width,
    height
  }
}

function spawnSize(originSize: number, preferred: number, minimum: number): number {
  return Math.min(preferred, Math.max(minimum, originSize - NEW_PANE_SPAWN_SPACING * 2))
}

function spawnOffset(start: number, originSize: number, size: number, fraction: number): number {
  return (
    start + NEW_PANE_SPAWN_SPACING + fraction * (originSize - size - NEW_PANE_SPAWN_SPACING * 2)
  )
}

// ---------------------------------------------------------------------------
// Anchoring
// ---------------------------------------------------------------------------

/**
 * Where `id` currently sits, in a form `restoreFloating` can aim at later.
 * Null when `id` isn't in the tree at all — `findParent` returns null both for
 * the root and for an absent id, so the two are told apart with `findNode`.
 * Exported for its unit tests; `detachForFloat` is the public entry.
 */
export function captureAnchor(root: ContentNode, id: NodeId): FloatAnchor | null {
  const ref = findParent(root, id)
  if (!ref) return findNode(root, id) ? { kind: 'root' } : null

  if (ref.kind === 'split') {
    const { parent, index } = ref
    return {
      kind: 'split',
      splitId: parent.id,
      direction: parent.direction,
      index,
      size: parent.sizes[index] ?? 1 / parent.children.length,
      beforeId: parent.children[index - 1]?.id,
      afterId: parent.children[index + 1]?.id
    }
  }

  const { parent: group, tab } = ref
  const index = group.tabs.findIndex((candidate) => candidate.id === tab.id)
  return {
    kind: 'tab',
    groupId: group.id,
    index,
    title: tab.title,
    beforeTabId: group.tabs[index - 1]?.id,
    afterTabId: group.tabs[index + 1]?.id
  }
}

// ---------------------------------------------------------------------------
// Detach / restore
// ---------------------------------------------------------------------------

export interface DetachedForFloat {
  /** The docked layout with the pane spliced out, normalized. */
  root: ContentNode
  floating: FloatingPane
}

/**
 * Lifts the node `id` out of `root` into a floating window at `rect`. The node
 * travels by reference, never rebuilt, so anything keyed by its id (a live
 * pty, a `<webview>` element) survives the move — the same discipline
 * `dockPane` follows. Null when `id` isn't in the tree.
 *
 * Detaching goes through `withPaneDetached`, not `closePane`: unpinning is a
 * relocation, so a group emptied by the departure goes away entirely rather
 * than leaving the placeholder pane that closing would.
 */
export function detachForFloat(
  root: ContentNode,
  id: NodeId,
  rect: FloatRect
): DetachedForFloat | null {
  const content = findNode(root, id)
  if (!content) return null
  const anchor = captureAnchor(root, id)
  if (!anchor) return null
  const detached = withPaneDetached(root, id)
  // Floating the root leaves nothing behind — the same fresh placeholder
  // `removeNode` falls back to when the root is removed.
  const nextRoot = detached ? normalize(detached) : createLeaf(EMPTY_TYPE)
  return { root: nextRoot, floating: { id: createId(), content, rect, anchor } }
}

/**
 * Puts a floating window's content back into `root`, as close to where it came
 * from as the layout still allows: its old container if that survives, else
 * beside whichever neighbour did, else `fallbackTargetId`. The last fallback
 * cannot fail, so re-pinning never loses content.
 *
 * `fallbackTargetId` is re-checked against `root` here rather than trusted,
 * since the caller's natural choice — the active pane — is very often inside
 * the very window being re-pinned.
 */
export function restoreFloating(
  root: ContentNode,
  entry: FloatingPane,
  titleOf: TabTitler,
  fallbackTargetId: NodeId
): ContentNode {
  const node = entry.content
  const anchor = entry.anchor

  if (anchor.kind === 'tab') {
    const group = findNode(root, anchor.groupId)
    if (group && isTabs(group)) {
      return normalize(addTab(root, anchor.groupId, createTab(anchor.title, node), anchor.index))
    }
    // The group is gone — usually collapsed by this pane's own departure — so
    // aim at whichever neighbouring tab survived, on the side it was on.
    const before = anchor.beforeTabId ? findTab(root, anchor.beforeTabId) : null
    const after = anchor.afterTabId ? findTab(root, anchor.afterTabId) : null
    const ref = before ?? after
    if (ref) {
      const at = ref === before ? ref.index + 1 : ref.index
      return normalize(addTab(root, ref.group.id, createTab(anchor.title, node), at))
    }
  }

  if (anchor.kind === 'split') {
    const split = findNode(root, anchor.splitId)
    if (split && isSplit(split) && split.direction === anchor.direction) {
      // `splitContent`'s same-direction branch splices a node in beside an
      // existing child, which is exactly a slot insert — no new primitive.
      const at = Math.min(Math.max(anchor.index, 0), split.children.length - 1)
      const position = anchor.index >= split.children.length ? 'after' : 'before'
      const next = splitContent(root, split.children[at]!.id, anchor.direction, node, position)
      return withRestoredSize(next, node.id, anchor.size)
    }
    // The split collapsed: re-split against whichever neighbour is left.
    const before = anchor.beforeId && findNode(root, anchor.beforeId) ? anchor.beforeId : null
    const after = anchor.afterId && findNode(root, anchor.afterId) ? anchor.afterId : null
    if (before || after) {
      const target = before ?? (after as NodeId)
      const position = before ? 'after' : 'before'
      const next = splitContent(root, target, anchor.direction, node, position)
      return withRestoredSize(next, node.id, anchor.size)
    }
  }

  // Root anchor, or every landmark gone. `openContent` never destroys what a
  // target already holds — it fills a placeholder in place, or promotes the
  // target into a group beside it — so this is the branch that makes re-pin
  // total.
  const target = findNode(root, fallbackTargetId) ? fallbackTargetId : root.id
  return openContent(root, target, node, titleOf)
}

/**
 * Best-effort return of the fraction the pane used to hold, taking the
 * difference proportionally from its new siblings. A no-op when it didn't land
 * in a split after all. `resizeSplit` runs the result through `normalizeSizes`,
 * so anything this arithmetic gets wrong is repaired rather than persisted.
 */
function withRestoredSize(root: ContentNode, nodeId: NodeId, size: number): ContentNode {
  const ref = findParent(root, nodeId)
  if (ref?.kind !== 'split') return root
  const { parent, index } = ref
  const ceiling = Math.max(1 - MIN_PANE_SIZE * (parent.children.length - 1), MIN_PANE_SIZE)
  const target = Math.min(Math.max(size, MIN_PANE_SIZE), ceiling)
  const rest = parent.sizes.reduce((sum, value, i) => (i === index ? sum : sum + value), 0)
  const scale = rest > 0 ? (1 - target) / rest : 0
  return resizeSplit(
    root,
    parent.id,
    parent.sizes.map((value, i) => (i === index ? target : value * scale))
  )
}

// ---------------------------------------------------------------------------
// The floating list (array order is z-order: last is topmost)
// ---------------------------------------------------------------------------

/** The window whose own subtree contains `id`, or null. */
export function floatOwning(
  floating: readonly FloatingPane[],
  id: NodeId
): FloatingPane | undefined {
  return floating.find((entry) => findNode(entry.content, id) !== null)
}

/**
 * `floatId`'s window moved to the top of the stack. Returns the same array
 * reference when it is already topmost (or unknown), so callers can use
 * identity to skip a state update entirely — the same structural-sharing
 * discipline the tree operations follow.
 */
export function raiseFloating(floating: FloatingPane[], floatId: NodeId): FloatingPane[] {
  const index = floating.findIndex((entry) => entry.id === floatId)
  if (index === -1 || index === floating.length - 1) return floating
  const next = [...floating]
  const raised = next.splice(index, 1)[0]!
  next.push(raised)
  return next
}

/** The list with `floatId`'s entry replaced; the same array when `fn` changed nothing. */
export function replaceFloating(
  floating: FloatingPane[],
  floatId: NodeId,
  fn: (entry: FloatingPane) => FloatingPane
): FloatingPane[] {
  const index = floating.findIndex((entry) => entry.id === floatId)
  if (index === -1) return floating
  const existing = floating[index]!
  const next = fn(existing)
  if (next === existing) return floating
  const result = [...floating]
  result[index] = next
  return result
}

// ---------------------------------------------------------------------------
// Geometry
// ---------------------------------------------------------------------------

/**
 * Keeps a window no smaller than the minimum and never fully off screen. The
 * top edge is clamped to zero rather than to `FLOAT_KEEP_ON_SCREEN`: a title
 * bar dragged above the viewport would be ungrabbable, which is the one way a
 * window really can be lost.
 */
export function clampRect(rect: FloatRect, viewport: { width: number; height: number }): FloatRect {
  const width = clampSize(rect.width, MIN_FLOAT_SIZE.width, viewport.width)
  const height = clampSize(rect.height, MIN_FLOAT_SIZE.height, viewport.height)
  const keep = Math.min(FLOAT_KEEP_ON_SCREEN, width, height)
  const x = Number.isFinite(rect.x) ? rect.x : 0
  const y = Number.isFinite(rect.y) ? rect.y : 0
  return {
    width,
    height,
    x: Math.min(Math.max(x, keep - width), Math.max(viewport.width - keep, 0)),
    y: Math.min(Math.max(y, 0), Math.max(viewport.height - keep, 0))
  }
}

function clampSize(value: number, min: number, max: number): number {
  const size = Number.isFinite(value) ? value : min
  return Math.max(min, Math.min(size, Math.max(max, min)))
}

// ---------------------------------------------------------------------------
// Deserialization
// ---------------------------------------------------------------------------

/**
 * Repairs whatever `floating` came off disk. An entry survives only if it
 * carries content worth showing and no node id already claimed by the docked
 * root or an earlier entry — `ownerOf` in layoutStore resolves a node id to
 * exactly one tree, so a duplicated id would silently route operations to the
 * wrong one. Geometry and a malformed anchor are *repaired* rather than
 * rejected: losing where a window sat is a nuisance, losing the pane inside it
 * is not. A duplicated *window* id is repaired the same way (re-minted, not
 * dropped): React keys, gesture sessions and the z-order list all hang off it
 * (see `FloatingPane.id`), so two windows sharing one would leave only the
 * first reachable — but the pane inside the second is still worth keeping.
 */
export function sanitizeFloating(floating: unknown, root: ContentNode): FloatingPane[] {
  if (!Array.isArray(floating)) return []
  const claimed = collectNodeIds(root, new Set())
  const windowIds = new Set<NodeId>()
  const result: FloatingPane[] = []
  for (const value of floating) {
    const entry = sanitizeEntry(value)
    if (!entry) continue
    const ids = collectNodeIds(entry.content, new Set())
    if (Array.from(ids).some((id) => claimed.has(id))) continue
    for (const id of ids) claimed.add(id)
    const unique = windowIds.has(entry.id) ? { ...entry, id: createId() } : entry
    windowIds.add(unique.id)
    result.push(unique)
  }
  return result
}

function sanitizeEntry(value: unknown): FloatingPane | null {
  if (typeof value !== 'object' || value === null) return null
  const entry = value as Partial<FloatingPane>
  if (!isPlausibleNode(entry.content)) return null
  const content = normalize(entry.content)
  return {
    id: typeof entry.id === 'string' && entry.id !== '' ? entry.id : createId(),
    content,
    rect: sanitizeRect(entry.rect),
    anchor: sanitizeAnchor(entry.anchor)
  }
}

function sanitizeRect(rect: unknown): FloatRect {
  if (typeof rect !== 'object' || rect === null) return DEFAULT_FLOAT_RECT
  const { x, y, width, height } = rect as FloatRect
  if (![x, y, width, height].every(isFiniteNumber)) return DEFAULT_FLOAT_RECT
  // Rebuilt rather than passed through, so nothing else the file carried ends
  // up back in the next save.
  return { x, y, width, height }
}

function isFiniteNumber(value: unknown): value is number {
  return typeof value === 'number' && Number.isFinite(value)
}

/** A string, or undefined for anything else — the optional-neighbour-id rule both anchor kinds share. */
function stringOrUndefined(value: unknown): string | undefined {
  return typeof value === 'string' ? value : undefined
}

// Rebuilt field-by-field, never spread through, for the same reason as
// sanitizeRect: an anchor is round-tripped into every future save, so a
// passthrough would carry whatever extra keys a hand-edited or foreign-version
// file held back onto disk forever. The neighbour ids are checked too — they
// end up in findNode/findTab lookups.
function sanitizeAnchor(anchor: unknown): FloatAnchor {
  if (typeof anchor !== 'object' || anchor === null) return { kind: 'root' }
  const candidate = anchor as Record<string, unknown>
  if (candidate.kind === 'tab' && typeof candidate.groupId === 'string') {
    return {
      kind: 'tab',
      groupId: candidate.groupId,
      index: isFiniteNumber(candidate.index) ? candidate.index : 0,
      title: typeof candidate.title === 'string' ? candidate.title : '',
      beforeTabId: stringOrUndefined(candidate.beforeTabId),
      afterTabId: stringOrUndefined(candidate.afterTabId)
    }
  }
  if (candidate.kind === 'split' && typeof candidate.splitId === 'string') {
    if (candidate.direction !== 'horizontal' && candidate.direction !== 'vertical') {
      return { kind: 'root' }
    }
    return {
      kind: 'split',
      splitId: candidate.splitId,
      direction: candidate.direction,
      index: isFiniteNumber(candidate.index) ? candidate.index : 0,
      size: isFiniteNumber(candidate.size) ? candidate.size : MIN_PANE_SIZE,
      beforeId: stringOrUndefined(candidate.beforeId),
      afterId: stringOrUndefined(candidate.afterId)
    }
  }
  return { kind: 'root' }
}

/** Every node id under `node` — splits and tab groups included, not just leaves. */
function collectNodeIds(node: ContentNode, into: Set<NodeId>): Set<NodeId> {
  into.add(node.id)
  if (isTabs(node)) for (const tab of node.tabs) collectNodeIds(tab.content, into)
  else if (isSplit(node)) for (const child of node.children) collectNodeIds(child, into)
  return into
}
