import type { ElectronApplication, Locator, Page } from '@playwright/test'
import { dataPage, navigateTo, openBrowser } from './helpers/browser'
import { type Box, requireBox } from './helpers/geometry'
import { guestEval, guestSnapshots, guestText } from './helpers/guest'
import { expect, test } from './helpers/launch'
import { activatePane, initialPane, splitHorizontal, wrapInTabGroup } from './helpers/pane'

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
  const browser = await openBrowser(initialPane(page))

  await expect(browser.getByTestId('browser-address-input')).toHaveValue('about:blank')
})

/**
 * The browser pane's stylesheet lives with its renderer
 * (src/plugins/browser/renderer/browser.css), not in global.css, so only a window that
 * renders browser panes loads it. `display` is the assertion worth making:
 * Electron's <webview> defaults to inline-flex, and the rule exists precisely
 * to override that, so `flex` cannot pass unless the stylesheet really
 * reached this window — unlike a property whose UA default already matches.
 *
 * The Settings window's half of this pairing is in settings.spec.ts.
 */
test('the pane window loads the browser pane stylesheet', async ({ page }) => {
  const browser = await openBrowser(initialPane(page))

  await expect(browser.locator('.browser-webview')).toHaveCSS('display', 'flex')
  await expect(browser.locator('.browser-toolbar')).toHaveCSS('height', '28px')
})

test('typing a URL and pressing Enter navigates, and the page title updates the pane header', async ({
  page
}) => {
  const header = page.getByTestId('pane-header')
  const browser = await openBrowser(initialPane(page))

  await navigateTo(browser, PAGE_A)

  await expect(header).toContainText('Page A')
  await expect(browser.getByTestId('browser-address-input')).toHaveValue(PAGE_A)
})

test('back/forward reflect navigation history', async ({ page, electronApp }) => {
  const header = page.getByTestId('pane-header')
  const browser = await openBrowser(initialPane(page))
  const back = browser.getByTestId('browser-back-button')
  const forward = browser.getByTestId('browser-forward-button')

  await expect(back).toBeDisabled()
  await expect(forward).toBeDisabled()

  await settleOnBlank(electronApp)
  await navigateTo(browser, PAGE_A)
  await expect(header).toContainText('Page A')
  // The pane's own starting blank page is not somewhere the user asked to
  // be, so it's dropped rather than left as a back target — see the
  // clearHistory in BrowserRenderer, which is what makes this hold whether
  // or not the navigation beat that page's own commit.
  await expect(back).toBeDisabled()

  await navigateTo(browser, PAGE_B)
  await expect(header).toContainText('Page B')
  await expect(back).toBeEnabled()
  await expect(forward).toBeDisabled()

  await back.click()
  await expect(header).toContainText('Page A')
  await expect(forward).toBeEnabled()
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
  const browser = await openBrowser(panes.nth(2))
  await navigateTo(browser, SCROLLABLE_PAGE)
  // Asked of the guest rather than of the pane header, so the wait is on the
  // page really being there rather than on a title round-trip.
  await expect.poll(() => guestEval(app, 'document.title')).toBe('Scrollable')

  await activatePane(panes.nth(1))
  await expect(panes.nth(1)).toHaveClass(/pane-active/)

  const content = await requireBox(browser.locator('.browser-content'))
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

  const rebuilt = page.getByTestId('browser')
  const box = await requireBox(rebuilt.locator('.browser-content'))

  // The left split pane (panes.nth(1) — root's own wrapper permanently
  // occupies nth(0)), untouched by the wrap above, is what "somewhere else"
  // means here.
  await activatePane(panes.nth(1))
  await expect(panes.nth(1)).toHaveClass(/pane-active/)

  await page.mouse.click(box.x + box.width / 2, box.y + box.height / 2)
  await expect(panes.nth(1)).not.toHaveClass(/pane-active/)
})
