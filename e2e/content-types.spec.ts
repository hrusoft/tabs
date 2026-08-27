import { PANE_BUTTON } from '../src/shared/paneDomAttrs'
import { expect, test, withApp } from './helpers/launch'
import { clickMenuItem } from './helpers/menu'
import { closeInactiveRootTab, headerOf, initialPane } from './helpers/pane'
import { openSettingsWindow } from './helpers/settings'
import { alive, openTerminal } from './helpers/terminal'

/**
 * Turning a content type off, end to end.
 *
 * What keeps these in the Electron tier rather than in jsdom (where the filter
 * logic itself is covered, against a stub type — see
 * src/renderer/src/__tests__/content-types.test.tsx) is that each one needs
 * something only the real app has: two real windows exchanging a settings
 * change over IPC, the real terminal/browser pair in their real registration
 * order, a real pty that has to survive its own type being disabled, and a
 * relaunch.
 *
 * Every test drives the checkboxes to the state it needs rather than
 * inheriting it, so a future default flip can't quietly change what any of
 * them is testing.
 *
 * `pane-header.ts`'s `openNewBrowser` helper is deliberately unused here: it
 * hovers `pane-new-terminal-button` as the group root, which is the exact
 * assumption these tests break.
 */

const CONTENT_TYPE_ROW = {
  terminal: 'settings-content-type-terminal-checkbox',
  browser: 'settings-content-type-browser-checkbox',
  gitTree: 'settings-content-type-gitTree-checkbox'
} as const

test('the General page offers a checkbox per content type', async ({ page, electronApp }) => {
  const settingsPage = await openSettingsWindow(electronApp, page)

  await expect(settingsPage.getByTestId(CONTENT_TYPE_ROW.terminal)).toBeVisible()
  await expect(settingsPage.getByTestId(CONTENT_TYPE_ROW.browser)).toBeVisible()
  // Labelled from the census's displayName, not from copy written here.
  await expect(settingsPage.getByTestId('settings-page-general')).toContainText('Content types')
})

test("turning a type off removes its creation button from the main window's panes", async ({
  page,
  electronApp
}) => {
  const settingsPage = await openSettingsWindow(electronApp, page)
  // States the premise rather than assuming the shipped default.
  await settingsPage.getByTestId(CONTENT_TYPE_ROW.browser).check()
  const header = headerOf(initialPane(page))
  await expect(header.getByTestId('pane-new-browser-button')).toHaveCount(1)

  await settingsPage.getByTestId(CONTENT_TYPE_ROW.browser).uncheck()

  // Live, over settings:changed into the other window's store — no reload.
  await expect(header.getByTestId('pane-new-browser-button')).toHaveCount(0)
  // Only that type's button goes; core chrome is untouched.
  await expect(header.getByTestId('pane-new-terminal-button')).toHaveCount(1)
  await expect(header.getByTestId(PANE_BUTTON.splitHorizontal)).toHaveCount(1)
  await expect(header.getByTestId(PANE_BUTTON.close)).toHaveCount(1)

  await settingsPage.getByTestId(CONTENT_TYPE_ROW.browser).check()
  await expect(header.getByTestId('pane-new-browser-button')).toHaveCount(1)
})

/**
 * The registration-order consequence, which only this tier can show with real
 * types: the first registered type is the always-visible root button and the
 * rest sit in its dropdown, so disabling the first promotes the next.
 *
 * Reduced to exactly two enabled types on purpose. The closing assertion is
 * about what the promoted button looks like when it is the *only* creation
 * action left — no dropdown at all, not even one repeating the root — and that
 * is a claim about the count, not about which types happen to ship. Stating it
 * here rather than inheriting it is what stops the next content type breaking
 * this test, which is exactly how it broke when the git tree was added.
 */
test('disabling the first registered type promotes the next one to the root button', async ({
  page,
  electronApp
}) => {
  const settingsPage = await openSettingsWindow(electronApp, page)
  await settingsPage.getByTestId(CONTENT_TYPE_ROW.terminal).check()
  await settingsPage.getByTestId(CONTENT_TYPE_ROW.browser).check()
  await settingsPage.getByTestId(CONTENT_TYPE_ROW.gitTree).uncheck()
  const header = headerOf(initialPane(page))
  // Terminal registers first, so the browser starts life as a menu item.
  await expect(header.getByTestId('pane-new-browser-button')).toHaveAttribute('role', 'menuitem')

  await settingsPage.getByTestId(CONTENT_TYPE_ROW.terminal).uncheck()

  await expect(header.getByTestId('pane-new-terminal-button')).toHaveCount(0)
  // Now the root button: no menuitem role, and — being the only *enabled*
  // creation action left — no dropdown repeating it either.
  await expect(header.getByTestId('pane-new-browser-button')).not.toHaveAttribute(
    'role',
    'menuitem'
  )
  await expect(header.getByTestId('pane-new-browser-button-menu-item')).toHaveCount(0)
})

test("a disabled type's settings page leaves the sidebar, and comes back on re-enabling", async ({
  page,
  electronApp
}) => {
  const settingsPage = await openSettingsWindow(electronApp, page)
  await settingsPage.getByTestId(CONTENT_TYPE_ROW.terminal).check()
  await expect(settingsPage.getByTestId('settings-tab-terminal')).toBeVisible()

  await settingsPage.getByTestId(CONTENT_TYPE_ROW.terminal).uncheck()

  await expect(settingsPage.getByTestId('settings-tab-terminal')).toHaveCount(0)
  // Core's own pages are not content types and are never filtered.
  await expect(settingsPage.getByTestId('settings-tab-general')).toBeVisible()
  await expect(settingsPage.getByTestId('settings-tab-keyboard')).toBeVisible()
  await expect(settingsPage.getByTestId('settings-tab-skills')).toBeVisible()

  await settingsPage.getByTestId(CONTENT_TYPE_ROW.terminal).check()
  await expect(settingsPage.getByTestId('settings-tab-terminal')).toBeVisible()
})

/**
 * The cost of gating clone-from-survivor, stated as a test because it is the
 * one visible surprise the decision buys: a pane of a disabled type keeps
 * working, but New Tab on it no longer copies it.
 */
test('New Tab on a surviving pane of a disabled type opens an empty pane, not another one', async ({
  page,
  electronApp
}) => {
  const settingsPage = await openSettingsWindow(electronApp, page)
  await settingsPage.getByTestId(CONTENT_TYPE_ROW.terminal).check()
  const term = await openTerminal(initialPane(page))
  const pid = Number(await term.getAttribute('data-pty-pid'))

  await settingsPage.getByTestId(CONTENT_TYPE_ROW.terminal).uncheck()
  // The pane it is running in keeps rendering, and its shell keeps running.
  await expect(term).toBeVisible()
  expect(await alive(electronApp, pid)).toBe(true)

  await clickMenuItem(electronApp, 'New Tab', page)

  // Two tabs: the surviving terminal, and an empty pane rather than a clone.
  await expect(page.getByRole('tab')).toHaveCount(2)
  await expect(page.getByTestId('terminal')).toHaveCount(1)
  await expect(page.getByTestId('empty-pane')).toHaveCount(1)

  // Tidy up the real shell rather than leaving it for the shared app's quit —
  // see the note on openTerminal. The terminal's tab is root's own original
  // one, backgrounded by the new tab just added, which is exactly the shape
  // closeInactiveRootTab names (both tabs read "Tabs" here, so structural
  // selection is the only stable kind — see its doc in helpers/pane.ts).
  await closeInactiveRootTab(page)
  await expect.poll(() => alive(electronApp, pid), { timeout: 3000 }).toBe(false)
})

/**
 * The destructive-adjacent guarantee, which is the whole reason disabling does
 * not unregister: a pane of a disabled type must survive a *restart*, not just
 * stay on screen until the next layout normalize. Self-launched, because a
 * relaunch is the subject; leaving a live terminal running across the quit is
 * deliberate here for the same reason (see openTerminal's note).
 */
test('a pane of a disabled type survives a relaunch, and so does the setting', async ({
  userDataDir
}) => {
  await withApp(userDataDir, async (app1, page1) => {
    const settings1 = await openSettingsWindow(app1, page1)
    await settings1.getByTestId(CONTENT_TYPE_ROW.terminal).check()
    await openTerminal(initialPane(page1))

    await settings1.getByTestId(CONTENT_TYPE_ROW.terminal).uncheck()
    await expect(page1.getByTestId('terminal')).toBeVisible()
  })

  await withApp(userDataDir, async (app2, page2) => {
    // Restored as a real terminal pane, not as core's no-renderer placeholder
    // (UnknownContent, which is what "disabled means unregistered" would have
    // left behind here). Matched by class — that component carries no test id.
    await expect(page2.getByTestId('terminal')).toBeVisible()
    await expect(page2.locator('.unknown-content')).toHaveCount(0)
    // And still disabled: no creation affordance, and the checkbox remembers.
    const header2 = headerOf(initialPane(page2))
    await expect(header2.getByTestId('pane-new-terminal-button')).toHaveCount(0)
    const settings2 = await openSettingsWindow(app2, page2)
    await expect(settings2.getByTestId(CONTENT_TYPE_ROW.terminal)).not.toBeChecked()
    await expect(settings2.getByTestId('settings-tab-terminal')).toHaveCount(0)
  })
})
