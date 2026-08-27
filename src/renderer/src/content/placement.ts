import type { FloatRect, NewPaneSpawnPosition } from '@shared/model/floating'
import {
  DEFAULT_FLOAT_RECT,
  floatOwning,
  resolveSpawnPosition,
  spawnRectIn
} from '@shared/model/floating'
import { ancestorTabSteps } from '@shared/model/navigation'
import type { ContentNode, NodeId, SplitDirection } from '@shared/model/types'
import { useLayoutStore } from '../core/store/layoutStore'
import { useSettingsStore } from '../core/store/settingsStore'
import { createContentLike } from './contentLike'
import { paneDomRect } from './paneDom'

/**
 * Places `content` at `targetId` — a new tab when `direction` is omitted, or
 * a split in the given direction otherwise. Where every *docking* creation
 * path lands: the three keyboard shortcuts, each passing its own fixed
 * direction (New Tab / New Horizontal Split / New Vertical Split — see
 * paneShortcuts.ts), and the matching three items in a pane's own header
 * (PaneHeaderControls.tsx), which differ only in aiming at that pane rather
 * than the active one. New Unpinned Pane is deliberately not one of them: it
 * never docks, so it goes straight to the store's `openFloatingPane` instead
 * (see `placeNewUnpinnedPane` below).
 *
 * A content type's own external-control verbs reach this through the plugin
 * context's `layout.placeNewPane`, with whatever direction that package's
 * policy resolves to — the browser's `controlledPanePlacement` setting is the
 * one such policy today. Core states the mechanism and nothing about the
 * policy: which panes an agent's belong beside is the package's question, and
 * a copy of the answer here is a copy that goes stale (it did once already,
 * when this paragraph still promised agent-created panes were always tabs).
 */
export function placeNewPane(
  targetId: NodeId,
  content: ContentNode,
  direction?: SplitDirection
): void {
  const { split, openContent } = useLayoutStore.getState()
  if (direction) split(targetId, direction, content)
  else openContent(targetId, content)
}

/**
 * `placeNewPane`, deriving its content from `origin` first via
 * `createContentLike` — the pane-header items (PaneHeaderControls.tsx) and
 * the tab strip's own "+" button (TabBar.tsx, `origin` there being the group
 * itself, so cwd inheritance resolves from its currently active tab) both
 * already have their target node in hand, so they can derive and place in
 * one call. The keyboard-shortcut path (paneShortcuts.ts) doesn't use this:
 * it resolves the active pane once and shares that lookup with
 * `placeNewUnpinnedPane` too, so its derivation stays separate from placing.
 */
export async function placeNewPaneLike(
  targetId: NodeId,
  origin: ContentNode,
  direction?: SplitDirection
): Promise<void> {
  placeNewPane(targetId, await createContentLike(origin), direction)
}

/**
 * A rect for a freshly spawned unpinned pane: `position`'s section of
 * `originId`'s on-screen rect. All the arithmetic (the size cap, the edge
 * insets, the centering) is `spawnRectIn`'s, in shared/model/floating.ts —
 * this half is only the DOM measurement, which is why the two are split at all.
 *
 * Falls back to the default floating geometry when the pane has no measurable
 * rect (e.g. a backgrounded tab): with no rect there is nothing to divide into
 * nine, so the setting simply has nothing to say about this case.
 * `openFloatingPane` clamps into the viewport regardless.
 */
function spawnRect(originId: NodeId, position: NewPaneSpawnPosition): FloatRect {
  const origin = paneDomRect(originId)
  if (!origin) return DEFAULT_FLOAT_RECT
  return spawnRectIn(
    { x: origin.left, y: origin.top, width: origin.width, height: origin.height },
    position
  )
}

/**
 * Opens `content` directly as a floating, unpinned window — never docked — in
 * whichever section of `originId`'s own rect the `newUnpinnedPanePosition`
 * setting names. Shared by the New Unpinned Pane keyboard shortcut
 * (paneShortcuts.ts) and the pane header's split-group dropdown item, both of
 * which already have the origin pane's id in scope.
 *
 * The setting is read at call time rather than subscribed to: this only ever
 * runs from an event handler, so `getState()` already sees the newest value —
 * including one the Settings window changed a moment ago in another window,
 * which settingsStore mirrors.
 */
export function placeNewUnpinnedPane(originId: NodeId, content: ContentNode): void {
  const position = resolveSpawnPosition(useSettingsStore.getState().newUnpinnedPanePosition)
  useLayoutStore.getState().openFloatingPane(content, spawnRect(originId, position))
}

/**
 * Brings an existing pane onto the screen: activates every ancestor tab
 * between it and its own tree's root — a pane can sit in a tab inside a tab,
 * so revealing it means winning at every level — then raises its floating
 * window if it lives in one, since a pane buried under other floats is a poor
 * kind of visible. A no-op for an id no tree holds.
 *
 * Focus is deliberately left alone: this makes a pane *visible*, it does not
 * grab the user's keyboard. Callers wanting focus have `setActivePane`.
 *
 * Content-agnostic on purpose, and here rather than in a content folder for
 * that reason — it is the same tab-walking mechanic `placeNewPane` relies on,
 * expressed for a pane that already exists. Its only caller today is the
 * external-control `activatePane` verb, which applies its own ownership rules
 * before calling (see src/plugins/browser/renderer/browserExternalControl.ts); the split
 * keeps the layout mechanics reusable and the ownership policy with the
 * content type that defines it.
 */
export function revealPane(paneId: NodeId): void {
  const state = useLayoutStore.getState()
  const { activateTab, raiseFloatingWindow } = state
  // One ownership resolution covers both halves: which window holds the pane
  // (if any), and the tree its ancestor tabs must be walked in.
  const owner = floatOwning(state.floating, paneId)
  const root = owner?.content ?? state.root
  for (const step of ancestorTabSteps(root, paneId)) {
    activateTab(step.groupId, step.tabId)
  }
  if (owner) raiseFloatingWindow(owner.id)
}
