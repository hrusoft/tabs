import { createLeaf, createSplit, createTab, createTabs, evenSizes } from './factories'
import type {
  ContentNode,
  DockZone,
  LeafContent,
  NodeId,
  SplitContent,
  SplitDirection,
  Tab,
  TabsContent
} from './types'
import { EMPTY_TYPE, isEmpty, isSplit, isTabs } from './types'

/** Panes are never resized below this fraction of their split. */
export const MIN_PANE_SIZE = 0.05

/**
 * Names a node for the tab being created to hold it — injected so the model
 * stays independent of the content registry. `destGroupId` is the *existing*
 * group the tab is landing in, when there is one; absent when the operation
 * mints a brand-new group around the tab. It's what lets a caller title tabs
 * landing in one specific group differently — layoutStore's titler names a
 * placeholder landing directly in the docked root group "Tabs" rather than
 * "New Tab" — without any operation here knowing that policy exists.
 */
export type TabTitler = (node: ContentNode, destGroupId?: NodeId) => string

// ---------------------------------------------------------------------------
// Lookup
// ---------------------------------------------------------------------------

function childrenOf(node: ContentNode): ContentNode[] {
  if (isTabs(node)) return node.tabs.map((tab) => tab.content)
  if (isSplit(node)) return node.children
  return []
}

export function findNode(root: ContentNode, id: NodeId): ContentNode | null {
  if (root.id === id) return root
  for (const child of childrenOf(root)) {
    const found = findNode(child, id)
    if (found) return found
  }
  return null
}

/**
 * The id of the first pane reachable from `root`, descending into a split's
 * first child — but deliberately NOT into a tab group's tabs: a group is
 * itself a legitimate active pane (its chrome can hold focus — see
 * navTarget's tab-cycling branch), so a tabs root answers with its own id.
 * `entryPaneId` (navigation.ts) is the variant that descends to the visible
 * tab's content, for callers that need a leaf.
 */
export function firstPaneId(root: ContentNode): NodeId {
  return isSplit(root) ? firstPaneId(root.children[0]!) : root.id
}

export type ParentRef =
  | { kind: 'split'; parent: SplitContent; index: number }
  | { kind: 'tab'; parent: TabsContent; tab: Tab }

/** Locates the node that directly contains `id` (a split pane or a tab's content). */
export function findParent(root: ContentNode, id: NodeId): ParentRef | null {
  if (isTabs(root)) {
    for (const tab of root.tabs) {
      if (tab.content.id === id) return { kind: 'tab', parent: root, tab }
      const found = findParent(tab.content, id)
      if (found) return found
    }
  } else if (isSplit(root)) {
    for (let i = 0; i < root.children.length; i++) {
      const child = root.children[i]!
      if (child.id === id) return { kind: 'split', parent: root, index: i }
      const found = findParent(child, id)
      if (found) return found
    }
  }
  return null
}

export interface TabRef {
  group: TabsContent
  tab: Tab
  index: number
}

export function findTab(root: ContentNode, tabId: NodeId): TabRef | null {
  if (isTabs(root)) {
    const index = root.tabs.findIndex((tab) => tab.id === tabId)
    if (index !== -1) return { group: root, tab: root.tabs[index]!, index }
  }
  for (const child of childrenOf(root)) {
    const found = findTab(child, tabId)
    if (found) return found
  }
  return null
}

// ---------------------------------------------------------------------------
// Leaf traversal
// ---------------------------------------------------------------------------

/**
 * Rebuilds the tree with `fn` applied to every leaf, keeping structural
 * sharing for subtrees `fn` leaves untouched (returns the same reference).
 */
export function mapLeaves(root: ContentNode, fn: (leaf: LeafContent) => LeafContent): ContentNode {
  if (isTabs(root)) {
    let changed = false
    const tabs = root.tabs.map((tab) => {
      const content = mapLeaves(tab.content, fn)
      if (content === tab.content) return tab
      changed = true
      return { ...tab, content }
    })
    return changed ? { ...root, tabs } : root
  }
  if (isSplit(root)) {
    let changed = false
    const children = root.children.map((child) => {
      const next = mapLeaves(child, fn)
      if (next !== child) changed = true
      return next
    })
    return changed ? { ...root, children } : root
  }
  return fn(root)
}

/** Every leaf under `node`, depth-first — the flat view content-type sweeps filter over. */
export function collectLeaves(node: ContentNode): LeafContent[] {
  if (isTabs(node) || isSplit(node)) return childrenOf(node).flatMap(collectLeaves)
  return [node]
}

// ---------------------------------------------------------------------------
// Structural replacement
// ---------------------------------------------------------------------------

/**
 * Rebuilds only the path from the root to the node with `id`, applying `fn` to
 * it. Untouched subtrees keep reference identity (structural sharing). `fn`
 * returning null removes the node: a removed split pane drops its size slot, a
 * removed tab content closes its tab. Returns null only when the root itself
 * is removed. If `id` is absent the same root is returned.
 *
 * `redistributeOnRemove` hands a removed split child's freed size to its
 * immediate array-neighbor(s) instead of leaving the shortfall for
 * `normalizeSizes` to spread proportionally across every sibling. Only
 * `removeNode` (real pane closes) opts in — `withPaneDetached` deliberately
 * leaves a raw gap for its own callers to fill.
 */
function replaceNode(
  root: ContentNode,
  id: NodeId,
  fn: (node: ContentNode) => ContentNode | null,
  redistributeOnRemove = false
): ContentNode | null {
  if (root.id === id) return fn(root)

  if (isTabs(root)) {
    for (let i = 0; i < root.tabs.length; i++) {
      const tab = root.tabs[i]!
      const result = replaceNode(tab.content, id, fn, redistributeOnRemove)
      if (result === tab.content) continue
      const tabs = [...root.tabs]
      if (result === null) {
        tabs.splice(i, 1)
      } else {
        tabs[i] = { ...tab, content: result }
      }
      return { ...root, tabs }
    }
    return root
  }

  if (isSplit(root)) {
    for (let i = 0; i < root.children.length; i++) {
      const child = root.children[i]!
      const result = replaceNode(child, id, fn, redistributeOnRemove)
      if (result === child) continue
      const children = [...root.children]
      const sizes = [...root.sizes]
      if (result === null) {
        if (redistributeOnRemove) {
          const freed = sizes[i] ?? 0
          const hasLeft = i > 0
          const hasRight = i < sizes.length - 1
          if (hasLeft && hasRight) {
            sizes[i - 1]! += freed / 2
            sizes[i + 1]! += freed / 2
          } else if (hasLeft) {
            sizes[i - 1]! += freed
          } else if (hasRight) {
            sizes[i + 1]! += freed
          }
        }
        children.splice(i, 1)
        sizes.splice(i, 1)
      } else {
        children[i] = result
      }
      return { ...root, children, sizes }
    }
    return root
  }

  return root
}

// ---------------------------------------------------------------------------
// Sizes
// ---------------------------------------------------------------------------

/**
 * Repairs a sizes array: non-finite/negative entries become 0, the whole array
 * is scaled to sum to 1, and every entry is raised to the minimum pane size
 * (excess is taken proportionally from larger panes).
 */
export function normalizeSizes(sizes: number[]): number[] {
  const count = sizes.length
  if (count === 0) return []
  const min = Math.min(MIN_PANE_SIZE, 1 / count)
  let values = sizes.map((v) => (Number.isFinite(v) && v > 0 ? v : 0))
  const total = values.reduce((sum, v) => sum + v, 0)
  values = total <= 0 ? evenSizes(count) : values.map((v) => v / total)
  for (let pass = 0; pass < count; pass++) {
    const low = new Set(values.flatMap((v, i) => (v < min ? [i] : [])))
    if (low.size === 0) break
    if (low.size === count) return evenSizes(count)
    const rest = values.reduce((sum, v, i) => (low.has(i) ? sum : sum + v), 0)
    const scale = (1 - min * low.size) / rest
    values = values.map((v, i) => (low.has(i) ? min : v * scale))
  }
  return values
}

function sizesEqual(a: number[], b: number[]): boolean {
  return a.length === b.length && a.every((v, i) => Math.abs(v - b[i]!) < 1e-9)
}

// ---------------------------------------------------------------------------
// Normalization
// ---------------------------------------------------------------------------

/**
 * Bottom-up invariant repair:
 * - splits with no children are removed, single-child splits are unwrapped
 * - child splits sharing their parent's direction are flattened into it
 * - sizes are renormalized whenever they drift
 * - a stale/missing activeTabId falls back to the first tab
 * - a tabs group left with no tabs (its last tab closed) reverts to a plain
 *   empty pane in place — never removing its slot from a split or a tab,
 *   regardless of nesting; only an explicit removeNode() does that
 *
 * Unchanged subtrees keep reference identity.
 */
export function normalize(root: ContentNode): ContentNode {
  return normalizeNode(root) ?? createLeaf(EMPTY_TYPE)
}

function normalizeNode(node: ContentNode): ContentNode | null {
  if (isTabs(node)) return normalizeTabs(node)
  if (isSplit(node)) return normalizeSplit(node)
  return node
}

function normalizeTabs(node: TabsContent): ContentNode {
  let changed = false
  const tabs: Tab[] = []
  for (const tab of node.tabs) {
    const content = normalizeNode(tab.content)
    if (content === null) {
      changed = true
      continue
    }
    if (content !== tab.content) {
      changed = true
      tabs.push({ ...tab, content })
    } else {
      tabs.push(tab)
    }
  }
  if (tabs.length === 0) return createLeaf(EMPTY_TYPE)
  let activeTabId = node.activeTabId
  if (!tabs.some((tab) => tab.id === activeTabId)) {
    activeTabId = tabs[0]!.id
    changed = true
  }
  return changed ? { ...node, tabs, activeTabId } : node
}

function normalizeSplit(node: SplitContent): ContentNode | null {
  let changed = false
  const children: ContentNode[] = []
  const sizes: number[] = []
  node.children.forEach((child, i) => {
    const result = normalizeNode(child)
    const size = node.sizes[i] ?? 0
    if (result === null) {
      changed = true
      return
    }
    if (isSplit(result) && result.direction === node.direction) {
      changed = true
      result.children.forEach((grandchild, j) => {
        children.push(grandchild)
        sizes.push(size * (result.sizes[j] ?? 0))
      })
      return
    }
    if (result !== child) changed = true
    children.push(result)
    sizes.push(size)
  })
  if (children.length === 0) return null
  if (children.length === 1) return children[0]!
  const repairedSizes = normalizeSizes(sizes)
  if (!sizesEqual(repairedSizes, node.sizes)) changed = true
  return changed ? { ...node, children, sizes: repairedSizes } : node
}

// ---------------------------------------------------------------------------
// Tab operations
// ---------------------------------------------------------------------------

/**
 * The element that takes over when `index`'s goes away: the right neighbour,
 * else the left — the one convention every "what survives a removal" choice
 * here and in navigation.ts follows.
 */
export function neighbourOf<T>(list: readonly T[], index: number): T | undefined {
  return list[index + 1] ?? list[index - 1]
}

/**
 * `replaceNode` narrowed to a tabs group: `fn` runs only when `id` names one
 * (anything else returns unchanged — the shared no-op every group operation
 * wants), and a vanished root collapses back to the same reference so store
 * subscribers skip re-rendering, the contract `updateLeaf` documents.
 */
function updateTabsGroup(
  root: ContentNode,
  id: NodeId,
  fn: (group: TabsContent) => ContentNode
): ContentNode {
  return replaceNode(root, id, (node) => (isTabs(node) ? fn(node) : node)) ?? root
}

/** Inserts `tab` into the group `groupId` (appended, or at `index`) and activates it. */
export function addTab(root: ContentNode, groupId: NodeId, tab: Tab, index?: number): ContentNode {
  return updateTabsGroup(root, groupId, (node) => {
    const tabs = [...node.tabs]
    const at = index === undefined ? tabs.length : Math.max(0, Math.min(index, tabs.length))
    tabs.splice(at, 0, tab)
    return { ...node, tabs, activeTabId: tab.id }
  })
}

export function activateTab(root: ContentNode, groupId: NodeId, tabId: NodeId): ContentNode {
  return updateTabsGroup(root, groupId, (node) => {
    if (node.activeTabId === tabId) return node
    if (!node.tabs.some((tab) => tab.id === tabId)) return node
    return { ...node, activeTabId: tabId }
  })
}

/**
 * Removes a tab from `group`, activating its right neighbor (or left at the
 * end). A group left with exactly one tab collapses to that tab's own
 * content, unwrapped in place — the mirror of how `openContent` promotes a
 * bare pane into a group when a second tab arrives beside it.
 */
function withTabRemoved(group: TabsContent, tabId: NodeId): ContentNode {
  const index = group.tabs.findIndex((tab) => tab.id === tabId)
  if (index === -1) return group
  const tabs = group.tabs.filter((tab) => tab.id !== tabId)
  if (tabs.length === 1) return tabs[0]!.content
  let activeTabId = group.activeTabId
  if (activeTabId === tabId) {
    activeTabId = neighbourOf(group.tabs, index)?.id ?? null
  }
  return { ...group, tabs, activeTabId }
}

/**
 * The tree with `tabId` removed from the group `groupId` (`withTabRemoved`
 * collapse rules included); null when that removal consumed the whole tree.
 */
function removeTabFromGroup(root: ContentNode, groupId: NodeId, tabId: NodeId): ContentNode | null {
  return replaceNode(root, groupId, (node) => (isTabs(node) ? withTabRemoved(node, tabId) : node))
}

export function closeTab(root: ContentNode, tabId: NodeId): ContentNode {
  const ref = findTab(root, tabId)
  if (!ref) return root
  return normalize(removeTabFromGroup(root, ref.group.id, tabId) ?? root)
}

/**
 * Collapses a single-tab group to that tab's own content, unwrapped in
 * place — the manual counterpart to the collapse `closeTab` performs when
 * removal leaves one tab behind. No-op for a group with more than one tab.
 */
export function ungroupTabs(root: ContentNode, groupId: NodeId): ContentNode {
  return normalize(
    updateTabsGroup(root, groupId, (node) =>
      node.tabs.length === 1 ? node.tabs[0]!.content : node
    )
  )
}

export function renameTab(root: ContentNode, tabId: NodeId, title: string): ContentNode {
  const ref = findTab(root, tabId)
  if (!ref || ref.tab.title === title) return root
  return updateTabsGroup(root, ref.group.id, (node) => ({
    ...node,
    tabs: node.tabs.map((tab) => (tab.id === tabId ? { ...tab, title } : tab))
  }))
}

/**
 * Applies `fn` to the leaf `id`, rebuilding only the path to it. The no-op
 * cases every leaf field-setter shares — `id` missing, a tabs/split node
 * (neither has leaf fields to set), or `fn` returning the same leaf to say
 * nothing changed — all return the same root reference, so store
 * subscribers skip re-rendering entirely (see `withOwner` in layoutStore.ts).
 */
function updateLeaf(
  root: ContentNode,
  id: NodeId,
  fn: (leaf: LeafContent) => LeafContent
): ContentNode {
  const node = findNode(root, id)
  if (!node || isTabs(node) || isSplit(node)) return root
  const next = fn(node)
  if (next === node) return root
  return replaceNode(root, id, () => next) ?? root
}

/**
 * Sets a pane's header title override — `undefined` clears it back to the
 * derived content-type label (see `paneTitleForContent`). Only leaf content
 * has a header of its own to title (a `split` never gets one; a `tabs` group's
 * label comes from its own tabs, not this), so both node kinds no-op here.
 *
 * This is the manual path (the "Edit title" UI): it marks the pane
 * `titleIsManual` so `setLiveTitle` won't overwrite it, and clearing the
 * override (`undefined`) un-marks it, re-opening the pane to live updates.
 */
export function renamePane(root: ContentNode, id: NodeId, title: string | undefined): ContentNode {
  const titleIsManual = title !== undefined
  return updateLeaf(root, id, (leaf) =>
    leaf.title === title && leaf.titleIsManual === titleIsManual
      ? leaf
      : { ...leaf, title, titleIsManual }
  )
}

/**
 * Sets a pane's title from its own running process (e.g. a terminal's OSC
 * title-change sequence) — the automatic counterpart to `renamePane`. A
 * no-op once the user has manually renamed the pane (`titleIsManual`), so a
 * live process can never clobber an explicit override. An empty title is
 * treated the same as `undefined`: some processes clear their reported title
 * on exit, which should fall back to the derived label just like a cleared
 * manual override does.
 */
export function setLiveTitle(root: ContentNode, id: NodeId, title: string): ContentNode {
  const next = title === '' ? undefined : title
  return updateLeaf(root, id, (leaf) =>
    leaf.titleIsManual || leaf.title === next ? leaf : { ...leaf, title: next }
  )
}

/**
 * Merges `config` into a leaf's own config — e.g. a browser pane persisting
 * its current URL after every navigation, so a remount or app restart
 * restores the same page. The automatic, always-on counterpart to a leaf's
 * `config`, mirroring how `setLiveTitle` is the automatic counterpart to a
 * leaf's `title`. No-ops when every key in `config` already matches the
 * node's current value.
 */
export function setLeafConfig(
  root: ContentNode,
  id: NodeId,
  config: Record<string, unknown>
): ContentNode {
  return updateLeaf(root, id, (leaf) =>
    Object.entries(config).every(([key, value]) => leaf.config[key] === value)
      ? leaf
      : { ...leaf, config: { ...leaf.config, ...config } }
  )
}

/**
 * Moves a tab within its own group (reorder by index), to a different
 * existing tabs group, or onto an `empty` leaf (converted in place into a new
 * tabs group containing just the dragged tab — e.g. a drag-and-drop onto a
 * content-less pane).
 */
export function moveTab(
  root: ContentNode,
  tabId: NodeId,
  targetGroupId: NodeId,
  index?: number
): ContentNode {
  const ref = findTab(root, tabId)
  if (!ref) return root

  if (ref.group.id === targetGroupId) {
    return updateTabsGroup(root, targetGroupId, (node) => {
      const from = node.tabs.findIndex((tab) => tab.id === tabId)
      const tabs = [...node.tabs]
      const moved = tabs.splice(from, 1)[0]!
      const at = index === undefined ? tabs.length : Math.max(0, Math.min(index, tabs.length))
      tabs.splice(at, 0, moved)
      return { ...node, tabs, activeTabId: moved.id }
    })
  }

  const target = findNode(root, targetGroupId)
  if (!target || (!isTabs(target) && !isEmpty(target))) return root

  const removed = removeTabFromGroup(root, ref.group.id, tabId) ?? root
  // The target vanished with the removal: it lived inside the moved tab itself.
  const survivor = findNode(removed, targetGroupId)
  if (!survivor) return root

  if (isEmpty(survivor)) {
    const converted = replaceNode(removed, targetGroupId, () =>
      createTabs([ref.tab], { id: targetGroupId })
    )
    return normalize(converted ?? removed)
  }

  return normalize(addTab(removed, targetGroupId, ref.tab, index))
}

// ---------------------------------------------------------------------------
// Split operations
// ---------------------------------------------------------------------------

/**
 * Splits the content node `targetId` in `direction`, placing `newNode` next to
 * it. If the target already sits in a same-direction split the new pane is
 * spliced in beside it (taking half the target's share); otherwise the target
 * is replaced by a new 50/50 split. Works on any node, including the root.
 */
export function splitContent(
  root: ContentNode,
  targetId: NodeId,
  direction: SplitDirection,
  newNode: ContentNode,
  position: 'before' | 'after' = 'after'
): ContentNode {
  const parentRef = findParent(root, targetId)

  if (parentRef?.kind === 'split' && parentRef.parent.direction === direction) {
    const next = replaceNode(root, parentRef.parent.id, (node) => {
      if (!isSplit(node)) return node
      const at = node.children.findIndex((child) => child.id === targetId)
      if (at === -1) return node
      const children = [...node.children]
      const sizes = [...node.sizes]
      const half = (sizes[at] ?? 1 / children.length) / 2
      sizes[at] = half
      const insertAt = position === 'before' ? at : at + 1
      children.splice(insertAt, 0, newNode)
      sizes.splice(insertAt, 0, half)
      return { ...node, children, sizes }
    })
    return normalize(next ?? root)
  }

  const next = replaceNode(root, targetId, (node) =>
    createSplit(direction, position === 'before' ? [newNode, node] : [node, newNode])
  )
  return normalize(next ?? root)
}

/**
 * True when docking `tabId` at `zone` of `targetId` would change the layout.
 * The drag hover check: a zone this declines shows no drop preview, so a
 * release there falls through to the fly-back no-op.
 */
export function canDockTab(
  root: ContentNode,
  tabId: NodeId,
  targetId: NodeId,
  zone: DockZone
): boolean {
  const ref = findTab(root, tabId)
  if (!ref) return false
  const target = findNode(root, targetId)
  if (!target || isSplit(target)) return false
  // Docking onto a pane inside the dragged tab's own content would nest the
  // tab into itself.
  if (findNode(ref.tab.content, targetId)) return false
  if (zone === 'center') return targetId !== ref.group.id
  // Splitting a group off of itself only rearranges when other tabs remain.
  return targetId !== ref.group.id || ref.group.tabs.length > 1
}

/** The split placement equivalent to docking at an edge `zone`. */
function edgeZoneToSplit(zone: Exclude<DockZone, 'center'>): {
  direction: SplitDirection
  position: 'before' | 'after'
} {
  return {
    direction: zone === 'left' || zone === 'right' ? 'horizontal' : 'vertical',
    position: zone === 'left' || zone === 'top' ? 'before' : 'after'
  }
}

/**
 * The tab wrapping `targetId`, when that tab lives in `groupId` — i.e. when
 * the drop target and the thing being dragged are peers in the same group.
 *
 * Both dock operations need it before they remove the dragged thing, because
 * that removal can collapse the shared group down to the target's bare content
 * (a group's last tab unwraps — see `removeTabFromGroup`), silently discarding
 * the tab, and the title, that used to wrap it. Most visible at the docked
 * root: two top-level tabs, drop one onto the other's content, and the removal
 * leaves root as just the survivor. `groupId` is `undefined` when the dragged
 * thing isn't in a tab at all, which is the "no shared group, nothing to
 * preserve" answer.
 */
function wrappingTabIn(root: ContentNode, targetId: NodeId, groupId?: NodeId): Tab | null {
  if (groupId === undefined) return null
  const ref = findParent(root, targetId)
  return ref?.kind === 'tab' && ref.parent.id === groupId ? ref.tab : null
}

/**
 * Promotes the bare content at `targetId` into a two-tab group holding it and
 * `incoming` — how both dock operations finish a `center` drop onto a leaf.
 *
 * `wrapperTitle` (from `wrappingTabIn` above) is what makes the collapsed case
 * come out right. When the removal left the target as the *whole* tree, there
 * is no slot for `replaceNode` to write the new group into, so the promotion
 * would simply become the operation's entire result and the wrapper tab's
 * title would be gone. Both layers are rebuilt explicitly instead: the
 * promotion nested one level in, wrapped again under the preserved title,
 * taking over the old slot rather than replacing the group that held it.
 */
function promoteIntoTabs(
  tree: ContentNode,
  targetId: NodeId,
  incoming: Tab,
  titleOf: TabTitler,
  wrapperTitle: string | null
): ContentNode {
  const promotion = (target: ContentNode): TabsContent =>
    createTabs([createTab(titleOf(target), target), incoming], { activeTabId: incoming.id })
  if (wrapperTitle !== null && tree.id === targetId) {
    return normalize(createTabs([createTab(wrapperTitle, promotion(tree))]))
  }
  return normalize(replaceNode(tree, targetId, promotion) ?? tree)
}

/**
 * Docks a dragged tab against the pane `targetId`. An edge zone splits the
 * pane, with the tab landing in the new half as a single-tab group (the same
 * shape a drop onto an empty pane produces); `center` merges the tab into the
 * pane: appended to a group, converting an empty leaf, or promoting a bare
 * leaf into a two-tab group. Nodes are relocated by reference, never rebuilt,
 * so live content keyed by node id survives. `titleOf` names a promoted bare
 * leaf's own tab, as in `openContent`.
 */
export function dockTab(
  root: ContentNode,
  tabId: NodeId,
  targetId: NodeId,
  zone: DockZone,
  titleOf: TabTitler
): ContentNode {
  if (!canDockTab(root, tabId, targetId, zone)) return root
  const ref = findTab(root, tabId)
  if (!ref) return root

  if (zone === 'center') {
    const target = findNode(root, targetId)
    if (!target) return root
    if (isTabs(target) || isEmpty(target)) return moveTab(root, tabId, targetId)
    // Read before the removal below, which is what can destroy it.
    const targetOwnTab = wrappingTabIn(root, targetId, ref.group.id)
    const removed = removeTabFromGroup(root, ref.group.id, tabId) ?? root
    if (!findNode(removed, targetId)) return root
    return promoteIntoTabs(removed, targetId, ref.tab, titleOf, targetOwnTab?.title ?? null)
  }

  const removed = removeTabFromGroup(root, ref.group.id, tabId) ?? root
  let effectiveTargetId = targetId
  if (!findNode(removed, targetId)) {
    // The only target that can vanish (guards above exclude the rest) is the
    // source group itself, collapsed to its surviving tab's content.
    if (targetId !== ref.group.id) return root
    const survivor = ref.group.tabs.find((tab) => tab.id !== tabId)
    if (!survivor) return root
    effectiveTargetId = survivor.content.id
  }
  const { direction, position } = edgeZoneToSplit(zone)
  return splitContent(removed, effectiveTargetId, direction, createTabs([ref.tab]), position)
}

export function resizeSplit(root: ContentNode, splitId: NodeId, sizes: number[]): ContentNode {
  return (
    replaceNode(root, splitId, (node) => {
      if (!isSplit(node)) return node
      if (sizes.length !== node.children.length) return node
      const repaired = normalizeSizes(sizes)
      return sizesEqual(repaired, node.sizes) ? node : { ...node, sizes: repaired }
    }) ?? root
  )
}

// ---------------------------------------------------------------------------
// Generic replacement / removal
// ---------------------------------------------------------------------------

/** Swaps the node `id` for entirely new content (e.g. an empty pane picking its type). */
export function replaceContent(root: ContentNode, id: NodeId, content: ContentNode): ContentNode {
  return normalize(replaceNode(root, id, () => content) ?? root)
}

/** Removes any content node. Removing the root resets it to an empty pane. */
export function removeNode(root: ContentNode, id: NodeId): ContentNode {
  if (root.id === id) return createLeaf(EMPTY_TYPE)
  return normalize(replaceNode(root, id, () => null, true) ?? root)
}

// ---------------------------------------------------------------------------
// Pane operations
// ---------------------------------------------------------------------------

/**
 * The pane `paneId` if the pane drag ops may detach it: it exists and isn't
 * the root (which has nowhere else to go). A pane travels alone, independent
 * of any tab that holds it.
 */
function detachablePane(root: ContentNode, paneId: NodeId): ContentNode | null {
  if (root.id === paneId) return null
  return findNode(root, paneId)
}

/**
 * The tree with the pane spliced out, ready for re-insertion elsewhere — by a
 * pane drag (`dockPane`, `movePaneToTabs`) or by lifting it into a floating
 * window (`detachForFloat` in floating.ts). A split child gives up its slot; a
 * pane living in a tab closes that tab behind it (`withTabRemoved` collapse
 * rules included), and a group emptied by its departure goes away entirely — a
 * relocation should leave nothing of the source, unlike closing, which leaves
 * the slot as a placeholder. Returns null when the removal consumed the whole
 * tree. Not normalized: callers insert the pane first, then normalize.
 */
export function withPaneDetached(root: ContentNode, paneId: NodeId): ContentNode | null {
  const ref = findParent(root, paneId)
  if (ref?.kind === 'tab') {
    const group = ref.parent
    if (group.tabs.length === 1) return replaceNode(root, group.id, () => null)
    return removeTabFromGroup(root, group.id, ref.tab.id)
  }
  return replaceNode(root, paneId, () => null)
}

/**
 * Closes the pane `id` and everything inside it — the header's close control.
 * A pane living in a tab closes through `closeTab`, so its group gets the
 * same neighbor activation and lone-tab collapse as closing the tab itself;
 * anything else is removed outright (the root resets to an empty pane).
 */
export function closePane(root: ContentNode, id: NodeId): ContentNode {
  const ref = findParent(root, id)
  if (ref?.kind === 'tab') return closeTab(root, ref.tab.id)
  return removeNode(root, id)
}

/**
 * Wraps the node `id` into a new tab group holding it as the sole tab — the
 * header's "tab group" control. The node is preserved by reference, and the
 * group takes over its slot, so this works anywhere: a split child, a tab's
 * content (nesting a group inside the tab), or the root. The single-tab
 * group survives `normalize` — only removal paths collapse one.
 */
export function wrapInTabs(root: ContentNode, id: NodeId, titleOf: TabTitler): ContentNode {
  const next = replaceNode(root, id, (node) => createTabs([createTab(titleOf(node), node)]))
  return normalize(next ?? root)
}

/**
 * The docked window's own invariant, applied to a whole tree at once: it
 * stays a tab group no matter what a collapse or a restructure just did to
 * it, so there is always a top-level "New Tab" and no separate window chrome
 * — the root's own tab bar doubles as the window's title bar. A no-op when
 * `node` is already tabs; otherwise wraps it as the sole tab, same shape
 * `wrapInTabs` produces for a node found by id.
 *
 * Unlike every other operation in this file, this one has no `id` to look
 * up — it always treats its whole argument as "the root" — so callers must
 * only ever apply it to the docked layout's actual root, never to a floating
 * window's content, which is a `ContentNode` tree in its own right and
 * carries no such invariant.
 */
export function ensureTabsRoot(node: ContentNode, titleOf: TabTitler): TabsContent {
  return isTabs(node) ? node : createTabs([createTab(titleOf(node), node)])
}

/**
 * True when docking the pane `paneId` against `targetId` would change the
 * layout. Only detachable panes dock (see `detachablePane`), and never onto
 * themselves or a pane inside their own subtree — the subtree travels with
 * the drag. Docking against the pane's own enclosing group has its own
 * degenerate cases: `center` would only re-group what is already grouped,
 * and an edge needs the group to leave behind at least a survivor to split
 * against once the pane's tab has closed.
 */
export function canDockPane(
  root: ContentNode,
  paneId: NodeId,
  targetId: NodeId,
  zone: DockZone
): boolean {
  const pane = detachablePane(root, paneId)
  if (!pane) return false
  const target = findNode(root, targetId)
  if (!target || isSplit(target)) return false
  if (findNode(pane, targetId)) return false
  const ref = findParent(root, paneId)
  if (ref?.kind === 'tab' && targetId === ref.parent.id) {
    if (zone === 'center') return false
    return ref.parent.tabs.length >= 2
  }
  return true
}

/**
 * True when dropping the pane `paneId` onto the tab bar of `targetGroupId`
 * would change the layout: the target is a group outside the pane's own
 * subtree, and one that still exists once the pane has detached — the pane's
 * own bar only qualifies while at least two other tabs keep it from
 * collapsing.
 */
export function canMovePaneToTabs(
  root: ContentNode,
  paneId: NodeId,
  targetGroupId: NodeId
): boolean {
  const pane = detachablePane(root, paneId)
  if (!pane) return false
  const target = findNode(root, targetGroupId)
  if (!target || !isTabs(target)) return false
  if (findNode(pane, targetGroupId)) return false
  const ref = findParent(root, paneId)
  if (ref?.kind === 'tab' && targetGroupId === ref.parent.id) return ref.parent.tabs.length >= 3
  return true
}

/**
 * True when dropping the tab `tabId` onto the tab bar of `targetGroupId` is a
 * meaningful move — the tab-drag counterpart of `canMovePaneToTabs`, and the
 * fourth quadrant of the drop-validity matrix beside `canDockTab` and
 * `canDockPane`. The target must be a group outside the dragged tab's own
 * content (dropping there would nest the tab into itself); the tab's own bar
 * qualifies, since that drop is a reorder.
 */
export function canMoveTabToTabs(root: ContentNode, tabId: NodeId, targetGroupId: NodeId): boolean {
  const ref = findTab(root, tabId)
  if (!ref) return false
  const target = findNode(root, targetGroupId)
  if (!target || !isTabs(target)) return false
  return !findNode(ref.tab.content, targetGroupId)
}

/**
 * Docks a dragged pane against the pane `targetId` — the pane mirror of
 * `dockTab`. An edge zone splits the target with the pane landing bare in
 * the new half (a pane is already standalone content; only tabs need a
 * group). `center` merges the pane into the target: appended as a tab to a
 * group, taking over an empty pane's slot, or promoting a bare leaf into a
 * two-tab group. The pane travels alone: a tab that held it closes behind
 * it (see `withPaneDetached`). Nodes are relocated by reference, never
 * rebuilt, so live content keyed by node id survives. `titleOf` names the
 * tabs this creates.
 */
export function dockPane(
  root: ContentNode,
  paneId: NodeId,
  targetId: NodeId,
  zone: DockZone,
  titleOf: TabTitler
): ContentNode {
  if (!canDockPane(root, paneId, targetId, zone)) return root
  const pane = findNode(root, paneId)
  const parentRef = findParent(root, paneId)
  if (!pane) return root

  // Read before the detach below, which is what can destroy it.
  const targetOwnTab = wrappingTabIn(
    root,
    targetId,
    parentRef?.kind === 'tab' ? parentRef.parent.id : undefined
  )

  // Normalization waits for the insert ops below, so the vacated slot can't
  // disturb the target's id in between.
  const detached = withPaneDetached(root, paneId)
  if (!detached) return root

  let effectiveTargetId = targetId
  if (!findNode(detached, targetId)) {
    // The only target that can vanish (guards above exclude the rest) is the
    // pane's own two-tab group, collapsed to its surviving tab's content.
    if (parentRef?.kind !== 'tab' || targetId !== parentRef.parent.id) return root
    const survivor = parentRef.parent.tabs.find((tab) => tab.id !== parentRef.tab.id)
    if (!survivor) return root
    effectiveTargetId = survivor.content.id
  }

  if (zone === 'center') {
    const target = findNode(detached, effectiveTargetId)
    if (!target) return root
    if (isTabs(target)) {
      return normalize(
        addTab(detached, effectiveTargetId, createTab(titleOf(pane, effectiveTargetId), pane))
      )
    }
    if (isEmpty(target)) {
      // The pane takes over the placeholder's slot under its own id — live
      // content stays keyed to the node that travelled, not the slot.
      return normalize(replaceNode(detached, effectiveTargetId, () => pane) ?? detached)
    }
    const paneTab = createTab(titleOf(pane), pane)
    return promoteIntoTabs(
      detached,
      effectiveTargetId,
      paneTab,
      titleOf,
      targetOwnTab?.title ?? null
    )
  }

  const { direction, position } = edgeZoneToSplit(zone)
  return splitContent(detached, effectiveTargetId, direction, pane, position)
}

/**
 * Moves a detachable pane into the tabs group `targetGroupId` as a new tab at
 * `index` — a pane-drag drop on a tab bar. The pane node itself becomes the
 * tab's content, by reference; a tab that held it closes behind it.
 */
export function movePaneToTabs(
  root: ContentNode,
  paneId: NodeId,
  targetGroupId: NodeId,
  titleOf: TabTitler,
  index?: number
): ContentNode {
  if (!canMovePaneToTabs(root, paneId, targetGroupId)) return root
  const pane = findNode(root, paneId)
  if (!pane) return root
  const detached = withPaneDetached(root, paneId)
  if (!detached || !findNode(detached, targetGroupId)) return root
  const tab = createTab(titleOf(pane, targetGroupId), pane)
  return normalize(addTab(detached, targetGroupId, tab, index))
}

// ---------------------------------------------------------------------------
// Content placement
// ---------------------------------------------------------------------------

/**
 * Opens `content` at the pane `targetId`. The conflict-of-interest rule: when
 * the target already holds content of its own, the two become tabs of a group
 * rather than one replacing the other. Existing content is never destroyed —
 * its node is preserved by reference and only relocated, so anything keyed by
 * its id (a live pty) survives the move.
 *
 * - a tabs group    -> `content` is appended as a new tab
 * - an empty pane   -> `content` replaces it: a placeholder holds nothing worth
 *   keeping, so there is no conflict. Declined for empty `content`, which would
 *   be a visual no-op; that falls through to the group rules below, which is
 *   what makes "new tab" work on a blank pane.
 * - a tab's content -> `content` is appended to that tab's own group, beside it
 * - anything else (real content, a split child, the root) -> the target is
 *   promoted into the first tab of a new group taking over its slot, with
 *   `content` as the second
 *
 * `titleOf` names a node for the tab holding it; injected so the model stays
 * independent of the content registry.
 */
export function openContent(
  root: ContentNode,
  targetId: NodeId,
  content: ContentNode,
  titleOf: TabTitler
): ContentNode {
  const target = findNode(root, targetId)
  if (!target) return root

  if (isEmpty(target) && !isEmpty(content)) return replaceContent(root, targetId, content)

  // The group the new tab lands in, resolved before the tab is created so its
  // title can depend on the destination (see TabTitler).
  const parentRef = isTabs(target) ? null : findParent(root, targetId)
  const groupId = isTabs(target)
    ? target.id
    : parentRef?.kind === 'tab'
      ? parentRef.parent.id
      : null
  if (groupId !== null) return addTab(root, groupId, createTab(titleOf(content, groupId), content))

  // The group takes over the target's slot, so a split child keeps its size,
  // a tab keeps its place, and the root stays the root.
  const tab = createTab(titleOf(content), content)
  const next = replaceNode(root, targetId, (node) =>
    createTabs(isEmpty(node) ? [tab] : [createTab(titleOf(node), node), tab], {
      activeTabId: tab.id
    })
  )
  return normalize(next ?? root)
}
