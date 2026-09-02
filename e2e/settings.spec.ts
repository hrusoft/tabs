import { writeFileSync } from 'node:fs'
import path from 'node:path'
import type { Page } from 'playwright'
import { expect, test, withApp } from './helpers/launch'
import { MOD_KEY } from './helpers/platform'
import { openSettingsTab, openSettingsWindow } from './helpers/settings'

/**
 * The painted chrome of a window's own title bar, read from live computed
 * style rather than from the stylesheet's source — so the assertions below
 * compare the two windows to each other and stay true whatever the palette
 * is changed to.
 */
function titleBarChrome(page: Page, selector: string) {
  return page.evaluate((sel) => {
    const element = document.querySelector(sel)
    if (!element) throw new Error(`no element matching ${sel}`)
    const style = getComputedStyle(element)
    return {
      backgroundColor: style.backgroundColor,
      height: style.height,
      appRegion: style.getPropertyValue('-webkit-app-region')
    }
  }, selector)
}

test('opens via the gear icon onto the General tab, and switches tabs', async ({
  page,
  electronApp
}) => {
  const settingsPage = await openSettingsWindow(electronApp, page)
  await expect(settingsPage.getByTestId('settings-page-general')).toBeVisible()

  await settingsPage.getByTestId('settings-tab-panes').click()
  await expect(settingsPage.getByTestId('settings-page-panes')).toBeVisible()
  await expect(settingsPage.getByTestId('settings-nav-flash-checkbox')).toBeChecked()

  await settingsPage.getByTestId('settings-tab-terminal').click()
  await expect(settingsPage.getByTestId('settings-page-terminal')).toBeVisible()
  // The terminal's appearance config lives on its own page now — there is no
  // separate core Appearance tab.
  await expect(settingsPage.getByTestId('settings-terminal-font-size-input')).toBeVisible()
  await expect(settingsPage.getByTestId('settings-tab-appearance')).toHaveCount(0)
})

/**
 * The appearance editor's stylesheet lives with its page def
 * (src/plugins/terminal/settings/terminalSettingsPage.css), not in global.css, so this
 * window is the only one that loads it. A co-located side-effect import is
 * invisible to typecheck and lint: drop it, or let the bundler chunk it behind
 * a module this entry never imports, and the page still renders — just
 * unstyled. Asserting a computed value the rule provides and the UA default
 * does not (`grid` vs `block`) is what makes that loud.
 *
 * The pane window's half of this pairing is in browser.spec.ts and
 * terminal.spec.ts.
 */
test('the Settings window loads the terminal appearance editor stylesheet', async ({
  page,
  electronApp
}) => {
  const settingsPage = await openSettingsTab(electronApp, page, 'terminal')
  await expect(settingsPage.getByTestId('settings-page-terminal')).toBeVisible()

  const swatchGrid = settingsPage.locator('.terminal-appearance-colors')
  await expect(swatchGrid).toBeVisible()
  await expect(swatchGrid).toHaveCSS('display', 'grid')
})

/**
 * The two windows read as one app in the ways that still apply once the main
 * window's root is always a tab group (see `ensureTabsRoot`): its own tab bar
 * (.tab-bar-root) plays the title-bar role Settings' plain .settings-titlebar
 * still does, and `trafficLightPosition` in main/windows.ts keeps both bars
 * pinned to the exact same height on purpose, so the two traffic-light
 * clusters land at the same place on screen. Background color is no longer
 * part of that contract: the root bar's own chrome now follows the same
 * depth-striping every other pane's does (`--surface`, currently `--bg` at
 * its depth), which is a real, deliberate, already-shipped-and-reviewed
 * difference from Settings' fixed `--bg-elevated` — asserting they match
 * would fail the design on purpose, not catch a regression.
 */
test('the Settings window wears the same custom title bar height as the main window', async ({
  page,
  electronApp
}) => {
  const settingsPage = await openSettingsWindow(electronApp, page)
  await expect(settingsPage.getByTestId('settings-titlebar')).toBeVisible()

  const main = await titleBarChrome(page, '.tab-bar-root')
  const settings = await titleBarChrome(settingsPage, '[data-testid="settings-titlebar"]')

  // Guards the comparison against passing vacuously on two unstyled bars.
  expect(main.backgroundColor).not.toBe('rgba(0, 0, 0, 0)')
  expect(main.height).toBe('30px')

  expect(settings.height).toBe(main.height)
  // Without this the Settings window would be unmovable: hiding the native
  // title bar takes its drag behavior with it.
  expect(settings.appRegion).toBe('drag')
  expect(main.appRegion).toBe('drag')
})

/**
 * The other half of the same change, and the half that can only be seen from
 * the main process: the native title bar is gone, so the web contents fill the
 * whole window. Stated as a relationship between the two windows — a stock
 * macOS frame would make the content ~30px shorter than the window.
 */
test('neither window has a native title bar above its web contents', async ({
  page,
  electronApp
}) => {
  test.skip(process.platform !== 'darwin', 'titleBarStyle: hidden is applied on macOS only')
  await openSettingsWindow(electronApp, page)

  const windows = await electronApp.evaluate(({ BrowserWindow }) =>
    BrowserWindow.getAllWindows().map((win) => ({
      url: win.webContents.getURL(),
      windowHeight: win.getBounds().height,
      contentHeight: win.getContentBounds().height
    }))
  )
  const settingsWindow = windows.find((win) => win.url.includes('settings.html'))
  const mainWindow = windows.find((win) => win.url.includes('index.html'))

  expect(mainWindow?.contentHeight).toBe(mainWindow?.windowHeight)
  expect(settingsWindow?.contentHeight).toBe(settingsWindow?.windowHeight)
})

test('is a real, independent second window', async ({ page, electronApp }) => {
  const settingsPage = await openSettingsWindow(electronApp, page)
  expect(electronApp.windows()).toHaveLength(2)
  expect(settingsPage).not.toBe(page)
})

test('closing the Settings window does not affect the main window', async ({
  page,
  electronApp
}) => {
  const settingsPage = await openSettingsWindow(electronApp, page)
  await settingsPage.close()
  expect(electronApp.windows()).toHaveLength(1)
  // The main window's own chrome — its root tab bar — is still there and
  // still working, not just present in the DOM.
  await expect(page.locator('.tab-bar-root')).toBeVisible()
  await expect(page.getByTestId('settings-open-button')).toBeVisible()
})

test('a change made in the Settings window is reflected live in the main window', async ({
  page,
  electronApp
}) => {
  const settingsPage = await openSettingsTab(electronApp, page, 'panes')
  await settingsPage.getByTestId('settings-nav-flash-checkbox').uncheck()

  await page.keyboard.press(`${MOD_KEY}+ArrowRight`)
  await expect(page.getByTestId('nav-flash')).toHaveCount(0)
})

test('unchecking suppresses the nav-flash overlay, and the change persists across a relaunch', async ({
  userDataDir
}) => {
  await withApp(userDataDir, async (app1, page1) => {
    const settingsPage1 = await openSettingsTab(app1, page1, 'panes')
    await settingsPage1.getByTestId('settings-nav-flash-checkbox').uncheck()

    await page1.keyboard.press(`${MOD_KEY}+ArrowRight`)
    await expect(page1.getByTestId('nav-flash')).toHaveCount(0)
  })

  await withApp(userDataDir, async (app2, page2) => {
    const settingsPage2 = await openSettingsTab(app2, page2, 'panes')
    await expect(settingsPage2.getByTestId('settings-nav-flash-checkbox')).not.toBeChecked()
  })
})

/**
 * The case the settings.json migration exists for: a file written by a
 * pre-contentTypes build (flat terminal keys, a hand-tuned palette) must
 * come through with nothing lost — including after a settings write forces
 * a save in the new shape and the app is relaunched from that file. Hex
 * values are seeded lowercase because <input type="color"> normalizes to
 * lowercase, so an uppercase seed would fail toHaveValue spuriously.
 */
test('a pre-contentTypes settings.json migrates without losing the terminal palette', async ({
  userDataDir
}) => {
  writeFileSync(
    path.join(userDataDir, 'settings.json'),
    JSON.stringify({
      showNavFlash: false,
      inheritCwdOnNewPane: false,
      terminal: { fontSize: 19, ansi: { red: '#123456' } }
    })
  )

  await withApp(userDataDir, async (app1, page1) => {
    const settingsPage1 = await openSettingsTab(app1, page1, 'panes')
    await expect(settingsPage1.getByTestId('settings-nav-flash-checkbox')).not.toBeChecked()
    await settingsPage1.getByTestId('settings-tab-terminal').click()
    await expect(settingsPage1.getByTestId('settings-inherit-cwd-checkbox')).not.toBeChecked()
    await expect(settingsPage1.getByTestId('settings-terminal-font-size-input')).toHaveValue('19')
    await expect(settingsPage1.getByTestId('settings-terminal-ansi-red-color')).toHaveValue(
      '#123456'
    )

    // A write through the new schema, so the relaunch below reads a file the
    // *new* shape's save path produced — the silent-wipe scenario. (Back on
    // Panes & Tabs first: the nav-flash row unmounts while the Terminal page is up.)
    await settingsPage1.getByTestId('settings-tab-panes').click()
    await settingsPage1.getByTestId('settings-nav-flash-checkbox').check()
  })

  await withApp(userDataDir, async (app2, page2) => {
    const settingsPage2 = await openSettingsTab(app2, page2, 'panes')
    await expect(settingsPage2.getByTestId('settings-nav-flash-checkbox')).toBeChecked()
    await settingsPage2.getByTestId('settings-tab-terminal').click()
    await expect(settingsPage2.getByTestId('settings-inherit-cwd-checkbox')).not.toBeChecked()
    await expect(settingsPage2.getByTestId('settings-terminal-font-size-input')).toHaveValue('19')
    await expect(settingsPage2.getByTestId('settings-terminal-ansi-red-color')).toHaveValue(
      '#123456'
    )
  })
})
