import { grabAndHover } from '../helpers/drag'
import { requireBox } from '../helpers/geometry'
import { activatePane, headerOf, initialPane, openNewTab, splitHorizontal } from '../helpers/pane'
import { emitSettingsChange, expect, test } from './helpers/harness'

// The two app.spec tests that need a real rendering engine: computed CSS
// filters, and a drag to build a nested group. The structural rest lives in
// src/renderer/src/__tests__/app.test.tsx; `opens a window titled Tabs` is
// e2e/ipc-smoke.spec.ts's (it proves the real preload boot). The dim setting
// is driven through the fake bridge — the Settings window round-trip is
// settings.spec.ts's subject.

test('dimming inactive panes fades only the inactive pane, and only once enabled', async ({
  page
}) => {
  // Set explicitly rather than relying on the default, which ships as `true`
  // (4451d4d) — this test's subject is the off→on transition, not what the
  // default happens to be.
  await emitSettingsChange(page, { dimInactivePanes: false })
  await splitHorizontal(initialPane(page))
  const panes = page.getByTestId('pane')
  const emptyPanes = page.getByTestId('empty-pane')
  await expect(panes.nth(2)).toHaveClass(/pane-active/)

  // Off: neither pane's content is dimmed despite one being inactive.
  await expect(emptyPanes.nth(0)).toHaveCSS('filter', 'none')
  await expect(emptyPanes.nth(1)).toHaveCSS('filter', 'none')

  await emitSettingsChange(page, { dimInactivePanes: true })

  // Only the inactive pane's content dims — its own header, and the active
  // pane, stay at full brightness.
  await expect(panes.nth(1)).toHaveClass(/pane-dimmed/)
  await expect(panes.nth(2)).not.toHaveClass(/pane-dimmed/)
  await expect(emptyPanes.nth(0)).not.toHaveCSS('filter', 'none')
  await expect(emptyPanes.nth(1)).toHaveCSS('filter', 'none')
  await expect(headerOf(panes.nth(1))).toHaveCSS('filter', 'none')

  // Activating the other pane swaps which one is dimmed.
  await activatePane(panes.nth(1))
  await expect(emptyPanes.nth(0)).toHaveCSS('filter', 'none')
  await expect(emptyPanes.nth(1)).not.toHaveCSS('filter', 'none')
})

test("closing a nested tab group's last tab empties its slot without removing the outer tab", async ({
  page
}) => {
  // Split off a second, independent pane to source a donor tab from, then
  // build the "outer" group on the first pane.
  await splitHorizontal(initialPane(page))
  const panes = page.getByTestId('pane')

  await openNewTab(panes.nth(1))
  // Root's own wrapper is pane 0. Converting pane 1 inserted its tab's
  // content pane at index 2, pushing the second split pane to index 3.
  const outerTabContent = panes.nth(2)

  await openNewTab(panes.nth(3))

  // Dragging the donor group's only tab onto the outer group's still-empty
  // tab content converts that empty leaf in place into a new nested tabs
  // group holding just the dragged tab: the New tab button alone can't nest
  // one there (it would only add a sibling to the bar it already belongs to),
  // but a drop onto an empty pane does, same as dropping onto a top-level one.
  // Root's own tablist (0) is untouched; outer (1) and donor (2) are the two
  // created above.
  const sourceTab = page.getByRole('tablist').nth(2).getByRole('tab').nth(0)
  const to = await requireBox(outerTabContent)

  await grabAndHover(sourceTab, to.x + to.width / 2, to.y + to.height / 2)
  await page.mouse.up()

  await expect(page.getByRole('tablist')).toHaveCount(3)
  const innerTablist = page.getByRole('tablist').nth(2)
  await innerTablist.getByRole('tab', { name: 'New Tab' }).getByLabel('Close New Tab').click()

  // The outer tab survives; its content reverts to a placeholder instead of
  // the outer tab (or group) disappearing. Root's own tablist plus the outer
  // group's are all that's left.
  await expect(page.getByRole('tablist')).toHaveCount(2)
  await expect(page.getByRole('tab', { name: 'New Tab' })).toHaveCount(1)
})
