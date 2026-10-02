import { writeFileSync } from 'node:fs'
import path from 'node:path'
import { createLeaf, createSplit } from '@tabs/plugin-sdk/shared/model/factories'
import { ORPHAN_GRACE_MS } from '../packages/plugin-terminal/shared/orphans'
import { LAYOUT_VERSION } from '../src/shared/layout'
import { expect, test, withApp } from './helpers/launch'
import { initialPane, splitHorizontal } from './helpers/pane'
import { seedSettingsFile } from './helpers/settings'
import { alive, openTerminal } from './helpers/terminal'
import { openNewPaneTreeWindow, windowContentBounds } from './helpers/windows'

// Multi-window lifecycle (issue #17): a second pane-tree window has its own
// layout, and every window is restored across a relaunch. The cross-window
// drag itself is covered in cross-window-drag.spec.ts.
test('a second pane-tree window gets its own independent layout, and both survive a relaunch', async ({
  userDataDir
}) => {
  seedSettingsFile(userDataDir, { persistLayoutOnExit: true })
  await withApp(userDataDir, async (app1, page1) => {
    // A split gives window 1 a pane count (3: the root's wrapper plus two
    // children) distinct from a fresh window's, so the two are telling apart
    // after a relaunch whatever order BrowserWindow reports them in.
    await splitHorizontal(initialPane(page1))
    await expect(page1.getByTestId('pane')).toHaveCount(3)

    const page2 = await openNewPaneTreeWindow(app1, page1)
    // Its own single empty pane, not a copy of window 1's layout.
    await expect(page2.getByTestId('pane')).toHaveCount(2)
    await expect(page2.getByTestId('empty-pane')).toBeVisible()

    expect(app1.windows()).toHaveLength(2)

    // Cascaded off the first, not on top of it (see cascadePosition).
    const bounds1 = await windowContentBounds(app1, page1)
    const bounds2 = await windowContentBounds(app1, page2)
    expect([bounds2.x, bounds2.y]).not.toEqual([bounds1.x, bounds1.y])
  })

  await withApp(userDataDir, async (app2, _page2) => {
    await expect.poll(() => app2.windows().length).toBe(2)
    const pages = app2.windows()
    await Promise.all(pages.map((page) => expect(page.getByTestId('pane').first()).toBeVisible()))
    const paneCounts = await Promise.all(pages.map((page) => page.getByTestId('pane').count()))
    // Order between the windows isn't guaranteed: compare the multiset.
    expect(paneCounts.sort()).toEqual([2, 3])
  })
})

test('closing the last window and quitting later still restores it, and never resurrects the pre-multi-window layout', async ({
  userDataDir
}) => {
  // What builds before multi-window support left on disk: a bare snapshot
  // at layout.json — a horizontal split, i.e. 3 panes once loaded.
  const legacyRoot = createSplit('horizontal', [createLeaf('empty'), createLeaf('empty')])
  writeFileSync(
    path.join(userDataDir, 'layout.json'),
    JSON.stringify({
      version: LAYOUT_VERSION,
      root: legacyRoot,
      activePaneId: legacyRoot.children[0]!.id
    })
  )

  seedSettingsFile(userDataDir, { persistLayoutOnExit: true })
  await withApp(userDataDir, async (_app1, page1) => {
    await expect(page1.getByTestId('pane')).toHaveCount(3)
    // One more split, so the relaunch can tell "restored" (4) from
    // "re-migrated the old file" (3) and "started fresh" (2). The save is
    // debounced 400ms — give it that before the window goes.
    await splitHorizontal(page1.getByTestId('pane').nth(1))
    await expect(page1.getByTestId('pane')).toHaveCount(4)
    await page1.waitForTimeout(600)

    // Close the window, not the app: withApp's own close is the quit that
    // follows. The window's 'closed' fires before any before-quit, the
    // ordering that used to forget the layout.
    await page1.close()
  })

  await withApp(userDataDir, async (app2, page2) => {
    await expect.poll(() => app2.windows().length).toBe(1)
    await expect(page2.getByTestId('pane')).toHaveCount(4)
  })
})

test('closing a window while another stays open ends the shells it held', async ({
  page,
  electronApp
}) => {
  // Its panes are gone for good — nothing can remount them — so a shell left
  // running would be unreachable until quit, then turn up in the quit dialog.
  const page2 = await openNewPaneTreeWindow(electronApp, page)
  const term = await openTerminal(initialPane(page2))
  const pid = Number(await term.getAttribute('data-pty-pid'))

  await page2.close()

  // After the grace a pty gets in case another window is about to claim it.
  await expect.poll(() => alive(electronApp, pid), { timeout: ORPHAN_GRACE_MS + 5000 }).toBe(false)
})

test('closing the last window ends its shell too, and New Window brings the window back on a fresh one', async ({
  userDataDir
}) => {
  // The last window used to be exempt: its close neither asked nor ended
  // anything, keeping the shells for a reactivate to reattach — so a running
  // process ran on unseen until the quit dialog listed it. Now it ends like
  // any window's, and only the layout is kept.
  test.skip(process.platform !== 'darwin', 'closing the last window quits elsewhere')
  await withApp(userDataDir, async (app, page) => {
    const term = await openTerminal(initialPane(page))
    const pid = await term.getAttribute('data-pty-pid')
    await page.waitForTimeout(600)
    // Through BrowserWindow.close(), which asks the close guard, as the
    // traffic light does; Playwright's page.close() goes around it.
    await app.evaluate(({ BrowserWindow }) => {
      for (const win of BrowserWindow.getAllWindows()) win.close()
    })
    await expect.poll(() => app.windows().length).toBe(0)
    await expect
      .poll(() => alive(app, Number(pid)), { timeout: ORPHAN_GRACE_MS + 5000 })
      .toBe(false)

    await app.evaluate(({ Menu }) => {
      const find = (items: Electron.MenuItem[]): Electron.MenuItem | undefined => {
        for (const item of items) {
          if (item.label === 'New Window') return item
          const found = item.submenu ? find(item.submenu.items) : undefined
          if (found) return found
        }
        return undefined
      }
      find(Menu.getApplicationMenu()?.items ?? [])?.click(undefined, undefined, undefined)
    })

    // The kept layout, its terminal pane on a new shell.
    await expect.poll(() => app.windows().length).toBe(1)
    const restored = app.windows()[0]!.getByTestId('terminal')
    await expect(restored).toHaveAttribute('data-pty-pid', /^\d+$/)
    expect(await restored.getAttribute('data-pty-pid')).not.toBe(pid)
  })
})

test('a window cascaded off a small window near the screen edge still fits on screen', async ({
  page,
  electronApp
}) => {
  // The cascade checked whether its *anchor's* size would overflow the
  // display, but a new window is always full size: off a small window near
  // the right edge it was placed without wrapping and hung off the screen.
  const workArea = await electronApp.evaluate(({ BrowserWindow, screen }, url) => {
    const area = screen.getPrimaryDisplay().workArea
    BrowserWindow.getAllWindows()
      .find((candidate) => candidate.webContents.getURL() === url)
      ?.setBounds({ x: area.x + area.width - 640, y: area.y + 40, width: 600, height: 400 })
    return area
  }, page.url())

  const page2 = await openNewPaneTreeWindow(electronApp, page)

  const bounds = await electronApp.evaluate(
    ({ BrowserWindow }, url) =>
      BrowserWindow.getAllWindows()
        .find((candidate) => candidate.webContents.getURL() === url)
        ?.getBounds(),
    page2.url()
  )
  if (!bounds) throw new Error('the new window has no bounds')
  expect(bounds.x).toBeGreaterThanOrEqual(workArea.x)
  expect(bounds.x + bounds.width).toBeLessThanOrEqual(workArea.x + workArea.width)
  expect(bounds.y + bounds.height).toBeLessThanOrEqual(workArea.y + workArea.height)
})

test('two windows closed together both end their shells, the one closing last included', async ({
  userDataDir
}) => {
  // Both closes go through the guard concurrently, and whichever finishes
  // last is the last window's close — which ends its shells like the other.
  test.skip(process.platform !== 'darwin', 'closing the last window quits elsewhere')
  await withApp(userDataDir, async (app, page) => {
    const pid = await (await openTerminal(initialPane(page))).getAttribute('data-pty-pid')
    const page2 = await openNewPaneTreeWindow(app, page)
    const pid2 = await (await openTerminal(initialPane(page2))).getAttribute('data-pty-pid')

    // Through BrowserWindow.close(), which asks the close guard, as the
    // traffic light does; Playwright's page.close() goes around it.
    await app.evaluate(({ BrowserWindow }) => {
      for (const win of BrowserWindow.getAllWindows()) win.close()
    })
    await expect.poll(() => app.windows().length).toBe(0)

    await expect
      .poll(async () => [await alive(app, Number(pid)), await alive(app, Number(pid2))], {
        timeout: ORPHAN_GRACE_MS + 5000
      })
      .toEqual([false, false])
  })
})
