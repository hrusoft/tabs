import { dataPage, navigateTo, openBrowser } from './helpers/browser'
import { expect, test } from './helpers/launch'
import { clickMenuItem } from './helpers/menu'
import { activatePane, initialPane, splitHorizontal } from './helpers/pane'

// What the other tiers can't reach: the real File menu item driving Cmd+P's
// IPC into the renderer with real content types visible (Terminal/Browser,
// not the stub), and — the actual regression risk in this feature — whether
// the overlay still receives keyboard input once a browser pane's <webview>
// guest already holds real DOM focus. A guest is a separate WebContents; no
// capture-phase listener in this window can intercept a keypress that lands
// there first (see CLAUDE.md's <webview> input-event gotchas), which is
// exactly why CommandPalette.tsx steals focus onto itself when it opens.
// Structure/keyboard-nav mechanics against the stub registry are jsdom's
// (src/renderer/src/__tests__/commandPalette.test.tsx); geometry is the
// browser tier's (e2e/browser/commandPalette.spec.ts).

test('File → New Content… opens the palette with real content types, and creates one', async ({
  page,
  electronApp
}) => {
  await expect(initialPane(page)).toBeVisible()

  await clickMenuItem(electronApp, 'New Content…', page)

  await expect(page.getByTestId('command-palette-backdrop')).toBeVisible()
  // The type's plain name, not the pane header button's imperative label.
  await expect(page.getByTestId('command-palette-item-pane-new-terminal-button')).toHaveText(
    /Terminal/
  )
  await expect(page.getByTestId('command-palette-item-pane-new-browser-button')).toHaveText(
    /Browser/
  )

  await page.getByTestId('command-palette-item-pane-new-terminal-button').click()
  await page.getByTestId('command-palette-item-new-tab').click()

  await expect(page.getByTestId('command-palette-backdrop')).toHaveCount(0)
  const term = page.getByTestId('terminal')
  await expect(term).toBeVisible()
  await expect(term).toHaveAttribute('data-pty-pid', /^\d+$/)
  // Safe to close only once the shell is actually up — see openTerminal's
  // note in helpers/terminal.ts on why a just-spawned shell can transiently
  // look like a foreground process to the quit-blocker check.
  await expect(term).toContainText('~', { timeout: 20_000 })

  // Close what the palette opened, per this file's shared-app convention.
  await clickMenuItem(electronApp, 'Close Pane', page)
})

test("the palette steals keyboard focus from a browser pane's guest, so arrow/Enter still drive it", async ({
  page,
  electronApp
}) => {
  await splitHorizontal(initialPane(page))
  const panes = page.getByTestId('pane')
  const browser = await openBrowser(panes.nth(2))
  await navigateTo(browser, dataPage('Probe'))

  // A real click inside the guest's own content — not the address bar —
  // hands it real DOM focus via click-to-activate.
  await activatePane(panes.nth(2))
  await expect
    .poll(() => page.evaluate(() => document.activeElement?.tagName ?? 'none'))
    .toBe('WEBVIEW')

  await clickMenuItem(electronApp, 'New Content…', page)
  await expect(page.getByTestId('command-palette-backdrop')).toBeVisible()

  // The overlay must have taken focus away from the guest already, or every
  // key below would vanish into the page instead of driving this list.
  await expect
    .poll(() => page.evaluate(() => document.activeElement?.tagName ?? 'none'))
    .not.toBe('WEBVIEW')

  // Registration order is terminal, browser, gitTree (src/plugins/index.ts)
  // — one ArrowDown from the default highlight reaches Browser.
  await page.keyboard.press('ArrowDown')
  await expect(page.getByTestId('command-palette-item-pane-new-browser-button')).toHaveClass(
    /command-palette-item-highlighted/
  )
  await page.keyboard.press('Enter') // choose Browser
  await page.keyboard.press('Enter') // choose the highlighted placement: New Tab

  await expect(page.getByTestId('command-palette-backdrop')).toHaveCount(0)
  // Proof the presses actually landed on the palette and not the guest: a
  // second browser pane now exists.
  await expect(page.getByTestId('browser')).toHaveCount(2)
})
