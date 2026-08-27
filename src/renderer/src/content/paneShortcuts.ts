import { entryPaneId } from '@shared/model/navigation'
import type { ContentNode, NodeId, SplitDirection } from '@shared/model/types'
import { SHORTCUT_ACTIONS, type ShortcutActionId } from '@shared/shortcuts'
import { getPaneCapability, type PaneCapabilities } from '../core/registry/paneHandles'
import { useCommandPaletteStore } from '../core/store/commandPaletteStore'
import { closeTargetNode, findNodeAnywhere, useLayoutStore } from '../core/store/layoutStore'
import { confirmClosingContent } from './closeConfirmation'
import { createContentLike } from './contentLike'
import { fireAndReport, type UiAction } from './fireAndReport'
import { placeNewPane, placeNewUnpinnedPane } from './placement'

/**
 * Wires each menu-forwarded shortcut (see `HANDLERS` below, and buildMenu in
 * src/main/menu.ts for the accelerators they arrive on) to the same
 * layoutStore calls the active pane's own header buttons make, just targeting
 * `activePaneId` instead of a node passed down through props. Each creation
 * shortcut has its own fixed placement — there is no shared setting to read.
 * Returns a single uninstaller for every listener it installed.
 */
export function installPaneShortcuts(): () => void {
  const unsubscribes = Object.entries(HANDLERS).map(([id, handler]) =>
    window.api.shortcuts.onShortcut(id as ShortcutActionId, () => fireAndReport(handler))
  )
  return () => {
    for (const unsubscribe of unsubscribes) unsubscribe()
  }
}

/**
 * What each menu-forwarded action does, keyed by the id main sends. One table
 * rather than a named subscribe/unsubscribe pair per action, so adding a
 * shortcut is an entry here plus one in the shared registry — the bridge
 * itself no longer grows a method per action (see shortcuts.onShortcut).
 */
const HANDLERS: Partial<Record<ShortcutActionId, UiAction>> = {
  'command-palette': handleOpenCommandPalette,
  'new-tab': () => handleNewPane(),
  'split-horizontal': () => handleNewPane('horizontal'),
  'split-vertical': () => handleNewPane('vertical'),
  'new-unpinned-pane': handleNewUnpinnedPane,
  'close-pane': handleClosePane,
  'clear-buffer': onActivePane('clear'),
  'refresh-pane': onActivePane('refresh')
}

/**
 * Menu-forwarded actions with no entry in `HANDLERS` — asserted empty in the
 * jsdom tier, the same gate the app's other two dispatch registries have
 * (unhandledControlVerbs, main's unhandledMainControlVerbs). HANDLERS is a
 * Partial<Record>, which is precisely the escape hatch that would let a new
 * menu action compile into a silently dead menu item. An action main answers
 * itself declares `layer: 'main'` in the registry and is not demanded here.
 */
export function unhandledShortcutActions(): ShortcutActionId[] {
  return SHORTCUT_ACTIONS.filter((def) => def.layer === 'menu' && !(def.id in HANDLERS)).map(
    (def) => def.id
  )
}

// Every handler below looks the active pane up across every tree, docked or
// floating: with a plain `findNode(root, ...)` the creation shortcuts would
// silently do nothing in a floating window, and Cmd+W would find no node —
// which `confirmClosingContent` reads as "nothing running to warn about" —
// and kill a live shell there without the confirmation a docked pane gets.

/** Opens the Cmd+P content-creation overlay, targeting the active pane. */
function handleOpenCommandPalette(): void {
  const state = useLayoutStore.getState()
  if (!findNodeAnywhere(state, state.activePaneId)) return
  useCommandPaletteStore.getState().open(state.activePaneId)
}

/**
 * Fresh content of the same type as the active pane, with that pane's id — the
 * shared opening move of every creation shortcut, which differ only in where
 * they then put it. Null when there is no active pane to copy.
 */
async function contentLikeActivePane(): Promise<{
  activePaneId: NodeId
  content: ContentNode
} | null> {
  const state = useLayoutStore.getState()
  const origin = findNodeAnywhere(state, state.activePaneId)
  if (!origin) return null
  return { activePaneId: state.activePaneId, content: await createContentLike(origin) }
}

/** `direction` absent opens a new tab; given, splits the active pane that way. */
async function handleNewPane(direction?: SplitDirection): Promise<void> {
  const spawn = await contentLikeActivePane()
  if (!spawn) return
  placeNewPane(spawn.activePaneId, spawn.content, direction)
}

/**
 * Opens a fresh pane of the same type as the active one directly as a
 * floating, unpinned window — never docked — in whichever section of the
 * active pane the `newUnpinnedPanePosition` setting names.
 */
async function handleNewUnpinnedPane(): Promise<void> {
  const spawn = await contentLikeActivePane()
  if (!spawn) return
  placeNewUnpinnedPane(spawn.activePaneId, spawn.content)
}

async function handleClosePane(): Promise<void> {
  const state = useLayoutStore.getState()
  const { activePaneId, closePane } = state
  // `closeTargetNode`, not a plain lookup: the docked root's own tab bar is a
  // legitimate active pane (clicking its blank space activates the group), and
  // Cmd+W there means "close the tab I'm looking at" — which is what the store
  // does — not "replace the whole window with a placeholder". Asking about the
  // root itself would warn about every pane in the window.
  const node = closeTargetNode(state, activePaneId)
  if (await confirmClosingContent(node)) closePane(activePaneId)
}

/**
 * Dispatches a core-owned capability to the active pane — content decides what
 * clearing or refreshing means. See getPaneCapability, which is what makes this
 * a no-op rather than an error on a pane that offers none. `entryPaneId`
 * resolves a container id down to the leaf actually on screen: clicking a tab
 * strip's own background activates the group node, not the tab's content.
 */
function onActivePane(capability: keyof PaneCapabilities): () => void {
  return () => {
    const state = useLayoutStore.getState()
    const node = findNodeAnywhere(state, state.activePaneId)
    if (!node) return
    getPaneCapability(entryPaneId(node), capability)?.()
  }
}
