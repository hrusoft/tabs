import { mkdtempSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import path from 'node:path'
import { expect, test, withApp } from './helpers/launch'
import { initialPane, openNewTab, splitHorizontal } from './helpers/pane'
import { openSettingsWindow } from './helpers/settings'
import { openTerminal, typeAndEnter } from './helpers/terminal'

test('a split with a terminal and a tab group survives a relaunch', async ({ userDataDir }) => {
  const pidBefore = await withApp(userDataDir, async (_app1, page1) => {
    // Build: split horizontally, a terminal in pane 1, a 2-tab group in pane 2.
    // Root's own wrapper permanently occupies pane 0 (see ensureTabsRoot in
    // tree.ts) and its own tablist/tab ("Tabs") are always there too.
    await splitHorizontal(initialPane(page1))
    const panes1 = page1.getByTestId('pane')
    const term1 = await openTerminal(panes1.nth(1))
    const pid = await term1.getAttribute('data-pty-pid')

    await openNewTab(panes1.nth(2))
    await openNewTab(panes1.nth(2))
    // Root's own tablist, plus the new nested one.
    await expect(page1.getByRole('tablist')).toHaveCount(2)
    // Root's own single tab ("Tabs"), plus the nested group's two.
    await expect(page1.getByRole('tab')).toHaveCount(3)
    // Root's wrapper, the terminal pane, the tab group pane, and each of its
    // two tabs' content panes.
    await expect(page1.getByTestId('pane')).toHaveCount(5)

    return pid
  })

  await withApp(userDataDir, async (_app2, page2) => {
    // Same shape: root's wrapper, the split, the tab group with both tabs,
    // and the terminal pane.
    await expect(page2.getByTestId('pane')).toHaveCount(5)
    await expect(page2.getByRole('tablist')).toHaveCount(2)
    await expect(page2.getByRole('tab')).toHaveCount(3)
    await expect(page2.getByTestId('terminal')).toHaveCount(1)

    // The restored terminal is a genuinely fresh, working shell — a new pid
    // (the old process was killed on quit, see src/plugins/terminal/main/terminal.ts's
    // disposeAllTerminals), not a stale reference, and actually interactive.
    const term2 = page2.getByTestId('terminal')
    await expect(term2).toHaveAttribute('data-pty-pid', /^\d+$/)
    const pidAfter = await term2.getAttribute('data-pty-pid')
    expect(pidAfter).not.toBe(pidBefore)

    await typeAndEnter(term2, 'echo hello-after-restart')
    await expect(term2).toContainText('hello-after-restart')
  })
})

test("a terminal's live directory survives a relaunch", async ({ userDataDir }) => {
  // Quitting is when the live cwd is actually captured (see main/index.ts's
  // before-quit handler calling layout.ts's refreshLeafCwds) — the close
  // withApp performs on the way out is the trigger under test, not an
  // incidental cleanup step.
  const dir = await withApp(userDataDir, async (_app1, page1) => {
    const term1 = await openTerminal(initialPane(page1))
    const tempDir = mkdtempSync(path.join(tmpdir(), 'tabs-e2e-cwd-'))
    // Confirmed on screen before quitting: the shell process itself must have
    // actually finished the chdir (not just received the keystrokes) before
    // the quit-time cwd capture below reads its live directory, or it's a race.
    await typeAndEnter(term1, `cd ${tempDir} && pwd`)
    await expect(term1).toContainText(tempDir)

    return tempDir
  })

  await withApp(userDataDir, async (_app2, page2) => {
    const term2 = page2.getByTestId('terminal')
    await expect(term2).toHaveAttribute('data-pty-pid', /^\d+$/)

    await typeAndEnter(term2, 'pwd')
    await expect(term2).toContainText(dir)
  })

  rmSync(dir, { recursive: true, force: true })
})

test('a corrupt layout.json falls back to a single empty pane instead of crashing', async ({
  userDataDir
}) => {
  writeFileSync(path.join(userDataDir, 'layout.json'), '{ not valid json')

  await withApp(userDataDir, async (_app, page) => {
    // Root's own wrapper (ensureTabsRoot in tree.ts, applied on load) plus
    // the single empty pane the fallback layout falls back to.
    await expect(page.getByTestId('pane')).toHaveCount(2)
    await expect(page.getByTestId('empty-pane')).toBeVisible()
  })
})

test('disabling "restore on relaunch" starts the next launch fresh, and re-enabling it resumes saving', async ({
  userDataDir
}) => {
  await withApp(userDataDir, async (app1, page1) => {
    const settingsPage1 = await openSettingsWindow(app1, page1)
    await settingsPage1.getByTestId('settings-persist-layout-checkbox').uncheck()

    await splitHorizontal(initialPane(page1))
    // Root's own wrapper, plus the split's two panes.
    await expect(page1.getByTestId('pane')).toHaveCount(3)
  })

  // The setting itself still persisted (it's a settings.json field, not the
  // layout); the layout built above should not have.
  await withApp(userDataDir, async (app2, page2) => {
    const settingsPage2 = await openSettingsWindow(app2, page2)
    await expect(settingsPage2.getByTestId('settings-persist-layout-checkbox')).not.toBeChecked()
    // Root's own wrapper plus the single empty pane the reset layout holds.
    await expect(page2.getByTestId('pane')).toHaveCount(2)
    await expect(page2.getByTestId('empty-pane')).toBeVisible()

    await settingsPage2.getByTestId('settings-persist-layout-checkbox').check()

    await splitHorizontal(initialPane(page2))
    await expect(page2.getByTestId('pane')).toHaveCount(3)
  })

  await withApp(userDataDir, async (_app3, page3) => {
    await expect(page3.getByTestId('pane')).toHaveCount(3)
  })
})

test('a layout save whose directory has vanished degrades instead of killing the app', async ({
  userDataDir
}) => {
  await withApp(userDataDir, async (app, page) => {
    // Root's own wrapper plus the single starting empty pane.
    await expect(page.getByTestId('pane')).toHaveCount(2)

    // Exactly what the suite itself used to do to an orphaned app: delete the
    // userData directory out from under a live process. saveLayout runs inside
    // a synchronous ipcMain.on listener, so before it was guarded the next
    // debounced layout:set threw ENOENT straight into Electron's C++ dispatch —
    // an uncaught main-process exception, i.e. a native error dialog that under
    // E2E_HIDDEN renders on screen with nothing able to click it.
    rmSync(userDataDir, { recursive: true, force: true })

    await splitHorizontal(initialPane(page))
    await expect(page.getByTestId('pane')).toHaveCount(3)

    // Past the renderer's 400ms save debounce, so the write has actually been
    // attempted, then prove the main process is still there and answering.
    await page.waitForTimeout(900)
    expect(await app.evaluate(() => process.type)).toBe('browser')
    await expect(page.getByTestId('pane')).toHaveCount(3)
  })
})
