import type { ElectronApplication, Page } from 'playwright'
import { clickMenuItem } from './menu'

/**
 * Opens the About window from the given main-window `page` and returns a
 * handle to its own Page. About lives in a real third BrowserWindow (see
 * createAboutWindow in src/main/windows.ts), so callers need a distinct Page,
 * exactly as they do for Settings.
 *
 * Driven through the application menu because that is the *only* route to it
 * — there is no in-app button, matching how a macOS About window is reached.
 * `clickMenuItem` invokes the item's own handler rather than pressing a key:
 * Playwright drives the renderer over CDP and never reaches macOS's native
 * menu matching (see the note on clickMenuItem itself).
 *
 * The main-process side is a singleton (openAboutWindow focuses an existing
 * window rather than creating a second), so call this at most once per test
 * and reuse the returned Page. A later test in the same file may call it
 * again: the between-test reset destroys every window but the main one, which
 * clears that singleton.
 */
export async function openAboutWindow(app: ElectronApplication, page: Page): Promise<Page> {
  const [aboutPage] = await Promise.all([
    app.waitForEvent('window'),
    clickMenuItem(app, 'About Tabs', page)
  ])
  await aboutPage.waitForLoadState('domcontentloaded')
  return aboutPage
}
