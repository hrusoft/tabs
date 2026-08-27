import { DOCKED_ROOT_SELECTOR, PANE_HEADER_SELECTOR } from '@shared/testing/paneSelectors'
import { screen, within } from '@testing-library/react'

/**
 * Every rendered pane, in DOM order — the jsdom tier's twin of e2e's
 * `page.getByTestId('pane')`. The `pane` test id is a markup contract, so it
 * is named here once rather than in each spec that queries it.
 */
export function panes(): HTMLElement[] {
  return screen.getAllByTestId('pane')
}

/**
 * Only the *docked* panes — the jsdom twin of e2e/helpers/floating.ts's
 * `dockedPanes`. A floating window's panes carry the same `pane` test id, so
 * anything counting one side has to scope to it; the container selector is
 * shared (see DOCKED_ROOT_SELECTOR), only the wrapper is per-tier.
 */
export function dockedPanes(): HTMLElement[] {
  const docked = document.querySelector<HTMLElement>(DOCKED_ROOT_SELECTOR)
  return docked ? within(docked).queryAllByTestId('pane') : []
}

/**
 * The pane meant to be interacted with in a freshly rendered app (no `root`
 * passed to `renderApp`) — as opposed to `panes()[0]`, which is always the
 * docked root's own auto-wrapping tab group now (see `ensureTabsRoot` in
 * tree.ts). A fresh render starts with exactly that wrapper plus the one
 * real pane its lone default tab holds, in that DOM order, so `panes()[1]`
 * is the one a test actually wants to split, fill, close, and so on — the
 * same role `panes()[0]` played before the root was always a tab group.
 * Every pane created *from* this one during a test keeps shifting by that
 * same +1, same as it would from any other starting pane.
 */
export function initialPane(): HTMLElement {
  return panes()[1]!
}

/**
 * jsdom twin of e2e/helpers/pane.ts's headerOf. Only the wrapper is duplicated
 * — the selector itself is shared (see PANE_HEADER_SELECTOR) — because the two
 * tiers return different types: a Playwright `Locator` there, an `HTMLElement`
 * here.
 */
export function headerOf(pane: Element): HTMLElement {
  const header = pane.querySelector<HTMLElement>(PANE_HEADER_SELECTOR)
  if (!header) throw new Error('Pane has no header chrome')
  return header
}
