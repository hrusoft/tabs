import type { LayoutSnapshot } from '../../src/shared/layout'
import { LAYOUT_VERSION } from '../../src/shared/layout'
import type { LeafContent, Tab, TabsContent } from '../../src/shared/model/types'
import { PANE_BUTTON } from '../../src/shared/paneDomAttrs'
import { requireBox } from '../helpers/geometry'
import { expect, test } from './helpers/harness'

/**
 * The chrome's depth striping, on the four-deep nesting it was designed
 * against. Geometry tier rather than jsdom: every claim here is a computed
 * style or a hit test, and three of them (the indent step, the active tab's
 * one-pixel overhang, what sits at the seam) have no meaning without real
 * layout.
 *
 * `stub` is the test tiers' stand-in content type — registerTestContent.ts.
 * The builders are typed against the real model shapes so the seed
 * typechecks like any other LayoutSnapshot — no cast anywhere.
 */
function leaf(id: string, title: string): LeafContent {
  return { id, type: 'stub', config: {}, title, titleIsManual: true }
}

function group(id: string, tabs: Tab[]): TabsContent {
  return { id, type: 'tabs', tabs, activeTabId: tabs[0]!.id }
}

const LAYOUT: LayoutSnapshot = {
  version: LAYOUT_VERSION,
  root: group('g0', [
    {
      id: 't0',
      title: 'Work',
      content: group('g1', [
        {
          id: 't1',
          title: 'tabs-app',
          content: group('g2', [
            {
              id: 't2',
              title: 'api',
              content: group('g3', [
                { id: 't3', title: 'server', content: leaf('l0', 'nick@Mac ~/tabs/api') },
                { id: 't3b', title: 'tests', content: leaf('l1', 'tests') }
              ])
            },
            { id: 't2b', title: 'web', content: leaf('l2', 'web') },
            { id: 't2c', title: 'db', content: leaf('l3', 'db') }
          ])
        },
        { id: 't1b', title: 'dotfiles', content: leaf('l4', 'dotfiles') },
        { id: 't1c', title: 'notes', content: leaf('l5', 'notes') }
      ])
    },
    { id: 't0b', title: 'Personal', content: leaf('l6', 'personal') },
    { id: 't0c', title: 'Client', content: leaf('l7', 'client') }
  ]),
  activePaneId: 'l0'
}

test.use({ seed: { layout: LAYOUT } })

function backgroundOf(page: import('@playwright/test').Locator): Promise<string> {
  return page.evaluate((el) => getComputedStyle(el).backgroundColor)
}

/** `--accent` resolved to the `rgb(...)` form computed colors come back in, so it can be compared against them directly. */
async function accentRgbOf(page: import('@playwright/test').Page): Promise<string> {
  const resolved = await page.evaluate(() => {
    const probe = document.createElement('span')
    probe.style.color = getComputedStyle(document.documentElement).getPropertyValue('--accent')
    document.body.append(probe)
    const color = getComputedStyle(probe).color
    probe.remove()
    return color
  })
  expect(resolved).not.toBe('')
  return resolved
}

/**
 * The painted color at one viewport pixel, as `rgb(r, g, b)` — for asserting
 * a pixel against a resolved token (see accentRgbOf) rather than against
 * another pixel, which is what the `Buffer.equals` comparisons elsewhere in
 * this file do when a known-good reference pixel is available.
 */
async function pixelColorAt(
  page: import('@playwright/test').Page,
  x: number,
  y: number
): Promise<string> {
  const buf = await page.screenshot({ clip: { x, y, width: 1, height: 1 } })
  return page.evaluate(
    async (src) => {
      const img = new Image()
      img.src = src
      await img.decode()
      const canvas = document.createElement('canvas')
      canvas.width = 1
      canvas.height = 1
      const ctx = canvas.getContext('2d')!
      ctx.drawImage(img, 0, 0)
      const [r, g, b] = ctx.getImageData(0, 0, 1, 1).data
      return `rgb(${r}, ${g}, ${b})`
    },
    `data:image/png;base64,${buf.toString('base64')}`
  )
}

test('nested tab bars alternate the two chrome surfaces and step their indent', async ({
  page
}) => {
  const bars = page.locator('.tab-bar')
  await expect(bars).toHaveCount(4)

  const shades: string[] = []
  const indents: string[] = []
  for (let depth = 0; depth < 4; depth++) {
    shades.push(await backgroundOf(bars.nth(depth)))
    indents.push(await bars.nth(depth).evaluate((el) => getComputedStyle(el).paddingLeft))
  }

  // Two surfaces, alternating — not a gradient that deepens without bound,
  // which is what lets an arbitrarily nested layout reuse the two chrome
  // colors a theme already declares.
  expect(shades[0]).toBe(shades[2])
  expect(shades[1]).toBe(shades[3])
  expect(shades[0]).not.toBe(shades[1])

  // Bar 0 is g0, this layout's docked root, whose bar doubles as the window's
  // title bar — its indent is the fixed traffic-light gutter
  // (.tab-bar-root), not the depth formula. Every nested bar below it still
  // steps by 7px per depth.
  expect(indents[0]).toBe('108px')
  expect(indents.slice(1)).toEqual(['14px', '21px', '28px'])
})

test('a leaf pane title bar is the last rung of the same ladder', async ({ page }) => {
  // Four tab groups enclose it, so it stripes and indents one step past the
  // deepest bar rather than restarting at its own pane's left edge.
  const header = page.getByTestId('pane-header').first()
  expect(await header.evaluate((el) => getComputedStyle(el).paddingLeft)).toBe('35px')
  expect(await backgroundOf(header)).toBe(await backgroundOf(page.locator('.tab-bar').nth(0)))
})

test('the active tab is painted in the shade of the level it reveals', async ({ page }) => {
  const bars = page.locator('.tab-bar')
  for (let depth = 0; depth < 3; depth++) {
    expect(await backgroundOf(bars.nth(depth).locator('.tab-active'))).toBe(
      await backgroundOf(bars.nth(depth + 1))
    )
  }
})

/**
 * The strip's one-pixel overhang (see `.tab-strip` in global.css) is a fixed
 * geometric fact of every bar, independent of what it reveals — checked once
 * here and taken for granted below.
 */
async function seamOverhangHolds(
  bar: import('@playwright/test').Locator
): Promise<{ seamY: number; probeX: number; pastX: number }> {
  const tab = bar.locator('.tab-active')
  const barBox = (await bar.boundingBox()) ?? { x: 0, y: 0, width: 0, height: 0 }
  const tabBox = (await tab.boundingBox()) ?? { x: 0, y: 0, width: 0, height: 0 }
  expect(Math.round(tabBox.y + tabBox.height)).toBe(Math.round(barBox.y + barBox.height) + 1)
  return {
    seamY: Math.round(barBox.y + barBox.height),
    probeX: Math.round(tabBox.x) + 3,
    pastX: Math.round(barBox.x + barBox.width) - 4
  }
}

test('the active tab covers its own seam into a nested tabs-group, but a real border-top shows beside it', async ({
  page
}) => {
  // Bar 1 (g1) reveals g2, another tabs-group nested directly inside it (no
  // split in between) — per TabsRenderer's unconditional suppression, g2 draws a
  // border-top of its own (`.pane-suppress-left/-right/-bottom` suppress the
  // other three) regardless of depth. The
  // active tab's own z-index+background still cover that border for exactly
  // its own width (the overhang mechanic every bar shares), so directly
  // under it the fill still reads as one continuous surface with no seam —
  // but past the tabs, in the bar's own empty space, the border-top is real
  // and visible, not swallowed the way a fully suppressed pane's would be.
  const bar = page.locator('.tab-bar').nth(1)
  const { seamY, probeX, pastX } = await seamOverhangHolds(bar)
  const pixel = (x: number, y: number) => page.screenshot({ clip: { x, y, width: 1, height: 1 } })

  const underTab = await pixel(probeX, seamY)
  const insideTab = await pixel(probeX, seamY - 4)
  const pastTabs = await pixel(pastX, seamY)
  const pastTabsBelow = await pixel(pastX, seamY + 4)

  // Directly under the active tab, the merge still holds.
  expect(underTab.equals(insideTab)).toBe(true)
  // Past the tabs, the border-top row is real: distinct from both the active
  // tab's own fill and from the plain surface a few pixels below it.
  expect(pastTabs.equals(insideTab)).toBe(false)
  expect(pastTabs.equals(pastTabsBelow)).toBe(false)

  // And it's specifically a border, not some unrelated color — g2's own
  // computed border-top color is the same neutral `--border` every other
  // pane's border uses, not the accent or a surface shade.
  const g2BorderColor = await page
    .locator('.tab-bar')
    .nth(2)
    .evaluate((el) => getComputedStyle(el.closest('.pane') as Element).borderTopColor)
  const rootBorderColor = await page
    .getByTestId('pane')
    .first()
    .evaluate((el) => getComputedStyle(el).borderTopColor)
  expect(g2BorderColor).toBe(rootBorderColor)
})

test('the active tab covers its own seam into a nested leaf just the same, not only a nested tabs-group', async ({
  page
}) => {
  // Bar 3 (g3) reveals a real leaf (l0), not another tabs-group — and it
  // behaves exactly like bar 1 revealing g2 above: a leaf at the bottom of a
  // nested-tabs chain is exactly as eligible for its own border-top as an
  // intermediate tabs-group is, regardless of depth (see TabsRenderer's
  // ContentView call). Left/right/bottom still suppress unconditionally
  // — that's the doubling risk measured in "a shallow sibling reads exactly
  // two pixels away from a deeply nested leaf" below — but the top side never
  // had that risk at any depth.
  const bar = page.locator('.tab-bar').nth(3)
  const { seamY, probeX, pastX } = await seamOverhangHolds(bar)
  const pixel = (x: number, y: number) => page.screenshot({ clip: { x, y, width: 1, height: 1 } })

  const underTab = await pixel(probeX, seamY)
  const insideTab = await pixel(probeX, seamY - 4)
  const pastTabs = await pixel(pastX, seamY)
  const pastTabsBelow = await pixel(pastX, seamY + 4)

  expect(underTab.equals(insideTab)).toBe(true)
  expect(pastTabs.equals(insideTab)).toBe(false)
  expect(pastTabs.equals(pastTabsBelow)).toBe(false)
})

test('a bar hover menu opens over every tab bar below it', async ({ page }) => {
  // The menus hang well past their own bar and across the nested bars below.
  // Anything that gives `.tab-bar` a stacking context traps its menu at the
  // bar's own level, and the next bar down — at the same level, later in the
  // DOM — paints over it: the menu looks half-hidden, and moving toward a
  // lower item lands the cursor on that bar instead, dropping the `:hover`
  // that keeps the menu open, so the lower items can't be clicked at all.
  // Bar 0 is g0, this layout's docked root: its own root menu button is New
  // tab, not Split horizontally (PaneHeaderControls.tsx's isDockedRoot
  // branch) — the stacking-context hazard this test guards is generic to any
  // bar's hover menu, so the button id is the only thing that changes here.
  const bar = page.locator('.tab-bar').nth(0)
  await bar.getByTestId(PANE_BUTTON.newTab).hover({ force: true })
  const menu = bar.locator('.pane-header-dropdown').first()
  await expect(menu).toBeVisible()
  // Opacity is transitioned, and Chromium keeps a not-yet-painted element out
  // of hit testing — see the note on openPaneMenuItem in e2e/helpers/pane.ts.
  await page.waitForTimeout(150)

  const menuBox = (await menu.boundingBox()) ?? { x: 0, y: 0, width: 0, height: 0 }
  const barBox = (await bar.boundingBox()) ?? { x: 0, y: 0, width: 0, height: 0 }
  // Non-vacuous only if the menu really does reach past its own bar.
  expect(menuBox.y + menuBox.height).toBeGreaterThan(barBox.y + barBox.height)

  const onMenu = await page.evaluate(
    ([x, y]) => document.elementFromPoint(x!, y!)?.closest('.pane-header-dropdown') !== null,
    [menuBox.x + menuBox.width / 2, menuBox.y + menuBox.height - 6]
  )
  expect(onMenu).toBe(true)
})

test('the active pane is outlined around its content, not around its title bar', async ({
  page
}) => {
  const accentRgb = await accentRgbOf(page)

  // The outline overlay, and where it starts: below the pane's chrome bar,
  // and pulled out over the pane's own border on the other three sides so it
  // replaces that hairline rather than adding a second one beside it.
  const active = page.locator('.pane-active').last()
  const outline = await active.evaluate((el) => {
    const after = getComputedStyle(el, '::after')
    return {
      color: after.borderTopColor,
      width: after.borderTopWidth,
      top: after.top,
      left: after.left
    }
  })
  expect(outline).toEqual({
    color: accentRgb,
    width: '1px',
    // Exactly --chrome-bottom (24): the outline and the chrome bar above it
    // are both measured from the same padding edge, so no compensation for
    // the pane's own border-top is needed — see `.pane-active::after`'s
    // comment.
    top: '24px',
    left: '-1px'
  })

  // Nothing on the pane itself or its title bar turns accent, so the bar is
  // free to merge upward into the active tab that revealed it.
  const chrome = await active.evaluate((el) => {
    const header = el.querySelector('.pane-header')
    const style = header && getComputedStyle(header)
    return {
      paneBorder: getComputedStyle(el).borderTopColor,
      headerBorder: style?.borderBottomColor,
      headerFill: style?.backgroundColor
    }
  })
  expect(chrome.paneBorder).not.toBe(accentRgb)
  expect(chrome.headerBorder).not.toBe(accentRgb)
  expect(chrome.headerFill).not.toBe(accentRgb)

  // ...and no chrome anywhere is filled with the accent either.
  const fills = await page
    .locator('.tab-bar, .pane-header')
    .evaluateAll((els) => els.map((el) => getComputedStyle(el).backgroundColor))
  expect(fills).not.toContain(accentRgb)
})

test('activating a pane does not move or resize its content box', async ({ page }) => {
  // Why the marker is an overlay and not a thicker `border-left`: a 1px to
  // 2px border would shrink the content box on every activation, which a
  // terminal pane answers by refitting and SIGWINCHing its pty.
  const pane = page.locator('.pane').nth(2)
  const body = pane.locator('> .pane-body')
  await expect(pane).not.toHaveClass(/pane-active/)
  const before = await body.boundingBox()

  // Empty bar to the right of this group's tabs, left of its hover controls.
  await page
    .locator('.tab-bar')
    .nth(2)
    .click({ position: { x: 380, y: 10 } })

  await expect(pane).toHaveClass(/pane-active/)
  expect(await body.boundingBox()).toEqual(before)
})

/**
 * A split, to pin the one measurement that has no home in the nested-tabs
 * layout above: how much line sits between two panes. The active pane's
 * outline is an overlay, so it is one edit away from stacking *beside* the
 * pane's own border instead of over it — which widens every seam next to the
 * active pane from 2px to 3px and reads, from across the room, as the split
 * having drifted apart rather than as a border bug.
 */
test.describe('two panes side by side', () => {
  test.use({
    seed: {
      layout: {
        version: LAYOUT_VERSION,
        root: {
          id: 's0',
          type: 'split',
          direction: 'horizontal',
          sizes: [0.5, 0.5],
          children: [leaf('a', 'A'), leaf('b', 'B')]
        },
        activePaneId: 'b'
      }
    }
  })

  test('are separated by exactly two pixels, active or not', async ({ page }) => {
    const panes = page.getByTestId('pane')
    // The split isn't itself a valid docked root (ensureTabsRoot in tree.ts),
    // so it's auto-wrapped in a synthetic single-tab root group — pane 0 is
    // that wrapper, panes 1 and 2 are the two leaves it wraps.
    await expect(panes).toHaveCount(3)
    await expect(panes.nth(2)).toHaveClass(/pane-active/)

    const left = (await panes.nth(1).boundingBox()) ?? { x: 0, y: 0, width: 0, height: 0 }
    // Well below both title bars, in content both panes paint identically.
    const y = Math.round(left.y + left.height - 20)
    const edge = Math.round(left.x + left.width)
    const pixel = (x: number) => page.screenshot({ clip: { x, y, width: 1, height: 1 } })

    const [leftContent, leftBorder, rightBorder, rightContent] = await Promise.all([
      pixel(edge - 3),
      pixel(edge - 1),
      pixel(edge),
      pixel(edge + 1)
    ])

    // Exactly two pixels of chrome: the inactive pane's own border, then the
    // active pane's outline standing in for its border rather than joining it.
    expect(leftContent.equals(rightContent)).toBe(true)
    expect(leftBorder.equals(leftContent)).toBe(false)
    expect(rightBorder.equals(rightContent)).toBe(false)
    expect(leftBorder.equals(rightBorder)).toBe(false)
  })
})

/**
 * The bug report this pins: splitting a tab's sole pane must not shift its
 * surviving content. Before the fix, a split's children always fell back to
 * a full border regardless of what the split itself received (see
 * ContentRendererProps.suppressBorderLeft/Right/Bottom and SplitRenderer's
 * childEdgeProps), so the surviving pane suddenly drew a border on
 * the three sides that used to sit flush against its tabs-group's own —
 * visibly nudging its content inward the instant a sibling appeared.
 */
test.describe('splitting a lone tab pane', () => {
  test.use({
    seed: {
      layout: {
        version: LAYOUT_VERSION,
        root: group('g0', [
          {
            id: 't0',
            title: 'Solo',
            content: {
              id: 's0',
              type: 'split',
              direction: 'horizontal',
              sizes: [0.5, 0.5],
              children: [leaf('l0', 'Solo'), leaf('l1', 'New')]
            }
          }
        ]),
        activePaneId: 'l0'
      }
    }
  })

  test('the surviving pane keeps only the seam it shares with its new sibling', async ({
    page
  }) => {
    const panes = page.getByTestId('pane')
    // pane 0 is g0 itself — a real single-tab root, not the synthetic
    // wrapper "two panes side by side" above needs (its root is a raw split,
    // which isn't a valid docked root on its own). Panes 1 and 2 are the
    // split's two leaves.
    await expect(panes).toHaveCount(3)

    const borders = await panes.evaluateAll((els) =>
      els.map((el) => {
        const s = getComputedStyle(el)
        return {
          left: s.borderLeftWidth,
          right: s.borderRightWidth,
          bottom: s.borderBottomWidth,
          top: s.borderTopWidth
        }
      })
    )

    expect(borders[0]).toEqual({ left: '1px', right: '1px', bottom: '1px', top: '1px' })
    // The surviving pane (l0): no border on the three sides that sit flush
    // against g0's own — only the seam shared with its new sibling is real.
    expect(borders[1]).toEqual({ left: '0px', right: '1px', bottom: '0px', top: '1px' })
    // The new pane (l1) is the mirror image.
    expect(borders[2]).toEqual({ left: '1px', right: '0px', bottom: '0px', top: '1px' })
  })

  test("the surviving pane's content starts exactly where a lone tab's would", async ({ page }) => {
    // Flush against g0's own 1px border on the left — the same position a
    // lone, unsplit tab pane's content sits at (border-box, no padding
    // anywhere in the .tabs-view chain). The bug moved this to x: 2.
    const body = page.locator('.pane-body').nth(1)
    const box = await body.boundingBox()
    expect(box?.x).toBe(1)
  })

  /**
   * The follow-up bug report from the fix above: suppressing a split child's
   * border on a side now means its active-pane overlay (`.pane-active::after`)
   * bleeds 1px past its own box on that side, same as it always has for a
   * plain tab-content leaf — but that bleed now has to cross two more DOM
   * layers on its way to the real ancestor border (react-resizable-panels'
   * own Group/Panel elements) than the plain-leaf case ever did. Both set
   * their own inline `overflow` (`hidden` on the Group, `auto` on the
   * Panel's inner div — see SplitRenderer.tsx's SPLIT_CLIP_STYLE), which a
   * stylesheet rule can't override: before that fix, the Group's `hidden`
   * silently clipped the bleed away on whichever side it reached first, and
   * the Panel's `auto` turned it into a real, visible scrollbar on the
   * active pane.
   */
  test("the active pane's outline survives the split wrapper instead of scrolling or clipping it away", async ({
    page
  }) => {
    const overflow = await page.evaluate(() => ({
      splitPane: getComputedStyle(document.querySelector('.split-pane')!).overflow,
      splitView: getComputedStyle(document.querySelector('.split-view')!).overflow
    }))
    // 'clip' never shows a scrollbar regardless of content extent — unlike
    // 'auto', which react-resizable-panels sets by default and which turned
    // this pane's own outline bleed into a real scrollbar.
    expect(overflow).toEqual({ splitPane: 'clip', splitView: 'clip' })

    const accentRgb = await accentRgbOf(page)

    const active = page.getByTestId('pane').nth(1)
    const box = await requireBox(active)
    const midY = Math.round(box.y + box.height / 2)
    const pixelColor = (x: number, y: number) => pixelColorAt(page, x, y)

    // Suppressed left side: the overlay bleeds 1px past this pane's own box,
    // onto g0's real border — it must actually render there, not be clipped
    // or scrolled out of view.
    expect(await pixelColor(Math.round(box.x) - 1, midY)).toBe(accentRgb)
    // Suppressed bottom side, same idea.
    const midX = Math.round(box.x + box.width / 2)
    expect(await pixelColor(midX, Math.round(box.y + box.height))).toBe(accentRgb)
    // Kept right side (the real seam with the sibling) still renders too —
    // this one never needed to bleed past the pane's own box.
    expect(await pixelColor(Math.round(box.x + box.width) - 1, midY)).toBe(accentRgb)
  })
})

/**
 * The bug report this whole rule exists to fix: a shallow leaf split-adjacent
 * to a leaf three tabs-groups deep. Only g1 (the split child) draws a full
 * border on all four sides — g2, g3 and the leaf at the bottom all suppress
 * left/right/bottom as nested tab content, even though the leaf is a leaf and
 * not a tabs-group. A version of the rule that suppressed only tabs-groups
 * left that leaf's own border stacking directly against g1's, one pixel
 * away, and doubled this exact seam to ~4px while "two panes side by side"
 * above kept measuring a clean 2px for two plain, unnested leaves — the split
 * between the two tests is what let the bug ship unnoticed. (Top is a
 * separate story — see the two "covers its own seam" tests above — and isn't
 * this seam's concern: this test measures the left/right divider, well below
 * any header.)
 */
test.describe('a shallow sibling beside a leaf three tabs-groups deep', () => {
  test.use({
    seed: {
      layout: {
        version: LAYOUT_VERSION,
        root: {
          id: 's0',
          type: 'split',
          direction: 'horizontal',
          sizes: [0.5, 0.5],
          children: [
            leaf('shallow', 'Shallow'),
            group('g1', [
              {
                id: 't1',
                title: 'one',
                content: group('g2', [
                  {
                    id: 't2',
                    title: 'two',
                    content: group('g3', [
                      { id: 't3', title: 'three', content: leaf('deep', 'Deep') }
                    ])
                  }
                ])
              }
            ])
          ]
        },
        activePaneId: 'deep'
      }
    }
  })

  test('reads exactly two pixels away, same as two plain siblings', async ({ page }) => {
    const panes = page.getByTestId('pane')
    // Same DOM-order convention as "two panes side by side": pane 0 is the
    // synthetic root wrapper, pane 1 the shallow leaf, panes 2-4 are
    // g1/g2/g3, pane 5 is the deep leaf.
    await expect(panes).toHaveCount(6)
    await expect(panes.last()).toHaveClass(/pane-active/)

    const left = (await panes.nth(1).boundingBox()) ?? { x: 0, y: 0, width: 0, height: 0 }
    // Computed from the shallow pane alone, same as the plain-siblings test —
    // it spans this split's full height regardless of how many header rows
    // stack on the other side.
    const y = Math.round(left.y + left.height - 20)
    const edge = Math.round(left.x + left.width)
    const pixel = (x: number) => page.screenshot({ clip: { x, y, width: 1, height: 1 } })

    // The bug this pins landed the deep leaf's own redundant border exactly
    // one pixel past g1's, so a fix that only half-worked (suppressing
    // tabs-groups but not leaves) would still show border color at edge+1
    // here rather than content — that's the specific pixel "two panes side
    // by side" never needed to check, because neither of its leaves is
    // nested behind anything.
    const [leftContent, leftBorder, rightBorder, rightContent] = await Promise.all([
      pixel(edge - 3),
      pixel(edge - 1),
      pixel(edge),
      pixel(edge + 1)
    ])

    // Neither pane is active where the seam actually is — activePaneId
    // points at the deep leaf, several levels inside g1's own box, not at
    // g1 or the shallow pane — so both border samples are the same plain
    // neutral color here (unlike "two panes side by side", which activates
    // the pane touching the seam specifically to prove the accent overlay
    // doesn't add width; that's already covered there and isn't this test's
    // claim).
    expect(leftContent.equals(rightContent)).toBe(true)
    expect(leftBorder.equals(leftContent)).toBe(false)
    expect(rightBorder.equals(rightContent)).toBe(false)
  })
})

/**
 * The bug this pins: an active leaf reached as a tab's sole content sits
 * pixel-flush against its own tabs-group's `.pane-body` on three sides (no
 * padding anywhere in the .tabs-view chain — only the top differs, offset
 * down by the tab strip). That ancestor body's `overflow: hidden` clipped the
 * outline's deliberate 1px bleed (see `.pane-active::after`'s comment) on
 * exactly those three sides, leaving only the never-bled top edge visible —
 * "the highlight border should appear on all four sides but only renders on
 * the top side." Filler panes surround the tabs-group on every side so the
 * sampled edges are internal split seams, never the viewport's own edge
 * (which a 1x1 `clip` screenshot can't safely straddle).
 */
test.describe('an active leaf nested one tabs-group deep beside a split', () => {
  test.use({
    seed: {
      layout: {
        version: LAYOUT_VERSION,
        root: {
          id: 's0',
          type: 'split',
          direction: 'horizontal',
          sizes: [0.3, 0.5, 0.2],
          children: [
            leaf('shallow', 'Shallow'),
            {
              id: 's1',
              type: 'split',
              direction: 'vertical',
              sizes: [0.7, 0.3],
              children: [
                group('g1', [{ id: 't1', title: 'deep', content: leaf('deep', 'Deep') }]),
                leaf('bottomFiller', 'Bottom filler')
              ]
            },
            leaf('rightFiller', 'Right filler')
          ]
        },
        activePaneId: 'deep'
      }
    }
  })

  test('outlines all four sides, not just the one under its tab bar', async ({ page }) => {
    const active = page.locator('.pane-active').last()
    await expect(active).toBeVisible()

    const box = (await active.boundingBox()) ?? { x: 0, y: 0, width: 0, height: 0 }
    const pixel = (x: number, y: number) => page.screenshot({ clip: { x, y, width: 1, height: 1 } })

    // The top edge is a positive inset (never bled past the box), so per the
    // bug report it already renders correctly — use it as the known-good
    // reference color for "this is the accent outline." +25, not
    // +--chrome-bottom (24): box.y is the pane's own border edge, and the
    // outline's top border row sits one pixel past that (the pane's own 1px
    // border-top) plus --chrome-bottom.
    const midX = Math.round(box.x + box.width / 2)
    const midY = Math.round(box.y + box.height / 2)
    const topAccent = await pixel(midX, Math.round(box.y) + 25)

    const [leftBleed, rightBleed, bottomBleed] = await Promise.all([
      pixel(Math.round(box.x) - 1, midY),
      pixel(Math.round(box.x + box.width), midY),
      pixel(midX, Math.round(box.y + box.height))
    ])

    expect(leftBleed.equals(topAccent)).toBe(true)
    expect(rightBleed.equals(topAccent)).toBe(true)
    expect(bottomBleed.equals(topAccent)).toBe(true)
  })
})

/**
 * --pane-corner-radius-left/-right's split half (global.css's "--- Splits
 * ---" section): the bug report this exists to fix was a visibly square
 * corner on whichever pane a horizontal or vertical split put at the
 * window's real bottom edge, even though a lone pane filling the whole
 * window rounded correctly. --os-corner-radius is 0 in this tier (the fake
 * bridge has no real OS window to measure), so it's overridden to a
 * distinguishable value before checking — otherwise "correctly inherited 0"
 * and "incorrectly reset to 0" would look identical.
 */
test.describe('corner radius through a split', () => {
  test.beforeEach(async ({ page }) => {
    await page.evaluate(() => {
      document.documentElement.style.setProperty('--os-corner-radius', '20px')
    })
  })

  test.describe('horizontal (side by side)', () => {
    test.use({
      seed: {
        layout: {
          version: LAYOUT_VERSION,
          root: {
            id: 's0',
            type: 'split',
            direction: 'horizontal',
            sizes: [0.5, 0.5],
            children: [leaf('a', 'A'), leaf('b', 'B')]
          },
          activePaneId: 'b'
        }
      }
    })

    test('the left child owns only the bottom-left corner, the right child only the bottom-right', async ({
      page
    }) => {
      const panes = page.getByTestId('pane')
      // pane 0 is the synthetic single-tab root wrapper (ensureTabsRoot) —
      // not itself a split child. Panes 1 and 2 are the split's two leaves,
      // in document order (left, then right).
      await expect(panes).toHaveCount(3)

      const corners = await panes.evaluateAll((els) =>
        els.map((el) => {
          const style = getComputedStyle(el)
          return [style.borderBottomLeftRadius, style.borderBottomRightRadius]
        })
      )
      expect(corners[1]).toEqual(['20px', '0px'])
      expect(corners[2]).toEqual(['0px', '20px'])
    })
  })

  test.describe('vertical (stacked)', () => {
    test.use({
      seed: {
        layout: {
          version: LAYOUT_VERSION,
          root: {
            id: 's0',
            type: 'split',
            direction: 'vertical',
            sizes: [0.5, 0.5],
            children: [leaf('top', 'Top'), leaf('bottom', 'Bottom')]
          },
          activePaneId: 'bottom'
        }
      }
    })

    test('the top child owns neither bottom corner, the bottom child owns both', async ({
      page
    }) => {
      const panes = page.getByTestId('pane')
      await expect(panes).toHaveCount(3)

      const corners = await panes.evaluateAll((els) =>
        els.map((el) => {
          const style = getComputedStyle(el)
          return [style.borderBottomLeftRadius, style.borderBottomRightRadius]
        })
      )
      expect(corners[1]).toEqual(['0px', '0px'])
      expect(corners[2]).toEqual(['20px', '20px'])
    })
  })

  /**
   * The bug report this generalized to a prop (rather than leaving it a CSS
   * selector/inheritance problem): one pane filling the left column, the
   * right column split top/bottom. Nothing between the outer horizontal
   * split and the inner vertical one is ever a `.pane` (a split contributes
   * none of its own), so a value with no way to be *reset* along that path
   * rode the outer split's right-side inherit all the way down and landed
   * on both of the bottom-right pane's corners instead of just its own.
   */
  test.describe('an L shape (one pane left, the right column split top/bottom)', () => {
    test.use({
      seed: {
        layout: {
          version: LAYOUT_VERSION,
          root: {
            id: 's0',
            type: 'split',
            direction: 'horizontal',
            sizes: [0.5, 0.5],
            children: [
              leaf('left', 'Left'),
              {
                id: 's1',
                type: 'split',
                direction: 'vertical',
                sizes: [0.5, 0.5],
                children: [leaf('topRight', 'Top right'), leaf('bottomRight', 'Bottom right')]
              }
            ]
          },
          activePaneId: 'bottomRight'
        }
      }
    })

    test('only the bottom-right pane owns the bottom-right corner, and only it — never both', async ({
      page
    }) => {
      // getByTestId('pane') matches every .pane in the tree in DOM order:
      // the synthetic root wrapper, then 'left', then s1's 'topRight' and
      // 'bottomRight' (the inner split is nested inside the outer split's
      // second child, so its own two leaves come last).
      const panes = page.getByTestId('pane')
      await expect(panes).toHaveCount(4)

      const corners = await panes.evaluateAll((els) =>
        els.map((el) => {
          const style = getComputedStyle(el)
          return [style.borderBottomLeftRadius, style.borderBottomRightRadius]
        })
      )
      expect(corners[1]).toEqual(['20px', '0px']) // left
      expect(corners[2]).toEqual(['0px', '0px']) // topRight
      expect(corners[3]).toEqual(['0px', '20px']) // bottomRight — the bug report
    })
  })
})
