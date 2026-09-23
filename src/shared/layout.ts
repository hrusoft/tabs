import type { FloatingPane } from './model/floating'
import { mapLeaves } from './model/tree'
import type { ContentNode, LeafContent, NodeId } from './model/types'

/**
 * The one snapshot version there is. Shared because both processes state it —
 * main's loader rejects on a mismatch and its default writes it, and the
 * renderer's persistLayout writes it on every save — so a bump made on one
 * side alone would make every save a snapshot the next boot silently
 * discards, i.e. persistence appearing to stop with no error anywhere. The
 * field is typed `typeof LAYOUT_VERSION` so that failure mode is a compile
 * error instead.
 */
export const LAYOUT_VERSION = 1

/**
 * Title of a top-level tab whose content has no name of its own to offer —
 * the docked root group's own placeholder title. Shared because both
 * processes mint such tabs (the renderer's layoutStore via
 * `rootTabTitleForContent`, main's loadLayoutFile via its own fallback) and they
 * name the same persisted artifact: the root tab's title written into
 * layout.json and asserted by name in e2e. Diverging copies would title the
 * same layout differently depending on which process wrapped it.
 */
export const ROOT_TAB_TITLE = 'Tabs'

/**
 * Title of any other tab whose content has no name of its own to offer —
 * ROOT_TAB_TITLE's counterpart everywhere below the docked root group. Shared
 * for the same reason: tab titles are assigned at creation and persisted, so
 * every program writing a snapshot must agree on what a fresh tab is called.
 */
export const NEW_TAB_TITLE = 'New Tab'

/** The persisted pane layout, as written to layout.json by main/layout.ts. */
export interface LayoutSnapshot {
  version: typeof LAYOUT_VERSION
  root: ContentNode
  activePaneId: NodeId
  /**
   * Panes lifted out of `root` into free-floating windows. Array order is
   * paint order — index 0 furthest back, the last entry on top — so the stack
   * a user built survives a restart exactly as they left it.
   *
   * Optional, and `version` deliberately stays 1: `loadLayoutFile` discards the
   * *whole* layout on a version mismatch, with no migration path, so an
   * additive optional key is the strictly better failure mode. A file written
   * before floating panes existed loads with nothing lost; a file written
   * after one, read by an older build, loses only the floating panes.
   */
  floating?: FloatingPane[]
}

/**
 * Every tree a layout holds: the docked root, then each floating window's
 * content. A pane the user has unpinned is only in the latter, so anything
 * looking for panes — or rewriting them — walks all of these, never `root`
 * alone.
 */
export function layoutTrees(layout: {
  root: ContentNode
  floating?: readonly FloatingPane[] | undefined
}): ContentNode[] {
  return [layout.root, ...(layout.floating ?? []).map((entry) => entry.content)]
}

/**
 * `mapLeaves` over every tree in `layout`, floating windows included. Keeps
 * structural sharing the way `mapLeaves` does, up to the snapshot itself:
 * `layout` comes back by reference when `fn` changed no leaf anywhere, which
 * callers use to decide whether anything needs saving.
 */
export function mapLayoutLeaves(
  layout: LayoutSnapshot,
  fn: (leaf: LeafContent) => LeafContent
): LayoutSnapshot {
  const root = mapLeaves(layout.root, fn)
  let floatingChanged = false
  const floating = layout.floating?.map((entry) => {
    const content = mapLeaves(entry.content, fn)
    if (content === entry.content) return entry
    floatingChanged = true
    return { ...entry, content }
  })
  if (root === layout.root && !floatingChanged) return layout
  return floating && floatingChanged ? { ...layout, root, floating } : { ...layout, root }
}
