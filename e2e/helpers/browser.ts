import type { Locator } from '@playwright/test'
import { expect } from './launch'
import { openNewBrowser } from './pane'

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

/** Opens a browser pane in `pane` via its own header controls. */
export async function openBrowser(pane: Locator): Promise<Locator> {
  await openNewBrowser(pane)
  const browser = pane.page().getByTestId('browser')
  await expect(browser).toBeVisible()
  return browser
}

/** Navigates via the pane's own address bar, the way a user would. */
export async function navigateTo(browser: Locator, url: string): Promise<void> {
  const address = browser.getByTestId('browser-address-input')
  await address.fill(url)
  await address.press('Enter')
}
