import type { Page } from '@playwright/test'
import { dragSeparatorToX, dragSeparatorX } from '../helpers/drag'
import { requireBox } from '../helpers/geometry'
import {
  activatePane,
  headerOf,
  initialPane,
  openNewTab,
  splitHorizontal,
  splitVertical
} from '../helpers/pane'
import { emitSettingsChange, expect, test } from './helpers/harness'

// Ported from the Electron tier: separator dragging is real-geometry behavior
// (react-resizable-panels hit targets, sub-pixel snap outcomes) with nothing
// Electron in it. The pure snap math is unit-tested in
// src/shared/model/__tests__/separatorSnap.test.ts; these assert the
// integration against a real layout engine. The snap setting is driven
// through the fake bridge instead of a Settings window — the cross-window
// settings round-trip is settings.spec.ts's subject.

/** Drags the split's first separator sideways by `dx`. */
function dragSeparator(page: Page, dx: number): Promise<void> {
  return dragSeparatorX(page.locator('.split-separator').first(), dx)
}

/** The `data-separator` attribute of whatever currently holds DOM focus, if any. */
function focusedSeparatorAttr(page: Page): Promise<string | null> {
  return page.evaluate(() => document.activeElement?.getAttribute('data-separator') ?? null)
}

test('dragging a separator leaves keyboard focus where it was', async ({ page }) => {
  await splitHorizontal(initialPane(page))
  const panes = page.getByTestId('pane')
  // Root's own wrapper (0), plus the split's two children.
  await expect(panes).toHaveCount(3)
  const widthBefore = (await requireBox(panes.nth(1))).width

  await dragSeparator(page, 80)

  // The resize really happened, so the focus assertion below can't pass vacuously.
  expect((await requireBox(panes.nth(1))).width).toBeGreaterThan(widthBefore + 40)
  expect(await focusedSeparatorAttr(page)).toBeNull()
})

test('resizing a split inside a tab group keeps the active pane active', async ({ page }) => {
  // Root's own wrapper is already the tab group, starting with one tab, so
  // one more call reaches two.
  await openNewTab(initialPane(page))
  const panes = page.getByTestId('pane')
  // Split tab 2's content; pane order: root's wrapper, tab 1 content, then
  // the split's two.
  await splitHorizontal(panes.nth(2))
  await expect(panes).toHaveCount(4)

  await activatePane(panes.nth(2))
  await expect(panes.nth(2)).toHaveClass(/pane-active/)

  await dragSeparator(page, 60)

  // The click ending the drag must not bubble out to the tab group's own
  // pane (root's own wrapper).
  await expect(panes.nth(2)).toHaveClass(/pane-active/)
  await expect(panes.nth(0)).not.toHaveClass(/pane-active/)
  expect(await focusedSeparatorAttr(page)).toBeNull()
})

test('a resize starting near a pane header does not also start a pane drag', async ({ page }) => {
  await splitHorizontal(initialPane(page))
  const panes = page.getByTestId('pane')
  // Root's own wrapper (0), plus the split's two children.
  await expect(panes).toHaveCount(3)
  const widthBefore = (await requireBox(panes.nth(1))).width

  const separatorBox = await requireBox(page.locator('.split-separator').first())
  const headerBox = await requireBox(headerOf(panes.nth(2)))
  // The separator has 0 rendered width by design (see global.css), but
  // react-resizable-panels still pads a real hit target around it, so 2px
  // into pane 1's header is inside that hit region: the same pointerdown
  // can be claimed by both the resize and, without the fix, pane 1's own
  // drag handle.
  const x = separatorBox.x + separatorBox.width + 2
  const y = headerBox.y + headerBox.height / 2

  await page.mouse.move(x, y)
  await page.mouse.down()
  await page.mouse.move(x + 60, y, { steps: 10 })
  // Still mid-gesture: a pane drag would already have shown its ghost.
  await expect(page.locator('.drag-ghost')).toHaveCount(0)
  await page.mouse.up()

  // The resize really happened, so the no-pane-drag assertion above can't pass vacuously.
  expect((await requireBox(panes.nth(1))).width).toBeGreaterThan(widthBefore + 20)
  await expect(panes).toHaveCount(3)
})

test('a plain click right at a split boundary still activates the pane it lands on', async ({
  page
}) => {
  await splitHorizontal(initialPane(page))
  const panes = page.getByTestId('pane')
  // Root's own wrapper (0), plus the split's two children.
  await expect(panes).toHaveCount(3)
  await activatePane(panes.nth(1))
  await expect(panes.nth(1)).toHaveClass(/pane-active/)

  const separatorBox = await requireBox(page.locator('.split-separator').first())
  const headerBox = await requireBox(headerOf(panes.nth(2)))
  const x = separatorBox.x + separatorBox.width + 2
  const y = headerBox.y + headerBox.height / 2

  // No movement at all: a real click, not a resize, so it must not be
  // mistaken for one and swallowed by the isSplitResizing guard.
  await page.mouse.move(x, y)
  await page.mouse.down()
  await page.mouse.up()

  await expect(panes.nth(2)).toHaveClass(/pane-active/)
  await expect(panes.nth(1)).not.toHaveClass(/pane-active/)
})

/**
 * A 2x2 grid with a real separator directly between the bottom-left and
 * bottom-right panes (and another directly between top-left and top-right):
 * root split vertical (rows stacked), each row itself a horizontal split
 * (columns side by side). `.split-separator` ends up in DOM order [top row's
 * (vertical line), root's own (horizontal line), bottom row's (vertical
 * line)] — indices 0 and 2 are the two we care about.
 */
async function build2x2Grid(page: Page) {
  await splitVertical(initialPane(page))
  const panes = page.getByTestId('pane')
  // Root's own wrapper (0), plus the top/bottom split.
  await expect(panes).toHaveCount(3)
  await splitHorizontal(panes.nth(1))
  await expect(panes).toHaveCount(4)
  await splitHorizontal(panes.nth(3))
  await expect(panes).toHaveCount(5)

  const separators = page.locator('.split-separator')
  await expect(separators).toHaveCount(3)
  return separators
}

test('dragging a separator snaps to another aligned separator when the setting is enabled', async ({
  page
}) => {
  await emitSettingsChange(page, { snapResizeSeparators: true })

  const separators = await build2x2Grid(page)
  const topRowSeparator = separators.nth(0)
  const bottomRowSeparator = separators.nth(2)
  const topBox = await requireBox(topRowSeparator)

  // Move the bottom row's separator well away from alignment first — proves
  // free dragging still works normally under the setting when nothing is
  // close enough to snap to.
  await dragSeparatorToX(bottomRowSeparator, topBox.x + 120)
  const movedBox = await requireBox(bottomRowSeparator)
  expect(Math.abs(movedBox.x - topBox.x)).toBeGreaterThan(50)

  // Then drag it back to within a few px of the top row's separator.
  await dragSeparatorToX(bottomRowSeparator, topBox.x + 3)
  const finalBox = await requireBox(bottomRowSeparator)
  expect(Math.abs(finalBox.x - topBox.x)).toBeLessThan(1.5)
})

test('the same drag does not snap when the setting is off', async ({ page }) => {
  // Set explicitly rather than relying on the default, which ships as `true`
  // (4451d4d) — this test's subject is the off behavior, not what the default
  // happens to be.
  await emitSettingsChange(page, { snapResizeSeparators: false })
  const separators = await build2x2Grid(page)
  const topRowSeparator = separators.nth(0)
  const bottomRowSeparator = separators.nth(2)
  const topBox = await requireBox(topRowSeparator)

  await dragSeparatorToX(bottomRowSeparator, topBox.x + 120)
  await dragSeparatorToX(bottomRowSeparator, topBox.x + 3)

  const finalBox = await requireBox(bottomRowSeparator)
  // The drag really moved it close to the target (proves this is "didn't
  // snap", not "didn't drag"), but the setting is off, so it must not have
  // locked exactly onto the top row's separator.
  expect(Math.abs(finalBox.x - topBox.x)).toBeLessThan(6)
  expect(Math.abs(finalBox.x - topBox.x)).toBeGreaterThan(1.5)
})
