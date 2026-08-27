import { NEW_TAB_TITLE, ROOT_TAB_TITLE } from '@shared/layout'
import type { ContentNode } from '@shared/model/types'
import { isEmpty, isSplit, isTabs } from '@shared/model/types'
import { contentRegistry } from './registry'

/** The registry-derived tab title, with `fallback` covering a content-less pane and an unregistered type alike. */
function derivedTabTitle(node: ContentNode, fallback: string): string {
  if (isEmpty(node)) return fallback
  return contentRegistry.get(node.type)?.displayName ?? fallback
}

/**
 * Names a node for the tab holding it, so a promoted terminal reads "Terminal"
 * rather than "New Tab". A content-less pane is titled by what it is about to
 * become instead of by its placeholder type ("Empty pane").
 *
 * Titles are assigned when a tab is created and are the user's to change from
 * there (`renameTab`) — filling a blank tab later never renames it.
 */
export function titleForContent(node: ContentNode): string {
  return derivedTabTitle(node, NEW_TAB_TITLE)
}

/**
 * `titleForContent`'s counterpart for a tab landing directly in the docked
 * root group: real content still gets its normal derived name (a promoted
 * terminal still reads "Terminal"), but a content-less placeholder reads
 * "Tabs" rather than "New Tab" — the window's own tab strip, not a pane
 * opened inside it. Applied by layoutStore's tab titler wherever a tab is
 * created in the root group specifically (see `tabTitler` there), and by
 * `ensureTabsRoot`'s call sites.
 */
export function rootTabTitleForContent(node: ContentNode): string {
  return derivedTabTitle(node, ROOT_TAB_TITLE)
}

/**
 * Titles a pane's header bar: a set title if there is one (a manual "Edit
 * title" override, or — for a terminal — its own live-reported title, see
 * `setLiveTitle` in tree.ts), else what the content is right now — an empty
 * pane reads "Empty pane", not the "New Tab" it might become. Recomputed on
 * every render, unlike tab titles, which are assigned once at creation.
 */
export function paneTitleForContent(node: ContentNode): string {
  const title = !isTabs(node) && !isSplit(node) ? node.title : undefined
  return title ?? contentRegistry.get(node.type)?.displayName ?? node.type
}
