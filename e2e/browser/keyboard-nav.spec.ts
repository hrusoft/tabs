import {
  activatePane,
  initialPane,
  openNewTab,
  splitHorizontal,
  splitVertical
} from '../helpers/pane'
import { MOD_KEY } from '../helpers/platform'
import { expect, test } from './helpers/harness'

// Ported from the Electron tier: these are the rect-driven navigation tests —
// which pane a move enters or wraps to is computed from live bounding boxes
// (spatialNav.ts), so they need a real layout engine; in jsdom every rect is
// zero and only the model fallback would run, making a pass vacuous. The
// model-driven tests live in src/renderer/src/__tests__/keyboard-nav.test.tsx;
// the terminal-focus and webview tests stay on Electron.

test('cmd+left/right move focus between split panes', async ({ page }) => {
  await splitHorizontal(initialPane(page))
  const panes = page.getByTestId('pane')
  await activatePane(panes.nth(1))
  await expect(panes.nth(1)).toHaveClass(/pane-active/)

  await page.keyboard.press(`${MOD_KEY}+ArrowRight`)
  await expect(panes.nth(2)).toHaveClass(/pane-active/)
  await expect(panes.nth(1)).not.toHaveClass(/pane-active/)

  await page.keyboard.press(`${MOD_KEY}+ArrowLeft`)
  await expect(panes.nth(1)).toHaveClass(/pane-active/)
})

test('cmd+up/down move focus between vertically split panes', async ({ page }) => {
  await splitVertical(initialPane(page))
  const panes = page.getByTestId('pane')
  await activatePane(panes.nth(1))

  await page.keyboard.press(`${MOD_KEY}+ArrowDown`)
  await expect(panes.nth(2)).toHaveClass(/pane-active/)

  await page.keyboard.press(`${MOD_KEY}+ArrowUp`)
  await expect(panes.nth(1)).toHaveClass(/pane-active/)
})

test('navigating past the edge of a plain split wraps to the opposite pane', async ({ page }) => {
  await splitHorizontal(initialPane(page))
  const panes = page.getByTestId('pane')
  await splitHorizontal(panes.nth(2))
  // Root's own wrapper (0), plus the three split leaves now beneath it.
  await expect(panes).toHaveCount(4)

  await activatePane(panes.nth(3))
  await expect(panes.nth(3)).toHaveClass(/pane-active/)

  // No tab group to cycle, so the true edge wraps to the far pane instead of
  // staying put. Root's own wrapper isn't a navigable target, so the wrap
  // lands on the leftmost real pane.
  await page.keyboard.press(`${MOD_KEY}+ArrowRight`)
  await expect(panes.nth(1)).toHaveClass(/pane-active/)

  await page.keyboard.press(`${MOD_KEY}+ArrowLeft`)
  await expect(panes.nth(3)).toHaveClass(/pane-active/)
})

test('a pane at the edge of a tab group walks the group before leaving it', async ({ page }) => {
  await splitHorizontal(initialPane(page))
  const panes = page.getByTestId('pane')
  // Turn the left (split) pane into a two-tab group; pane order: root's
  // wrapper, group, its two tab contents, then the right-hand pane.
  await openNewTab(panes.nth(1))
  await openNewTab(panes.nth(1))
  await expect(panes).toHaveCount(5)
  // Root's own tablist, plus the new nested group's.
  const tabs = page.getByRole('tablist').last().getByRole('tab')

  await tabs.nth(0).click()
  await expect(panes.nth(2)).toHaveClass(/pane-active/)

  // The right-hand pane sits right there on screen, but the rest of the group
  // comes first.
  await page.keyboard.press(`${MOD_KEY}+ArrowRight`)
  await expect(tabs.nth(1)).toHaveAttribute('aria-selected', 'true')
  await expect(panes.nth(3)).toHaveClass(/pane-active/)

  // Only once the group is exhausted does focus leave it.
  await page.keyboard.press(`${MOD_KEY}+ArrowRight`)
  await expect(panes.nth(4)).toHaveClass(/pane-active/)
  await expect(tabs.nth(1)).toHaveAttribute('aria-selected', 'true')
})

test('up/down move between a pane and the tab group below it, never cycling tabs', async ({
  page
}) => {
  await splitVertical(initialPane(page))
  const panes = page.getByTestId('pane')
  // Turn the bottom pane into a two-tab group; pane order: root's wrapper,
  // top pane, group, then the group's two tab contents.
  await openNewTab(panes.nth(2))
  await openNewTab(panes.nth(2))
  await expect(panes).toHaveCount(5)
  // Root's own tablist, plus the new nested group's.
  const tabs = page.getByRole('tablist').last().getByRole('tab')
  await expect(tabs.nth(1)).toHaveAttribute('aria-selected', 'true')

  await activatePane(panes.nth(1))
  await expect(panes.nth(1)).toHaveClass(/pane-active/)

  // Down lands on whatever the group is showing — never the group node
  // itself, and never the tab hidden behind it.
  await page.keyboard.press(`${MOD_KEY}+ArrowDown`)
  await expect(panes.nth(4)).toHaveClass(/pane-active/)

  await page.keyboard.press(`${MOD_KEY}+ArrowUp`)
  await expect(panes.nth(1)).toHaveClass(/pane-active/)

  // Inside the group, a vertical press leaves the tab selection alone: with
  // nothing below it, focus wraps to the pane above instead.
  await page.keyboard.press(`${MOD_KEY}+ArrowDown`)
  await page.keyboard.press(`${MOD_KEY}+ArrowDown`)
  await expect(tabs.nth(1)).toHaveAttribute('aria-selected', 'true')
  await expect(panes.nth(1)).toHaveClass(/pane-active/)
})

test('entering a tab lands on the pane nearest the crossed edge', async ({ page }) => {
  // Root's own wrapper is already the tab group, starting with one tab, so
  // one more call reaches two.
  await openNewTab(initialPane(page))
  const panes = page.getByTestId('pane')
  // Split tab 2's content; pane order: root's wrapper, tab 1 content, then
  // the split's two.
  await splitHorizontal(panes.nth(2))
  await expect(panes).toHaveCount(4)
  const tabs = page.getByRole('tab')

  // Switching to tab 1 focuses its lone content pane directly.
  await tabs.nth(0).click()
  await expect(panes.nth(1)).toHaveClass(/pane-active/)

  // Entering rightward lands on tab 2's leftmost pane...
  await page.keyboard.press(`${MOD_KEY}+ArrowRight`)
  await expect(tabs.nth(1)).toHaveAttribute('aria-selected', 'true')
  await expect(panes.nth(2)).toHaveClass(/pane-active/)

  // ...walks on through the split...
  await page.keyboard.press(`${MOD_KEY}+ArrowRight`)
  await expect(panes.nth(3)).toHaveClass(/pane-active/)

  // ...wraps back to tab 1 at the edge...
  await page.keyboard.press(`${MOD_KEY}+ArrowRight`)
  await expect(tabs.nth(0)).toHaveAttribute('aria-selected', 'true')
  await expect(panes.nth(1)).toHaveClass(/pane-active/)

  // ...and entering leftward lands on tab 2's rightmost pane.
  await page.keyboard.press(`${MOD_KEY}+ArrowLeft`)
  await expect(tabs.nth(1)).toHaveAttribute('aria-selected', 'true')
  await expect(panes.nth(3)).toHaveClass(/pane-active/)
})

test('moving into a column of panes stays in the row the movement came from', async ({ page }) => {
  await splitHorizontal(initialPane(page))
  const panes = page.getByTestId('pane')
  // Two columns of two, so entering one has a real choice of rows to land in.
  await splitVertical(panes.nth(1))
  await splitVertical(panes.nth(3))
  // Root's own wrapper (0), plus the four leaves in a 2x2 grid.
  await expect(panes).toHaveCount(5)

  // Bottom-left → right lands bottom-right, not at the top of the column.
  await activatePane(panes.nth(2))
  await page.keyboard.press(`${MOD_KEY}+ArrowRight`)
  await expect(panes.nth(4)).toHaveClass(/pane-active/)

  await page.keyboard.press(`${MOD_KEY}+ArrowLeft`)
  await expect(panes.nth(2)).toHaveClass(/pane-active/)
})

test('a press with nowhere to go still flashes and keeps focus', async ({ page }) => {
  const pane = initialPane(page)
  await expect(pane).toHaveClass(/pane-active/)

  await page.keyboard.press(`${MOD_KEY}+ArrowUp`)
  await expect(page.getByTestId('nav-flash')).toHaveAttribute('data-direction', 'up')
  await expect(pane).toHaveClass(/pane-active/)
})
