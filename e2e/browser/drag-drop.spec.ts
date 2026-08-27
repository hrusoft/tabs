import { PANE_BUTTON } from '../../src/shared/paneDomAttrs'
import { grabAndHover, holdPastSpringLoad } from '../helpers/drag'
import { requireBox } from '../helpers/geometry'
import { clickPaneRoot, headerOf, initialPane, openNewTab, splitHorizontal } from '../helpers/pane'
import { expect, test } from './helpers/harness'

// Ported from the Electron tier: tab drag-and-drop is real-geometry behavior
// (hit bands, elementFromPoint, spring-load timing) with zero Electron
// dependency — the one terminal the old spec opened purely as a center-merge
// dock target is stub content here.

test('dragging a tab onto another tab bar moves it there, collapsing an emptied source bar', async ({
  page
}) => {
  await splitHorizontal(initialPane(page))
  const panes = page.getByTestId('pane')

  await openNewTab(panes.nth(1))

  // Root's own wrapper is pane 0. Converting pane 1 inserted its (empty)
  // tab-content pane at index 2, pushing the second split pane to index 3.
  await openNewTab(panes.nth(3))

  // Root's own tablist (0) is untouched; the two nested groups created above
  // are the source and destination for the drag.
  const sourceTab = page.getByRole('tablist').nth(1).getByRole('tab').nth(0)
  const targetTab = page.getByRole('tablist').nth(2).getByRole('tab').nth(0)
  const draggedId = await sourceTab.getAttribute('data-drop-tab-id')

  const to = await requireBox(targetTab)

  // Release over the right half of the target's only tab -> insert after it.
  await grabAndHover(sourceTab, to.x + to.width * 0.75, to.y + to.height / 2)
  await page.mouse.up()

  // The source bar had exactly one tab; dragging it away collapses that bar
  // to an empty pane, so root's own tablist plus the target's are all that's
  // left.
  await expect(page.getByRole('tablist')).toHaveCount(2)
  const remainingTabs = page.getByRole('tablist').last().getByRole('tab')
  await expect(remainingTabs).toHaveCount(2)

  const idsAfter = await remainingTabs.evaluateAll((els) =>
    els.map((el) => el.getAttribute('data-drop-tab-id'))
  )
  expect(idsAfter[1]).toBe(draggedId)
  await expect(remainingTabs.nth(1)).toHaveAttribute('aria-selected', 'true')
})

test('dragging one tab out of a two-tab bar collapses the source bar to the remaining pane', async ({
  page
}) => {
  await splitHorizontal(initialPane(page))
  const panes = page.getByTestId('pane')

  await openNewTab(panes.nth(1))
  await openNewTab(panes.nth(2))

  // Root's own wrapper is pane 0. Converting pane 1 inserted its tab-content
  // panes starting at index 2, pushing the second split pane further down.
  await openNewTab(panes.last())

  // Root's own tablist (0) is untouched; the two nested groups created above
  // are the source and destination for the drag.
  const sourceBar = page.getByRole('tablist').nth(1)
  const sourceTab = sourceBar.getByRole('tab').nth(0)
  const targetTab = page.getByRole('tablist').nth(2).getByRole('tab').nth(0)
  const draggedId = await sourceTab.getAttribute('data-drop-tab-id')

  const to = await requireBox(targetTab)

  // Release over the right half of the target's only tab -> insert after it.
  await grabAndHover(sourceTab, to.x + to.width * 0.75, to.y + to.height / 2)
  await page.mouse.up()

  // The source bar had two tabs; losing one collapses it entirely to the
  // surviving tab's own content, not just down to a one-tab bar — root's own
  // tablist plus the target's are all that's left.
  await expect(page.getByRole('tablist')).toHaveCount(2)
  const remainingTabs = page.getByRole('tablist').last().getByRole('tab')
  await expect(remainingTabs).toHaveCount(2)

  const idsAfter = await remainingTabs.evaluateAll((els) =>
    els.map((el) => el.getAttribute('data-drop-tab-id'))
  )
  expect(idsAfter[1]).toBe(draggedId)
})

test('dragging a tab onto an empty pane converts it into a tabs group containing just that tab', async ({
  page
}) => {
  await splitHorizontal(initialPane(page))
  const panes = page.getByTestId('pane')
  // Acts on the new (second) pane directly, leaving the first (root's own
  // split sibling) empty.
  await openNewTab(panes.nth(2))

  // Root's own tablist (0) plus the new group created above (1).
  const sourceTab = page.getByRole('tablist').nth(1).getByRole('tab').nth(0)
  const draggedId = await sourceTab.getAttribute('data-drop-tab-id')
  const targetEmptyPane = page.getByTestId('empty-pane').nth(0)

  const to = await requireBox(targetEmptyPane)

  await grabAndHover(sourceTab, to.x + to.width / 2, to.y + to.height / 2)
  await page.mouse.up()

  await expect(page.getByRole('tablist')).toHaveCount(2)
  const newTabs = page.getByRole('tablist').last().getByRole('tab')
  await expect(newTabs).toHaveCount(1)
  await expect(newTabs).toHaveAttribute('data-drop-tab-id', draggedId ?? '')
  await expect(newTabs).toHaveAttribute('aria-selected', 'true')
})

test('reordering a tab within its own tab bar via drag', async ({ page }) => {
  // Root's own tab bar already holds one tab, so building it up to three only
  // takes two New tab calls (each adds a sibling directly — see openContent
  // in tree.ts), rather than the wrap-then-add-twice a bare pane would need.
  await openNewTab(initialPane(page))
  const panes = page.getByTestId('pane')
  await openNewTab(panes.nth(2))

  const tabs = page.getByRole('tablist').getByRole('tab')
  await expect(tabs).toHaveCount(3)
  const idsBefore = await tabs.evaluateAll((els) =>
    els.map((el) => el.getAttribute('data-drop-tab-id'))
  )

  const first = tabs.nth(0)
  const last = tabs.nth(2)
  const to = await requireBox(last)

  // Release over the right portion of the last tab -> insert after it.
  await grabAndHover(first, to.x + to.width * 0.9, to.y + to.height / 2)
  await page.mouse.up()

  await expect(tabs).toHaveCount(3)
  const idsAfter = await tabs.evaluateAll((els) =>
    els.map((el) => el.getAttribute('data-drop-tab-id'))
  )
  expect(idsAfter).toEqual([idsBefore[1], idsBefore[2], idsBefore[0]])
  await expect(tabs.nth(2)).toHaveAttribute('aria-selected', 'true')
})

test('releasing a drag over an invalid target is a no-op', async ({ page }) => {
  // Root's own tab bar already holds one tab, so one New tab call is enough
  // to reach two.
  await openNewTab(initialPane(page))

  const tabs = page.getByRole('tablist').getByRole('tab')
  await expect(tabs).toHaveCount(2)
  const idsBefore = await tabs.evaluateAll((els) =>
    els.map((el) => el.getAttribute('data-drop-tab-id'))
  )
  const activeBefore = await tabs.evaluateAll((els) =>
    els.map((el) => el.getAttribute('aria-selected'))
  )

  const dragged = tabs.nth(0)
  // Off-screen: no pane covers it, so it's not a registered drop target. The
  // window's own chrome is gone (root's own tab bar plays the title-bar role
  // now — see App.tsx), so the whole viewport is pane content and there is
  // no more "outside every pane" DOM element to grab a box from.
  const viewport = page.viewportSize()
  if (!viewport) throw new Error('no viewport size')

  await grabAndHover(dragged, viewport.width + 200, viewport.height / 2)
  await page.mouse.up()

  await expect(tabs).toHaveCount(2)
  const idsAfter = await tabs.evaluateAll((els) =>
    els.map((el) => el.getAttribute('data-drop-tab-id'))
  )
  const activeAfter = await tabs.evaluateAll((els) =>
    els.map((el) => el.getAttribute('aria-selected'))
  )
  expect(idsAfter).toEqual(idsBefore)
  expect(activeAfter).toEqual(activeBefore)
  // No stray tab bars/panes were created by the failed drop.
  await expect(page.getByRole('tablist')).toHaveCount(1)
})

test('docking a tab on a pane edge shows a preview and splits the pane', async ({ page }) => {
  // A NESTED group, not root's own: splitting a group out of itself needs a
  // slot in a parent to leave the rest behind in, which the docked root has
  // not got (see the companion test below, and the same rule for pane drags in
  // pane-drag.spec.ts).
  await splitHorizontal(initialPane(page))
  const panes = page.getByTestId('pane')
  // Real content first: `openNewTab` on a *placeholder* replaces it rather
  // than adding a tab beside it (see `openContent`), which would leave a
  // one-tab group with nothing to split out of.
  await headerOf(panes.nth(1)).getByTestId('pane-new-stub-button').click()
  await openNewTab(panes.nth(1))

  const tabs = page.getByRole('tablist').last().getByRole('tab')
  await expect(tabs).toHaveCount(2)
  const draggedId = await tabs.nth(0).getAttribute('data-drop-tab-id')

  // The group's own pane. Its content is an empty pane, which the edge zone
  // must out-rank as a target.
  const pane = await requireBox(panes.nth(1))

  // Hover deep in the right edge zone of the pane body.
  await grabAndHover(tabs.nth(0), pane.x + pane.width * 0.92, pane.y + pane.height * 0.5)

  // The preview shows where the tab would land before anything is dropped.
  const preview = page.getByTestId('dock-preview')
  await expect(preview).toBeVisible()
  const previewBox = await requireBox(preview)
  expect(previewBox.x).toBeGreaterThan(pane.x + pane.width * 0.4)

  await page.mouse.up()

  // The two-tab group split: its lone survivor collapsed to that tab's bare
  // content on the left, and the dragged tab landed in a new one-tab group to
  // its right. Root's own strip is untouched — still its single tab — which is
  // the half that used to fail when this same gesture was aimed at root's own
  // group: `ensureTabsRoot` re-wrapped the whole window instead.
  await expect(page.locator('.tab-bar-root .tab')).toHaveCount(1)
  const landedTabs = page.getByRole('tablist').last().getByRole('tab')
  await expect(landedTabs).toHaveCount(1)
  await expect(landedTabs).toHaveAttribute('data-drop-tab-id', draggedId ?? '')

  // Pane 1 is the survivor now holding the split's left half (the group and
  // its own content follow it in DOM order).
  const survivorBox = await requireBox(panes.nth(1))
  const landedBox = await requireBox(page.getByRole('tablist').last())
  expect(landedBox.x).toBeGreaterThan(survivorBox.x)
})

test("a tab dropped on the docked root's own edge is declined", async ({ page }) => {
  // The same gesture aimed at root's own group. It used to be honoured, and
  // `ensureTabsRoot` then had to wrap the resulting split in a brand-new
  // single-tab group: the window's strip became a stranger holding one tab
  // called "Split", and every tab the user had became a sub-pane one level
  // down. Root has no slot to be split into, so there is no target.
  await headerOf(initialPane(page)).getByTestId('pane-new-stub-button').click()
  const panes = page.getByTestId('pane')
  await clickPaneRoot(panes.nth(0), PANE_BUTTON.newTab)
  const tabs = page.locator('.tab-bar-root .tab')
  await expect(tabs).toHaveCount(2)
  // Show the tab holding the stub: a placeholder is its own drop target (see
  // `empty-pane` in dragController), which would absorb the tab before the
  // dock resolution this test is about ever ran.
  await tabs.first().click()
  const idsBefore = await tabs.evaluateAll((els) =>
    els.map((el) => el.getAttribute('data-drop-tab-id'))
  )

  const pane = await requireBox(panes.nth(0))
  await grabAndHover(tabs.first(), pane.x + pane.width * 0.92, pane.y + pane.height * 0.5)
  await expect(page.getByTestId('dock-preview')).toHaveCount(0)
  await page.mouse.up()

  // Nothing moved, and no wrapper group appeared.
  await expect(tabs).toHaveCount(2)
  expect(
    await tabs.evaluateAll((els) => els.map((el) => el.getAttribute('data-drop-tab-id')))
  ).toEqual(idsBefore)
  await expect(page.getByRole('tablist')).toHaveCount(1)
})

test("docking a tab in the center of another pane's content merges into its group", async ({
  page
}) => {
  await splitHorizontal(initialPane(page))
  const panes = page.getByTestId('pane')

  await openNewTab(panes.nth(1))
  await openNewTab(panes.nth(3))
  // Fill group B's blank tab with stub content: real content, so its pane
  // center is a dock target rather than an empty-pane target.
  await headerOf(panes.nth(4)).getByTestId('pane-new-stub-button').click()

  // Root's own tablist (0) is untouched; A (1) and B (2) are the two created
  // above.
  await expect(page.getByRole('tablist')).toHaveCount(3)

  const sourceTab = page.getByRole('tablist').nth(1).getByRole('tab').nth(0)
  const draggedId = await sourceTab.getAttribute('data-drop-tab-id')
  // Pane order: root's wrapper, group A, A's tab content, group B, B's tab
  // content.
  const targetPane = await requireBox(panes.nth(3))

  // Hover the dead center of group B's pane.
  await grabAndHover(
    sourceTab,
    targetPane.x + targetPane.width / 2,
    targetPane.y + targetPane.height / 2
  )

  await expect(page.getByTestId('dock-preview')).toBeVisible()

  await page.mouse.up()

  // The dragged tab joined the target group; its emptied source collapsed.
  // Root's own tablist plus group B's are all that's left.
  await expect(page.getByRole('tablist')).toHaveCount(2)
  const mergedTabs = page.getByRole('tablist').last().getByRole('tab')
  await expect(mergedTabs).toHaveCount(2)
  await expect(mergedTabs.nth(1)).toHaveAttribute('data-drop-tab-id', draggedId ?? '')
  await expect(mergedTabs.nth(1)).toHaveAttribute('aria-selected', 'true')
})

test('a drop with no preview flies the tab back and changes nothing', async ({ page }) => {
  // Root's own tab bar already holds one tab, so one New tab call is enough
  // to reach two.
  await openNewTab(initialPane(page))

  const tabs = page.getByRole('tablist').getByRole('tab')
  await expect(tabs).toHaveCount(2)
  const idsBefore = await tabs.evaluateAll((els) =>
    els.map((el) => el.getAttribute('data-drop-tab-id'))
  )

  // Off-screen: no pane covers it, so no dock zone previews (the whole
  // viewport is pane chrome now that root's own tab bar plays the window's
  // title-bar role — see App.tsx — so there is no more "outside every pane"
  // element on the page).
  const viewport = page.viewportSize()
  if (!viewport) throw new Error('no viewport size')

  await grabAndHover(tabs.nth(0), viewport.width + 200, viewport.height / 2)

  await expect(page.getByTestId('dock-preview')).toHaveCount(0)
  await expect(page.locator('.drag-ghost')).toBeVisible()

  await page.mouse.up()

  // The ghost flies back to the source tab, then disappears; the layout is
  // exactly as it was.
  await expect(page.locator('.drag-ghost')).toHaveCount(0)
  const idsAfter = await tabs.evaluateAll((els) =>
    els.map((el) => el.getAttribute('data-drop-tab-id'))
  )
  expect(idsAfter).toEqual(idsBefore)
  await expect(page.getByRole('tablist')).toHaveCount(1)
})

test('spring-loaded hover previews a tab in another bar before dropping', async ({ page }) => {
  await splitHorizontal(initialPane(page))
  const panes = page.getByTestId('pane')

  await openNewTab(panes.nth(1))
  await openNewTab(panes.nth(3))
  // Group B gets a second tab, which becomes active.
  await openNewTab(panes.nth(4))

  // Root's own tablist (0) is untouched; A (1) and B (2) are the two created
  // above.
  const groupABar = page.getByRole('tablist').nth(1)
  const groupBBar = page.getByRole('tablist').nth(2)
  const tabA = groupABar.getByRole('tab').nth(0)
  const b1 = groupBBar.getByRole('tab').nth(0)
  const b2 = groupBBar.getByRole('tab').nth(1)

  await expect(b1).toHaveAttribute('aria-selected', 'false')
  await expect(b2).toHaveAttribute('aria-selected', 'true')

  const from = await requireBox(tabA)
  const b1Box = await requireBox(b1)

  // Hover B1 briefly, then move off before the spring-load delay elapses:
  // the pending preview must be cancelled, not applied.
  await grabAndHover(tabA, b1Box.x + b1Box.width / 2, b1Box.y + b1Box.height / 2)
  await page.waitForTimeout(200)
  await page.mouse.move(from.x + from.width / 2, from.y + from.height / 2, { steps: 5 })
  await page.waitForTimeout(500)
  await expect(b1).toHaveAttribute('aria-selected', 'false')
  await expect(b2).toHaveAttribute('aria-selected', 'true')

  // Hover again and hold past the delay: B1 previews without dropping yet.
  await page.mouse.move(b1Box.x + b1Box.width / 2, b1Box.y + b1Box.height / 2, { steps: 5 })
  await holdPastSpringLoad(page)
  await expect(b1).toHaveAttribute('aria-selected', 'true')
  await expect(groupABar.getByRole('tab')).toHaveCount(1)

  await page.mouse.up()

  // Root's own tablist plus group B's are all that's left — A dissolved.
  await expect(page.getByRole('tablist')).toHaveCount(2)
  const remainingBar = page.getByRole('tablist').last()
  await expect(remainingBar.getByRole('tab')).toHaveCount(3)
})
