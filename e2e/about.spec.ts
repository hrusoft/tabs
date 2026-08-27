import type { ElectronApplication } from 'playwright'
import { ATTRIBUTIONS, RUNTIME_COMPONENTS } from '../src/shared/attributions'
import { CRYPTO_ADDRESSES, DONATION_TIERS } from '../src/shared/donations'
import { openAboutWindow } from './helpers/about'
import { expect, test } from './helpers/launch'
import { clickMenuItem } from './helpers/menu'
import { rootPane } from './helpers/pane'

/**
 * The About window's integration half — everything that only exists with a
 * real main process behind it: that the application menu opens it at all,
 * that the versions on screen are the running ones, that its own stylesheet
 * reached this window and no other, that Close Pane closes it, and that the
 * copy buttons put text on the real system clipboard.
 *
 * What it *renders* from the shared data is the jsdom tier's subject
 * (src/renderer/src/about/__tests__/aboutWindow.test.tsx), which is also
 * where a tier click's outbound URL is asserted — clicking one here would
 * launch the developer's actual browser.
 *
 * Note this spec can import @shared/attributions and @shared/donations
 * directly, unlike shared/settings: neither reaches the content-type census,
 * which is what makes that module unimportable from an e2e spec.
 */

/** Whatever `process.versions` and app.getVersion() say inside the real app. */
function realAppInfo(app: ElectronApplication) {
  return app.evaluate(({ app: electronApp }) => ({
    version: electronApp.getVersion(),
    electron: process.versions.electron,
    chrome: process.versions.chrome,
    node: process.versions.node
  }))
}

test('the application menu opens a real About window', async ({ page, electronApp }) => {
  const aboutPage = await openAboutWindow(electronApp, page)

  await expect(aboutPage.getByTestId('about-window')).toBeVisible()
  // Its own window, not a view inside the main one.
  expect(aboutPage.url()).toContain('about.html')
  expect(aboutPage).not.toBe(page)
  await expect(aboutPage.getByRole('heading', { level: 1, name: 'Tabs' })).toBeVisible()
})

test('shows the running app and runtime versions, not restated literals', async ({
  page,
  electronApp
}) => {
  const aboutPage = await openAboutWindow(electronApp, page)
  const info = await realAppInfo(electronApp)

  await expect(aboutPage.getByTestId('about-version')).toHaveText(`Version ${info.version}`)
  // The half the unit tier structurally cannot check: `process.versions` has
  // no `electron` or `chrome` outside Electron, so that each versionKey names
  // a field that exists — and that the value shown is the running one — can
  // only be asserted here.
  for (const component of RUNTIME_COMPONENTS) {
    const version = info[component.versionKey]
    expect(version, `process.versions.${component.versionKey} is empty`).not.toBe('')
    await expect(
      aboutPage.getByTestId(`about-credit-${component.name}`).locator('..')
    ).toContainText(version)
  }
})

test('credits every package the reconciliation gate requires', async ({ page, electronApp }) => {
  const aboutPage = await openAboutWindow(electronApp, page)

  // The same list src/shared/__tests__/attributions.test.ts reconciles
  // against package.json — so "every shipped dependency is credited" and
  // "every credit reaches the screen" together close the compliance loop.
  for (const entry of ATTRIBUTIONS) {
    await expect(aboutPage.getByTestId(`about-credit-${entry.name}`)).toHaveText(entry.name)
  }
})

test('offers the three donation tiers', async ({ page, electronApp }) => {
  const aboutPage = await openAboutWindow(electronApp, page)

  await expect(aboutPage.getByTestId('about-donations')).toContainText(
    'buy me a coffee to fuel future development'
  )
  for (const tier of DONATION_TIERS) {
    // Deliberately not clicked: openExternal really does hand the URL to the
    // OS, which would open a browser on the machine running the suite. The
    // jsdom tier asserts each tier sends its own link.
    await expect(aboutPage.getByTestId(`about-tier-${tier.id}`)).toContainText(tier.label)
  }
})

/**
 * The co-located stylesheet is side-effect imported from AboutWindow.tsx and
 * so is invisible to typecheck and lint — drop it, or let the bundler chunk
 * it behind a module this entry never imports, and the page still renders,
 * just unstyled. Asserting a computed value the rule provides and the UA
 * default does not (`grid` vs a button's `inline-block`) is what makes that
 * loud. Same pairing as the Settings window's own stylesheet assertion in
 * settings.spec.ts.
 */
test('the About window loads its own stylesheet', async ({ page, electronApp }) => {
  const aboutPage = await openAboutWindow(electronApp, page)

  const firstTier = DONATION_TIERS[0]!
  await expect(aboutPage.getByTestId(`about-tier-${firstTier.id}`)).toHaveCSS('display', 'grid')
})

test('Close Pane closes the About window rather than reaching for a pane', async ({
  page,
  electronApp
}) => {
  const aboutPage = await openAboutWindow(electronApp, page)

  // The isAuxiliaryWindow branch in buildMenu: this window hosts no panes and
  // has no listener for the action, so the item can only mean "close me".
  // Without that branch the action is forwarded to a renderer that ignores it
  // and the window simply stays open.
  const closed = aboutPage.waitForEvent('close')
  await clickMenuItem(electronApp, 'Close Pane', aboutPage)
  await closed

  expect(aboutPage.isClosed()).toBe(true)
  // The main window is untouched — the branch closes the focused auxiliary
  // window, not the app.
  await expect(rootPane(page)).toBeVisible()
})

test('a copy button puts the address on the real system clipboard', async ({
  page,
  electronApp
}) => {
  const aboutPage = await openAboutWindow(electronApp, page)
  // The suite runs on a developer's own machine, so put back whatever was
  // there. Restored even if an assertion below fails.
  const original = await electronApp.evaluate(({ clipboard }) => clipboard.readText())
  try {
    const entry = CRYPTO_ADDRESSES[0]!
    await aboutPage.getByTestId(`about-copy-${entry.id}`).click()

    // The whole reason copyText goes through main rather than
    // navigator.clipboard: this window is never genuinely focused under
    // E2E_HIDDEN, and navigator.clipboard.writeText throws on an unfocused
    // document — so the renderer route could not be asserted here at all.
    await expect
      .poll(() => electronApp.evaluate(({ clipboard }) => clipboard.readText()))
      .toBe(entry.address)
    // And it says so, so the user knows the string was taken.
    await expect(aboutPage.getByTestId(`about-copy-${entry.id}`)).toHaveText('Copied')
  } finally {
    await electronApp.evaluate(({ clipboard }, text) => {
      clipboard.writeText(text)
    }, original)
  }
})

test('opening About twice focuses the one window rather than making a second', async ({
  page,
  electronApp
}) => {
  await openAboutWindow(electronApp, page)

  await clickMenuItem(electronApp, 'About Tabs', page)
  // No new window event to wait for is exactly the assertion; give a real
  // second one time to appear before counting.
  await page.waitForTimeout(300)

  const aboutWindows = await electronApp.evaluate(
    ({ BrowserWindow }) =>
      BrowserWindow.getAllWindows().filter((win) => win.webContents.getURL().includes('about.html'))
        .length
  )
  expect(aboutWindows).toBe(1)
})
