import type { ElectronApplication, Locator, Page } from '@playwright/test'
import { dataPage, navigateTo, openBrowser } from './helpers/browser'
import { type Box, requireBox } from './helpers/geometry'
import { guestEval, guestSnapshots, guestText } from './helpers/guest'
import { expect, test } from './helpers/launch'
import {
  activatePane,
  headerOf,
  initialPane,
  splitHorizontal,
  wrapInTabGroup
} from './helpers/pane'

const PAGE_A = dataPage('Page A')
const PAGE_B = dataPage('Page B')

/**
 * Waits until the pane's guest has actually committed its starting
 * about:blank, asked of the guest `WebContents` itself — a `<webview>` is a
 * separate WebContents and never a frame of the host page, so the renderer
 * has nothing to assert against (see CLAUDE.md).
 *
 * History behavior differs on either side of that commit: navigate first and
 * the blank page is replaced, navigate after and it becomes an entry of its
 * own. Settling here deliberately puts the test on the *slower* side, which
 * is the one a real user is always on and the one the old test silently
 * never exercised.
 */
async function settleOnBlank(app: ElectronApplication): Promise<void> {
  await expect
    .poll(async () =>
      (await guestSnapshots(app)).map((guest) => `${guest.url} loading=${guest.loading}`)
    )
    .toEqual(['about:blank loading=false'])
}

test('a new browser pane starts blank', async ({ page }) => {
  const pane = initialPane(page)
  await openBrowser(pane)

  await expect(headerOf(pane).getByTestId('browser-address-input')).toHaveValue('about:blank')
})

/**
 * The browser pane's stylesheet lives with its renderer
 * (src/plugins/browser/renderer/browser.css), not in global.css, so only a window that
 * renders browser panes loads it. `display` is the assertion worth making:
 * Electron's <webview> defaults to inline-flex, and the rule exists precisely
 * to override that, so `flex` cannot pass unless the stylesheet really
 * reached this window — unlike a property whose UA default already matches.
 *
 * The Settings window's half of this pairing is in settings.spec.ts. The nav
 * chrome (BrowserHeaderTitle) side-effect imports the same stylesheet, so its
 * own rendering already proves the css reached the window too — nothing
 * separate to assert about a toolbar bar, which no longer exists as its own
 * element (its geometry is .pane-header's now, covered generically there).
 */
test('the pane window loads the browser pane stylesheet', async ({ page }) => {
  const browser = await openBrowser(initialPane(page))

  await expect(browser.locator('.browser-webview')).toHaveCSS('display', 'flex')
})

/**
 * Back/Forward/Refresh are icon-only, so `aria-label` alone left them with
 * no visible hint at all. The coverage is Tooltip.tsx's own hover bubble —
 * ordinary page content this suite can see, where a bare `title` is native
 * chrome that CDP-driven automation cannot verify either way (and see
 * Tooltip.tsx for why it is unreliable here regardless). The same interaction
 * is covered against plain Chromium in e2e/browser/tooltip.spec.ts, but
 * BrowserRenderer needs a real `<webview>` and cannot render in that tier.
 *
 * Back starts disabled (nothing to go back to on a fresh pane) — exactly the
 * case where naming the button matters most, and not automatic: Tooltip.tsx's
 * hover listeners sit on a wrapper around the button, not on the disabled
 * button itself, so a disabled button's hover still reaching them is pinned
 * here too.
 */
test('the toolbar buttons carry a hover tooltip naming what they do, disabled or not', async ({
  page
}) => {
  const pane = initialPane(page)
  await openBrowser(pane)
  const header = headerOf(pane)
  const bubble = page.getByTestId('tooltip-bubble')

  const back = header.getByTestId('browser-back-button')
  await expect(back).toBeDisabled()
  await back.hover()
  await expect(bubble).toBeVisible()
  await expect(bubble).toHaveText('Back')

  await header.getByTestId('browser-forward-button').hover()
  await expect(bubble).toHaveText('Forward')

  await header.getByTestId('browser-refresh-button').hover()
  await expect(bubble).toHaveText('Refresh')
})

// The page title's own display moved with this pane's chrome: BrowserHeaderTitle
// replaces the header's whole title slot with nav chrome, so there's no
// `.pane-title` text left to show it any more for a plain (non-renamed) tab.
// setLiveTitle (see BrowserRenderer's onTitleUpdated) still updates the leaf's
// own `title`, and BrowserHeaderTitle now renders it into the address bar's
// own `.browser-title-segment` — but a Tab carries its own independent title
// (see Tab in shared/model/types.ts and tree.ts's renameTab), which
// setLiveTitle never touches, so a bare browser pane's page title still has
// no surface on the tab strip itself. These tests check navigation through
// the address bar's own value rather than the title segment, since a fresh
// `about:blank` pane has no title to show yet.

test('typing a URL and pressing Enter navigates', async ({ page }) => {
  const pane = initialPane(page)
  await openBrowser(pane)

  await navigateTo(pane, PAGE_A)

  await expect(headerOf(pane).getByTestId('browser-address-input')).toHaveValue(PAGE_A)
})

test('back/forward reflect navigation history', async ({ page, electronApp }) => {
  const pane = initialPane(page)
  await openBrowser(pane)
  const header = headerOf(pane)
  const address = header.getByTestId('browser-address-input')
  const back = header.getByTestId('browser-back-button')
  const forward = header.getByTestId('browser-forward-button')

  await expect(back).toBeDisabled()
  await expect(forward).toBeDisabled()

  await settleOnBlank(electronApp)
  await navigateTo(pane, PAGE_A)
  await expect(address).toHaveValue(PAGE_A)
  // The pane's own starting blank page is not somewhere the user asked to
  // be, so it's dropped rather than left as a back target — see the
  // clearHistory in BrowserRenderer, which is what makes this hold whether
  // or not the navigation beat that page's own commit.
  await expect(back).toBeDisabled()

  await navigateTo(pane, PAGE_B)
  await expect(address).toHaveValue(PAGE_B)
  await expect(back).toBeEnabled()
  await expect(forward).toBeDisabled()

  await back.click()
  await expect(address).toHaveValue(PAGE_A)
  await expect(forward).toBeEnabled()
})

test("the address bar's title segment shows the page's live title", async ({ page }) => {
  const pane = initialPane(page)
  await openBrowser(pane)
  const header = headerOf(pane)

  await navigateTo(pane, PAGE_A)

  const titleSegment = header.getByTestId('browser-title-segment')
  await expect(titleSegment).toHaveText('Page A')
  await expect(titleSegment).toHaveAttribute('title', 'Page A')
})

test('the title segment paints a different shade than the address input', async ({ page }) => {
  const pane = initialPane(page)
  await openBrowser(pane)
  const header = headerOf(pane)

  await navigateTo(pane, PAGE_A)

  const titleBackground = await header
    .getByTestId('browser-title-segment')
    .evaluate((el) => getComputedStyle(el).backgroundColor)
  const inputBackground = await header
    .getByTestId('browser-address-input')
    .evaluate((el) => getComputedStyle(el).backgroundColor)
  expect(titleBackground).not.toBe(inputBackground)
})

const LONG_TITLE_PAGE = dataPage(
  'This Is An Extremely Long Page Title That Should Never Fit Inside Thirty Percent Of The Address Bar'
)

test('a long page title is capped at 30% of the address bar and keeps its full text for hover', async ({
  page
}) => {
  const pane = initialPane(page)
  await openBrowser(pane)
  const header = headerOf(pane)

  await navigateTo(pane, LONG_TITLE_PAGE)

  const titleSegment = header.getByTestId('browser-title-segment')
  await expect(titleSegment).toHaveAttribute(
    'title',
    'This Is An Extremely Long Page Title That Should Never Fit Inside Thirty Percent Of The Address Bar'
  )
  await expect(titleSegment).toHaveCSS('text-overflow', 'ellipsis')

  const barBox = await requireBox(header.getByTestId('browser-address-bar'))
  const segmentBox = await requireBox(titleSegment)
  // max-width:30% resolves against the bar's own content box (its border-box
  // minus the 1px border it draws on each side), so allow a couple of pixels
  // of slack rather than pinning an exact fraction.
  expect(segmentBox.width).toBeLessThanOrEqual(barBox.width * 0.3 + 2)
  // Confirms the cap is actually doing something — this title, untruncated,
  // would be several times wider than 30% of the bar.
  expect(segmentBox.width).toBeGreaterThan(barBox.width * 0.2)
})

// Non-URL-input → search-engine-query resolution is pure logic, covered by
// addressInput.test.ts — exercising it here would mean actually letting the
// webview hit a real network address, which this suite avoids entirely.

/**
 * A page taller than any pane, so a wheel gesture has somewhere to go, with a
 * field parked at a known offset so a click can be aimed at it without asking
 * the guest where it is.
 */
const SCROLLABLE_PAGE = dataPage(
  'Scrollable',
  '<style>body{margin:0}#field{position:absolute;left:0;top:0;width:240px;height:48px}</style>' +
    '<input id="field"><div id="status">idle</div><div style="height:4000px">tall</div>' +
    '<script>document.getElementById("field").addEventListener("input", (event) => {' +
    'document.getElementById("status").textContent = "typed:" + event.target.value })</script>'
)

/**
 * Splits the root pane, puts a browser on the scrollable page in the right
 * half, then leaves the *left* pane active — the starting state for every
 * "does interacting with a background browser pane activate it" test below.
 * Returns both panes and the guest's viewport rect in host coordinates.
 */
async function browserPaneInBackground(
  page: Page,
  app: ElectronApplication
): Promise<{ panes: Locator; content: Box }> {
  await splitHorizontal(initialPane(page))
  const panes = page.getByTestId('pane')
  // Root's own wrapper is permanently pane 0 (see ensureTabsRoot in tree.ts);
  // the split it just made is panes 1 (left) and 2 (right).
  const pane = panes.nth(2)
  const browser = await openBrowser(pane)
  await navigateTo(pane, SCROLLABLE_PAGE)
  // Asked of the guest rather than of the pane header, so the wait is on the
  // page really being there rather than on a title round-trip.
  await expect.poll(() => guestEval(app, 'document.title')).toBe('Scrollable')

  await activatePane(panes.nth(1))
  await expect(panes.nth(1)).toHaveClass(/pane-active/)

  // `browser` (data-testid="browser") is itself .browser-content now — the
  // pane body renders nothing else, since the nav chrome moved to the header.
  const content = await requireBox(browser)
  return { panes, content }
}

/**
 * The gap this closes: a press inside a `<webview>` guest produces no host DOM
 * event at all, so `Pane`'s own onClick is unreachable from a guest and the
 * only way in used to be the pane header or the arrow keys. The press is
 * observed on the guest's input pipeline in main instead — see
 * src/plugins/browser/main/guestActivation.ts.
 *
 * Electron tier because the guest *is* the subject: no other tier has one, and
 * Playwright cannot reach into it (a guest is never a frame of the host page).
 * The renderer's half of the same path — which pane a forwarded press
 * activates, and the injection suppression — is jsdom
 * (src/renderer/src/__tests__/guest-activation.test.tsx).
 */
test('clicking inside an inactive browser pane page makes it the active pane', async ({
  page,
  electronApp
}) => {
  const { panes, content } = await browserPaneInBackground(page, electronApp)

  await page.mouse.click(content.x + content.width / 2, content.y + content.height / 2)

  await expect(panes.nth(2)).toHaveClass(/pane-active/)
  await expect(panes.nth(1)).not.toHaveClass(/pane-active/)
})

/**
 * The other half of the contract, and the reason activation keys off
 * `mouseDown` rather than any press-like signal: a background macOS window can
 * be scrolled without coming forward, and a wheel/trackpad gesture provably
 * never produces a `mouseDown` (it produces mouseWheel + gestureScroll*).
 *
 * Asserting the guest actually scrolled is what keeps the negative assertion
 * from passing vacuously — a wheel that went nowhere would "not activate" too.
 */
test('scrolling a background browser pane scrolls its page without activating it', async ({
  page,
  electronApp
}) => {
  const { panes, content } = await browserPaneInBackground(page, electronApp)

  await page.mouse.move(content.x + content.width / 2, content.y + content.height / 2)
  await page.mouse.wheel(0, 400)

  await expect.poll(() => guestEval<number>(electronApp, 'window.scrollY')).toBeGreaterThan(100)
  await expect(panes.nth(1)).toHaveClass(/pane-active/)
  await expect(panes.nth(2)).not.toHaveClass(/pane-active/)
})

/**
 * Activation must not eat the click that caused it. Becoming active runs
 * core's focus-follows-active, which calls the browser pane handle's `focus()`
 * → `webview.focus()`; if that disturbed the guest's own activeElement, the
 * field the user just clicked would silently stop receiving their typing.
 */
test('the click that activates a browser pane still lands in its page', async ({
  page,
  electronApp
}) => {
  const { panes, content } = await browserPaneInBackground(page, electronApp)

  // The field is positioned at the guest viewport's top-left, so this needs no
  // round-trip to find it.
  await page.mouse.click(content.x + 60, content.y + 24)
  await expect(panes.nth(2)).toHaveClass(/pane-active/)

  await page.keyboard.type('hello')
  await expect.poll(() => guestText(electronApp, '#status')).toBe('typed:hello')
})

/**
 * The one that would have caught the defect the three above missed.
 *
 * They only exercise a pane's *first* guest, so whether the pane → guest
 * mapping survives a **second** one depended on where in a file they ran and
 * how loaded the machine was: `getWebContentsId()` is not readable at
 * `did-attach` (see BrowserRenderer's reportGuest), so the report was lost for
 * every guest but the first in a window, and the tests above passed only when
 * contention delayed the attach enough to hide it. Wrapping the pane in a tab
 * group forces a real structural reparent — the guest `WebContents` is
 * destroyed and a new one with a new id is built under the same element — so
 * this reaches the second guest deterministically, in one test, whatever else
 * has run.
 *
 * Everything keyed on that mapping rides on this, not just activation:
 * read-network-requests, popup ownership and the will-navigate allowlist all
 * resolve a pane through it.
 */
test('click-to-activate survives the guest being rebuilt by a reparent', async ({
  page,
  electronApp
}) => {
  const { panes, content } = await browserPaneInBackground(page, electronApp)

  // Sanity: the first guest works, so a failure below is about the second.
  await page.mouse.click(content.x + content.width / 2, content.y + content.height / 2)
  await expect(panes.nth(2)).toHaveClass(/pane-active/)

  const guestIdsNow = async (): Promise<number[]> =>
    (await guestSnapshots(electronApp)).map((guest) => guest.id)
  const before = await guestIdsNow()

  await wrapInTabGroup(panes.nth(2))
  // The rebuild is what the rest of this test is about, so wait for it by
  // identity rather than by a timeout — and prove it really happened.
  await expect.poll(guestIdsNow).not.toEqual(before)
  await expect.poll(() => guestEval(electronApp, 'document.title')).toBe('Scrollable')

  // Itself .browser-content now — see the comment on browserPaneInBackground.
  const rebuilt = page.getByTestId('browser')
  const box = await requireBox(rebuilt)

  // The left split pane (panes.nth(1) — root's own wrapper permanently
  // occupies nth(0)), untouched by the wrap above, is what "somewhere else"
  // means here.
  await activatePane(panes.nth(1))
  await expect(panes.nth(1)).toHaveClass(/pane-active/)

  await page.mouse.click(box.x + box.width / 2, box.y + box.height / 2)
  await expect(panes.nth(1)).not.toHaveClass(/pane-active/)
})
