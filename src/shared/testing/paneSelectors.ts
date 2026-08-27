import { PANE_ATTR } from '../paneDomAttrs'
/**
 * DOM selectors describing the app's own markup contract, shared by the test
 * tiers that query it from opposite sides of the preload boundary — the jsdom
 * component tier (src/renderer/src/testing/domQueries.ts, via `@shared`) and
 * the Playwright tiers (e2e/helpers/pane.ts, via a relative import). Both
 * tsconfig projects include src/shared, so this is a real shared home rather
 * than two copies that have to be kept textually identical by hand.
 *
 * Only the selector string is shared. Each tier's own `headerOf` wrapper stays
 * where it is: one returns a Playwright `Locator`, the other an `HTMLElement`,
 * and neither type is available to the other.
 */

/**
 * A pane's own chrome bar, never a nested pane's: its title bar, or — for a
 * tab-group pane, which has no separate title bar — the tab strip that doubles
 * as one. Both hosts carry `data-pane-drag-id` (see `Pane` and `TabBar`), so
 * the two `:scope >` paths are what keep the match to this pane's own level.
 */
export const PANE_HEADER_SELECTOR = `:scope > [${PANE_ATTR.paneDrag}], :scope > .pane-body > .tabs-view > [${PANE_ATTR.paneDrag}]`

/**
 * The docked half's container (App.tsx) — floating panes render outside it,
 * so any query counting one side scopes through this. Shared for the same
 * reason as the header selector: both tiers' `dockedPanes` were restating it.
 */
export const DOCKED_ROOT_SELECTOR = '.app-content'
