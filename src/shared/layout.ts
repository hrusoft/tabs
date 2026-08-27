import type { FloatingPane } from './model/floating'
import type { ContentNode, NodeId } from './model/types'

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
 * `rootTabTitleForContent`, main's loadLayout via its own fallback) and they
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
   * Optional, and `version` deliberately stays 1: `loadLayout` discards the
   * *whole* layout on a version mismatch, with no migration path, so an
   * additive optional key is the strictly better failure mode. A file written
   * before floating panes existed loads with nothing lost; a file written
   * after one, read by an older build, loses only the floating panes.
   */
  floating?: FloatingPane[]
}
