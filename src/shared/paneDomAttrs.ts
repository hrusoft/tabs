/**
 * The pane DOM's attribute vocabulary — the contract between the JSX that
 * stamps these (Pane, TabBar, EmptyPaneRenderer) and everything that queries
 * them back off the live DOM (dragController's hit-testing, spatialNav,
 * paneDom, and both test tiers through testing/paneSelectors.ts and
 * e2e/helpers). Renaming one used to be an eight-file edit with no compile
 * error anywhere; every producer and consumer now spells the name through
 * this map. Process-agnostic on purpose — no DOM API is touched here, so the
 * Playwright tier's node-side helpers can import it too.
 */
export const PANE_ATTR = {
  /** Stamped on every pane div — the id the layout model knows the node by. */
  dock: 'data-dock-id',
  /** A pane's own chrome bar, which is also its drag handle (Pane's header, TabBar's bar). */
  paneDrag: 'data-pane-drag-id',
  /** A tab bar, as a drop target for docking. */
  dropGroup: 'data-drop-group-id',
  /** A single tab, as a drop target. */
  dropTab: 'data-drop-tab-id',
  /** An empty pane's whole area, as a drop target. */
  dropEmptyPane: 'data-drop-empty-pane-id'
} as const

/**
 * The core pane-header buttons' test ids — stamped by PaneHeaderControls and
 * read back by both tiers' action helpers (e2e/helpers/pane.ts and
 * src/renderer/src/testing/paneActions.ts). The mechanics differ per tier —
 * real geometry hides menu items behind a hover there, jsdom clicks directly
 * — but the producer and both consumers spell each id through this one map.
 * A content type's own creation button is named by its package instead.
 */
export const PANE_BUTTON = {
  newTab: 'pane-new-tab-button',
  splitHorizontal: 'pane-split-horizontal-button',
  splitVertical: 'pane-split-vertical-button',
  newUnpinnedTab: 'pane-new-unpinned-tab-button',
  wrapInTabGroup: 'pane-tab-group-button',
  clear: 'pane-clear-button',
  close: 'pane-close-button'
} as const

/** `{ [attr]: id }` — spreadable onto the JSX element that carries the attribute. */
export function paneAttr(name: keyof typeof PANE_ATTR, id: string): Record<string, string> {
  return { [PANE_ATTR[name]]: id }
}
