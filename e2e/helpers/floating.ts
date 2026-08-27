import type { Locator, Page } from '@playwright/test'
import { PANE_ATTR } from '../../src/shared/paneDomAttrs'
import { DOCKED_ROOT_SELECTOR } from '../../src/shared/testing/paneSelectors'
import { dragTo } from './drag'
import { centerOf, requireBox } from './geometry'

/**
 * Floating-window queries and gestures, shared by both Playwright tiers —
 * any spec that counts docked vs. floating panes or drives a window's own
 * chrome imports these. The testids and the menu labels are named once here:
 * a tier that kept its own copy would fail far from whatever change broke
 * it, and only in the tier nobody reran.
 */

/** The docked half itself, for scoping ad hoc queries the way dockedPanes does. */
export function dockedRoot(page: Page): Locator {
  return page.locator(DOCKED_ROOT_SELECTOR)
}

/**
 * A floating pane's panes carry `data-dock-id` and `data-testid="pane"` just
 * like docked ones, so every count has to scope to one side or the other.
 */
export function dockedPanes(page: Page): Locator {
  return dockedRoot(page).getByTestId('pane')
}

export function floatingWindows(page: Page): Locator {
  return page.getByTestId('floating-window')
}

/** The pane a floating window is built around — its own outermost chrome. */
export function windowPane(win: Locator): Locator {
  return win.locator(':scope > [data-testid="pane"]')
}

/** Right-clicks `chrome` and picks a context-menu item. Exact match, or "Pin" would find "Unpin" too. */
async function contextMenuItem(chrome: Locator, name: string): Promise<void> {
  await chrome.click({ button: 'right' })
  await chrome.page().getByRole('menuitem', { name, exact: true }).click()
}

export async function unpin(chrome: Locator): Promise<void> {
  await contextMenuItem(chrome, 'Unpin')
}

export async function pin(chrome: Locator): Promise<void> {
  await contextMenuItem(chrome, 'Pin')
}

/** Drags a floating window by a delta, using its own chrome as the handle. */
export async function moveWindowBy(chrome: Locator, dx: number, dy: number): Promise<void> {
  const from = centerOf(await requireBox(chrome))
  await dragTo(chrome, from.x + dx, from.y + dy)
}

/** Every floating window's id, back to front. */
export function stackOrder(page: Page): Promise<string[]> {
  return page.evaluate(() =>
    [...document.querySelectorAll<HTMLElement>('[data-floating-id]')]
      .sort((a, b) => Number(a.style.zIndex) - Number(b.style.zIndex))
      .map((el) => el.dataset.floatingId ?? '')
  )
}

/** The floating window built around the pane `paneId`. */
export function windowHolding(page: Page, paneId: string): Locator {
  return page.locator(`[data-floating-id]:has(> [${PANE_ATTR.dock}="${paneId}"])`)
}

/** The id of the frontmost floating window at a point, per real hit-testing. */
export function frontmostAt(page: Page, x: number, y: number): Promise<string | null> {
  return page.evaluate(
    ([px, py]) => {
      const el = document.elementFromPoint(px!, py!)
      return el?.closest<HTMLElement>('[data-floating-id]')?.dataset.floatingId ?? null
    },
    [x, y]
  )
}
