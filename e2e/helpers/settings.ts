import { writeFileSync } from 'node:fs'
import path from 'node:path'
import type { ElectronApplication, Page } from 'playwright'
import type { Settings } from '../../src/shared/settings'

/**
 * Opens the Settings window from the given main-window `page` (clicking the
 * gear button) and returns a handle to its own Page. Settings lives in a
 * real second BrowserWindow (see `settingsWindow` in src/main/windows.ts),
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

/**
 * States a settings premise without driving the Settings window: the write
 * lands in main and is mirrored into every open window, as though another
 * window had made it. A content type's blob is merged key by key, so name
 * only the key the test depends on:
 *
 *     await mergeSettings(electronApp, { contentTypes: { browser: { controlledPanePlacement: 'tab' } } })
 *
 * For a test whose *subject* is the Settings UI, drive the UI instead.
 */
export async function mergeSettings(
  app: ElectronApplication,
  partial: Partial<Settings>
): Promise<void> {
  await app.evaluate((_electron, change) => {
    const hooks = globalThis.__tabsE2e
    if (!hooks) throw new Error('e2e hooks are not installed — is E2E_HIDDEN set?')
    hooks.mergeSettings(change)
  }, partial)
}

/**
 * Writes `partial` as the settings file of an app not yet launched in
 * `userDataDir` — how a relaunch test states a premise the first boot
 * already reads (persistLayoutOnExit decides whether that boot loads
 * layout.json at all), where `mergeSettings` would land too late. A partial
 * file loads merged over the defaults, like any older settings.json.
 */
export function seedSettingsFile(userDataDir: string, partial: Partial<Settings>): void {
  writeFileSync(path.join(userDataDir, 'settings.json'), JSON.stringify(partial))
}
