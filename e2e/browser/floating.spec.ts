import { MIN_FLOAT_SIZE, NEW_PANE_SPAWN_SPACING } from '../../src/shared/model/floating'
import { PANE_BUTTON } from '../../src/shared/paneDomAttrs'
import { dragTo, grabAndHover } from '../helpers/drag'
import {
  dockedPanes,
  dockedRoot,
  floatingWindows,
  frontmostAt,
  moveWindowBy,
  pin,
  unpin,
  windowHolding,
  windowPane
} from '../helpers/floating'
import { requireBox } from '../helpers/geometry'
import {
  activatePane,
  clickPaneRoot,
  closePane,
  headerOf,
  initialPane,
  openNewTab,
  openNewUnpinnedTab,
  rootPane,
  splitHorizontal
} from '../helpers/pane'
import { MOD_KEY } from '../helpers/platform'
import { emitSettingsChange, expect, fireShortcut, test } from './helpers/harness'

// Ported from the Electron tier: floating-window behavior is real-geometry
// through and through — windows open over their pane's rect, move and resize
// by pixel deltas, stack by z-index resolved with real hit-testing. Cmd+T is
// fired through the fake bridge (the same shortcuts.onShortcut contract the
// native menu drives); the terminal-pid and relaunch-persistence tests stay
// in e2e/floating.spec.ts, where the pty and the disk are the subject.

test('unpinning a pane from a split lifts it into a floating window and collapses the split', async ({
  page
}) => {
  await splitHorizontal(initialPane(page))
  const docked = dockedPanes(page)
  // docked.nth(0) is root's own always-present tab-group wrapper (see
  // ensureTabsRoot in tree.ts); the split's children follow at 1 and 2.
  await expect(docked).toHaveCount(3)
  const liftedId = await docked.nth(1).getAttribute('data-dock-id')
  const before = await requireBox(docked.nth(1))

  await unpin(headerOf(docked.nth(1)))

  await expect(floatingWindows(page)).toHaveCount(1)
  // The split is gone: its surviving child took over the whole layout, so
  // just root's own wrapper and that one pane remain docked.
  await expect(docked).toHaveCount(2)
  await expect(windowPane(floatingWindows(page).first())).toHaveAttribute(
    'data-dock-id',
    liftedId ?? ''
  )

  // The window opens over the pane's own place on screen, so it reads as
  // lifting off the layout rather than jumping somewhere else.
  const after = await requireBox(floatingWindows(page).first())
  expect(after.x).toBeCloseTo(before.x, 0)
  expect(after.y).toBeCloseTo(before.y, 0)
  expect(after.width).toBeCloseTo(before.width, 0)
})

test('re-pinning a floating pane puts it back beside the sibling it came from', async ({
  page
}) => {
  await splitHorizontal(initialPane(page))
  const docked = dockedPanes(page)
  const liftedId = await docked.nth(1).getAttribute('data-dock-id')
  await unpin(headerOf(docked.nth(1)))
  await expect(docked).toHaveCount(2)

  await pin(headerOf(windowPane(floatingWindows(page).first())))

  await expect(floatingWindows(page)).toHaveCount(0)
  await expect(docked).toHaveCount(3)
  // Back on its old side of the split, not merely somewhere in the layout.
  await expect(docked.nth(1)).toHaveAttribute('data-dock-id', liftedId ?? '')
})

test('re-pinning restores a pane into the tab group and position it came from', async ({
  page
}) => {
  // Root's own wrapper is already the tab group (ensureTabsRoot in tree.ts),
  // starting with one tab, so two more calls reach three. Its own root button
  // is New tab directly (PaneHeaderControls.tsx's isDockedRoot branch), not
  // nested behind Split horizontally the way a non-root group's is.
  await clickPaneRoot(rootPane(page), PANE_BUTTON.newTab)
  await clickPaneRoot(rootPane(page), PANE_BUTTON.newTab)
  await expect(page.getByRole('tab')).toHaveCount(3)
  const titles = await page.getByRole('tab').allInnerTexts()

  // The middle tab's content, unpinned from inside the group.
  await unpin(page.getByRole('tab').nth(1))
  await expect(page.getByRole('tab')).toHaveCount(2)
  await expect(floatingWindows(page)).toHaveCount(1)

  await pin(headerOf(windowPane(floatingWindows(page).first())))

  await expect(page.getByRole('tab')).toHaveCount(3)
  expect(await page.getByRole('tab').allInnerTexts()).toEqual(titles)
})

test('re-pinning after its old neighbours are gone still lands the pane in the layout', async ({
  page
}) => {
  await splitHorizontal(initialPane(page))
  const docked = dockedPanes(page)
  const liftedId = await docked.nth(1).getAttribute('data-dock-id')
  await unpin(headerOf(docked.nth(1)))
  await expect(docked).toHaveCount(2)

  // Demolish everything the anchor named: the sibling it split against is
  // replaced by a whole new pane.
  await closePane(docked.nth(1))
  await expect(docked).toHaveCount(2)

  await pin(headerOf(windowPane(floatingWindows(page).first())))

  await expect(floatingWindows(page)).toHaveCount(0)
  // Nothing was lost — the pane is somewhere in the docked layout again.
  await expect(dockedRoot(page).locator(`[data-dock-id="${liftedId}"]`)).toHaveCount(1)
})

test("dragging a floating window's header moves the window instead of docking it", async ({
  page
}) => {
  await splitHorizontal(initialPane(page))
  const docked = dockedPanes(page)
  await unpin(headerOf(docked.nth(1)))
  const win = floatingWindows(page).first()
  const before = await requireBox(win)

  const target = await requireBox(docked.nth(1))
  await grabAndHover(
    headerOf(windowPane(win)),
    target.x + target.width * 0.5,
    target.y + target.height * 0.5
  )

  // A window is moved, not docked: no dock preview, and no drag ghost either.
  await expect(page.getByTestId('dock-preview')).toHaveCount(0)
  await expect(page.locator('.drag-ghost')).toHaveCount(0)
  const during = await requireBox(win)
  expect(during.x).not.toBeCloseTo(before.x, 0)

  await page.mouse.up()
  await expect(docked).toHaveCount(2)
  const after = await requireBox(win)
  expect(after.x).toBeCloseTo(during.x, 0)
  expect(after.y).toBeCloseTo(during.y, 0)
})

test('escape cancels a floating-window move', async ({ page }) => {
  await splitHorizontal(initialPane(page))
  await unpin(headerOf(dockedPanes(page).nth(1)))
  const win = floatingWindows(page).first()
  const before = await requireBox(win)

  await grabAndHover(headerOf(windowPane(win)), before.x + 220, before.y + 160)
  expect((await requireBox(win)).x).not.toBeCloseTo(before.x, 0)

  await page.keyboard.press('Escape')
  await page.mouse.up()

  const after = await requireBox(win)
  expect(after.x).toBeCloseTo(before.x, 0)
  expect(after.y).toBeCloseTo(before.y, 0)
})

test('a floating-window move whose release the renderer never saw cancels instead of sticking', async ({
  page
}) => {
  await splitHorizontal(initialPane(page))
  await unpin(headerOf(dockedPanes(page).nth(1)))
  const win = floatingWindows(page).first()
  const before = await requireBox(win)

  await grabAndHover(headerOf(windowPane(win)), before.x + 220, before.y + 160)
  expect((await requireBox(win)).x).not.toBeCloseTo(before.x, 0)

  // The button came back up somewhere the host was never told about — native
  // chrome, outside the window. Nothing announces it; the only evidence is
  // the next move carrying no buttons (same mechanism the pane-drag spec
  // pins for dragController).
  await page.evaluate(() => {
    window.dispatchEvent(
      new PointerEvent('pointermove', {
        pointerId: 1,
        clientX: 40,
        clientY: 40,
        buttons: 0,
        bubbles: true
      })
    )
  })

  // Cancelled, not committed: the window is back where the gesture started.
  const after = await requireBox(win)
  expect(after.x).toBeCloseTo(before.x, 0)
  expect(after.y).toBeCloseTo(before.y, 0)
  await page.mouse.up()

  // And the gesture machinery is usable again — a stuck session would refuse
  // every later move for the life of the window.
  await moveWindowBy(headerOf(windowPane(win)), 120, 90)
  const moved = await requireBox(win)
  expect(moved.x).toBeCloseTo(before.x + 120, 0)
  expect(moved.y).toBeCloseTo(before.y + 90, 0)
})

test('a floating window resizes from its corner handle and never below the minimum', async ({
  page
}) => {
  await splitHorizontal(initialPane(page))
  await unpin(headerOf(dockedPanes(page).nth(1)))
  const win = floatingWindows(page).first()
  const origin = await requireBox(win)
  const handle = win.getByTestId('floating-resize-se')

  // Sized from its south-east corner to an absolute point, kept well inside
  // the viewport — a handle dragged off-screen would stop receiving moves.
  await dragTo(handle, origin.x + 400, origin.y + 300)
  const sized = await requireBox(win)
  expect(sized.width).toBeGreaterThan(380)
  expect(sized.width).toBeLessThan(430)
  expect(sized.height).toBeGreaterThan(280)
  expect(sized.height).toBeLessThan(330)

  // Then collapsed back past the floor: the minimum holds exactly.
  await dragTo(handle, origin.x + 10, origin.y + 10)
  const shrunk = await requireBox(win)
  expect(Math.round(shrunk.width)).toBe(MIN_FLOAT_SIZE.width)
  expect(Math.round(shrunk.height)).toBe(MIN_FLOAT_SIZE.height)
})

test('the last activated floating window paints over the others', async ({ page }) => {
  await splitHorizontal(initialPane(page))
  const docked = dockedPanes(page)
  const olderId = (await docked.nth(1).getAttribute('data-dock-id')) ?? ''
  await unpin(headerOf(docked.nth(1)))
  // The survivor is now the whole docked layout; float it too, so it starts
  // on top of the one unpinned before it.
  const newerId = (await docked.nth(1).getAttribute('data-dock-id')) ?? ''
  await unpin(headerOf(docked.nth(1)))
  await expect(floatingWindows(page)).toHaveCount(2)

  // Located by the pane each holds — DOM order is stable, not stack order.
  const older = windowHolding(page, olderId)
  const newer = windowHolding(page, newerId)
  const olderFloatId = await older.getAttribute('data-floating-id')
  const newerFloatId = await newer.getAttribute('data-floating-id')

  // Offset the frontmost one so the one behind stays individually reachable.
  await moveWindowBy(headerOf(windowPane(newer)), 160, 140)
  const moved = await requireBox(newer)

  const overlapX = moved.x + 20
  const overlapY = moved.y + 20
  expect(await frontmostAt(page, overlapX, overlapY)).toBe(newerFloatId)

  // Clicking the one behind, on a part of it still exposed, brings it forward.
  const olderBox = await requireBox(older)
  await page.mouse.click(olderBox.x + 20, olderBox.y + 8)
  expect(await frontmostAt(page, overlapX, overlapY)).toBe(olderFloatId)
})

test('a docked pane cannot be docked onto a floating window', async ({ page }) => {
  await splitHorizontal(initialPane(page))
  const docked = dockedPanes(page)
  await splitHorizontal(docked.nth(2))
  // Root's own wrapper (0), plus the three split leaves now beneath it.
  await expect(docked).toHaveCount(4)

  await unpin(headerOf(docked.nth(1)))
  await expect(docked).toHaveCount(3)
  const win = floatingWindows(page).first()
  const target = await requireBox(win)
  const idsBefore = await docked.evaluateAll((els) =>
    els.map((el) => (el as HTMLElement).dataset.dockId)
  )

  // Hover the middle of the floating window, and each of its edge bands.
  for (const [fx, fy] of [
    [0.5, 0.5],
    [0.08, 0.5],
    [0.5, 0.92]
  ]) {
    await grabAndHover(
      headerOf(docked.nth(2)),
      target.x + target.width * fx!,
      target.y + target.height * fy!
    )
    await expect(page.getByTestId('dock-preview')).toHaveCount(0)
    await expect(page.locator('.empty-pane-drop-target')).toHaveCount(0)
  }
  await page.mouse.up()

  await expect(floatingWindows(page)).toHaveCount(1)
  expect(
    await docked.evaluateAll((els) => els.map((el) => (el as HTMLElement).dataset.dockId))
  ).toEqual(idsBefore)
})

test('cmd+arrow inside a floating window stays inside it', async ({ page }) => {
  await splitHorizontal(initialPane(page))
  const docked = dockedPanes(page)
  await unpin(headerOf(docked.nth(1)))
  const win = floatingWindows(page).first()

  // Two panes inside the window, so there is somewhere to go within it.
  await splitHorizontal(windowPane(win))
  const inWindow = win.getByTestId('pane')
  await expect(inWindow).toHaveCount(2)

  await activatePane(inWindow.nth(0))
  await expect(inWindow.nth(0)).toHaveClass(/pane-active/)

  await page.keyboard.press(`${MOD_KEY}+ArrowRight`)
  await expect(inWindow.nth(1)).toHaveClass(/pane-active/)

  // Past the window's own edge it wraps within the window, never ejecting
  // into the docked layout behind it.
  await page.keyboard.press(`${MOD_KEY}+ArrowRight`)
  await expect(inWindow.nth(0)).toHaveClass(/pane-active/)
  await expect(docked.locator('.pane-active')).toHaveCount(0)
})

test('cmd+T opens a new tab inside the focused floating window, not in the docked layout', async ({
  page
}) => {
  await splitHorizontal(initialPane(page))
  const docked = dockedPanes(page)
  await unpin(headerOf(docked.nth(1)))
  const win = floatingWindows(page).first()
  await activatePane(windowPane(win))

  await fireShortcut(page, 'new-tab')

  await expect(win.getByRole('tablist')).toHaveCount(1)
  // Root's own wrapper still contributes its own tablist; the point is that
  // the new tab landed in the floating window's, not root's.
  await expect(dockedRoot(page).getByRole('tablist')).toHaveCount(1)
  await expect(docked).toHaveCount(2)
})

test('closing a floating window last pane removes the window', async ({ page }) => {
  await splitHorizontal(initialPane(page))
  const docked = dockedPanes(page)
  await unpin(headerOf(docked.nth(1)))
  const win = floatingWindows(page).first()

  await closePane(windowPane(win))

  await expect(floatingWindows(page)).toHaveCount(0)
  // The docked layout is untouched — a window has no slot to leave behind.
  await expect(docked).toHaveCount(2)
})

test('a whole tab group can be unpinned and re-pinned, tabs intact', async ({ page }) => {
  await splitHorizontal(initialPane(page))
  const docked = dockedPanes(page)
  await openNewTab(docked.nth(2))
  await openNewTab(docked.nth(2))
  // Root's own tablist, plus the new nested one just built.
  await expect(page.getByRole('tablist')).toHaveCount(2)
  await expect(page.getByRole('tablist').last().getByRole('tab')).toHaveCount(2)

  // The bar's grip is the group pane's own chrome, never a tab's.
  await unpin(headerOf(docked.nth(2)).locator('.pane-grip'))

  const win = floatingWindows(page).first()
  await expect(win.getByRole('tablist')).toHaveCount(1)
  await expect(win.getByRole('tab')).toHaveCount(2)
  // Root's own wrapper still contributes its own tablist.
  await expect(dockedRoot(page).getByRole('tablist')).toHaveCount(1)

  await pin(headerOf(windowPane(win)).locator('.pane-grip'))

  await expect(floatingWindows(page)).toHaveCount(0)
  // Root's own tablist, plus the re-pinned group's.
  await expect(dockedRoot(page).getByRole('tablist')).toHaveCount(2)
  await expect(dockedRoot(page).getByRole('tablist').last().getByRole('tab')).toHaveCount(2)
})

/**
 * Where a *new* unpinned pane spawns follows the newUnpinnedPanePosition
 * setting, so every test below states the position it is about rather than
 * inheriting one from DEFAULT_SETTINGS — a default flip has broken tests that
 * named the old value in their title before now (see CLAUDE.md). Note this
 * setting deliberately does not touch the unpin tests further up: unpinning an
 * existing pane still lifts it off in place.
 */
test('New Unpinned Pane opens a floating window over the top-right corner of the active pane, never docking it', async ({
  page
}) => {
  await emitSettingsChange(page, { newUnpinnedPanePosition: 'top-right' })
  const origin = await requireBox(initialPane(page))

  await fireShortcut(page, 'new-unpinned-pane')

  await expect(floatingWindows(page)).toHaveCount(1)
  // The docked layout never saw the new pane — it was created straight into
  // the floating list, not via a dock-then-unpin round trip. Root's own
  // wrapper plus the original active pane are all that's docked.
  await expect(dockedPanes(page)).toHaveCount(2)

  const win = await requireBox(floatingWindows(page).first())
  // Top-right corner of the window sits inset from the origin pane's own
  // top-right corner by the spawn spacing, on both axes.
  expect(win.y - origin.y).toBeCloseTo(NEW_PANE_SPAWN_SPACING, 0)
  expect(origin.x + origin.width - (win.x + win.width)).toBeCloseTo(NEW_PANE_SPAWN_SPACING, 0)
  // Sized to fit inside the pane it spawned next to.
  expect(win.width).toBeLessThanOrEqual(origin.width)
  expect(win.height).toBeLessThanOrEqual(origin.height)
})

test("the header dropdown's New Unpinned Tab opens a floating window at the same spawn point as the shortcut", async ({
  page
}) => {
  await emitSettingsChange(page, { newUnpinnedPanePosition: 'top-right' })
  const origin = await requireBox(initialPane(page))

  await openNewUnpinnedTab(initialPane(page))

  await expect(floatingWindows(page)).toHaveCount(1)
  await expect(dockedPanes(page)).toHaveCount(2)

  const win = await requireBox(floatingWindows(page).first())
  expect(win.y - origin.y).toBeCloseTo(NEW_PANE_SPAWN_SPACING, 0)
  expect(origin.x + origin.width - (win.x + win.width)).toBeCloseTo(NEW_PANE_SPAWN_SPACING, 0)
})

test('the position setting moves the spawn to the opposite corner, insets and all', async ({
  page
}) => {
  await emitSettingsChange(page, { newUnpinnedPanePosition: 'bottom-left' })
  const origin = await requireBox(initialPane(page))

  await fireShortcut(page, 'new-unpinned-pane')

  const win = await requireBox(floatingWindows(page).first())
  // Both axes flip: the leading edge is now the inset one horizontally, the
  // trailing edge vertically.
  expect(win.x - origin.x).toBeCloseTo(NEW_PANE_SPAWN_SPACING, 0)
  expect(origin.y + origin.height - (win.y + win.height)).toBeCloseTo(NEW_PANE_SPAWN_SPACING, 0)
})

test('a centered position leaves equal margins on both axes, not an inset corner', async ({
  page
}) => {
  await emitSettingsChange(page, { newUnpinnedPanePosition: 'middle-center' })
  const origin = await requireBox(initialPane(page))

  await fireShortcut(page, 'new-unpinned-pane')

  const win = await requireBox(floatingWindows(page).first())
  expect(win.x - origin.x).toBeCloseTo(origin.x + origin.width - (win.x + win.width), 0)
  expect(win.y - origin.y).toBeCloseTo(origin.y + origin.height - (win.y + win.height), 0)
  // Not merely symmetrical by accident of being in a corner.
  expect(win.x - origin.x).toBeGreaterThan(NEW_PANE_SPAWN_SPACING)
})
