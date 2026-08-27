import type { Page } from '@playwright/test'
import { PANE_BUTTON } from '../../src/shared/paneDomAttrs'
import {
  grabAndHover,
  grabAndHoverCenter,
  holdPastSpringLoad,
  releaseOnRightEdge
} from '../helpers/drag'
import { requireBox } from '../helpers/geometry'
import {
  clickPaneRoot,
  headerOf,
  initialPane,
  openNewTab,
  paneById,
  splitHorizontal,
  wrapInTabGroup
} from '../helpers/pane'
import { expect, test } from './helpers/harness'

// Ported from the Electron tier: pane drag/dock mechanics are real-geometry
// behavior (edge-zone bands, previews, spring-load timing). Where the old
// spec used a terminal purely as "a pane with real content" it's stub content
// here; the pty-survival halves stay in e2e/pane-drag.spec.ts ("a terminal
// keeps its shell and scrollback across an edge-dock pane drag" and the
// center-merge variant), where the shell is the subject.

test('dragging a pane header over a sibling previews every dock zone and splits on release', async ({
  page
}) => {
  await splitHorizontal(initialPane(page))
  const panes = page.getByTestId('pane')
  // Root's own wrapper (0), plus the split's two children.
  await expect(panes).toHaveCount(3)
  const draggedId = await panes.nth(1).getAttribute('data-dock-id')

  const target = await requireBox(panes.nth(2))
  const preview = page.getByTestId('dock-preview')

  // Left edge zone: the preview covers the target's left half.
  await grabAndHover(
    headerOf(panes.nth(1)),
    target.x + target.width * 0.08,
    target.y + target.height * 0.5
  )
  await expect(preview).toBeVisible()
  await page.waitForTimeout(150) // let the zone-change transition settle
  let box = await requireBox(preview)
  expect(box.x).toBeLessThan(target.x + target.width * 0.1)
  expect(box.width).toBeLessThan(target.width * 0.7)

  // Top edge zone: upper half.
  await page.mouse.move(target.x + target.width * 0.5, target.y + target.height * 0.08, {
    steps: 5
  })
  await page.waitForTimeout(150)
  box = await requireBox(preview)
  expect(box.y).toBeLessThan(target.y + target.height * 0.1)
  expect(box.height).toBeLessThan(target.height * 0.7)

  // Bottom edge zone: lower half.
  await page.mouse.move(target.x + target.width * 0.5, target.y + target.height * 0.92, {
    steps: 5
  })
  await page.waitForTimeout(150)
  box = await requireBox(preview)
  expect(box.y).toBeGreaterThan(target.y + target.height * 0.4)

  // Right edge zone, then release: the dragged pane lands right of its sibling.
  await page.mouse.move(target.x + target.width * 0.92, target.y + target.height * 0.5, {
    steps: 5
  })
  await page.waitForTimeout(150)
  box = await requireBox(preview)
  expect(box.x).toBeGreaterThan(target.x + target.width * 0.4)
  await page.mouse.up()

  await expect(panes).toHaveCount(3)
  await expect(panes.nth(2)).toHaveAttribute('data-dock-id', draggedId ?? '')
  const leftBox = await requireBox(panes.nth(1))
  const rightBox = await requireBox(panes.nth(2))
  expect(rightBox.x).toBeGreaterThan(leftBox.x)
})

test('dropping a pane at the center of another pane merges the two into one tab group', async ({
  page
}) => {
  await splitHorizontal(initialPane(page))
  const panes = page.getByTestId('pane')
  // The split activated the second pane: stub B lives there.
  await headerOf(panes.nth(2)).getByTestId('pane-new-stub-button').click()
  await headerOf(panes.nth(1)).getByTestId('pane-new-stub-button').click()
  await expect(page.getByTestId('stub-content')).toHaveCount(2)

  const targetBox = await requireBox(panes.nth(2))
  await grabAndHover(
    headerOf(panes.nth(1)),
    targetBox.x + targetBox.width / 2,
    targetBox.y + targetBox.height / 2
  )
  await expect(page.getByTestId('dock-preview')).toBeVisible()
  await page.mouse.up()

  // The bare target was promoted into a two-tab group — the dragged pane's
  // content beside it, active — and the vacated split collapsed away. Root's
  // own tablist plus the new group's are all that's left.
  await expect(page.getByRole('tablist')).toHaveCount(2)
  const tabs = page.getByRole('tablist').last().getByRole('tab')
  await expect(tabs).toHaveCount(2)
  await expect(page.getByRole('tab', { name: 'Stub' })).toHaveCount(2)
  await expect(tabs.nth(1)).toHaveAttribute('aria-selected', 'true')
  await expect(page.getByTestId('stub-content')).toHaveCount(2)
})

test('center-docking a tab-group pane onto another group nests it as a single tab', async ({
  page
}) => {
  await splitHorizontal(initialPane(page))
  const panes = page.getByTestId('pane')

  // Group A on the left…
  await openNewTab(panes.nth(1))
  // …group B on the right, its blank tab filled with stub content so its
  // content is a dock target rather than an empty-pane target.
  await openNewTab(panes.nth(3))
  await headerOf(panes.nth(4)).getByTestId('pane-new-stub-button').click()
  // Root's own tablist (0), plus A (1) and B (2).
  await expect(page.getByRole('tablist')).toHaveCount(3)

  // Hover the middle of B's tab content: docking resolves against the whole
  // group, and the center zone merges into it.
  const contentBox = await requireBox(panes.nth(4))
  await grabAndHover(
    headerOf(panes.nth(1)),
    contentBox.x + contentBox.width / 2,
    contentBox.y + contentBox.height / 2
  )
  await expect(page.getByTestId('dock-preview')).toBeVisible()
  await page.mouse.up()

  // Group A landed as ONE tab of group B — nested whole, tabs unmerged — so
  // both tab bars survive, one inside the other, alongside root's own.
  await expect(page.getByRole('tablist')).toHaveCount(3)
  const outerTabs = page.getByRole('tablist').nth(1).getByRole('tab')
  await expect(outerTabs).toHaveCount(2)
  await expect(outerTabs.nth(1)).toHaveText(/Tab group/)
  await expect(outerTabs.nth(1)).toHaveAttribute('aria-selected', 'true')
  await expect(page.getByRole('tablist').nth(2).getByRole('tab')).toHaveCount(1)
})

test("edge-docking near a tab's own content splits within that tab, leaving the group otherwise untouched", async ({
  page
}) => {
  await splitHorizontal(initialPane(page))
  const panes = page.getByTestId('pane')

  // Group A on the left, with a second tab (active) holding stub content…
  await openNewTab(panes.nth(1))
  await openNewTab(panes.nth(2))
  await headerOf(panes.nth(3)).getByTestId('pane-new-stub-button').click()

  // …and a bare stub pane B on the right, the drag subject.
  await headerOf(panes.nth(4)).getByTestId('pane-new-stub-button').click()

  // Root's own tablist plus group A's.
  const tablist = page.getByRole('tablist').last()
  const beforeBox = await requireBox(tablist)

  // Hover just inside the active tab's own content, close to its edge but
  // short of the thin sliver that targets the whole group instead.
  const contentBox = await requireBox(panes.nth(3))
  await grabAndHover(
    headerOf(panes.nth(4)),
    contentBox.x + contentBox.width * 0.85,
    contentBox.y + contentBox.height * 0.5
  )
  await expect(page.getByTestId('dock-preview')).toBeVisible()
  await page.mouse.up()

  // Group A is still the only (nested) tab group, still with exactly two
  // tabs — no sibling group and no new tab were created.
  await expect(page.getByRole('tablist')).toHaveCount(2)
  await expect(tablist.getByRole('tab')).toHaveCount(2)

  // But it now spans (roughly) the full width instead of half: the split
  // landed *inside* the active tab, so group A absorbed pane B's old slot
  // and became root's sole content, rather than staying beside it as a
  // sibling.
  const afterBox = await requireBox(tablist)
  expect(afterBox.width).toBeGreaterThan(beforeBox.width * 1.8)

  // Both stub panes survive, side by side inside the tab.
  await expect(page.getByTestId('stub-content')).toHaveCount(2)
})

test("edge-docking in the thin sliver at a group's true edge still splits the whole group out as a sibling", async ({
  page
}) => {
  await splitHorizontal(initialPane(page))
  const panes = page.getByTestId('pane')

  // Group A on the left, with a second tab (active) holding stub content…
  await openNewTab(panes.nth(1))
  await openNewTab(panes.nth(2))
  await headerOf(panes.nth(3)).getByTestId('pane-new-stub-button').click()

  // …and a bare stub pane B on the right, the drag subject.
  await headerOf(panes.nth(4)).getByTestId('pane-new-stub-button').click()

  // Root's own tablist plus group A's.
  const tablist = page.getByRole('tablist').last()
  const beforeBox = await requireBox(tablist)

  // Hover right at the active tab's edge, inside the thin band nearest the
  // group's true outer edge.
  const contentBox = await requireBox(panes.nth(3))
  await grabAndHover(
    headerOf(panes.nth(4)),
    contentBox.x + contentBox.width * 0.97,
    contentBox.y + contentBox.height * 0.5
  )
  await expect(page.getByTestId('dock-preview')).toBeVisible()
  await page.mouse.up()

  // Still one (nested) group, still two tabs — the drop didn't land inside
  // the tab.
  await expect(page.getByRole('tablist')).toHaveCount(2)
  await expect(tablist.getByRole('tab')).toHaveCount(2)

  // And its width is essentially unchanged: it's still confined to one side
  // of a split alongside pane B, exactly as before the drag.
  const afterBox = await requireBox(tablist)
  expect(afterBox.width).toBeLessThan(beforeBox.width * 1.3)
})

test('dropping a pane onto a tab bar inserts it as a tab at that position', async ({ page }) => {
  await splitHorizontal(initialPane(page))
  const panes = page.getByTestId('pane')
  await headerOf(panes.nth(2)).getByTestId('pane-new-stub-button').click()

  await openNewTab(panes.nth(1))
  await openNewTab(panes.nth(2))
  // Root's own tablist plus group A's.
  const tabs = page.getByRole('tablist').last().getByRole('tab')
  await expect(tabs).toHaveCount(2)

  // Release over the right half of the first tab -> insert at index 1.
  const tab0 = await requireBox(tabs.nth(0))
  await grabAndHover(headerOf(panes.nth(4)), tab0.x + tab0.width * 0.75, tab0.y + tab0.height / 2)
  await page.mouse.up()

  // The pane became the middle tab, activated; its emptied split collapsed.
  await expect(tabs).toHaveCount(3)
  await expect(tabs.nth(1)).toHaveText(/Stub/)
  await expect(tabs.nth(1)).toHaveAttribute('aria-selected', 'true')
  // Root's own wrapper, the group, and its now-three tab contents.
  await expect(page.getByTestId('pane')).toHaveCount(5)
  await expect(page.getByTestId('stub-content')).toBeVisible()
})

test('dropping a pane into an empty pane moves it there bare, collapsing the source split', async ({
  page
}) => {
  await splitHorizontal(initialPane(page))
  const panes = page.getByTestId('pane')
  await headerOf(panes.nth(2)).getByTestId('pane-new-stub-button').click()

  const emptyBox = await requireBox(panes.nth(1))
  await grabAndHover(
    headerOf(panes.nth(2)),
    emptyBox.x + emptyBox.width / 2,
    emptyBox.y + emptyBox.height / 2
  )
  // The placeholder highlights as the drop target (no dock preview: an empty
  // pane's center is a take-over, not a merge).
  await expect(page.getByTestId('empty-pane')).toHaveClass(/empty-pane-drop-target/)
  await page.mouse.up()

  // The stub took over the placeholder's slot under its own identity; no
  // tab group was created, and the vacated split collapsed to just it —
  // root's own wrapper plus that one pane are all that's left.
  await expect(page.getByTestId('pane')).toHaveCount(2)
  // Root's own tablist is always there; no nested group was created.
  await expect(page.getByRole('tablist')).toHaveCount(1)
  await expect(page.getByTestId('empty-pane')).toHaveCount(0)
  await expect(page.getByTestId('stub-content')).toBeVisible()
})

test('spring-loaded hover opens a tab mid pane-drag, allowing a drop inside its content', async ({
  page
}) => {
  await splitHorizontal(initialPane(page))
  const panes = page.getByTestId('pane')

  // Group A: tab 1 holds stub content, tab 2 (also a stub, mirroring tab
  // 1's type) is selected on top of it.
  await openNewTab(panes.nth(1))
  await headerOf(panes.nth(2)).getByTestId('pane-new-stub-button').click()
  await openNewTab(panes.nth(2))
  // Root's own tablist plus group A's.
  const groupTabs = page.getByRole('tablist').last().getByRole('tab')
  await expect(groupTabs).toHaveCount(2)
  await expect(groupTabs.nth(1)).toHaveAttribute('aria-selected', 'true')

  // Stub pane B in the second split pane is the drag subject. From here on,
  // address it by node id: the drag collapses the split and shifts pane
  // indices, so an index-based locator wouldn't reliably follow it.
  await headerOf(panes.nth(4)).getByTestId('pane-new-stub-button').click()
  const draggedId = await panes.nth(4).getAttribute('data-dock-id')
  const paneB = paneById(page, draggedId)
  const paneBBox = await requireBox(panes.nth(4))

  const tab0Box = await requireBox(groupTabs.nth(0))

  // Hover the covered tab briefly, then leave before the spring-load delay:
  // the pending activation must be cancelled, not applied.
  await grabAndHover(
    headerOf(panes.nth(4)),
    tab0Box.x + tab0Box.width / 2,
    tab0Box.y + tab0Box.height / 2
  )
  await page.waitForTimeout(200)
  await page.mouse.move(paneBBox.x + paneBBox.width / 2, paneBBox.y + paneBBox.height / 2, {
    steps: 5
  })
  await page.waitForTimeout(500)
  await expect(groupTabs.nth(0)).toHaveAttribute('aria-selected', 'false')

  // Hover again and hold past the delay: the tab springs open under the drag.
  await page.mouse.move(tab0Box.x + tab0Box.width / 2, tab0Box.y + tab0Box.height / 2, { steps: 5 })
  await holdPastSpringLoad(page)
  await expect(groupTabs.nth(0)).toHaveAttribute('aria-selected', 'true')

  // The revealed content is now hoverable; its center merges into the whole
  // group.
  const revealed = await requireBox(panes.nth(2))
  await page.mouse.move(revealed.x + revealed.width / 2, revealed.y + revealed.height / 2, {
    steps: 5
  })
  await expect(page.getByTestId('dock-preview')).toBeVisible()
  await page.mouse.up()

  // The dragged pane joined the group as a third tab, and its split collapsed.
  await expect(page.getByRole('tablist')).toHaveCount(2)
  const tabsAfter = page.getByRole('tablist').last().getByRole('tab')
  await expect(tabsAfter).toHaveCount(3)
  await expect(tabsAfter.nth(2)).toHaveText(/Stub/)
  await expect(tabsAfter.nth(2)).toHaveAttribute('aria-selected', 'true')
  await expect(paneB).toHaveCount(1)
})

test('spring-loading a sibling tab of the drag’s own bar is not gated on that bar accepting the drop', async ({
  page
}) => {
  // Two tabs, one pane each — the smallest shape there is, and the one where
  // the bar itself refuses the drop: detaching the pane collapses its tab, so
  // re-adding it to the same bar changes nothing (`canMovePaneToTabs`). The
  // reveal still has to happen, or the sibling tab's content is unreachable.
  await headerOf(initialPane(page)).getByTestId('pane-new-stub-button').click()
  // Clones the origin's own type, so the second tab arrives holding stub
  // content of its own rather than a placeholder.
  await openNewTab(initialPane(page))
  const panes = page.getByTestId('pane')

  const tabs = page.getByRole('tablist').getByRole('tab')
  await expect(tabs).toHaveCount(2)
  await expect(tabs.nth(1)).toHaveAttribute('aria-selected', 'true')

  const paneA = paneById(page, await panes.nth(1).getAttribute('data-dock-id'))
  const draggedId = await panes.nth(2).getAttribute('data-dock-id')

  await grabAndHoverCenter(headerOf(panes.nth(2)), tabs.nth(0))
  await holdPastSpringLoad(page)
  await expect(tabs.nth(0)).toHaveAttribute('aria-selected', 'true')

  // The revealed sibling's content is now a real target: dock into its left
  // edge, which is the whole point of springing it open. 18% rather than the
  // usual 8%: this pane fills the window, so the outer tenth is root's own
  // (refused) group-edge band — see GROUP_EDGE_ZONE_FRACTION.
  const revealed = await requireBox(paneA)
  await page.mouse.move(revealed.x + revealed.width * 0.18, revealed.y + revealed.height * 0.5, {
    steps: 5
  })
  await expect(page.getByTestId('dock-preview')).toBeVisible()
  await page.mouse.up()

  // One top-level tab left, holding a split of the two panes.
  await expect(tabs).toHaveCount(1)
  await expect(panes).toHaveCount(3)
  await expect(panes.nth(1)).toHaveAttribute('data-dock-id', draggedId ?? '')
})

// The shape a tab dropped on a sibling tab's pane edge leaves behind: the
// dragged tab lands as a single-tab GROUP in the new half, so its pane is a
// tab-group's child one level below root's own bar. Dragging that child back
// out — onto an ancestor bar, which is the only bar above it — walks a
// removal through two collapses at once (the group it leaves holds nothing
// else, and the split it sat in drops to one child), so it is where a
// relocation is most likely to lose or duplicate something.
test.describe('a pane dragged out of a nested tab group onto an ancestor bar', () => {
  // Everything below starts from the reported sequence, so it is built once.
  async function dockTabTwoIntoTabOne(page: Page): Promise<void> {
    await headerOf(initialPane(page)).getByTestId('pane-new-stub-button').click()
    await openNewTab(initialPane(page))
    const panes = page.getByTestId('pane')
    const tabs = page.getByRole('tablist').first().getByRole('tab')
    await expect(tabs).toHaveCount(2)

    const paneA = paneById(page, await panes.nth(1).getAttribute('data-dock-id'))
    // The tab, not the pane: dragging tab 2 onto tab 1 springs tab 1 open…
    await grabAndHoverCenter(tabs.nth(1), tabs.nth(0))
    await holdPastSpringLoad(page)
    await expect(tabs.nth(0)).toHaveAttribute('aria-selected', 'true')
    // …and the drop lands on the revealed pane's right edge.
    await releaseOnRightEdge(paneA)

    // Root collapsed to its one remaining tab, whose content is now a split of
    // the original pane and a single-tab group holding the tab that landed.
    await expect(tabs).toHaveCount(1)
    await expect(page.getByRole('tablist')).toHaveCount(2)
    await expect(page.getByTestId('stub-content')).toHaveCount(2)
  }

  /** The nested group's own child — the deepest pane on screen. */
  function deepestPaneId(page: Page): Promise<string | null> {
    return page.evaluate(() => {
      const all = Array.from(document.querySelectorAll('[data-dock-id]'))
      const depth = (el: Element): number => (el.parentElement ? depth(el.parentElement) + 1 : 0)
      return all
        .reduce((best, el) => (depth(el) > depth(best) ? el : best))
        .getAttribute('data-dock-id')
    })
  }

  test('lands as a top-level tab, taking its content and collapsing the group behind it', async ({
    page
  }) => {
    await dockTabTwoIntoTabOne(page)
    const childId = await deepestPaneId(page)
    const rootTabs = page.getByRole('tablist').first().getByRole('tab')
    const dest = await requireBox(rootTabs.first())

    await grabAndHover(
      headerOf(paneById(page, childId)),
      dest.x + dest.width * 0.75,
      dest.y + dest.height / 2
    )
    // Held past the spring-load delay: the ancestor tab is already the open
    // one, so revealing it must be a no-op rather than a second write.
    await holdPastSpringLoad(page)
    await page.mouse.up()

    // Two top-level tabs, and root's bar is the only bar left — the group the
    // pane left held nothing else, and the split it sat in dropped to one
    // child, so both collapsed away.
    await expect(rootTabs).toHaveCount(2)
    await expect(page.getByRole('tablist')).toHaveCount(1)
    await expect(rootTabs.nth(1)).toHaveAttribute('aria-selected', 'true')
    // Both panes survive by reference, neither duplicated: root's wrapper plus
    // exactly the two of them.
    await expect(page.getByTestId('pane')).toHaveCount(3)
    await expect(paneById(page, childId)).toHaveCount(1)
    await expect(page.getByTestId('stub-content')).toHaveCount(2)
    await expect(page.getByTestId('empty-pane')).toHaveCount(0)
  })

  test('is refused by its own bar, which would only re-add what is already there', async ({
    page
  }) => {
    await dockTabTwoIntoTabOne(page)
    const childId = await deepestPaneId(page)
    const before = await page
      .getByTestId('pane')
      .evaluateAll((els) => els.map((el) => el.getAttribute('data-dock-id')))

    // The nested group's own tab — its only one. Detaching the pane collapses
    // that group, so re-adding it there is a no-op (`canMovePaneToTabs`), and
    // the drop must change nothing rather than half-apply.
    const ownTab = await requireBox(page.getByRole('tablist').last().getByRole('tab').first())
    await grabAndHover(
      headerOf(paneById(page, childId)),
      ownTab.x + ownTab.width / 2,
      ownTab.y + ownTab.height / 2
    )
    await holdPastSpringLoad(page)
    await expect(page.getByTestId('dock-preview')).toHaveCount(0)
    await page.mouse.up()

    await expect(page.getByTestId('pane')).toHaveCount(before.length)
    expect(
      await page
        .getByTestId('pane')
        .evaluateAll((els) => els.map((el) => el.getAttribute('data-dock-id')))
    ).toEqual(before)
    await expect(page.getByRole('tablist')).toHaveCount(2)
  })

  test('crosses two levels of nesting without losing the pane or blanking the window', async ({
    page
  }) => {
    // A group inside a group inside root's tab — the same gesture with one
    // more level for the removal to walk up through.
    await headerOf(initialPane(page)).getByTestId('pane-new-stub-button').click()
    await wrapInTabGroup(initialPane(page))
    await wrapInTabGroup(page.getByTestId('pane').last())
    await expect(page.getByRole('tablist')).toHaveCount(3)

    const childId = await deepestPaneId(page)
    const rootTabs = page.getByRole('tablist').first().getByRole('tab')
    const dest = await requireBox(rootTabs.first())
    await grabAndHover(
      headerOf(paneById(page, childId)),
      dest.x + dest.width * 0.75,
      dest.y + dest.height / 2
    )
    await holdPastSpringLoad(page)
    await page.mouse.up()

    // The pane is a top-level tab and still holds its content; both nested
    // bars are gone. What the emptied chain leaves in the tab it vacated is a
    // placeholder — the same thing closing a group's last tab leaves — not a
    // group with no tabs, which would render as nothing at all.
    await expect(page.getByRole('tablist')).toHaveCount(1)
    await expect(rootTabs).toHaveCount(2)
    await expect(paneById(page, childId)).toHaveCount(1)
    await expect(page.getByTestId('stub-content')).toHaveCount(1)
    await expect(page.getByTestId('empty-pane')).toHaveCount(1)
  })
})

test('a targetless release flies the pane ghost home and changes nothing', async ({ page }) => {
  await splitHorizontal(initialPane(page))
  const panes = page.getByTestId('pane')
  const idsBefore = await panes.evaluateAll((els) =>
    els.map((el) => el.getAttribute('data-dock-id'))
  )

  // Off-screen: no pane covers it, so it's not a registered drop target. The
  // window's own chrome is gone (root's own tab bar plays the title-bar role
  // now — see App.tsx), so the whole viewport is pane content.
  const viewport = page.viewportSize()
  if (!viewport) throw new Error('no viewport size')

  await grabAndHover(headerOf(panes.nth(1)), viewport.width + 200, viewport.height / 2)

  await expect(page.getByTestId('dock-preview')).toHaveCount(0)
  // The ghost is labeled like the header it was grabbed by.
  await expect(page.locator('.drag-ghost')).toHaveText('Empty pane')

  await page.mouse.up()

  // The ghost flies back to the header, then disappears; the layout is
  // exactly as it was.
  await expect(page.locator('.drag-ghost')).toHaveCount(0)
  await expect(panes).toHaveCount(3)
  const idsAfter = await panes.evaluateAll((els) =>
    els.map((el) => el.getAttribute('data-dock-id'))
  )
  expect(idsAfter).toEqual(idsBefore)
})

test('a release this window never saw cancels the drag instead of wedging it', async ({ page }) => {
  await splitHorizontal(initialPane(page))
  const panes = page.getByTestId('pane')
  await headerOf(panes.nth(2)).getByTestId('pane-new-stub-button').click()
  const idsBefore = await panes.evaluateAll((els) =>
    els.map((el) => el.getAttribute('data-dock-id'))
  )

  // Hover a real target, so there IS something the drag would land on: the
  // point is that a lost release must not drop there.
  const target = await requireBox(panes.nth(2))
  await grabAndHover(
    headerOf(panes.nth(1)),
    target.x + target.width / 2,
    target.y + target.height / 2
  )
  await expect(page.getByTestId('dock-preview')).toBeVisible()

  // The button came back up somewhere the host was never told about — over a
  // `<webview>` guest, a native control, outside the window. Nothing announces
  // it (measured: no pointercancel, no lostpointercapture, no blur), so the
  // only evidence is the next move carrying no buttons, which is what this
  // dispatches.
  await page.evaluate(() => {
    window.dispatchEvent(
      new PointerEvent('pointermove', {
        pointerId: 1,
        clientX: 300,
        clientY: 300,
        buttons: 0,
        bubbles: true
      })
    )
  })

  // Cancelled, not dropped blind: the previewed target is exactly where the
  // release did NOT happen, so acting on it would relocate a pane on a gesture
  // the user had already finished elsewhere.
  await expect(page.locator('.drag-ghost')).toHaveCount(0)
  const idsAfter = await panes.evaluateAll((els) =>
    els.map((el) => el.getAttribute('data-dock-id'))
  )
  expect(idsAfter).toEqual(idsBefore)

  // And the controller is usable again. Without the recovery the session stays
  // armed for the life of the window: every later drag is refused, and the
  // next click's pointerup lands as a drop of this stale subject.
  await grabAndHover(
    headerOf(panes.nth(1)),
    target.x + target.width / 2,
    target.y + target.height / 2
  )
  await expect(page.locator('.drag-ghost')).toBeVisible()
  await page.mouse.up()
  await expect(page.getByRole('tablist')).toHaveCount(2)
})

test("the root pane's header does not start a drag", async ({ page }) => {
  const header = headerOf(page.getByTestId('pane').first())
  const box = await requireBox(header)

  await page.mouse.move(box.x + box.width / 2, box.y + box.height / 2)
  await page.mouse.down()
  await page.mouse.move(box.x + box.width / 2 + 60, box.y + box.height / 2 + 60, { steps: 8 })

  await expect(page.locator('.drag-ghost')).toHaveCount(0)
  await page.mouse.up()
  await expect(page.getByTestId('pane')).toHaveCount(2)
})

test('dragging a pane out of a multi-tab group closes only its tab behind it', async ({ page }) => {
  await splitHorizontal(initialPane(page))
  const panes = page.getByTestId('pane')

  await openNewTab(panes.nth(1))
  await openNewTab(panes.nth(2))
  await openNewTab(panes.nth(3))
  // Root's own tablist plus group A's.
  const tabs = page.getByRole('tablist').last().getByRole('tab')
  await expect(tabs).toHaveCount(3)

  // Pane 4 is the active third tab's content; pane 5 is the empty sibling.
  const draggedId = await panes.nth(4).getAttribute('data-dock-id')
  const target = await requireBox(panes.nth(5))
  await grabAndHover(
    headerOf(panes.nth(4)),
    target.x + target.width / 2,
    target.y + target.height / 2
  )
  await page.mouse.up()

  // The pane moved alone into the placeholder's slot under its own identity;
  // the tab that held it closed, and the group kept its other two tabs.
  await expect(tabs).toHaveCount(2)
  // Root's own tablist plus group A's.
  await expect(page.getByRole('tablist')).toHaveCount(2)
  await expect(panes.nth(4)).toHaveAttribute('data-dock-id', draggedId ?? '')
})

test("dragging the sole tab's pane out dissolves its group entirely", async ({ page }) => {
  await splitHorizontal(initialPane(page))
  const panes = page.getByTestId('pane')

  // A one-tab group holding stub content on the left, a placeholder right.
  await openNewTab(panes.nth(1))
  await headerOf(panes.nth(2)).getByTestId('pane-new-stub-button').click()
  // Root's own tablist plus group A's.
  await expect(page.getByRole('tablist')).toHaveCount(2)

  // The ghost wears the pane's own title — the drag is the pane's, not the
  // tab's.
  const paneTitle = await headerOf(panes.nth(2)).locator('.pane-title').innerText()
  const target = await requireBox(panes.nth(3))
  await grabAndHover(
    headerOf(panes.nth(2)),
    target.x + target.width * 0.92,
    target.y + target.height / 2
  )
  await expect(page.locator('.drag-ghost')).toHaveText(paneTitle)
  await expect(page.getByTestId('dock-preview')).toBeVisible()
  await page.mouse.up()

  // The emptied group left with its pane — no husk, no tab bar — leaving the
  // placeholder and the relocated stub side by side. Root's own tablist is
  // the only one left.
  await expect(page.getByRole('tablist')).toHaveCount(1)
  await expect(panes).toHaveCount(3)
  await expect(page.getByTestId('empty-pane')).toHaveCount(1)
  await expect(page.getByTestId('stub-content')).toBeVisible()
})

test('the grip drags a whole tab group, tabs and all', async ({ page }) => {
  await splitHorizontal(initialPane(page))
  const panes = page.getByTestId('pane')

  await openNewTab(panes.nth(1))
  await openNewTab(panes.nth(2))
  // Root's own tablist plus group A's.
  await expect(page.getByRole('tablist').last().getByRole('tab')).toHaveCount(2)

  // The strip's grip is the guaranteed handle, however many tabs fill it.
  const grip = headerOf(panes.nth(1)).locator('.pane-grip')
  await expect(grip).toBeVisible()

  // Dock the group against the empty sibling's right edge.
  const target = await requireBox(panes.nth(4))
  await grabAndHover(grip, target.x + target.width * 0.92, target.y + target.height / 2)
  await expect(page.getByTestId('dock-preview')).toBeVisible()
  await page.mouse.up()

  // The whole group moved — both tabs intact — landing right of the placeholder.
  // Root's own tablist plus the moved group's.
  await expect(page.getByRole('tablist')).toHaveCount(2)
  await expect(page.getByRole('tablist').last().getByRole('tab')).toHaveCount(2)
  const emptyBox = await requireBox(page.getByTestId('empty-pane').first())
  const barBox = await requireBox(page.getByRole('tablist').last())
  expect(barBox.x).toBeGreaterThan(emptyBox.x)
})

test('hovering a dragged pane over itself shows no preview, and releasing there is a no-op', async ({
  page
}) => {
  await splitHorizontal(initialPane(page))
  const panes = page.getByTestId('pane')
  await headerOf(panes.nth(2)).getByTestId('pane-new-stub-button').click()

  const own = await requireBox(panes.nth(2))

  // Hover the pane's own body center, then its own left edge zone: a pane
  // can't dock onto itself, so neither previews.
  await grabAndHover(headerOf(panes.nth(2)), own.x + own.width / 2, own.y + own.height / 2)
  await expect(page.locator('.drag-ghost')).toBeVisible()
  await expect(page.getByTestId('dock-preview')).toHaveCount(0)
  await page.mouse.move(own.x + own.width * 0.08, own.y + own.height / 2, { steps: 5 })
  await expect(page.getByTestId('dock-preview')).toHaveCount(0)

  await page.mouse.up()

  // Fly-back no-op: same two panes, same stub content.
  await expect(page.locator('.drag-ghost')).toHaveCount(0)
  await expect(panes).toHaveCount(3)
  await expect(panes.nth(2).getByTestId('stub-content')).toBeVisible()
})

// --- The docked root has no edge zones ---
//
// A nested group can be split out of itself as a sibling: it has a slot in its
// parent to leave the rest behind in. The docked root has no parent, so
// `splitContent` replaced the whole tree with the split and `ensureRootGroup`
// then invented a fresh single-tab group around it — the window's tab strip
// became a stranger holding one tab called "Split", and every tab the user had
// became a sub-pane one level down, at which point closing what looked like
// the offending wrapper took every pane with it. The band that triggered it is
// the outer tenth of the entire window, so any pane drag straying near an edge
// could land it by accident.

test('dragging a top-level pane to the window edge never splits the docked root out of itself', async ({
  page
}) => {
  // Three top-level tabs, so the pane being dragged is a direct tab of the
  // docked root — the shape whose enclosing group IS the root, and the only
  // one that could reach the root's own edge zone.
  await headerOf(initialPane(page)).getByTestId('pane-new-stub-button').click()
  const rootBar = page.getByTestId('pane').nth(0)
  await clickPaneRoot(rootBar, PANE_BUTTON.newTab)
  await clickPaneRoot(rootBar, PANE_BUTTON.newTab)
  await expect(page.locator('.tab-bar-root .tab')).toHaveCount(3)
  // The newest tab lands active; show the first one again so the pane being
  // dragged is the one on screen.
  await page.locator('.tab-bar-root .tab').first().click()

  const panes = page.getByTestId('pane')
  const before = await panes.evaluateAll((els) => els.map((el) => el.getAttribute('data-dock-id')))
  const viewport = page.viewportSize()
  if (!viewport) throw new Error('no viewport size')

  // The far-left band of the whole window — the docked root pane's own rect.
  await grabAndHover(headerOf(panes.nth(1)), 4, viewport.height / 2)
  await expect(page.getByTestId('dock-preview')).toHaveCount(0)
  await page.mouse.up()

  // Root's strip is untouched: still three tabs, no "Split" wrapper, and the
  // same panes in the same places.
  await expect(page.locator('.tab-bar-root .tab')).toHaveCount(3)
  await expect(page.locator('.tab-bar-root .tab-title').first()).not.toHaveText('Split')
  const after = await panes.evaluateAll((els) => els.map((el) => el.getAttribute('data-dock-id')))
  expect(after).toEqual(before)
})
