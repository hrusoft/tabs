import type { ElectronApplication, Page } from 'playwright'

/**
 * Invokes an application-menu item by label, the way a real accelerator
 * keypress would. Playwright's CDP-driven `page.keyboard` only dispatches DOM
 * events in the renderer and never reaches macOS's native menu key-equivalent
 * matching, so a menu-bound shortcut (Cmd/Ctrl+T, Cmd/Ctrl+W — see
 * src/main/menu.ts's buildMenu) can't be exercised via a simulated keypress
 * in a headless test run; this calls the menu item's own `click` instead.
 *
 * `targetPage` pins the click to that window (matched by URL). Required, not
 * a fallback: under E2E_HIDDEN no window ever becomes genuinely focused (see
 * the never-show()/focus() discipline in src/main/windows.ts), and with more
 * than one window open `getAllWindows()[0]` is not reliably the main window
 * — so the "guess a window" branch was unreliable by its own doc, and every
 * caller passed a page anyway.
 */
export async function clickMenuItem(
  app: ElectronApplication,
  label: string,
  targetPage: Page
): Promise<void> {
  const pageUrl = targetPage.url()
  await app.evaluate(
    ({ Menu, BrowserWindow }, { targetLabel, targetUrl }) => {
      function find(items: Electron.MenuItem[]): Electron.MenuItem | undefined {
        for (const item of items) {
          if (item.label === targetLabel) return item
          if (item.submenu) {
            const found = find(item.submenu.items)
            if (found) return found
          }
        }
        return undefined
      }
      const menuItems = Menu.getApplicationMenu()?.items ?? []
      const item = find(menuItems)
      if (!item) throw new Error(`menu item not found: ${targetLabel}`)
      const win = BrowserWindow.getAllWindows().find((w) => w.webContents.getURL() === targetUrl)
      // click(menuItem, window, event) — the handler needs the window to know
      // which renderer to notify (see buildMenu in src/main/menu.ts).
      item.click(undefined, win, undefined)
    },
    { targetLabel: label, targetUrl: pageUrl }
  )
}

/**
 * The live accelerator on the application-menu item labelled `label`, or null
 * if it has none — how a test asserts a rebinding actually reached the native
 * menu. Playwright drives the renderer over CDP and never reaches macOS's
 * key-equivalent matching (see above), so a simulated press could never fire a
 * menu item at all; reading the accelerator back out of main is the only way.
 *
 * Lives beside `clickMenuItem` so label→MenuItem resolution has one home. The
 * `find` walk is spelled out again inside the closure only because an
 * `app.evaluate` body is serialized into the main process and cannot reference
 * anything in this module's scope.
 */
export function acceleratorOf(app: ElectronApplication, label: string): Promise<string | null> {
  return app.evaluate(({ Menu }, targetLabel) => {
    function find(items: Electron.MenuItem[]): Electron.MenuItem | undefined {
      for (const item of items) {
        if (item.label === targetLabel) return item
        if (item.submenu) {
          const found = find(item.submenu.items)
          if (found) return found
        }
      }
      return undefined
    }
    const item = find(Menu.getApplicationMenu()?.items ?? [])
    if (!item) throw new Error(`menu item not found: ${targetLabel}`)
    return item.accelerator ?? null
  }, label)
}
