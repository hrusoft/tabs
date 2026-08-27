import { headerOf, initialPane, rootPane, wrapInTabGroup } from '../helpers/pane'
import { expect, test } from './helpers/harness'

// The tab strip's own "+", appended after the last tab (TabBar.tsx) — a
// plain HeaderButton sitting directly in .tab-strip rather than inside
// PaneHeaderControls' toolbar (see openNewTab in helpers/pane.ts), but
// hidden until the bar is hovered the same as that toolbar's own buttons
// (global.css's .tab-bar:hover rule covers both). Opacity alone doesn't
// block Playwright's hit-testing, so a bare `.click()` still reaches it
// without an explicit `.hover()` first.

test("the tab strip's + button adds and activates a new tab in its own group", async ({ page }) => {
  await headerOf(rootPane(page)).getByTestId('tab-strip-new-tab-button').click()

  await expect(page.getByRole('tab')).toHaveCount(2)
  await expect(page.getByRole('tab').nth(1)).toHaveAttribute('aria-selected', 'true')
})

test("a nested group's + button adds a tab to that group only, leaving root's alone", async ({
  page
}) => {
  await wrapInTabGroup(initialPane(page))
  // Root's own wrapper, the new group's wrapper — same shape asserted in
  // pane-header.spec.ts's wrap test.
  const nestedGroup = page.getByTestId('pane').nth(1)

  await headerOf(nestedGroup).getByTestId('tab-strip-new-tab-button').click()

  await expect(page.getByRole('tablist').first().getByRole('tab')).toHaveCount(1)
  await expect(page.getByRole('tablist').nth(1).getByRole('tab')).toHaveCount(2)
})
