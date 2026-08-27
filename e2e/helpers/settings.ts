import type { ElectronApplication, Page } from 'playwright'

/**
 * Opens the Settings window from the given main-window `page` (clicking the
 * gear button) and returns a handle to its own Page. Settings lives in a
 * real second BrowserWindow (see createSettingsWindow in src/main/windows.ts),
 * not inside the main window's DOM, so callers need a distinct Page.
 *
 * The main-process side is a singleton (openSettingsWindow focuses an
 * existing window rather than creating a new one), so call this at most once
 * per test and reuse the returned Page. A later test in the same file may
 * call it again: the between-test reset destroys the Settings window, which
 * clears that singleton.
 */
export async function openSettingsWindow(app: ElectronApplication, page: Page): Promise<Page> {
  const [settingsPage] = await Promise.all([
    app.waitForEvent('window'),
    page.getByTestId('settings-open-button').click()
  ])
  await settingsPage.waitForLoadState('domcontentloaded')
  return settingsPage
}

/**
 * `openSettingsWindow` plus switching to `tabId`'s sidebar page — the pairing
 * nearly every Settings-driving test repeats. Same singleton caveat as above.
 */
export async function openSettingsTab(
  app: ElectronApplication,
  page: Page,
  tabId: string
): Promise<Page> {
  const settingsPage = await openSettingsWindow(app, page)
  await settingsPage.getByTestId(`settings-tab-${tabId}`).click()
  return settingsPage
}
