import { execFileSync } from 'node:child_process'
import type { ElectronApplication } from 'playwright'
import type { CaffeinateFlags } from '../src/shared/api'
import { expect, test, withApp } from './helpers/launch'
import { clickMenuItem, hasMenuItem } from './helpers/menu'
import { initialPane, splitHorizontal } from './helpers/pane'
import { isAlive } from './helpers/terminal'
import { openNewPaneTreeWindow } from './helpers/windows'

// macOS only, real /usr/bin/caffeinate throughout — no stand-in. The feature
// itself is macOS-only (see main/menu.ts, main/caffeinate.ts), so there's no
// portability loss in that choice, and it's the only way to prove the actual
// spawn/exit/kill wiring this ticket is about: a fake binary would pass a
// broken exit-detection path just as cleanly as a correct one. Every "is it
// really running" check here goes by the OS pid `__tabsE2e.caffeinatePid()`
// exposes, never by process name — this Mac can easily have an unrelated
// caffeinate already running (CLAUDE.md's "several checkouts at once" entry
// is exactly this class of bug), so `pgrep -f caffeinate` would be a
// machine-global lie.

/**
 * The managed process's live pid, asserted to be a real one — never `pid 0`,
 * which `process.kill` always treats as "signal my own process group" and so
 * would make `isAlive` lie `true` if `caffeinatePid()` ever answered
 * undefined instead of failing loudly right here.
 */
async function livePid(electronApp: ElectronApplication): Promise<number> {
  const pid = await electronApp.evaluate(() => globalThis.__tabsE2e?.caffeinatePid())
  expect(pid).toBeGreaterThan(0)
  return pid as number
}

/**
 * The real process's own argv, as the OS itself reports it — proves the
 * flags the dialog collected actually reached the spawned binary, not just
 * that *some* process is running under that pid (a pid check alone would
 * pass identically for a caffeinate started with every flag wrong).
 */
function argvOf(pid: number): string {
  return execFileSync('ps', ['-o', 'args=', '-p', String(pid)], { encoding: 'utf8' })
}

/**
 * Starts the managed process directly in main, bypassing the renderer and
 * its IPC round trip — the same reasoning `mergeSettings` bypasses the
 * Settings window with. Most of the tests below are about Decaf, the cup
 * button, a timer, or quitting, not about re-proving the Start button's IPC
 * path a second time; the first test covers that once, through the real
 * dialog.
 */
function startForTests(electronApp: ElectronApplication, flags: CaffeinateFlags): Promise<void> {
  return electronApp.evaluate((_electron, f) => {
    globalThis.__tabsE2e?.startCaffeinateForTests(f)
  }, flags)
}

const ALL_OFF: CaffeinateFlags = {
  preventDisplaySleep: false,
  preventIdleSleep: false,
  preventDiskSleep: false,
  preventSystemSleep: false,
  declareUserActive: false
}

test('File → Caffeinate… opens the dialog, and Start launches the real process with the selected flags', async ({
  page,
  electronApp
}) => {
  test.skip(process.platform !== 'darwin', 'caffeinate is macOS-only')
  // installCaffeinate's onOpenDialog subscription is installed by a mount
  // effect; reaching the native menu before the renderer has painted its
  // first pane risks sending caffeinate:open-dialog into a window with no
  // subscriber yet — the same class of race keyboard-shortcuts.spec.ts's own
  // first test guards against.
  await expect(initialPane(page)).toBeVisible()

  expect(await hasMenuItem(electronApp, 'Caffeinate…')).toBe(true)
  expect(await hasMenuItem(electronApp, 'Decaf')).toBe(false)

  await clickMenuItem(electronApp, 'Caffeinate…', page)
  await expect(page.getByTestId('caffeinate-dialog')).toBeVisible()

  await page.getByTestId('caffeinate-field-display').check()
  await page.getByTestId('caffeinate-start-button').click()

  await expect(page.getByTestId('caffeinate-dialog')).not.toBeVisible()
  await expect(page.getByTestId('caffeinate-decaf-button')).toBeVisible()
  await expect.poll(() => hasMenuItem(electronApp, 'Decaf')).toBe(true)
  expect(await hasMenuItem(electronApp, 'Caffeinate…')).toBe(false)

  const pid = await livePid(electronApp)
  expect(isAlive(pid)).toBe(true)

  // The flags actually reached the real process: -i and -s from the dialog's
  // own defaults, -d from the box just checked above — never -m or -u
  // (left unchecked) or -t (no timer typed).
  const argv = argvOf(pid)
  expect(argv).toContain('-d')
  expect(argv).toContain('-i')
  expect(argv).toContain('-s')
  expect(argv).not.toContain('-m')
  expect(argv).not.toContain('-u')
  expect(argv).not.toContain('-t')

  // Clean up the real process this test started — the shared electronApp's
  // between-test reset also kills it, but leaving it running for however
  // long the rest of the file takes is needless.
  await clickMenuItem(electronApp, 'Decaf', page)
  await expect.poll(() => isAlive(pid)).toBe(false)
})

test('a timer typed into the dialog reaches the real process as -t <seconds>', async ({
  page,
  electronApp
}) => {
  test.skip(process.platform !== 'darwin', 'caffeinate is macOS-only')
  await expect(initialPane(page)).toBeVisible()

  await clickMenuItem(electronApp, 'Caffeinate…', page)
  await expect(page.getByTestId('caffeinate-dialog')).toBeVisible()
  await page.getByTestId('caffeinate-field-timer').fill('1')
  await page.getByTestId('caffeinate-start-button').click()
  await expect(page.getByTestId('caffeinate-decaf-button')).toBeVisible()

  const pid = await livePid(electronApp)
  expect(argvOf(pid)).toContain('-t 60')

  // Decaf immediately rather than waiting out the real 60-second timer.
  await clickMenuItem(electronApp, 'Decaf', page)
  await expect.poll(() => isAlive(pid)).toBe(false)
})

test('Decaf from the menu stops the real process, and both surfaces revert', async ({
  page,
  electronApp
}) => {
  test.skip(process.platform !== 'darwin', 'caffeinate is macOS-only')

  await startForTests(electronApp, ALL_OFF)
  await expect(page.getByTestId('caffeinate-decaf-button')).toBeVisible()
  const pid = await livePid(electronApp)

  await clickMenuItem(electronApp, 'Decaf', page)

  await expect.poll(() => isAlive(pid)).toBe(false)
  await expect(page.getByTestId('caffeinate-decaf-button')).not.toBeVisible()
  await expect.poll(() => hasMenuItem(electronApp, 'Caffeinate…')).toBe(true)
  expect(await hasMenuItem(electronApp, 'Decaf')).toBe(false)
})

test('clicking the title-bar cup button does the same thing as Decaf', async ({
  page,
  electronApp
}) => {
  test.skip(process.platform !== 'darwin', 'caffeinate is macOS-only')

  await startForTests(electronApp, ALL_OFF)
  await expect(page.getByTestId('caffeinate-decaf-button')).toBeVisible()
  const pid = await livePid(electronApp)

  await page.getByTestId('caffeinate-decaf-button').click()

  await expect.poll(() => isAlive(pid)).toBe(false)
  await expect(page.getByTestId('caffeinate-decaf-button')).not.toBeVisible()
})

test('the process exiting on its own (a timer) is noticed: both surfaces revert without anyone clicking Decaf', async ({
  page,
  electronApp
}) => {
  test.skip(process.platform !== 'darwin', 'caffeinate is macOS-only')

  // Seconds granularity, driven straight over the wire rather than through
  // the dialog's minutes-only field — CaffeinateFlags.timerSeconds is what
  // the protocol actually carries; the dialog's coarser unit is a UI choice
  // covered by its own jsdom test, not a wire constraint. 2s keeps this fast.
  await startForTests(electronApp, { ...ALL_OFF, timerSeconds: 2 })
  await expect(page.getByTestId('caffeinate-decaf-button')).toBeVisible()
  const pid = await livePid(electronApp)

  await expect.poll(() => isAlive(pid), { timeout: 8000 }).toBe(false)
  await expect(page.getByTestId('caffeinate-decaf-button')).not.toBeVisible()
  await expect.poll(() => hasMenuItem(electronApp, 'Caffeinate…')).toBe(true)
})

test('quitting the app stops the real process, by its own specific pid', async ({
  userDataDir
}) => {
  test.skip(process.platform !== 'darwin', 'caffeinate is macOS-only')

  const pid = await withApp(userDataDir, async (app, page) => {
    // No timer: this proves quitting stops it, as opposed to the timer test
    // above proving the process's own exit is noticed.
    await startForTests(app, ALL_OFF)
    await expect(page.getByTestId('caffeinate-decaf-button')).toBeVisible()
    return livePid(app)
    // withApp's own `finally` closes the app here — main/index.ts's
    // `before-quit` handler is what must have killed the process by the
    // time this returns, not any tab/pane-close path.
  })

  await expect.poll(() => isAlive(pid), { timeout: 3000 }).toBe(false)
})

test('crash safety: SIGKILLing Electron outright still ends the real process, via -w rather than before-quit', async ({
  userDataDir
}) => {
  test.skip(process.platform !== 'darwin', 'caffeinate is macOS-only')

  let caffeinatePid = 0
  await withApp(userDataDir, async (app, page) => {
    await startForTests(app, ALL_OFF)
    await expect(page.getByTestId('caffeinate-decaf-button')).toBeVisible()
    caffeinatePid = await livePid(app)

    // A SIGKILL never runs before-quit at all, so if anything ends
    // caffeinate after this it has to be -w's own backstop.
    const mainPid = app.process().pid
    expect(mainPid).toBeGreaterThan(0)
    process.kill(mainPid as number, 'SIGKILL')
    // withApp's own `finally` calls app.close() next, on a process this
    // already killed out from under it — must degrade rather than hang.
  })

  await expect.poll(() => isAlive(caffeinatePid), { timeout: 5000 }).toBe(false)
})

test('with two pane-tree windows open, the dialog opens in the one the menu was used from', async ({
  page,
  electronApp
}) => {
  test.skip(process.platform !== 'darwin', 'caffeinate is macOS-only')
  await expect(initialPane(page)).toBeVisible()
  // The newer window is the fallback target (see caffeinateMenuItem), so
  // using the menu from the older one is what tells the two rules apart.
  const page2 = await openNewPaneTreeWindow(electronApp, page)

  await clickMenuItem(electronApp, 'Caffeinate…', page)

  await expect(page.getByTestId('caffeinate-dialog')).toBeVisible()
  await expect(page2.getByTestId('caffeinate-dialog')).toHaveCount(0)
  await page.getByTestId('caffeinate-cancel-button').click()
})

test('the menu reopens the last window closed, layout intact, and opens the dialog there', async ({
  userDataDir
}) => {
  test.skip(process.platform !== 'darwin', 'caffeinate is macOS-only')

  await withApp(userDataDir, async (app, page) => {
    // A split tells the window that comes back from a fresh one: 3 panes (the
    // root's wrapper and two children) against a fresh window's 2. The save
    // is debounced 400ms, and destroy() runs no beforeunload flush.
    await splitHorizontal(initialPane(page))
    await expect(page.getByTestId('pane')).toHaveCount(3)
    await page.waitForTimeout(600)

    // Destroy the only window while keeping the app alive — macOS keeps
    // running with no windows open, which is exactly the state File →
    // Caffeinate… has to recover from.
    await app.evaluate(({ BrowserWindow }) => {
      for (const win of BrowserWindow.getAllWindows()) win.destroy()
    })
    await expect
      .poll(() => app.evaluate(({ BrowserWindow }) => BrowserWindow.getAllWindows().length))
      .toBe(0)

    const newWindow = app.waitForEvent('window')
    // Not clickMenuItem: that helper takes a target Page to resolve which
    // BrowserWindow the click's own `window` argument names, and there is no
    // live page left to give it — with no pane-tree window open,
    // caffeinateMenuItem's click handler opens one whatever the argument
    // names (see its own comment in main/menu.ts).
    await app.evaluate(({ Menu }) => {
      function find(items: Electron.MenuItem[]): Electron.MenuItem | undefined {
        for (const item of items) {
          if (item.label === 'Caffeinate…') return item
          if (item.submenu) {
            const found = find(item.submenu.items)
            if (found) return found
          }
        }
        return undefined
      }
      const item = find(Menu.getApplicationMenu()?.items ?? [])
      if (!item) throw new Error('Caffeinate… menu item not found')
      item.click(undefined, undefined, undefined)
    })

    const newPage = await newWindow
    await expect(newPage.getByTestId('caffeinate-dialog')).toBeVisible()
    // The last window's layout, as a Dock reactivate would bring back — not
    // a fresh window, which would also have discarded it (see layout.ts).
    await expect(newPage.getByTestId('pane')).toHaveCount(3)
    // Clean up: leaving the dialog open is harmless, but Cancel is one line.
    await newPage.getByTestId('caffeinate-cancel-button').click()
  })
})
