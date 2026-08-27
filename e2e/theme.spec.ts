import { DARK_THEME, LIGHT_THEME } from '../src/shared/theme'
import { expect, test, withApp } from './helpers/launch'
import { openSettingsWindow } from './helpers/settings'

/**
 * The integration half of theming: the parts that only exist with a real main
 * process behind the renderer — the cross-window broadcast, persistence across
 * a relaunch, and the native chrome (`nativeTheme.themeSource` plus each
 * window's own background), which is not CSS and so cannot be reached from
 * either non-Electron tier.
 *
 * What the tokens actually paint is e2e/browser/theme.spec.ts's subject, and
 * the resolver's logic is a unit test — neither needs Electron.
 */

function themeSource(app: import('playwright').ElectronApplication): Promise<string> {
  return app.evaluate(({ nativeTheme }) => nativeTheme.themeSource)
}

function windowBackgrounds(app: import('playwright').ElectronApplication): Promise<string[]> {
  return app.evaluate(({ BrowserWindow }) =>
    BrowserWindow.getAllWindows().map((win) => win.getBackgroundColor().toLowerCase())
  )
}

/**
 * The one test whose subject genuinely *is* the shipping default. The value
 * is a literal here rather than a read of DEFAULT_SETTINGS — an e2e spec
 * cannot import src/shared/settings at all, because its graph reaches the
 * content-type census, which only exists inside Vite-built contexts (the
 * census throws under Playwright's transform, naming this rule). The literal
 * costs nothing: the app half of every assertion below is the real launched
 * build, so a shipped default drifting from 'dark' fails here regardless.
 */
const SHIPPED_COLOR_THEME = 'dark'

test('ships a real theme by default, and the main window paints it', async ({
  page,
  electronApp
}) => {
  await expect(page.locator('html')).toHaveAttribute('data-theme', SHIPPED_COLOR_THEME)
  // Also the proof that the between-test reset restores themeSource — this
  // test runs after the ones below that change it (see main/e2e.ts).
  expect(await themeSource(electronApp)).toBe(SHIPPED_COLOR_THEME)

  const settingsPage = await openSettingsWindow(electronApp, page)
  await expect(settingsPage.getByTestId('settings-color-theme-select')).toHaveValue(
    SHIPPED_COLOR_THEME
  )
})

test('the picker offers every shipped theme plus the system alias', async ({
  page,
  electronApp
}) => {
  const settingsPage = await openSettingsWindow(electronApp, page)
  const options = settingsPage.getByTestId('settings-color-theme-select').locator('option')
  await expect(options).toHaveText(['Dark', 'Light', 'System'])
})

test('changing the theme in the Settings window restyles both windows live', async ({
  page,
  electronApp
}) => {
  const settingsPage = await openSettingsWindow(electronApp, page)
  await settingsPage.getByTestId('settings-color-theme-select').selectOption('light')

  // The window that made the change...
  await expect(settingsPage.locator('html')).toHaveAttribute('data-theme', 'light')
  // ...and the one that only heard about it over the settings:changed
  // broadcast, with no reload.
  await expect(page.locator('html')).toHaveAttribute('data-theme', 'light')
})

test('the theme drives the native chrome the app does not style itself', async ({
  page,
  electronApp
}) => {
  const settingsPage = await openSettingsWindow(electronApp, page)
  // Stated, not inherited: this test is about the setting reaching the native
  // layer, so it drives both ends itself.
  await settingsPage.getByTestId('settings-color-theme-select').selectOption('dark')

  // themeSource is what carries the theme to the traffic lights, the Settings
  // window's native title bar, and the native confirmation dialogs.
  await expect.poll(() => themeSource(electronApp)).toBe('dark')
  expect(await windowBackgrounds(electronApp)).toEqual([
    DARK_THEME.windowBackground,
    DARK_THEME.windowBackground
  ])

  await settingsPage.getByTestId('settings-color-theme-select').selectOption('light')

  await expect.poll(() => themeSource(electronApp)).toBe('light')
  // Every open window, not just the one that changed it — and the value comes
  // from the theme, so it can't drift from what the renderer paints.
  expect(await windowBackgrounds(electronApp)).toEqual([
    LIGHT_THEME.windowBackground,
    LIGHT_THEME.windowBackground
  ])

  await settingsPage.getByTestId('settings-color-theme-select').selectOption('system')
  await expect.poll(() => themeSource(electronApp)).toBe('system')
})

test('the chosen theme persists across a relaunch', async ({ userDataDir }) => {
  await withApp(userDataDir, async (app1, page1) => {
    const settingsPage1 = await openSettingsWindow(app1, page1)
    await settingsPage1.getByTestId('settings-color-theme-select').selectOption('light')
    await expect(page1.locator('html')).toHaveAttribute('data-theme', 'light')
  })

  await withApp(userDataDir, async (app2, page2) => {
    // Applied from the persisted setting on the very first render, not after a
    // hydration round-trip — settingsStore reads it over synchronous IPC and
    // installTheme runs before createRoot().render() (see CLAUDE.md).
    await expect(page2.locator('html')).toHaveAttribute('data-theme', 'light')
    expect(await themeSource(app2)).toBe('light')
    // The window was constructed with the persisted theme's background, so the
    // pre-paint frame matches too rather than flashing the other theme.
    expect(await windowBackgrounds(app2)).toEqual([LIGHT_THEME.windowBackground])

    const settingsPage2 = await openSettingsWindow(app2, page2)
    await expect(settingsPage2.getByTestId('settings-color-theme-select')).toHaveValue('light')
  })
})
