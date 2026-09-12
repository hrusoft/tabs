import type { Locator } from '@playwright/test'
import { expect } from './launch'
import { headerOf, openNewBrowser } from './pane'

/**
 * Driving a browser pane through its own UI — shared by every Electron-tier
 * spec that opens one (browser.spec.ts, keyboard-nav.spec.ts), so the
 * open-and-navigate sequence and the hermetic data:-URL construction exist
 * once rather than re-inlined per spec.
 */

/**
 * A hermetic page for a guest to load — a `data:` URL instead of a real
 * internet address, so no spec acquires a network dependency.
 */
export function dataPage(title: string, bodyHtml = ''): string {
  return `data:text/html,${encodeURIComponent(`<title>${title}</title>${bodyHtml}`)}`
}

/**
 * Opens a browser pane in `pane` via its own header controls. Returns the
 * `data-testid="browser"` element — the pane body's own webview host, which
 * is what a caller wants for webview/geometry assertions. The nav chrome
 * (back/forward/refresh/address bar) is no longer inside this subtree — see
 * `navigateTo`, which takes `pane` itself for that reason.
 */
export async function openBrowser(pane: Locator): Promise<Locator> {
  await openNewBrowser(pane)
  const browser = pane.page().getByTestId('browser')
  await expect(browser).toBeVisible()
  return browser
}

/**
 * Navigates via the pane's own address bar, the way a user would. Takes the
 * pane itself, not the `openBrowser` return value: the address bar lives in
 * the pane's header (BrowserHeaderTitle), a sibling of the webview host, not
 * a descendant of it.
 */
export async function navigateTo(pane: Locator, url: string): Promise<void> {
  const address = headerOf(pane).getByTestId('browser-address-input')
  await address.fill(url)
  await address.press('Enter')
}
