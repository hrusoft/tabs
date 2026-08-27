import { DARK_THEME, LIGHT_THEME, type Theme } from '../../src/shared/theme'
import { expect, test } from './helpers/harness'

/**
 * The tier that proves the tokens actually reach paint. The jsdom tests assert
 * that installTheme writes the custom properties; only a real layout engine
 * can say whether global.css's rules then resolve to them — a token renamed on
 * one side of that boundary would leave every jsdom assertion green.
 *
 * This is also where the `system` alias is exercised, because Playwright's
 * `emulateMedia` drives `prefers-color-scheme` natively in Chromium, which is
 * exactly the signal installTheme resolves through.
 */

/** '#1e1f24' → 'rgb(30, 31, 36)', the form getComputedStyle reports. */
function rgb(hex: string): string {
  const value = Number.parseInt(hex.slice(1), 16)
  return `rgb(${(value >> 16) & 255}, ${(value >> 8) & 255}, ${value & 255})`
}

/**
 * Computed colors come back in two different serializations and have to be
 * compared numerically: a legacy `rgba()` for a plain literal, but
 * `color(srgb 0.309804 0.54902 1 / 0.16)` for anything `color-mix` produced.
 * Same color, different spelling — a string comparison would call them
 * different.
 */
function parseColor(value: string): [number, number, number, number] {
  const srgb = value.match(/^color\(srgb ([\d.]+) ([\d.]+) ([\d.]+)(?: \/ ([\d.]+))?\)$/)
  if (srgb) {
    return [
      Number(srgb[1]) * 255,
      Number(srgb[2]) * 255,
      Number(srgb[3]) * 255,
      srgb[4] === undefined ? 1 : Number(srgb[4])
    ]
  }
  const rgba = value.match(/^rgba?\((\d+),\s*(\d+),\s*(\d+)(?:,\s*([\d.]+))?\)$/)
  if (!rgba) throw new Error(`unrecognized color: ${value}`)
  return [
    Number(rgba[1]),
    Number(rgba[2]),
    Number(rgba[3]),
    rgba[4] === undefined ? 1 : Number(rgba[4])
  ]
}

function expectSameColor(actual: string, expected: string): void {
  const [ar, ag, ab, aa] = parseColor(actual)
  const [er, eg, eb, ea] = parseColor(expected)
  expect(ar).toBeCloseTo(er, 0)
  expect(ag).toBeCloseTo(eg, 0)
  expect(ab).toBeCloseTo(eb, 0)
  expect(aa).toBeCloseTo(ea, 2)
}

function background(page: import('@playwright/test').Page, selector: string): Promise<string> {
  return page
    .locator(selector)
    .first()
    .evaluate((el) => getComputedStyle(el).backgroundColor)
}

/**
 * The surfaces that between them cover both token roles: content and chrome.
 * The root tab bar (.tab-bar-root) is the chrome surface now that the main
 * window's root is always a tab group — it's a depth-0 pane like any other,
 * so it paints in `--bg`, not `--bg-elevated` (see the depth-striping
 * comment on `.pane` in global.css); there's no longer a piece of main-window
 * chrome that's unconditionally elevated the way the old separate window
 * header was.
 */
async function expectPainted(page: import('@playwright/test').Page, theme: Theme): Promise<void> {
  await expect(page.locator('html')).toHaveAttribute('data-theme', theme.id)
  expect(await background(page, '.tab-bar-root')).toBe(rgb(theme.tokens['--bg']))
  await expect(page.locator('body')).toHaveCSS('background-color', rgb(theme.tokens['--bg']))
}

test.describe('dark', () => {
  test.use({ seed: { settings: { colorTheme: 'dark' } } })

  test('paints the dark tokens', async ({ page }) => {
    await expectPainted(page, DARK_THEME)
  })

  // The tokenization refactor's regression guard: these rules used to carry
  // literal rgba() values, and the -rgb/color-mix forms that replaced them are
  // easy to get subtly wrong (an invalid declaration is dropped silently, and
  // the rule just renders with no background at all).
  test('derived tints still resolve to the values they replaced', async ({ page }) => {
    const derived = await page.evaluate(() => {
      const probe = document.createElement('div')
      probe.style.background = 'rgb(var(--hover-rgb) / 0.12)'
      probe.style.color = 'color-mix(in srgb, var(--accent) 16%, transparent)'
      document.body.appendChild(probe)
      const style = getComputedStyle(probe)
      const result = { background: style.backgroundColor, color: style.color }
      probe.remove()
      return result
    })
    // The exact literals these two forms replaced in global.css.
    expectSameColor(derived.background, 'rgba(255, 255, 255, 0.12)')
    expectSameColor(derived.color, 'rgba(79, 140, 255, 0.16)')
  })
})

test.describe('light', () => {
  test.use({ seed: { settings: { colorTheme: 'light' } } })

  test('paints the light tokens instead', async ({ page }) => {
    await expectPainted(page, LIGHT_THEME)
  })

  test('is genuinely a different palette from dark', async ({ page }) => {
    // Guards the failure mode where the theme is "applied" but every token
    // happens to resolve to the fallback.
    expect(await background(page, '.tab-bar-root')).not.toBe(rgb(DARK_THEME.tokens['--bg']))
  })
})

test.describe('system', () => {
  test.use({ seed: { settings: { colorTheme: 'system' } } })

  test('resolves from the OS preference and tracks it changing while running', async ({ page }) => {
    await page.emulateMedia({ colorScheme: 'dark' })
    await expectPainted(page, DARK_THEME)

    // The ticket's live-tracking requirement: no reload in between.
    await page.emulateMedia({ colorScheme: 'light' })
    await expectPainted(page, LIGHT_THEME)

    await page.emulateMedia({ colorScheme: 'dark' })
    await expectPainted(page, DARK_THEME)
  })
})

test.describe('an explicit theme', () => {
  test.use({ seed: { settings: { colorTheme: 'light' } } })

  test('ignores the OS preference entirely', async ({ page }) => {
    await page.emulateMedia({ colorScheme: 'dark' })
    await expectPainted(page, LIGHT_THEME)
  })
})
