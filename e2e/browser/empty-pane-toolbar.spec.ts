import { requireBox } from '../helpers/geometry'
import { expect, test } from './helpers/harness'

/**
 * The empty pane's content-type toolbar, measured. Geometry tier rather than
 * jsdom: every claim here is a real box or a real pixel, and the one that
 * matters most — that two neighbouring buttons share *one* hairline rather
 * than stacking two — has no meaning without layout. What the row offers and
 * what pressing a button does is jsdom's
 * (src/renderer/src/__tests__/empty-pane-toolbar.test.tsx).
 *
 * The default harness registers exactly one creation-capable content type, so
 * the multi-button cases opt into a second through `extraContentType` — see
 * testing/mountTestApp.tsx for why that is opt-in. Two stub types is this
 * file's own stated premise, not a count read off the real registry: the
 * shipping app's type list is not what these measurements are about.
 */

/** The row's buttons, left to right. */
function toolbarButtons(page: import('@playwright/test').Page) {
  return page.getByTestId('empty-pane-toolbar').locator('button')
}

test.describe('a row of two', () => {
  test.use({ extraContentType: true })

  test('every button is exactly 32x32', async ({ page }) => {
    const buttons = toolbarButtons(page)
    await expect(buttons).toHaveCount(2)

    for (let index = 0; index < 2; index++) {
      const box = await requireBox(buttons.nth(index))
      expect({ width: box.width, height: box.height }).toEqual({ width: 32, height: 32 })
    }
  })

  test('neighbours overlap by exactly one pixel, so their shared edge is one hairline', async ({
    page
  }) => {
    const buttons = toolbarButtons(page)
    const first = await requireBox(buttons.nth(0))
    const second = await requireBox(buttons.nth(1))

    // The negative margin, stated as the measurement it exists to produce:
    // the second button starts one pixel *before* the first one ends, so the
    // two 1px borders land in the same column instead of side by side.
    expect(Math.round(second.x)).toBe(Math.round(first.x + first.width) - 1)

    // ...and read as pixels, because "one hairline" is a claim about what is
    // painted, not about boxes. Sampled at the row's vertical middle, where a
    // centred 16px glyph inside a 32px button comes nowhere near either edge.
    const seam = Math.round(first.x + first.width) - 1
    const y = Math.round(first.y + first.height / 2)
    const pixel = (x: number) => page.screenshot({ clip: { x, y, width: 1, height: 1 } })

    const [insideFirst, onSeam, insideSecond] = await Promise.all([
      pixel(seam - 2),
      pixel(seam),
      pixel(seam + 1)
    ])

    // Border in the middle, button fill on both sides of it. Without the
    // negative margin `seam + 1` would be a second border column and this
    // would fail — which is what makes the assertion non-vacuous.
    expect(onSeam.equals(insideFirst)).toBe(false)
    expect(insideSecond.equals(insideFirst)).toBe(true)
  })

  test('only the outer corners are rounded', async ({ page }) => {
    const buttons = toolbarButtons(page)
    const corners = (index: number) =>
      buttons.nth(index).evaluate((el) => {
        const style = getComputedStyle(el)
        return {
          topLeft: style.borderTopLeftRadius,
          topRight: style.borderTopRightRadius,
          bottomLeft: style.borderBottomLeftRadius,
          bottomRight: style.borderBottomRightRadius
        }
      })

    // The leftmost button rounds only its left corners and the rightmost only
    // its right ones — so the pair's *inner* corners are square, which is the
    // same `border-radius: 0` base every button between them would take. A
    // third type would exercise no further rule.
    expect(await corners(0)).toEqual({
      topLeft: '5px',
      bottomLeft: '5px',
      topRight: '0px',
      bottomRight: '0px'
    })
    expect(await corners(1)).toEqual({
      topLeft: '0px',
      bottomLeft: '0px',
      topRight: '5px',
      bottomRight: '5px'
    })
  })
})

test('a lone button is rounded on both ends', async ({ page }) => {
  // No `extraContentType`: the default harness registers one creation-capable
  // type, which is also what a user who has turned every other type off sees.
  const buttons = toolbarButtons(page)
  await expect(buttons).toHaveCount(1)

  // Both `:first-child` and `:last-child` match it, so the single-type case
  // needs no rule of its own — this is what pins that.
  const radii = await buttons.evaluate((el) => {
    const style = getComputedStyle(el)
    return [
      style.borderTopLeftRadius,
      style.borderTopRightRadius,
      style.borderBottomRightRadius,
      style.borderBottomLeftRadius
    ]
  })
  expect(radii).toEqual(['5px', '5px', '5px', '5px'])

  const box = await requireBox(buttons)
  expect({ width: box.width, height: box.height }).toEqual({ width: 32, height: 32 })
})
