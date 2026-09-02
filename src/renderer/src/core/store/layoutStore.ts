import { LAYOUT_VERSION } from '@shared/layout'
import { createLeaf } from '@shared/model/factories'
import type { FloatingPane, FloatRect } from '@shared/model/floating'
import {
  clampRect,
  detachForFloat,
  floatOwning,
  raiseFloating,
  replaceFloating,
  restoreFloating,
  sanitizeFloating
} from '@shared/model/floating'
import { createId } from '@shared/model/ids'
import { entryPaneId, focusAfterClose } from '@shared/model/navigation'
import * as tree from '@shared/model/tree'
import type {
  ContentNode,
  DockZone,
  NodeId,
  SplitDirection,
  TabsContent
} from '@shared/model/types'
import { EMPTY_TYPE, isEmpty, isTabs } from '@shared/model/types'
import { create } from 'zustand'
import { rootTabTitleForContent, titleForContent } from '../registry/titles'

export interface LayoutState {
  /**
   * The docked half of the layout — always a tab group, so the window's own
   * tab bar always exists (it doubles as the title bar). The type is the
   * invariant: every write path funnels through `ensureRootGroup` (via
   * `withOwner` or directly), and a new write path that forgets is a compile
   * error rather than a window that silently loses its chrome.
   */
  root: TabsContent
  /**
   * Panes lifted out of `root` into free-floating windows, drawn over the
   * docked layout. Array order is z-order: the last entry is topmost. Each
   * entry's `content` is a tree in its own right — every operation below runs
   * against exactly one tree, the docked root or one window's content, never
   * across two (see `withOwner`).
   */
  floating: FloatingPane[]
  /** The pane shown as focused (its header/tab-bar gets the active highlight). Always resolves to a node in `root` or in a floating window. */
  activePaneId: NodeId
  setActivePane: (id: NodeId) => void
  closeTab: (tabId: NodeId) => void
  activateTab: (groupId: NodeId, tabId: NodeId) => void
  moveTab: (tabId: NodeId, targetGroupId: NodeId, index?: number) => void
  /** Docks a dragged tab against a pane: edge zones split it, center merges into it. */
  dockTab: (tabId: NodeId, targetId: NodeId, zone: DockZone) => void
  renameTab: (tabId: NodeId, title: string) => void
  renamePane: (nodeId: NodeId, title: string | undefined) => void
  /** Updates a pane's title from its own running process (e.g. a terminal's reported title) — a no-op if the pane's title was set manually. */
  setLiveTitle: (nodeId: NodeId, title: string) => void
  /** Merges into a leaf's own config (e.g. a browser pane persisting its current URL). */
  setLeafConfig: (nodeId: NodeId, config: Record<string, unknown>) => void
  /** Splits `targetId`, adding `content` as the new sibling. */
  split: (targetId: NodeId, direction: SplitDirection, content: ContentNode) => void
  resizeSplit: (splitId: NodeId, sizes: number[]) => void
  /** Opens content at a pane without evicting what it already holds. */
  openContent: (targetId: NodeId, content: ContentNode) => void
  /** Closes a pane and everything in it — the header's close control. */
  closePane: (nodeId: NodeId) => void
  /** Replaces a pane's content with a fresh placeholder — the header's clear control. */
  clearPane: (nodeId: NodeId) => void
  /** Wraps a pane's content into a single-tab group — the header's tab-group control. */
  wrapPaneInTabs: (nodeId: NodeId) => void
  /** Collapses a single-tab group back to its tab's bare content — the tab bar's own context-menu control. */
  ungroupTabs: (groupId: NodeId) => void
  /** Docks a dragged pane against another pane: edge zones split it, center merges into it. */
  dockPane: (paneId: NodeId, targetId: NodeId, zone: DockZone) => void
  /** Drops a dragged pane onto a tab bar, becoming a tab of that group. */
  movePaneToTabs: (paneId: NodeId, targetGroupId: NodeId, index?: number) => void
  /** Lifts a docked pane out of the layout into a floating window at `rect` (viewport pixels). */
  unpinPane: (nodeId: NodeId, rect: FloatRect) => void
  /**
   * Opens brand-new `content` directly as a floating window at `rect`,
   * without ever docking it — the New Unpinned Pane shortcut's landing spot.
   * Unlike `unpinPane`, there is no docked node to detach, so this never
   * touches `root`; the window's anchor is `{ kind: 'root' }`, the same one a
   * floating pane with no other landmark falls back to, which is exactly the
   * right behavior on re-pin: dock it beside whatever is active then.
   */
  openFloatingPane: (content: ContentNode, rect: FloatRect) => void
  /** Returns a floating window's content to (approximately) where it came from. */
  repinPane: (floatId: NodeId) => void
  /** Commits a move/resize gesture's final geometry. */
  setFloatingRect: (floatId: NodeId, rect: FloatRect) => void
  /** Re-clamps every floating window against the current viewport in one update (see FloatingLayer). */
  reclampFloating: () => void
  /** Brings a floating window to the front of the stack. */
  raiseFloatingWindow: (floatId: NodeId) => void
}

/** The trees a layout holds — everything the owner/focus helpers need to look at. */
type LayoutTrees = Pick<LayoutState, 'root' | 'floating'>

/** `ensureTabsRoot` with the root-tab titler bound — the one spelling of the docked root's repair, so no write path can pick the wrong title function. `preferredTitle` overrides the type-derived default — see `survivorTitle`. */
function ensureRootGroup(
  node: ContentNode,
  preferredTitle?: () => string | undefined
): TabsContent {
  // A thunk, not a string: `ensureTabsRoot` consults the titler only when it
  // actually has to rebuild the wrapper — the rare collapse — while this runs
  // on every write to the docked tree, activations and resizes included.
  return tree.ensureTabsRoot(
    node,
    (content) => preferredTitle?.() ?? rootTabTitleForContent(content)
  )
}

/**
 * The title to give the docked root's wrapper when a collapse forces
 * `ensureRootGroup` to rebuild it (see `withOwner`) — whichever of the root's
 * *pre-operation* tabs is still findable in the result, by its content id.
 *
 * Without this, a root that collapses down to its one surviving tab gets
 * retitled from scratch by `rootTabTitleForContent`, which names the node
 * that happens to end up at the top — e.g. a nested dock landing a second
 * tab inside the survivor's content leaves a bare `SplitContent` there, whose
 * registered display name is "Split". The window's own tab strip would then
 * read "Split" instead of whatever the surviving tab was actually showing
 * (its derived name, or a title the user set by hand), which reads as the
 * window losing track of its own tab rather than as the drop that just
 * succeeded.
 *
 * Matched by content id rather than tab id: nodes travel by reference through
 * a collapse, but the `Tab` struct holding the title doesn't necessarily
 * survive, so the id that persists is the content's own. `before` is only
 * ever the docked root, which is always a `TabsContent`, so every one of its
 * tabs has a title to offer; `undefined` when nothing from before is
 * recognizable in `after` (a fresh tree, or no rewrap was needed at all).
 *
 * `excludeId` skips the tab the operation itself named (`withOwner`'s own
 * `id` argument — a tab id for a tab drag/close/move, a pane's own content id
 * for a pane drag, matched against whichever field applies). Its content is
 * frequently *still* findable in `after` too — relocated rather than
 * destroyed, e.g. nested into the very group being titled — so without the
 * exclusion the departing tab can shadow the tab that actually stayed behind
 * whenever it's listed first, naming root's wrapper after the thing that
 * just left rather than the thing still showing.
 */
function survivorTitle(
  before: TabsContent,
  after: ContentNode,
  excludeId?: NodeId
): string | undefined {
  for (const tab of before.tabs) {
    if (tab.id === excludeId || tab.content.id === excludeId) continue
    if (tree.findNode(after, tab.content.id)) return tab.title
  }
  return undefined
}

/**
 * Titles a newly minted tab: the root group's own placeholder title when the
 * tab lands directly in the docked root group, the normal derived title
 * everywhere else — including everywhere in a floating window's tree, whose
 * group ids never collide with the docked root's. Passed to every tree
 * operation that creates tabs, so the policy holds for New Tab and for a
 * pane dragged, docked, or re-pinned into the root strip alike.
 */
function tabTitler(state: LayoutTrees): tree.TabTitler {
  return (node, destGroupId) =>
    destGroupId === state.root.id ? rootTabTitleForContent(node) : titleForContent(node)
}

/**
 * A to-be-docked root, repaired the way every boot path repairs one:
 * normalized, then wrapped in the tab group the docked root always is.
 * `activePaneId` is the tree's own first pane, resolved against the
 * *pre-wrap* tree — `firstPaneId` deliberately doesn't descend into a tabs
 * group's own tabs (a group is a legitimate active pane in its own right
 * elsewhere), so resolving against the wrapper would land focus on its
 * chrome instead of the content. Also the jsdom tier's seed (see
 * testing/renderApp.tsx), so the two can't drift.
 */
export function repairDockedRoot(node: ContentNode): { root: TabsContent; activePaneId: NodeId } {
  const normalized = tree.normalize(node)
  return { root: ensureRootGroup(normalized), activePaneId: tree.firstPaneId(normalized) }
}

/**
 * Keeps `desired` active if it still exists — docked or floating — else falls
 * back to the first pane of the docked root, which always exists.
 */
function resolveActive(trees: LayoutTrees, desired: NodeId): NodeId {
  if (tree.findNode(trees.root, desired)) return desired
  if (floatOwning(trees.floating, desired)) return desired
  return tree.firstPaneId(trees.root)
}

interface Owner {
  /** The tree that owns the id: the docked root, or one floating window's content. */
  root: ContentNode
  /** The owning window's stable id, or null when the docked root owns it. */
  floatId: NodeId | null
}

/** True when `id` names either a node or a tab of `root` — layout actions are keyed by both. */
function holds(root: ContentNode, id: NodeId): boolean {
  return tree.findNode(root, id) !== null || tree.findTab(root, id) !== null
}

/**
 * Which tree owns `id`. Falls back to the docked root for an id in neither,
 * which preserves every operation's existing "unknown id is a no-op"
 * behaviour — the tree functions all return their input root unchanged for an
 * id they can't find.
 */
function ownerOf(trees: LayoutTrees, id: NodeId): Owner {
  if (holds(trees.root, id)) return { root: trees.root, floatId: null }
  const entry = trees.floating.find((candidate) => holds(candidate.content, id))
  return entry ? { root: entry.content, floatId: entry.id } : { root: trees.root, floatId: null }
}

/**
 * Redirects a pane action away from the docked root's own id, onto whichever
 * top-level tab is currently showing instead. A keyboard shortcut fires with
 * no guard at all — the root tab group's own bar is a legitimate focus target,
 * like any group's, so `activePaneId` really can be the root — and every
 * action that reaches it there would otherwise act on the whole window:
 * `split` would bury the entire tab strip inside one new tab beside a blank
 * pane, `wrapPaneInTabs` would nest a pointless single-tab group around it,
 * and `closePane`/`clearPane` would replace the layout — every tab, every
 * pane, every running process — with one empty placeholder. Redirecting makes
 * all four mean what they mean everywhere else: act on the tab you are
 * looking at. Every other id, including a floating window's own root, passes
 * through unchanged — only the docked root carries this invariant.
 *
 * Returns the root's own id only when it has no showing tab to redirect onto,
 * which `normalize` makes unreachable (a stale `activeTabId` falls back to the
 * first tab). The destructive callers below refuse that case outright rather
 * than acting on the root, so "the docked root cannot be closed" holds without
 * depending on that repair.
 */
function redirectFromDockedRoot(root: TabsContent, id: NodeId): NodeId {
  if (id !== root.id) return id
  const activeTab = root.tabs.find((tab) => tab.id === root.activeTabId)
  return activeTab?.content.id ?? id
}

/**
 * The node a close or clear aimed at `id` will really destroy — `id` itself
 * everywhere but the docked root, which redirects as above. Exported so the
 * close confirmation asks about the same content the store is about to act
 * on: asking about the root would list every pane in the window and then
 * close a single tab, which is the wrong prompt in both directions.
 */
export function closeTargetNode(trees: LayoutTrees, id: NodeId): ContentNode | null {
  return findNodeAnywhere(trees, redirectFromDockedRoot(trees.root, id))
}

/**
 * True when docking `targetId` at `zone` would try to split the docked root
 * out of itself. A nested group can be split out as a sibling — it has a slot
 * in its parent to leave behind — but the docked root has no parent, so
 * `splitContent` replaces the whole tree with the split and `ensureRootGroup`
 * then has to invent a fresh single-tab group around it: the window's tab
 * strip becomes a stranger holding one tab called "Split", and every tab the
 * user had is suddenly a sub-pane one level down. Nothing about the gesture
 * asks for that, and the band that triggers it is the outer tenth of the whole
 * window, so any pane drag that strays near an edge could land it. `center`
 * stays allowed: on a tabs node it means `addTab`, i.e. "make this a
 * top-level tab", which is exactly what dropping on the root's tab bar does.
 *
 * Exported for the same reason `closeTargetNode` is: the drag layer declines
 * this zone too, so the outer band of the whole window shows no preview rather
 * than previewing a drop that would then do nothing. Two layers refusing the
 * same thing is the intended shape — two layers *spelling* it separately is
 * how they drift apart.
 */
export function splitsDockedRootOutOfItself(
  root: TabsContent,
  targetId: NodeId,
  zone: DockZone
): boolean {
  return zone !== 'center' && targetId === root.id
}

/**
 * State after a tree operation on whichever tree owns `id`, with the result
 * written back where it came from and focus on `desired` — the destination the
 * operation just created or relocated, named directly or computed from the
 * result — or kept on the current active pane when no destination is named.
 * Either way the id is re-resolved, since `normalize` can collapse the very
 * node it names. An operation that no-oped (returning the same root reference)
 * gets the state back unchanged, so zustand skips notifying subscribers
 * entirely — no re-render, no redundantly scheduled persist — and focus stays
 * put even when a `desired` destination was named.
 *
 * The write back matches on the *pre-operation* float id, never on the new
 * content's id: several operations replace a subtree's root node (clearing a
 * pane, a dock that promotes one into a group), and a window's identity must
 * not follow its content's.
 *
 * The docked root gets one extra repair a floating window's content never
 * does: `ensureTabsRoot` re-wraps it in a tab group if this operation left it
 * as anything else — closing a docked root down to its last tab collapses
 * the wrapper the same way any nested group's does (see `withTabRemoved`),
 * and the window has no chrome of its own left to fall back on. `desired`
 * resolves against the wrapped tree, not the raw one, since that's what
 * actually gets stored — a `desired` naming the node that just got wrapped
 * still resolves correctly, since wrapping preserves it by reference.
 */
function withOwner(
  state: LayoutState,
  id: NodeId,
  apply: (root: ContentNode) => ContentNode,
  desired?: NodeId | ((next: ContentNode) => NodeId | undefined)
): LayoutState | Partial<LayoutState> {
  const owner = ownerOf(state, id)
  const rawNext = apply(owner.root)
  if (rawNext === owner.root) return state
  if (owner.floatId === null) {
    const next = ensureRootGroup(rawNext, () => survivorTitle(state.root, rawNext, id))
    const want = (typeof desired === 'function' ? desired(next) : desired) ?? state.activePaneId
    return { root: next, activePaneId: resolveActive({ ...state, root: next }, want) }
  }
  const want = (typeof desired === 'function' ? desired(rawNext) : desired) ?? state.activePaneId
  const floating = replaceFloating(state.floating, owner.floatId, (entry) => ({
    ...entry,
    content: rawNext
  }))
  return { floating, activePaneId: resolveActive({ ...state, floating }, want) }
}

/**
 * The store's starting state: the layout persisted to disk by the main process
 * (see src/main/layout.ts), read synchronously so the first render already
 * shows it — an async load would flash an empty pane first (settingsStore
 * reads its values the same way). Falls back to a single empty pane on first
 * run. Both trees are re-repaired here rather than trusted: main's own
 * `normalize` pass can collapse the very node that was active, e.g. a
 * single-tab group unwrapping to its lone child under a different id.
 *
 * The docked root is also re-wrapped in a tab group if it somehow isn't one
 * — main already does this on load (see `loadLayout`), so in practice this
 * is a no-op, but it's the same "repair here rather than trust it" reasoning
 * as `normalize`: this is the one spot every boot path funnels through,
 * including whatever a test harness hands `window.api.layout.getSync()`
 * directly. Both branches repair through `repairDockedRoot`; the snapshot's
 * own `activePaneId` wins over its default whenever it still resolves.
 */
function loadInitialState(): LayoutTrees & { activePaneId: NodeId } {
  const snapshot = window.api.layout.getSync()
  if (!snapshot?.root) return { ...repairDockedRoot(createLeaf(EMPTY_TYPE)), floating: [] }
  const { root } = repairDockedRoot(snapshot.root)
  const floating = sanitizeFloating(snapshot.floating, root)
  return { root, floating, activePaneId: resolveActive({ root, floating }, snapshot.activePaneId) }
}

const initialState = loadInitialState()

/** The viewport a floating window is clamped into — the one definition both the store's commits and floatingDrag's per-frame clamp share. */
export function viewportSize(): { width: number; height: number } {
  return { width: window.innerWidth, height: window.innerHeight }
}

function rectsEqual(a: FloatRect, b: FloatRect): boolean {
  return a.x === b.x && a.y === b.y && a.width === b.width && a.height === b.height
}

// Focus policy: operations that create or relocate content hand focus to the
// destination (the new split pane, the group now holding a docked tab, the
// just-opened content), so the next action lands there without an extra
// click; everything else keeps the current active pane. An operation that
// no-ops (returning the same root reference) leaves focus untouched.
export const useLayoutStore = create<LayoutState>()((set) => ({
  root: initialState.root,
  floating: initialState.floating,
  activePaneId: initialState.activePaneId,
  setActivePane: (id) =>
    set((state) => {
      const owner = ownerOf(state, id)
      if (!tree.findNode(owner.root, id)) return state
      // Activating a pane inside a floating window brings that window forward,
      // which is what makes "the last active one goes over the others" true
      // for every path that focuses a pane — clicks, spatial navigation, an
      // agent revealing a pane. `raiseFloating` returns the same array when it
      // is already topmost, so nothing churns in the common case.
      const floating = owner.floatId ? raiseFloating(state.floating, owner.floatId) : state.floating
      if (id === state.activePaneId && floating === state.floating) return state
      return { activePaneId: id, floating }
    }),
  closeTab: (tabId) =>
    set((state) => withOwner(state, tabId, (root) => tree.closeTab(root, tabId))),
  activateTab: (groupId, tabId) =>
    set((state) => withOwner(state, groupId, (root) => tree.activateTab(root, groupId, tabId))),
  moveTab: (tabId, targetGroupId, index) =>
    set((state) =>
      withOwner(
        state,
        tabId,
        (root) => tree.moveTab(root, tabId, targetGroupId, index),
        targetGroupId
      )
    ),
  dockTab: (tabId, targetId, zone) =>
    set((state) => {
      if (splitsDockedRootOutOfItself(state.root, targetId, zone)) return state
      return withOwner(
        state,
        tabId,
        (root) => tree.dockTab(root, tabId, targetId, zone, tabTitler(state)),
        (next) => tree.findTab(next, tabId)?.group.id
      )
    }),
  renameTab: (tabId, title) =>
    set((state) => withOwner(state, tabId, (root) => tree.renameTab(root, tabId, title))),
  renamePane: (nodeId, title) =>
    set((state) => withOwner(state, nodeId, (root) => tree.renamePane(root, nodeId, title))),
  setLiveTitle: (nodeId, title) =>
    set((state) => withOwner(state, nodeId, (root) => tree.setLiveTitle(root, nodeId, title))),
  setLeafConfig: (nodeId, config) =>
    set((state) => withOwner(state, nodeId, (root) => tree.setLeafConfig(root, nodeId, config))),
  split: (targetId, direction, content) =>
    set((state) => {
      const target = redirectFromDockedRoot(state.root, targetId)
      return withOwner(
        state,
        target,
        (root) => tree.splitContent(root, target, direction, content),
        content.id
      )
    }),
  resizeSplit: (splitId, sizes) =>
    set((state) => withOwner(state, splitId, (root) => tree.resizeSplit(root, splitId, sizes))),
  openContent: (targetId, content) =>
    set((state) =>
      withOwner(
        state,
        targetId,
        (root) => tree.openContent(root, targetId, content, tabTitler(state)),
        // Focus on the just-opened content matters beyond the usual policy: it
        // lands on a new tab's blank content, so a following pick fills that
        // tab rather than opening yet another one beside it.
        content.id
      )
    ),
  closePane: (nodeId) =>
    set((state) => {
      // A docked root resets to a placeholder because its slot survives; a
      // floating window has no slot, so closing the pane it is built around
      // closes the window itself.
      const entry = state.floating.find((candidate) => candidate.content.id === nodeId)
      if (entry) {
        const floating = state.floating.filter((candidate) => candidate !== entry)
        const top = floating[floating.length - 1]
        const desired = entryPaneId(top ? top.content : state.root)
        return { floating, activePaneId: resolveActive({ ...state, floating }, desired) }
      }
      // Closing the docked root means closing the tab it is showing, not the
      // window's entire contents (see `redirectFromDockedRoot`); with no tab
      // to redirect onto there is nothing here to close at all.
      const target = redirectFromDockedRoot(state.root, nodeId)
      if (target === state.root.id) return state
      const owner = ownerOf(state, target)
      return withOwner(
        state,
        target,
        (root) => tree.closePane(root, target),
        (next) =>
          target === state.activePaneId
            ? (focusAfterClose(owner.root, next, target) ?? undefined)
            : undefined
      )
    }),
  clearPane: (nodeId) =>
    set((state) => {
      // Redirected and refused exactly like `closePane` — clearing the docked
      // root would replace every tab in the window with one placeholder.
      const target = redirectFromDockedRoot(state.root, nodeId)
      if (target === state.root.id) return state
      const node = findNodeAnywhere(state, target)
      // Clearing a placeholder would only swap it for another placeholder.
      if (!node || isEmpty(node)) return state
      const empty = createLeaf(EMPTY_TYPE)
      // The cleared pane keeps focus under its new identity, so its own
      // header controls can immediately refill the slot that was just emptied.
      return withOwner(state, target, (root) => tree.replaceContent(root, target, empty), empty.id)
    }),
  wrapPaneInTabs: (nodeId) =>
    set((state) => {
      const target = redirectFromDockedRoot(state.root, nodeId)
      return withOwner(
        state,
        target,
        (root) => tree.wrapInTabs(root, target, tabTitler(state)),
        // The destination is the group just created — the wrapped node's new parent.
        (next) => {
          const ref = tree.findParent(next, target)
          return ref?.kind === 'tab' ? ref.parent.id : target
        }
      )
    }),
  ungroupTabs: (groupId) =>
    set((state) => {
      // The docked root can't ungroup — the window has no chrome to fall back
      // on. The tab bar already hides the option there (see TabBar's context
      // menu); this is the store-level backstop for any other surface, since
      // letting it through would collapse and instantly re-wrap the root
      // under a fresh group id, churning its identity for nothing.
      if (groupId === state.root.id) return state
      const group = findNodeAnywhere(state, groupId)
      const survivor =
        group && isTabs(group) && group.tabs.length === 1 ? group.tabs[0]!.content : null
      return withOwner(
        state,
        groupId,
        (root) => tree.ungroupTabs(root, groupId),
        survivor ? entryPaneId(survivor) : undefined
      )
    }),
  dockPane: (paneId, targetId, zone) =>
    set((state) => {
      if (splitsDockedRootOutOfItself(state.root, targetId, zone)) return state
      return withOwner(
        state,
        paneId,
        // The pane survives the move by reference and keeps focus in its new place.
        (root) => tree.dockPane(root, paneId, targetId, zone, tabTitler(state)),
        paneId
      )
    }),
  movePaneToTabs: (paneId, targetGroupId, index) =>
    set((state) =>
      withOwner(
        state,
        paneId,
        (root) => tree.movePaneToTabs(root, paneId, targetGroupId, tabTitler(state), index),
        paneId
      )
    ),
  unpinPane: (nodeId, rect) =>
    set((state) => {
      // The docked root has no parent to detach from — floating it would lift
      // every tab in the window into one floating pane and leave the docked
      // area a single fresh placeholder. Refused here as the backstop, same
      // as ungroupTabs/closePane/clearPane for the identical hazard; the
      // chrome menu also hides the entry for the root (see pinOrUnpinItem).
      if (nodeId === state.root.id) return state
      // Only docked panes float: `detachForFloat` resolves against the docked
      // root alone, so a node already inside a window comes back null.
      const result = detachForFloat(state.root, nodeId, clampRect(rect, viewportSize()))
      if (!result) return state
      // Appended last, so the newest window starts on top.
      const floating = [...state.floating, result.floating]
      // Re-wrap like every other docked-root mutation (see `withOwner`, which
      // this bypasses entirely): the root itself can no longer reach here,
      // but floating the last content of the root group still collapses it.
      const root = ensureRootGroup(result.root)
      // The pane survives by reference and keeps focus in its new place — the
      // same policy `dockPane` follows.
      const trees = { root, floating }
      return { ...trees, activePaneId: resolveActive(trees, nodeId) }
    }),
  openFloatingPane: (content, rect) =>
    set((state) => {
      const entry: FloatingPane = {
        id: createId(),
        content,
        rect: clampRect(rect, viewportSize()),
        anchor: { kind: 'root' }
      }
      // Appended last, so the newest window starts on top and focused — the
      // same policy `unpinPane` follows.
      return { floating: [...state.floating, entry], activePaneId: content.id }
    }),
  repinPane: (floatId) =>
    set((state) => {
      const entry = state.floating.find((candidate) => candidate.id === floatId)
      if (!entry) return state
      const contentId = entry.content.id
      // Re-wrapped like every other direct root write (`withOwner` for the
      // rest) — restoreFloating's current branches all preserve a tabs root,
      // but that's its implementation, not its contract.
      const root = ensureRootGroup(
        restoreFloating(state.root, entry, tabTitler(state), state.activePaneId)
      )
      const floating = state.floating.filter((candidate) => candidate !== entry)
      return { root, floating, activePaneId: resolveActive({ root, floating }, contentId) }
    }),
  setFloatingRect: (floatId, rect) =>
    set((state) => {
      const clamped = clampRect(rect, viewportSize())
      const floating = replaceFloating(state.floating, floatId, (entry) =>
        rectsEqual(entry.rect, clamped) ? entry : { ...entry, rect: clamped }
      )
      return floating === state.floating ? state : { floating }
    }),
  reclampFloating: () =>
    set((state) => {
      const viewport = viewportSize()
      let changed = false
      const floating = state.floating.map((entry) => {
        const clamped = clampRect(entry.rect, viewport)
        if (rectsEqual(entry.rect, clamped)) return entry
        changed = true
        return { ...entry, rect: clamped }
      })
      return changed ? { floating } : state
    }),
  raiseFloatingWindow: (floatId) =>
    set((state) => {
      const floating = raiseFloating(state.floating, floatId)
      return floating === state.floating ? state : { floating }
    })
}))

// ---------------------------------------------------------------------------
// Cross-tree queries
// ---------------------------------------------------------------------------
//
// Anything outside the store that used to reach for `state.root` directly has
// to go through one of these instead, or it silently stops seeing panes the
// moment a user unpins one. Kept here beside `ownerOf` so there is one
// definition of "which tree is this id in".

/** Every tree the layout holds: the docked root first, then each floating window's content. */
export function allRoots(trees: LayoutTrees): ContentNode[] {
  return [trees.root, ...trees.floating.map((entry) => entry.content)]
}

/** The tree that owns `id`, or the docked root when nothing does. */
export function ownerRootOf(trees: LayoutTrees, id: NodeId): ContentNode {
  return ownerOf(trees, id).root
}

/** `findNode` across every tree. */
export function findNodeAnywhere(trees: LayoutTrees, id: NodeId): ContentNode | null {
  for (const root of allRoots(trees)) {
    const found = tree.findNode(root, id)
    if (found) return found
  }
  return null
}

// ---------------------------------------------------------------------------
// Persistence
// ---------------------------------------------------------------------------

function persistLayout(state: LayoutState): void {
  window.api.layout.set({
    version: LAYOUT_VERSION,
    root: state.root,
    activePaneId: state.activePaneId,
    floating: state.floating
  })
}

let saveTimer: ReturnType<typeof setTimeout> | undefined

// Layout changes (drags, resizes, tab moves) fire far more often than a
// settings toggle, so saves are debounced rather than written on every
// mutation the way settingsStore's `setSetting` does.
useLayoutStore.subscribe((state) => {
  clearTimeout(saveTimer)
  saveTimer = setTimeout(() => persistLayout(state), 400)
})

// A quit shortly after the last edit shouldn't lose it to the debounce
// window above.
window.addEventListener('beforeunload', () => {
  clearTimeout(saveTimer)
  persistLayout(useLayoutStore.getState())
})
