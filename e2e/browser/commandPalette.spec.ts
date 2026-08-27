import { requireBox } from '../helpers/geometry'
import { emitSettingsChange, expect, fireShortcut, test } from './helpers/harness'

/**
 * The Cmd+P command palette, measured — real viewport coverage, real
 * stacking above a floating window, real mouse hover/click. What each item
 * shows, keyboard nav mechanics and the empty-state message are jsdom's
 * (src/renderer/src/__tests__/commandPalette.test.tsx); driving it from
 * inside a real `<webview>` guest needs Electron and stays in
 * e2e/commandPalette.spec.ts.
 *
 * The default harness registers exactly one creation-capable content type;
 * the hover/highlight test opts into a second through `extraContentType`
 * (see empty-pane-toolbar.spec.ts for the same pattern) so there is a second
 * item to hover past the first.
 */

function palette(page: import('@playwright/test').Page) {
  return page.getByTestId('command-palette')
}

test('opens with a backdrop covering the full viewport', async ({ page }) => {
  const viewport = page.viewportSize()
  if (!viewport) throw new Error('no viewport')

  await fireShortcut(page, 'command-palette')

  const backdrop = await requireBox(page.getByTestId('command-palette-backdrop'))
  expect(Math.round(backdrop.x)).toBe(0)
  expect(Math.round(backdrop.y)).toBe(0)
  expect(Math.round(backdrop.width)).toBe(viewport.width)
  expect(Math.round(backdrop.height)).toBe(viewport.height)
})

test('the panel is centered in the viewport', async ({ page }) => {
  const viewport = page.viewportSize()
  if (!viewport) throw new Error('no viewport')

  await fireShortcut(page, 'command-palette')

  const panel = await requireBox(palette(page))
  expect(panel.x + panel.width / 2).toBeCloseTo(viewport.width / 2, 0)
  expect(panel.y + panel.height / 2).toBeCloseTo(viewport.height / 2, 0)
})

test('renders above a floating window', async ({ page }) => {
  await emitSettingsChange(page, { newUnpinnedPanePosition: 'middle-center' })
  await fireShortcut(page, 'new-unpinned-pane')
  await expect(page.getByTestId('floating-window')).toHaveCount(1)

  await fireShortcut(page, 'command-palette')

  const panel = await requireBox(palette(page))
  const center = { x: panel.x + panel.width / 2, y: panel.y + panel.height / 2 }
  // Real hit-testing at a point the floating window (centered, same as the
  // palette) also occupies — the palette must be what's actually on top.
  const onTop = await page.evaluate(
    ([px, py]) => document.elementFromPoint(px!, py!)?.closest('.command-palette') !== null,
    [center.x, center.y]
  )
  expect(onTop).toBe(true)
})

test.describe('a row of two content types', () => {
  test.use({ extraContentType: true })

  test('hovering the second item highlights it, and clicking it advances the step', async ({
    page
  }) => {
    await fireShortcut(page, 'command-palette')
    const items = palette(page).locator('.command-palette-item')
    await expect(items).toHaveCount(2)
    await expect(items.nth(0)).toHaveClass(/command-palette-item-highlighted/)

    await items.nth(1).hover()
    await expect(items.nth(1)).toHaveClass(/command-palette-item-highlighted/)
    await expect(items.nth(0)).not.toHaveClass(/command-palette-item-highlighted/)

    await items.nth(1).click()

    // Advanced to the placement step: its four items replace the two
    // content-type ones.
    await expect(palette(page).getByTestId('command-palette-item-new-tab')).toBeVisible()
  })
})

test('clicking through both steps creates and places the content in real layout', async ({
  page
}) => {
  await expect(page.getByTestId('empty-pane')).toBeVisible()

  await fireShortcut(page, 'command-palette')
  await palette(page).getByTestId('command-palette-item-pane-new-stub-button').click()
  await palette(page).getByTestId('command-palette-item-split-horizontal').click()

  // A split, not an in-place fill: two panes now sit side by side.
  await expect(page.getByTestId('pane')).toHaveCount(3)
  await expect(page.getByTestId('command-palette-backdrop')).toHaveCount(0)
})
