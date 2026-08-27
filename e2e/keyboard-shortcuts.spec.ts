import { SHORTCUT_ACTIONS, type ShortcutActionId, toAccelerator } from '../src/shared/shortcuts'
import { expect, test, withApp } from './helpers/launch'
import { acceleratorOf, clickMenuItem } from './helpers/menu'
import { headerOf, initialPane, splitHorizontal } from './helpers/pane'
import { MOD_KEY, PLATFORM } from './helpers/platform'
import { openSettingsTab } from './helpers/settings'

// Only what the other tiers cannot reach: the real application menu carrying a
// rebound accelerator, capture mode actually suspending those accelerators,
// and persistence across a relaunch. The capture UI's own behaviour (conflict
// reassignment, validation, cancel) is covered in
// src/renderer/src/settings/__tests__/keyboardSettings.test.tsx, and the
// renderer's nav matcher in src/renderer/src/__tests__/keyboard-nav.test.tsx.
//
// Accelerators are asserted by reading MenuItem.accelerator out of the main
// process rather than by pressing keys: Playwright drives the renderer over
// CDP and never reaches macOS's native menu key-equivalent matching (see
// helpers/menu.ts), so a simulated press could never fire a menu item at all.

/**
 * Where a menu item's label differs from its action's label in the shared
 * registry. Only the app menu does, using the platform's own wording; every
 * other item takes `shortcutAction(id).label` verbatim (see paneShortcutItem
 * in src/main/menu.ts).
 */
const MENU_ITEM_LABEL: Partial<Record<ShortcutActionId, string>> = {
  'open-settings': 'Settings…'
}

/**
 * Every action the native menu enforces, with the label its item carries and
 * the accelerator its shipped default spells out.
 *
 * Derived from the shared registry rather than hand-listed, because the
 * hand-listed version silently went stale: New Unpinned Pane shipped without
 * being added to either "every accelerator" assertion below, and both kept
 * passing. The literal accelerator strings stay pinned exhaustively in
 * src/shared/__tests__/shortcuts.test.ts — what these two tests uniquely prove
 * is that the binding crossed into the real application menu at all.
 */
const MENU_ACTIONS = SHORTCUT_ACTIONS.filter((action) => action.layer !== 'renderer').map(
  (action) => ({
    label: MENU_ITEM_LABEL[action.id] ?? action.label,
    accelerator: toAccelerator(action.defaultBinding, PLATFORM)
  })
)

test('the shipped defaults are the accelerators the menu has always carried', async ({
  page,
  electronApp
}) => {
  // Wait for the window before reaching into main: firstWindow() resolves
  // before the renderer has finished loading, and an evaluate landing in that
  // gap dies with "execution context was destroyed".
  await expect(initialPane(page)).toBeVisible()
  for (const { label, accelerator } of MENU_ACTIONS) {
    expect(await acceleratorOf(electronApp, label), label).toBe(accelerator)
  }
})

test('rebinding an action rebuilds the real menu, and the item still works', async ({
  page,
  electronApp
}) => {
  const settingsPage = await openSettingsTab(electronApp, page, 'keyboard')
  await expect(settingsPage.getByTestId('settings-page-keyboard')).toBeVisible()

  await settingsPage.getByTestId('settings-shortcut-close-pane').click()
  await settingsPage.keyboard.press(`${MOD_KEY}+Alt+N`)

  // The menu is rebuilt wholesale on a rebind — there is no in-place
  // accelerator update — so this is the assertion that the whole
  // settings → main → Menu.setApplicationMenu path ran.
  await expect.poll(() => acceleratorOf(electronApp, 'Close Pane')).toBe('CommandOrControl+Alt+N')

  // Rebinding must not disturb what the item *does*. Close Pane rather than
  // New Tab is an arbitrary pick here — either would do, this one just needs
  // a second pane to close, which the header's own split button gives it.
  // Root's own wrapper is permanently pane 0 (see ensureTabsRoot in
  // tree.ts), so splitting the initial pane leaves 3, and closing one of the
  // two split children collapses back to 2.
  await splitHorizontal(initialPane(page))
  await expect(page.getByTestId('pane')).toHaveCount(3)
  await headerOf(initialPane(page)).click()
  await clickMenuItem(electronApp, 'Close Pane', page)
  await expect(page.getByTestId('pane')).toHaveCount(2)
})

test('clearing a binding leaves the item in the menu with no accelerator', async ({
  page,
  electronApp
}) => {
  const settingsPage = await openSettingsTab(electronApp, page, 'keyboard')
  await settingsPage.getByTestId('settings-shortcut-clear-clear-buffer').click()

  await expect.poll(() => acceleratorOf(electronApp, 'Clear Buffer')).toBeNull()

  // Still present and still clickable — an unbound action loses its key, not
  // its place in the menu.
  await clickMenuItem(electronApp, 'Clear Buffer', page)
})

// The reason capture mode exists at all: macOS matches a menu key equivalent
// before the keystroke reaches any renderer, so without suspension the
// recorder could never observe the combinations already bound to menu items.
test('arming capture suspends every customizable accelerator, and cancelling restores them', async ({
  page,
  electronApp
}) => {
  const settingsPage = await openSettingsTab(electronApp, page, 'keyboard')

  await settingsPage.getByTestId('settings-shortcut-new-tab').click()
  await expect.poll(() => acceleratorOf(electronApp, 'New Tab')).toBeNull()
  for (const { label } of MENU_ACTIONS) {
    expect(await acceleratorOf(electronApp, label), label).toBeNull()
  }
  // The stock role accelerators are never suspended — they aren't ours.
  expect(await acceleratorOf(electronApp, 'Copy')).toBeTruthy()

  await settingsPage.keyboard.press('Escape')
  await expect.poll(() => acceleratorOf(electronApp, 'New Tab')).toBe('CommandOrControl+T')
})

// The search box's own capture, armed by focus instead of a chip click (see
// KeyboardSettings.tsx) — same mechanism, same real-menu proof as the test
// above, just a different trigger.
test('focusing the shortcut search box suspends every customizable accelerator, and blurring restores them', async ({
  page,
  electronApp
}) => {
  const settingsPage = await openSettingsTab(electronApp, page, 'keyboard')

  await settingsPage.getByTestId('settings-shortcut-search').click()
  await expect.poll(() => acceleratorOf(electronApp, 'New Tab')).toBeNull()
  for (const { label } of MENU_ACTIONS) {
    expect(await acceleratorOf(electronApp, label), label).toBeNull()
  }
  expect(await acceleratorOf(electronApp, 'Copy')).toBeTruthy()

  // Blur onto something inert rather than a shortcut chip, which would arm
  // capture again for its own recording instead of just releasing it.
  await settingsPage.getByRole('heading', { name: 'Keyboard' }).click()
  await expect.poll(() => acceleratorOf(electronApp, 'New Tab')).toBe('CommandOrControl+T')
})

// Complements the test above (which reads the real MenuItem.accelerator to
// prove the *native* menu goes silent) with the text-insertion half. Note
// what this can and can't prove: Playwright's CDP session never reaches
// macOS's native menu matching regardless of capture mode (see helpers/
// menu.ts's own comment on this — a simulated press can't fire a menu item
// either way), so the pane-count assertion below is a sanity check, not the
// real proof that the menu stayed silent — that's the test above. What this
// *does* prove: a CDP-delivered keydown reaches this <input>'s own handler
// the same way a genuine keypress would (this isn't a <webview> guest, where
// CDP and a real press diverge — see CLAUDE.md's guest-nav-key forwarding
// gotcha), so it's real coverage beyond the jsdom-only assertion in
// keyboardSettings.test.tsx.
test('pressing a bound combination while the search box is focused types it out as text', async ({
  page,
  electronApp
}) => {
  const settingsPage = await openSettingsTab(electronApp, page, 'keyboard')
  await settingsPage.getByTestId('settings-shortcut-search').click()

  await settingsPage.keyboard.press(`${MOD_KEY}+T`)

  const expected = process.platform === 'darwin' ? 'cmd+t' : 'ctrl+t'
  await expect(settingsPage.getByTestId('settings-shortcut-search')).toHaveValue(expected)
  // Root's own wrapper is permanently pane 0 (see ensureTabsRoot in tree.ts)
  // plus the one real pane — unchanged proves no new tab actually opened.
  await expect(page.getByTestId('pane')).toHaveCount(2)
})

// Leaving capture armed would leave the app with no accelerators at all and no
// window able to turn them back on, so main releases it by itself.
test('closing the Settings window mid-capture restores the accelerators', async ({
  page,
  electronApp
}) => {
  const settingsPage = await openSettingsTab(electronApp, page, 'keyboard')
  await settingsPage.getByTestId('settings-shortcut-new-tab').click()
  await expect.poll(() => acceleratorOf(electronApp, 'New Tab')).toBeNull()

  await settingsPage.close()

  await expect.poll(() => acceleratorOf(electronApp, 'New Tab')).toBe('CommandOrControl+T')
})

// The renderer-enforced half. Unlike the menu actions this *is* reachable by a
// CDP keypress, because it's an ordinary window keydown listener.
test('a rebound navigation shortcut moves pane focus in the real app', async ({
  page,
  electronApp
}) => {
  const settingsPage = await openSettingsTab(electronApp, page, 'keyboard')
  await settingsPage.getByTestId('settings-shortcut-nav-right').click()
  await settingsPage.keyboard.press(`${MOD_KEY}+Alt+L`)
  await expect(settingsPage.getByTestId('settings-shortcut-nav-right')).not.toHaveText(
    'Press keys…'
  )

  // Root's own wrapper is permanently pane 0 (see ensureTabsRoot in
  // tree.ts); splitting the initial pane puts the original leaf at 1 and the
  // new sibling at 2.
  await splitHorizontal(initialPane(page))
  const panes = page.getByTestId('pane')
  await headerOf(panes.nth(1)).click()
  await expect(panes.nth(1)).toHaveClass(/pane-active/)

  // The old combination does nothing now…
  await page.keyboard.press(`${MOD_KEY}+ArrowRight`)
  await expect(panes.nth(1)).toHaveClass(/pane-active/)

  // …and the new one navigates. The Settings window pushed this change into
  // the main window over settings:changed, with no reload.
  await page.keyboard.press(`${MOD_KEY}+Alt+L`)
  await expect(panes.nth(2)).toHaveClass(/pane-active/)
})

test('a rebinding survives a relaunch, in the menu and in the Settings list', async ({
  userDataDir
}) => {
  await withApp(userDataDir, async (app1, page1) => {
    const settings1 = await openSettingsTab(app1, page1, 'keyboard')
    await settings1.getByTestId('settings-shortcut-new-tab').click()
    await settings1.keyboard.press(`${MOD_KEY}+Alt+N`)
    await expect.poll(() => acceleratorOf(app1, 'New Tab')).toBe('CommandOrControl+Alt+N')
    await settings1.getByTestId('settings-shortcut-clear-clear-buffer').click()
    await expect.poll(() => acceleratorOf(app1, 'Clear Buffer')).toBeNull()
  })

  await withApp(userDataDir, async (app2, page2) => {
    // Read straight off the menu built during startup: this is the ordering that
    // matters, since buildMenu now needs settings to have been loaded first.
    expect(await acceleratorOf(app2, 'New Tab')).toBe('CommandOrControl+Alt+N')
    expect(await acceleratorOf(app2, 'Clear Buffer')).toBeNull()

    const settings2 = await openSettingsTab(app2, page2, 'keyboard')
    const expected = process.platform === 'darwin' ? '⌥⌘N' : 'Ctrl+Alt+N'
    await expect(settings2.getByTestId('settings-shortcut-new-tab')).toHaveText(expected)
    await expect(settings2.getByTestId('settings-shortcut-clear-buffer')).toHaveText('Not set')
  })
})
