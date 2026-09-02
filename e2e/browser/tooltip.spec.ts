import { PANE_BUTTON } from '../../src/shared/paneDomAttrs'
import { requireBox } from '../helpers/geometry'
import { headerOf, initialPane, openNewTab } from '../helpers/pane'
import { expect, test } from './helpers/harness'

/**
 * Real hover-and-see-the-bubble coverage for Tooltip.tsx — the replacement
 * for a bare `title` attribute (see its own comment: macOS Electron 38+
 * shows a `title` tooltip on the first hover only, rarely afterward,
 * electron/electron#49843). Unlike the native tooltip it replaces, this one
 * is ordinary page content, so a real browser engine can actually prove it
 * renders — not just that a `title` attribute exists in the DOM (that half
 * is already covered structurally in the `components` tier and is not
 * repeated here). This lives in the Chromium tier rather than jsdom
 * specifically because jsdom has no real layout engine: `getBoundingClientRect`
 * always returns zeros there, so the positioning and clipping-escape this
 * component exists for cannot be exercised at all.
 */

const bubble = (page: import('@playwright/test').Page) => page.getByTestId('tooltip-bubble')

test('hovering a pane-header action shows its tooltip, and moving away hides it', async ({
  page
}) => {
  const header = headerOf(initialPane(page))
  const splitHorizontal = header.getByTestId(PANE_BUTTON.splitHorizontal)

  await expect(bubble(page)).toHaveCount(0)

  // force: true — the group's dropdown opens flush over its own root button
  // (real, synchronous CSS :hover; see PaneHeaderMenuGroup's comment), so
  // Playwright's own "is the target itself receiving this" pre-check can
  // never pass here, the same reason pane-header-menu.spec.ts needs it.
  await splitHorizontal.hover({ force: true })
  await expect(bubble(page)).toBeVisible()
  await expect(bubble(page)).toHaveText('Split horizontally')
  await expect(bubble(page)).toHaveCSS('opacity', '1')

  // Moving off the button (not just releasing the mouse) is what should
  // hide it — mousemove to a point well clear of the whole header.
  await page.mouse.move(10, 400)
  await expect(bubble(page)).toHaveCount(0)
})

test('hovering a grouped root button hands off to its own tooltip once the dropdown covers it', async ({
  page
}) => {
  // PaneHeaderMenuGroup opens its dropdown flush over the root button via
  // real, synchronous CSS :hover (see its own comment) — so the element
  // under the cursor changes the instant the group is hovered, from the
  // root button to the dropdown's own copy of it. Tooltip.tsx's comment
  // documents that this is expected to "just work": the new element starts
  // its own hover timer. This is the exact case from the bug report ("the
  // little menus that show up with icons only" showed no tooltip at all).
  const header = headerOf(initialPane(page))
  const splitHorizontal = header.getByTestId(PANE_BUTTON.splitHorizontal)

  // force: true — see the previous test's comment.
  await splitHorizontal.hover({ force: true })
  await expect(bubble(page)).toBeVisible()
  await expect(bubble(page)).toHaveText('Split horizontally')

  // A different row of the now-open dropdown — moving onto it should swap
  // the tooltip to that row's own label.
  await header.getByTestId(PANE_BUTTON.splitVertical).hover()
  await expect(bubble(page)).toHaveText('Split vertically')
})

test("a tab strip's own buttons show a tooltip that isn't clipped by the strip's overflow", async ({
  page
}) => {
  // .tab-strip is `overflow-x: auto`, which computes `overflow-y` to `auto`
  // too (see global.css) — a tooltip positioned as a normal descendant
  // trying to open above/below a 24px-tall strip would be clipped away
  // entirely. Tooltip.tsx portals to document.body specifically so this
  // can't happen. The "+" button sits directly inside .tab-strip, unlike
  // the pane-header actions above.
  const strip = await requireBox(page.locator('.tab-strip').first())

  await page.getByTestId('tab-strip-new-tab-button').hover()
  await expect(bubble(page)).toBeVisible()
  await expect(bubble(page)).toHaveText('New tab')
  await expect(bubble(page)).toHaveCSS('opacity', '1')

  const box = await requireBox(bubble(page))
  // Structural proof the portal actually escaped the clip, not just that
  // *something* is nominally "visible": the bubble renders below the whole
  // strip rather than being squeezed inside its own 24px box.
  expect(box.y).toBeGreaterThanOrEqual(strip.y + strip.height)
})

test("a tab's close button shows a tooltip naming what it closes, also unclipped", async ({
  page
}) => {
  await openNewTab(initialPane(page))

  const tabs = page.getByRole('tab')
  await expect(tabs).toHaveCount(2)
  const secondTab = tabs.nth(1)
  const title = (await secondTab.locator('.tab-title').textContent()) ?? ''
  expect(title).not.toBe('')

  const strip = await requireBox(page.locator('.tab-strip').first())

  await secondTab.locator('.tab-close').hover()
  await expect(bubble(page)).toBeVisible()
  await expect(bubble(page)).toHaveText(`Close ${title}`)

  const box = await requireBox(bubble(page))
  expect(box.y).toBeGreaterThanOrEqual(strip.y + strip.height)
})

test('keyboard focus shows the tooltip too, not just mouse hover', async ({ page }) => {
  const header = headerOf(initialPane(page))
  const closeButton = header.getByTestId(PANE_BUTTON.close)

  await closeButton.focus()
  await expect(bubble(page)).toBeVisible()
  await expect(bubble(page)).toHaveText('Close pane')

  await closeButton.blur()
  await expect(bubble(page)).toHaveCount(0)
})
