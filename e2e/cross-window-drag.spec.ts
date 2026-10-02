import { mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import path from 'node:path'
import { REATTACH_GRACE_MS } from '@tabs/plugin-sdk/shared/reattach'
import { ORPHAN_GRACE_MS } from '../packages/plugin-terminal/shared/orphans'
import type { Api } from '../src/shared/api'
import { createAgentPane, openAgentSession, runTabsCtl } from './helpers/agentSession'
import { dataPage, navigateTo, openBrowser } from './helpers/browser'
import { grabAndHover } from './helpers/drag'
import { requireBox } from './helpers/geometry'
import { guestEval } from './helpers/guest'
import { expect, test, withApp } from './helpers/launch'
import {
  activatePane,
  headerOf,
  initialPane,
  openNewTab,
  paneOf,
  splitHorizontal,
  wrapInTabGroup
} from './helpers/pane'
import { openSettingsWindow, seedSettingsFile } from './helpers/settings'
import { alive, openTerminal, terminalWithPid, typeAndEnter } from './helpers/terminal'
import {
  engageCrossWindowDrag,
  holdRendererBusy,
  hoverIntoWindow,
  OFFSCREEN_POINT,
  onWindowOf,
  openNewPaneTreeWindow,
  placeWindowsSideBySide,
  setCrossWindowCursorPoint,
  windowContentBounds
} from './helpers/windows'

// Dragging a pane out of one pane-tree window into another (issue #17). A
// real drag across two OS windows cannot be produced here: OS mouse capture
// routes every pointer event to the window that received the press, and
// Playwright drives each window as a separate CDP target. So each test
// engages a real gesture in the source, feeds main's cursor poll a fake
// point (`hoverIntoWindow`), and releases in the source — the real poll,
// hit-test and relay, never a faked event in the destination's DOM. Tests
// that want a hover in the other window lay the windows side by side first;
// the two that keep them overlapping are about the source-wins rule.

test('dragging a terminal pane into another window moves it there, live process and scrollback intact', async ({
  userDataDir
}) => {
  seedSettingsFile(userDataDir, { persistLayoutOnExit: true })
  const pidBefore = await withApp(userDataDir, async (app1, page1) => {
    const term1 = await openTerminal(initialPane(page1))
    const pid = Number(await term1.getAttribute('data-pty-pid'))
    await typeAndEnter(term1, 'echo before-cross-window-drag')
    await expect(term1).toContainText('before-cross-window-drag')

    const page2 = await openNewPaneTreeWindow(app1, page1)
    await placeWindowsSideBySide(app1, page1, page2)
    await hoverIntoWindow(app1, headerOf(initialPane(page1)), page2, initialPane(page2))
    await page1.mouse.up()

    // Same pid, same scrollback in B; A's pane back to empty.
    const termB = page2.getByTestId('terminal')
    await expect(termB).toHaveAttribute('data-pty-pid', String(pid))
    await expect(termB).toContainText('before-cross-window-drag')
    await expect(page1.getByTestId('empty-pane')).toBeVisible()
    await expect(page1.getByTestId('terminal')).toHaveCount(0)

    // Reattached, not respawned: outlives the disposal grace period and
    // still accepts input.
    await page2.waitForTimeout(REATTACH_GRACE_MS * 2)
    expect(await alive(app1, pid)).toBe(true)
    await typeAndEnter(termB, 'echo still-alive-in-window-b')
    await expect(termB).toContainText('still-alive-in-window-b')

    return pid
  })

  // Persisted on both sides: after a relaunch B has the terminal, A is empty.
  await withApp(userDataDir, async (app2, _page2) => {
    await expect.poll(() => app2.windows().length).toBe(2)
    const pages = app2.windows()
    await Promise.all(pages.map((page) => expect(page.getByTestId('pane').first()).toBeVisible()))
    const terminalCounts = await Promise.all(
      pages.map((page) => page.getByTestId('terminal').count())
    )
    // Sorted as a copy: the index below must still match `pages`.
    expect([...terminalCounts].sort()).toEqual([0, 1])
    const withTerminal = pages[terminalCounts.indexOf(1)]
    if (withTerminal) {
      const term = withTerminal.getByTestId('terminal')
      await expect(term).toHaveAttribute('data-pty-pid', /^\d+$/)
      const pidAfter = await term.getAttribute('data-pty-pid')
      // A fresh shell: the old process was killed on quit.
      expect(pidAfter).not.toBe(String(pidBefore))
    }
  })
})

test('a real local dock target in the source always wins over an overlapping window, even at the exact same screen point', async ({
  page,
  electronApp
}) => {
  // The target pane needs real content: an empty pane resolves to an
  // 'empty-pane' target with its own highlight, not dock-preview. Split
  // leaves the new pane empty, so the terminal goes in the original first.
  const term = await openTerminal(initialPane(page))
  await splitHorizontal(initialPane(page))
  const panes = page.getByTestId('pane')
  const paneCount = await panes.count()
  const targetPane = panes.nth(paneCount - 2)
  const sourcePane = panes.nth(paneCount - 1)
  await expect(term).toBeVisible()

  const page2 = await openNewPaneTreeWindow(electronApp, page)
  const bounds1 = await windowContentBounds(electronApp, page)

  const targetBox = await requireBox(targetPane)
  const targetX = targetBox.x + targetBox.width / 2
  const targetY = targetBox.y + targetBox.height / 2
  // B cascades only slightly off A, so this point is inside B's bounds too.
  await setCrossWindowCursorPoint(electronApp, { x: bounds1.x + targetX, y: bounds1.y + targetY })

  await grabAndHover(headerOf(sourcePane), targetX, targetY)

  // Inside its own bounds the source is the window on top: it previews, and
  // B never becomes a hover candidate.
  await expect(page.getByTestId('dock-preview')).toBeVisible()
  await expect(page2.getByTestId('dock-preview')).toHaveCount(0)
  await expect(page.locator('.drag-ghost')).toBeVisible()

  await page.mouse.up()

  // Landed locally in A; B still shows its untouched single-pane layout.
  await expect(page2.getByTestId('pane').first()).toBeVisible()
  await expect(page2.getByTestId('empty-pane')).toBeVisible()
  expect(await page2.getByTestId('pane').count()).toBe(2)
})

test('a browser pane dragged into another window is usable there at the same URL', async ({
  userDataDir
}) => {
  await withApp(userDataDir, async (app1, page1) => {
    // Not about:blank: every new browser pane starts there, so it could not
    // show the URL was carried.
    const url = dataPage('Carried across')
    await openBrowser(initialPane(page1))
    await navigateTo(initialPane(page1), url)
    await expect.poll(() => guestEval(app1, 'document.title')).toBe('Carried across')

    const page2 = await openNewPaneTreeWindow(app1, page1)
    await placeWindowsSideBySide(app1, page1, page2)
    // The grip, not the header's center: a browser pane's header is its
    // address bar, which correctly refuses to arm a drag.
    const grip = headerOf(initialPane(page1)).locator('.pane-grip')
    await hoverIntoWindow(app1, grip, page2, initialPane(page2))
    await page1.mouse.up()

    // A fresh guest at the same URL: a <webview> cannot survive any DOM
    // reparent (see browserGuestRegistry.ts).
    await expect(page2.locator('webview')).toHaveCount(1)
    await expect(page2.locator('webview')).toHaveJSProperty('src', url)
    await expect(page1.locator('webview')).toHaveCount(0)
    await expect.poll(() => guestEval(app1, 'document.title')).toBe('Carried across')

    // And it still navigates where it landed.
    await navigateTo(initialPane(page2), dataPage('Landed'))
    await expect.poll(() => guestEval(app1, 'document.title')).toBe('Landed')
  })
})

test("a browser pane moved into another window stays wired to its page past the source's grace period", async ({
  userDataDir
}) => {
  // The source's reattach cache disposes the old instance a grace period
  // after the move, and that disposal reports the pane detached. Taken at its
  // word, it wiped the guest mapping the destination had just reported, and
  // everything main resolves a pane through — click-to-activate here,
  // network capture and popup ownership elsewhere — went dead.
  await withApp(userDataDir, async (app1, page1) => {
    await openBrowser(initialPane(page1))
    const page2 = await openNewPaneTreeWindow(app1, page1)
    // A second pane in B to activate away to, and back from by a click.
    await splitHorizontal(initialPane(page2))
    const panesB = page2.getByTestId('pane')
    await placeWindowsSideBySide(app1, page1, page2)
    const grip = headerOf(initialPane(page1)).locator('.pane-grip')
    await hoverIntoWindow(app1, grip, page2, panesB.nth(2))
    await page1.mouse.up()
    await expect(page2.locator('webview')).toHaveCount(1)
    await page2.waitForTimeout(REATTACH_GRACE_MS * 3)

    await activatePane(panesB.nth(1))
    await expect(panesB.nth(1)).toHaveClass(/pane-active/)
    const page = await requireBox(page2.getByTestId('browser'))
    await page2.mouse.click(page.x + page.width / 2, page.y + page.height / 2)
    await expect(panesB.nth(2)).toHaveClass(/pane-active/)
  })
})

test('releasing a cross-window drag over the gap between windows flies it home, and both windows keep working', async ({
  page,
  electronApp
}) => {
  const term = await openTerminal(initialPane(page))
  const pid = await term.getAttribute('data-pty-pid')
  const page2 = await openNewPaneTreeWindow(electronApp, page)
  await placeWindowsSideBySide(electronApp, page, page2)
  await hoverIntoWindow(electronApp, headerOf(initialPane(page)), page2, initialPane(page2))

  // Into the gap placeWindowsSideBySide leaves between the two: in neither
  // window, so B's hover ends and the release is a plain fly-back.
  const left = await windowContentBounds(electronApp, page)
  const right = await windowContentBounds(electronApp, page2)
  await setCrossWindowCursorPoint(electronApp, {
    x: (left.x + left.width + right.x) / 2,
    y: right.y + right.height / 2
  })
  await expect(page2.locator('.empty-pane-drop-target')).toHaveCount(0)
  await page.mouse.up()

  await expect(page.locator('.drag-ghost')).toHaveCount(0)
  await expect(term).toHaveAttribute('data-pty-pid', pid ?? '')
  await expect(page2.getByTestId('terminal')).toHaveCount(0)
  await expect(page2.getByTestId('empty-pane')).toBeVisible()

  // Nothing left stuck on either side: the same drag, finished this time.
  await hoverIntoWindow(electronApp, headerOf(initialPane(page)), page2, initialPane(page2))
  await page.mouse.up()
  await expect(page2.getByTestId('terminal')).toHaveAttribute('data-pty-pid', pid ?? '')
  expect(await alive(electronApp, Number(pid))).toBe(true)
})

test('a release no window saw cancels a drag cleanly, and the window keeps working', async ({
  page,
  electronApp
}) => {
  const term = await openTerminal(initialPane(page))
  const pid = await term.getAttribute('data-pty-pid')

  const headerBox = await requireBox(headerOf(initialPane(page)))
  await grabAndHover(
    headerOf(initialPane(page)),
    headerBox.x + headerBox.width / 2 + 40,
    headerBox.y + headerBox.height / 2 + 20
  )
  await expect(page.locator('.drag-ghost')).toBeVisible()

  // A release neither window saw, simulated as floating.spec.ts does: the
  // next pointermove carries no button. No second window exists, so main's
  // poll has nothing to hover whatever the real cursor does.
  await page.evaluate(() => {
    window.dispatchEvent(
      new PointerEvent('pointermove', { pointerId: 1, clientX: 40, clientY: 40, buttons: 0 })
    )
  })

  // Cancelled, not committed, and not stuck: a fresh drag still works.
  await expect(page.locator('.drag-ghost')).toHaveCount(0)
  await expect(term).toBeVisible()
  await expect(term).toHaveAttribute('data-pty-pid', pid ?? '')

  await grabAndHover(headerOf(initialPane(page)), 40, 400)
  await expect(page.locator('.drag-ghost')).toBeVisible()
  await page.mouse.up()

  await expect(await term.getAttribute('data-pty-pid')).toBe(pid)
  expect(await alive(electronApp, Number(pid))).toBe(true)
})

test('closing the source window mid-drag leaves neither the other window nor main stuck', async ({
  userDataDir
}) => {
  await withApp(userDataDir, async (app, page1) => {
    await openTerminal(initialPane(page1))
    const page2 = await openNewPaneTreeWindow(app, page1)
    await setCrossWindowCursorPoint(app, OFFSCREEN_POINT)

    // Engage in A, then close A before anything releases: main's
    // window-closed hook has to recover, since A can send nothing.
    const headerBox = await requireBox(headerOf(initialPane(page1)))
    await grabAndHover(
      headerOf(initialPane(page1)),
      headerBox.x + headerBox.width / 2 + 40,
      headerBox.y + headerBox.height / 2 + 20
    )
    await page1.close()

    // B can still complete a fresh cross-window drag of its own — if main's
    // one pending-drag slot were still held by A's, the arm would be refused.
    await openTerminal(initialPane(page2))
    const page3 = await openNewPaneTreeWindow(app, page2)
    await placeWindowsSideBySide(app, page2, page3)
    await hoverIntoWindow(app, headerOf(initialPane(page2)), page3, initialPane(page3))
    await page2.mouse.up()

    await expect(page3.getByTestId('terminal')).toHaveCount(1)
    await expect(page2.getByTestId('terminal')).toHaveCount(0)
  })
})

test('closing the destination window while it holds the live hover leaves the source usable, not stuck', async ({
  page,
  electronApp
}) => {
  const term = await openTerminal(initialPane(page))
  const pid = await term.getAttribute('data-pty-pid')
  const page2 = await openNewPaneTreeWindow(electronApp, page)
  await placeWindowsSideBySide(electronApp, page, page2)
  await hoverIntoWindow(electronApp, headerOf(initialPane(page)), page2, initialPane(page2))

  // Close B while it holds the hover and A's pointer is still down: main's
  // window-closed hook is all that can tell A the drag is over.
  await page2.close()

  // A's ghost comes down by broadcast cancel, the terminal never left, and
  // a fresh local drag works at once.
  await expect(page.locator('.drag-ghost')).toHaveCount(0)
  await expect(term).toBeVisible()
  await expect(term).toHaveAttribute('data-pty-pid', pid ?? '')

  await grabAndHover(headerOf(initialPane(page)), 40, 400)
  await expect(page.locator('.drag-ghost')).toBeVisible()
  await page.mouse.up()
  expect(await alive(electronApp, Number(pid))).toBe(true)
})

test('a destination that crashes before answering the insert gives the pane back to the source', async ({
  userDataDir
}) => {
  // The source has already detached by the time the destination is asked to
  // insert. A crashed renderer never answers, and the relay used to wait for
  // it forever: no rollback, the source's ghost held, and the source's next
  // save persisting a tree without the pane.
  await withApp(userDataDir, async (app1, page1) => {
    const term = await openTerminal(initialPane(page1))
    const pid = await term.getAttribute('data-pty-pid')
    const page2 = await openNewPaneTreeWindow(app1, page1)
    await placeWindowsSideBySide(app1, page1, page2)
    await hoverIntoWindow(app1, headerOf(initialPane(page1)), page2, initialPane(page2))

    // B busy, so the insert sits unanswered until B is crashed under it.
    holdRendererBusy(page2, 3000)
    await page1.waitForTimeout(150)
    await page1.mouse.up()
    await expect(page1.getByTestId('terminal')).toHaveCount(0)
    await onWindowOf(app1, page2, 'crash')

    await expect(page1.getByTestId('terminal')).toHaveAttribute('data-pty-pid', pid ?? '')
    await expect(page1.locator('.drag-ghost')).toHaveCount(0)
    expect(await alive(app1, Number(pid))).toBe(true)
    // Back in the slot it left, not in a second tab beside a placeholder.
    await expect(page1.getByRole('tablist').first().getByRole('tab')).toHaveCount(1)
    await expect(page1.getByTestId('empty-pane')).toHaveCount(0)
  })
})

test('a destination reloaded before answering the insert leaves the pane in exactly one window', async ({
  userDataDir
}) => {
  // An invariant rather than a regression pin: here the old document handles
  // the queued insert before it unloads (this passes without the reload
  // refusal in relayTo, which is for a request lost with the document it
  // went to). Whichever happens, the pane ends up in one window, on its pty.
  await withApp(userDataDir, async (app1, page1) => {
    const term = await openTerminal(initialPane(page1))
    const pid = await term.getAttribute('data-pty-pid')
    const page2 = await openNewPaneTreeWindow(app1, page1)
    await placeWindowsSideBySide(app1, page1, page2)
    await hoverIntoWindow(app1, headerOf(initialPane(page1)), page2, initialPane(page2))

    holdRendererBusy(page2, 1500)
    await page1.waitForTimeout(150)
    await page1.mouse.up()
    await expect(page1.getByTestId('terminal')).toHaveCount(0)
    await onWindowOf(app1, page2, 'reload')

    const withPid = (page: typeof page1) => terminalWithPid(page, pid).count()
    await expect
      .poll(async () => (await withPid(page1)) + (await withPid(page2)), { timeout: 10_000 })
      .toBe(1)
    await page1.waitForTimeout(REATTACH_GRACE_MS * 2)
    expect((await withPid(page1)) + (await withPid(page2))).toBe(1)
    await expect(page1.locator('.drag-ghost')).toHaveCount(0)
    expect(await alive(app1, Number(pid))).toBe(true)
  })
})

test('closing the source while the destination is still inserting keeps the moving shell, and does not bring the source back at relaunch', async ({
  userDataDir
}) => {
  // Two things went wrong here. The source's close drops its layout (another
  // window stays open), and the insert's success, landing after that, used to
  // record the source's post-detach snapshot again — so the next launch
  // reopened a window the user had closed. And that close ends the closed
  // window's shells — including, before the orphan grace, the one in transit,
  // still hosted by the source until the destination mounts it: the pane
  // arrived looking intact (its scrollback travels) on a fresh shell.
  seedSettingsFile(userDataDir, { persistLayoutOnExit: true })
  await withApp(userDataDir, async (app1, page1) => {
    const term = await openTerminal(initialPane(page1))
    const pid = await term.getAttribute('data-pty-pid')
    const page2 = await openNewPaneTreeWindow(app1, page1)
    await placeWindowsSideBySide(app1, page1, page2)
    await hoverIntoWindow(app1, headerOf(initialPane(page1)), page2, initialPane(page2))

    holdRendererBusy(page2, 2000)
    await page1.waitForTimeout(150)
    await page1.mouse.up()
    await expect(page1.getByTestId('terminal')).toHaveCount(0)
    await page1.close()

    await expect(page2.getByTestId('terminal')).toHaveAttribute('data-pty-pid', pid ?? '', {
      timeout: 10_000
    })
    await page2.waitForTimeout(ORPHAN_GRACE_MS + 1000)
    expect(await alive(app1, Number(pid))).toBe(true)
  })

  await withApp(userDataDir, async (app2, page2) => {
    await expect(page2.getByTestId('terminal')).toHaveCount(1)
    expect(app2.windows()).toHaveLength(1)
  })
})

test('dragging one tab out of a multi-tab group into another window moves just that tab', async ({
  page,
  electronApp
}) => {
  const term = await openTerminal(initialPane(page))
  await typeAndEnter(term, 'echo cross-window-tab-drag')
  await expect(term).toContainText('cross-window-tab-drag')
  const pid = await term.getAttribute('data-pty-pid')

  // "New Tab" clones the origin's type, so this is a second, different
  // terminal that stays behind while the first tab travels alone.
  await openNewTab(initialPane(page))
  const tabs = page.getByRole('tablist').getByRole('tab')
  await expect(tabs).toHaveCount(2)
  await tabs.first().click()
  await expect(term).toBeVisible()

  const page2 = await openNewPaneTreeWindow(electronApp, page)
  await placeWindowsSideBySide(electronApp, page, page2)
  await hoverIntoWindow(electronApp, tabs.first(), page2, initialPane(page2))
  await page.mouse.up()

  // Only the dragged tab moved: B runs its terminal, A keeps the other one.
  const termB = page2.getByTestId('terminal')
  await expect(termB).toHaveAttribute('data-pty-pid', String(pid))
  await expect(termB).toContainText('cross-window-tab-drag')
  await expect(tabs).toHaveCount(1)
  const termA = page.getByTestId('terminal')
  await expect(termA).toBeVisible()
  await expect(termA).not.toHaveAttribute('data-pty-pid', String(pid))
})

test('a window hidden behind the source never receives the drop', async ({ page, electronApp }) => {
  // The windows stay where they land, B almost entirely under A. Releasing
  // over A's own dragged pane resolves no local target (a pane can't dock
  // into itself) — an in-window fly-back — and without the source-wins rule
  // that release committed the pane into the window the user couldn't see.
  const term = await openTerminal(initialPane(page))
  const pid = await term.getAttribute('data-pty-pid')
  const page2 = await openNewPaneTreeWindow(electronApp, page)
  const bounds1 = await windowContentBounds(electronApp, page)
  const bounds2 = await windowContentBounds(electronApp, page2)

  const paneBox = await requireBox(initialPane(page))
  const overSelfX = paneBox.x + paneBox.width / 2
  const overSelfY = paneBox.y + paneBox.height / 2
  const screenPoint = { x: bounds1.x + overSelfX, y: bounds1.y + overSelfY }
  // The premise: this point is inside both windows.
  expect(screenPoint.x).toBeGreaterThanOrEqual(bounds2.x)
  expect(screenPoint.x).toBeLessThan(bounds2.x + bounds2.width)
  expect(screenPoint.y).toBeGreaterThanOrEqual(bounds2.y)
  expect(screenPoint.y).toBeLessThan(bounds2.y + bounds2.height)
  await setCrossWindowCursorPoint(electronApp, screenPoint)

  await grabAndHover(headerOf(initialPane(page)), overSelfX, overSelfY)
  await expect(page.locator('.drag-ghost')).toBeVisible()
  // Enough poll ticks for B to have been hovered, if it ever would be.
  await page.waitForTimeout(200)
  await expect(page2.getByTestId('dock-preview')).toHaveCount(0)
  await expect(page2.locator('.drag-ghost')).toHaveCount(0)

  await page.mouse.up()

  // Flew back: the terminal is still A's, and B is untouched.
  await expect(page.locator('.drag-ghost')).toHaveCount(0)
  await expect(term).toBeVisible()
  await expect(term).toHaveAttribute('data-pty-pid', pid ?? '')
  await expect(page2.getByTestId('terminal')).toHaveCount(0)
  await expect(page2.getByTestId('empty-pane')).toBeVisible()
})

test('dragging a tab group holding two terminals into another window keeps both shells alive', async ({
  page,
  electronApp
}) => {
  // Every terminal in a dragged group has to be primed for the move, not
  // only a bare-leaf subject; priming one left the rest on the ordinary
  // unmount path, whose grace-period disposal killed the ptys B had
  // reattached. This pins the outcome, which two layers now guarantee —
  // that priming, and main refusing a dispose from a window that no longer
  // hosts the pty (disposeTerminalFrom) — so it passes if either holds; the
  // priming itself is pinned in content/__tests__/crossWindowDrag.test.tsx.
  await openTerminal(initialPane(page))
  await wrapInTabGroup(initialPane(page))
  // Root's wrapper, the nested group, its one terminal leaf.
  const nestedGroup = page.getByTestId('pane').nth(1)
  await expect(headerOf(nestedGroup).getByRole('tablist')).toBeVisible()
  // The strip's "+" clones the active tab's type — a second terminal.
  await headerOf(nestedGroup).getByTestId('tab-strip-new-tab-button').click()
  const terminals = page.getByTestId('terminal')
  await expect(terminals).toHaveCount(2)
  await expect(terminals.nth(0)).toHaveAttribute('data-pty-pid', /^\d+$/)
  await expect(terminals.nth(1)).toHaveAttribute('data-pty-pid', /^\d+$/)
  const pids = [
    Number(await terminals.nth(0).getAttribute('data-pty-pid')),
    Number(await terminals.nth(1).getAttribute('data-pty-pid'))
  ].sort()

  const page2 = await openNewPaneTreeWindow(electronApp, page)
  await placeWindowsSideBySide(electronApp, page, page2)
  const grip = headerOf(nestedGroup).locator('.pane-grip')
  await hoverIntoWindow(electronApp, grip, page2, initialPane(page2))
  await page.mouse.up()

  // Both arrived on the same ptys.
  const terminalsB = page2.getByTestId('terminal')
  await expect(terminalsB).toHaveCount(2)
  await expect(terminalsB.nth(0)).toHaveAttribute('data-pty-pid', /^\d+$/)
  await expect(terminalsB.nth(1)).toHaveAttribute('data-pty-pid', /^\d+$/)
  const pidsB = [
    Number(await terminalsB.nth(0).getAttribute('data-pty-pid')),
    Number(await terminalsB.nth(1).getAttribute('data-pty-pid'))
  ].sort()
  expect(pidsB).toEqual(pids)
  await expect(page.getByTestId('terminal')).toHaveCount(0)

  // And outlive the source's grace period, which is where the bug landed.
  await page2.waitForTimeout(REATTACH_GRACE_MS * 3)
  for (const pid of pids) expect(await alive(electronApp, pid)).toBe(true)
})

test("a drop on another window's tab bar lands between its tabs, not appended", async ({
  page,
  electronApp
}) => {
  const term = await openTerminal(initialPane(page))
  const pid = await term.getAttribute('data-pty-pid')

  const page2 = await openNewPaneTreeWindow(electronApp, page)
  // Two tabs in B's root group, so "first" is a real position.
  await openNewTab(initialPane(page2))
  const tabsB = page2.getByRole('tablist').first().getByRole('tab')
  await expect(tabsB).toHaveCount(2)
  await placeWindowsSideBySide(electronApp, page, page2)

  // The left half of B's first tab: a tab-bar target at index 0, previewed
  // by the strip's insertion marker rather than a whole-group highlight.
  await hoverIntoWindow(electronApp, headerOf(initialPane(page)), page2, tabsB.first(), {
    pointIn: (box) => ({ x: box.x + box.width * 0.25, y: box.y + box.height / 2 }),
    preview: (target) => target.locator('.tab-drop-indicator')
  })
  await expect(page2.getByTestId('dock-preview')).toHaveCount(0)
  await page.mouse.up()

  // Three tabs, the terminal's first; the tab that was first is now second.
  await expect(tabsB).toHaveCount(3)
  await tabsB.first().click()
  await expect(page2.getByTestId('terminal')).toBeVisible()
  await expect(page2.getByTestId('terminal')).toHaveAttribute('data-pty-pid', String(pid))
  await tabsB.nth(1).click()
  // Both empty tabs keep their panes in the DOM; exactly one shows.
  await expect(page2.getByTestId('empty-pane').filter({ visible: true })).toHaveCount(1)
  await expect(page2.getByTestId('terminal')).toBeHidden()
})

test('an agent keeps driving and listing its pane after the user drags that pane into another window', async ({
  page,
  electronApp
}) => {
  // Every verb used to go to the agent's own window, and a renderer finds
  // panes only in its own tree — so the moment the pane left, every verb
  // naming it answered that it was gone, and list-panes stopped showing it,
  // while main's ownership ledger still said the agent owned it.
  const { env } = await openAgentSession(page, electronApp)
  const paneId = await createAgentPane(env, '--url', 'about:blank')
  const page2 = await openNewPaneTreeWindow(electronApp, page)
  await placeWindowsSideBySide(electronApp, page, page2)
  // The agent's pane opens as a tab beside its terminal (openAgentSession).
  const tabs = page.getByRole('tablist').first().getByRole('tab')
  await expect(tabs).toHaveCount(2)
  await hoverIntoWindow(electronApp, tabs.nth(1), page2, initialPane(page2))
  await page.mouse.up()
  await expect(page2.locator('webview')).toHaveCount(1)
  await expect(page.locator('webview')).toHaveCount(0)

  const info = await runTabsCtl(['pane-info', '--pane', paneId], env)
  expect(info.error).toBeUndefined()
  expect(info.result?.paneId).toBe(paneId)
  const listed = await runTabsCtl(['list-panes'], env)
  expect(listed.result?.panes?.map((pane) => pane.paneId)).toEqual([paneId])

  const closed = await runTabsCtl(['close-pane', '--pane', paneId], env)
  expect(closed.ok).toBe(true)
  await expect(page2.locator('webview')).toHaveCount(0)
})

test('a zoomed destination previews the pane under the cursor, not one scaled away from it', async ({
  userDataDir
}) => {
  // Main hit-tests the cursor in screen DIPs and hands the window a local
  // point; the renderer resolves it in CSS pixels. At 150% the unscaled
  // point for the right-hand pane's center lands past the window's edge,
  // and no preview ever showed. Its own app: zoom is per origin, and every
  // pane-tree window shares one.
  await withApp(userDataDir, async (app1, page1) => {
    await openTerminal(initialPane(page1))
    const page2 = await openNewPaneTreeWindow(app1, page1)
    await splitHorizontal(initialPane(page2))
    const right = page2.getByTestId('pane').nth(2)
    // A pane with content: an empty one resolves to its own highlight.
    await openTerminal(right)
    await placeWindowsSideBySide(app1, page1, page2)
    const zoom = 1.5
    const widthBefore = await page2.evaluate(() => window.innerWidth)
    await app1.evaluate(
      ({ BrowserWindow }, { url, factor }) => {
        BrowserWindow.getAllWindows()
          .find((win) => win.webContents.getURL() === url)
          ?.webContents.setZoomFactor(factor)
      },
      { url: page2.url(), factor: zoom }
    )
    await expect
      .poll(() => page2.evaluate(() => window.innerWidth))
      .toBeLessThan(widthBefore / (zoom - 0.1))
    const zoomed = await requireBox(right)

    await engageCrossWindowDrag(app1, headerOf(initialPane(page1)))
    const bounds = await windowContentBounds(app1, page2)
    await setCrossWindowCursorPoint(app1, {
      x: bounds.x + (zoomed.x + zoomed.width / 2) * zoom,
      y: bounds.y + (zoomed.y + zoomed.height / 2) * zoom
    })

    const preview = page2.getByTestId('dock-preview')
    await expect(preview).toBeVisible()
    const previewBox = await requireBox(preview)
    expect(previewBox.x).toBeGreaterThanOrEqual(zoomed.x - 1)
    expect(previewBox.x + previewBox.width).toBeLessThanOrEqual(zoomed.x + zoomed.width + 1)
    await setCrossWindowCursorPoint(app1, OFFSCREEN_POINT)
    await page1.mouse.up()
  })
})

test('a window the user cannot see at the cursor never receives the hover', async ({
  page,
  electronApp
}) => {
  // Main hit-tests windows by frame, and a minimized window keeps the frame
  // it was minimized from — so a drag over the desktop where it used to be
  // previewed, and dropped, into a window nobody could see. A native
  // fullscreen window is the same on macOS: alone on a Space the source is
  // not on. Neither can be made real under E2E_HIDDEN, so main's own
  // answer is stubbed; the hover lands once the stub is lifted, which is
  // what keeps the refusals from passing vacuously.
  await openTerminal(initialPane(page))
  const page2 = await openNewPaneTreeWindow(electronApp, page)
  await placeWindowsSideBySide(electronApp, page, page2)
  const stub = (method: 'isMinimized' | 'isFullScreen', value: boolean | null) =>
    electronApp.evaluate(
      ({ BrowserWindow }, { url, name, answer }) => {
        const win = BrowserWindow.getAllWindows().find(
          (candidate) => candidate.webContents.getURL() === url
        )
        if (!win) throw new Error(`No BrowserWindow found for ${url}`)
        if (answer === null) Reflect.deleteProperty(win, name)
        else Object.defineProperty(win, name, { value: () => answer, configurable: true })
      },
      { url: page2.url(), name: method, answer: value }
    )

  await stub('isMinimized', true)
  await engageCrossWindowDrag(electronApp, headerOf(initialPane(page)))
  const bounds = await windowContentBounds(electronApp, page2)
  await setCrossWindowCursorPoint(electronApp, {
    x: bounds.x + bounds.width / 2,
    y: bounds.y + bounds.height / 2
  })
  // B's pane is empty, so a landed hover shows its drop highlight.
  const preview = page2.locator('.empty-pane-drop-target')
  // Enough poll ticks for B to have been hovered, if it ever would be.
  await page.waitForTimeout(200)
  await expect(preview).toHaveCount(0)

  await stub('isMinimized', null)
  await expect(preview).toBeVisible()

  if (process.platform === 'darwin') {
    await stub('isFullScreen', true)
    await expect(preview).toHaveCount(0)
    await stub('isFullScreen', null)
    await expect(preview).toBeVisible()
  }

  // Off B again before releasing, so this ends as a plain fly-back.
  await setCrossWindowCursorPoint(electronApp, OFFSCREEN_POINT)
  await expect(preview).toHaveCount(0)
  await page.mouse.up()
  await expect(page.getByTestId('terminal')).toHaveCount(1)
})

test("dragging a window's only tab into another window moves it there, leaving a placeholder behind", async ({
  page,
  electronApp
}) => {
  // Its departure consumes the source's whole tree, and the detach used to
  // refuse that — after the destination had already previewed the drop, so
  // the gesture showed a landing spot and then did nothing. The same content
  // dragged by its pane header always moved, leaving an empty pane.
  const term = await openTerminal(initialPane(page))
  const pid = await term.getAttribute('data-pty-pid')
  const page2 = await openNewPaneTreeWindow(electronApp, page)
  await placeWindowsSideBySide(electronApp, page, page2)
  const tabs = page.getByRole('tablist').first().getByRole('tab')
  await expect(tabs).toHaveCount(1)

  await hoverIntoWindow(electronApp, tabs.first(), page2, initialPane(page2))
  await page.mouse.up()

  await expect(page2.getByTestId('terminal')).toHaveAttribute('data-pty-pid', pid ?? '')
  await expect(page.getByTestId('terminal')).toHaveCount(0)
  await expect(page.getByTestId('empty-pane')).toBeVisible()
  await expect(page.locator('.drag-ghost')).toHaveCount(0)
})

test('a drop into the middle of a tab in another window joins that tab group, as it would in-window', async ({
  page,
  electronApp
}) => {
  // The cross-window resolver always aimed at the innermost pane, so a center
  // drop promoted the hovered tab's content into a fresh nested group; the
  // in-window one walks up to the enclosing group and adds a tab to it.
  await openTerminal(initialPane(page))
  const page2 = await openNewPaneTreeWindow(electronApp, page)
  // B: a split whose right half is a group of two terminals.
  await splitHorizontal(initialPane(page2))
  const right = page2.getByTestId('pane').nth(2)
  await openTerminal(right)
  await wrapInTabGroup(right)
  const group = page2.getByTestId('pane').nth(2)
  await headerOf(group).getByTestId('tab-strip-new-tab-button').click()
  await expect(page2.getByTestId('terminal')).toHaveCount(2)
  const groupTabs = headerOf(group).getByRole('tab')
  await expect(groupTabs).toHaveCount(2)
  const tablists = await page2.getByRole('tablist').count()
  await placeWindowsSideBySide(electronApp, page, page2)

  const shownTab = paneOf(page2.getByTestId('terminal').filter({ visible: true }))
  await hoverIntoWindow(electronApp, headerOf(initialPane(page)), page2, shownTab)
  await page.mouse.up()

  await expect(page2.getByTestId('terminal')).toHaveCount(3)
  await expect(groupTabs).toHaveCount(3)
  expect(await page2.getByRole('tablist').count()).toBe(tablists)
})

test('a drop into an empty tab of a nested group in another window fills that tab, as it would in-window', async ({
  page,
  electronApp
}) => {
  // Sharing the in-window dock walk without its empty-pane step made a drop
  // on an empty tab inside a group walk up to the group and open a new tab
  // beside the placeholder, where in-window it fills the placeholder.
  await openTerminal(initialPane(page))
  const page2 = await openNewPaneTreeWindow(electronApp, page)
  // B: a split whose right half is a group of two empty tabs.
  await splitHorizontal(initialPane(page2))
  const right = page2.getByTestId('pane').nth(2)
  await wrapInTabGroup(right)
  const group = page2.getByTestId('pane').nth(2)
  await headerOf(group).getByTestId('tab-strip-new-tab-button').click()
  const groupTabs = headerOf(group).getByRole('tab')
  await expect(groupTabs).toHaveCount(2)
  await placeWindowsSideBySide(electronApp, page, page2)

  const shownEmptyTab = paneOf(group.getByTestId('empty-pane').filter({ visible: true }))
  await hoverIntoWindow(electronApp, headerOf(initialPane(page)), page2, shownEmptyTab, {
    preview: (target) => target.locator('.empty-pane-drop-target')
  })
  await page.mouse.up()

  await expect(page2.getByTestId('terminal')).toBeVisible()
  await expect(groupTabs).toHaveCount(2)
})

test('a hover holding still over another window is not re-sent every poll tick', async ({
  page,
  electronApp
}) => {
  // Each hover costs the hovered window a hit test, two drag-store writes
  // and a reply; main used to send one every 16ms tick whether or not the
  // cursor had moved — about 60 a second into a window that may be busy
  // painting terminal output.
  await openTerminal(initialPane(page))
  const page2 = await openNewPaneTreeWindow(electronApp, page)
  await placeWindowsSideBySide(electronApp, page, page2)
  await page2.evaluate(() => {
    const host = window as unknown as { api: Api; hoversSeen: number }
    host.hoversSeen = 0
    host.api.layout.onCrossWindow((message) => {
      if (message.type === 'hover') host.hoversSeen += 1
    })
  })
  await hoverIntoWindow(electronApp, headerOf(initialPane(page)), page2, initialPane(page2))

  const seen = () => page2.evaluate(() => (window as unknown as { hoversSeen: number }).hoversSeen)
  const before = await seen()
  await page2.waitForTimeout(1000)
  // A few refreshes a second, never a tick's worth.
  expect((await seen()) - before).toBeLessThanOrEqual(8)

  await setCrossWindowCursorPoint(electronApp, OFFSCREEN_POINT)
  await expect(page2.locator('.empty-pane-drop-target')).toHaveCount(0)
  await page.mouse.up()
})

test('with two other windows under the cursor, the drop goes to the one in front', async ({
  page,
  electronApp
}) => {
  // Main asked the windows in creation order, so over a cascade it hovered
  // the oldest — the one underneath — and the pane landed where it could
  // not be seen. It now asks front to back: a window comes forward when it
  // opens and whenever it gains focus.
  await openTerminal(initialPane(page))
  const back = await openNewPaneTreeWindow(electronApp, page)
  const front = await openNewPaneTreeWindow(electronApp, page)
  // The source on the left half; the other two overlapping on the right.
  await electronApp.evaluate(
    ({ BrowserWindow, screen }, urls) => {
      const area = screen.getPrimaryDisplay().workArea
      const half = Math.floor(area.width / 2)
      const bounds = [
        { x: area.x, y: area.y, width: half - 10, height: area.height },
        { x: area.x + half + 10, y: area.y, width: half - 10, height: area.height },
        { x: area.x + half + 60, y: area.y + 60, width: half - 70, height: area.height - 60 }
      ]
      urls.forEach((url, index) => {
        BrowserWindow.getAllWindows()
          .find((win) => win.webContents.getURL() === url)
          ?.setBounds(bounds[index]!)
      })
    },
    [page.url(), back.url(), front.url()]
  )
  const frontBounds = await windowContentBounds(electronApp, front)
  await expect.poll(() => front.evaluate(() => window.innerWidth)).toBe(frontBounds.width)

  await engageCrossWindowDrag(electronApp, headerOf(initialPane(page)))
  // Inside both of the other windows, clear of either pane's edge zones.
  await setCrossWindowCursorPoint(electronApp, {
    x: frontBounds.x + frontBounds.width / 2,
    y: frontBounds.y + frontBounds.height / 2
  })
  const previewIn = (target: typeof page) => target.locator('.empty-pane-drop-target')
  await expect(previewIn(front)).toBeVisible()
  await expect(previewIn(back)).toHaveCount(0)

  // Focusing the other one brings it forward, and the hover follows.
  await electronApp.evaluate(({ BrowserWindow }, url) => {
    BrowserWindow.getAllWindows()
      .find((win) => win.webContents.getURL() === url)
      ?.emit('focus')
  }, back.url())
  await expect(previewIn(back)).toBeVisible()
  await expect(previewIn(front)).toHaveCount(0)

  // And the drop lands where the preview was.
  await page.mouse.up()
  await expect(back.getByTestId('terminal')).toHaveCount(1)
  await expect(front.getByTestId('terminal')).toHaveCount(0)
  await expect(page.getByTestId('terminal')).toHaveCount(0)
})

test('what a shell prints while its pane is between windows reaches the window it lands in', async ({
  userDataDir
}) => {
  // The source unsubscribes as the pane unmounts, and main kept sending the
  // pty's output there until the destination attached — so everything
  // printed in between was lost: a torn TUI, a gap in a build log.
  await withApp(userDataDir, async (app1, page1) => {
    const term = await openTerminal(initialPane(page1))
    const page2 = await openNewPaneTreeWindow(app1, page1)
    await placeWindowsSideBySide(app1, page1, page2)
    // Prints only once the test says so — after the detach, while B, held
    // busy, has yet to mount the pane — however slow the hover is. The
    // arithmetic keeps the typed command itself from matching.
    const trigger = triggerFile()
    await typeAndEnter(
      term,
      `until [ -f ${trigger.path} ]; do sleep 0.1; done; echo held-$((40+2))`
    )
    await hoverIntoWindow(app1, headerOf(initialPane(page1)), page2, initialPane(page2))

    holdRendererBusy(page2, 4000)
    await page1.waitForTimeout(150)
    await page1.mouse.up()
    await expect(page1.getByTestId('terminal')).toHaveCount(0)
    trigger.pull()

    await expect(page2.getByTestId('terminal')).toContainText('held-42', { timeout: 15_000 })
  })
})

test('a shell that exits while its pane is between windows shows its last output and exit there, not a fresh shell', async ({
  userDataDir
}) => {
  // The exit deleted the pty and dropped what was held, and told a source
  // that had already unsubscribed; the destination then found no pty and
  // quietly started a new login shell under the old scrollback.
  await withApp(userDataDir, async (app1, page1) => {
    const term = await openTerminal(initialPane(page1))
    const pid = await term.getAttribute('data-pty-pid')
    const page2 = await openNewPaneTreeWindow(app1, page1)
    await placeWindowsSideBySide(app1, page1, page2)
    const trigger = triggerFile()
    await typeAndEnter(
      term,
      `until [ -f ${trigger.path} ]; do sleep 0.1; done; echo last-$((40+2)); exit`
    )
    await hoverIntoWindow(app1, headerOf(initialPane(page1)), page2, initialPane(page2))

    holdRendererBusy(page2, 3000)
    await page1.waitForTimeout(150)
    await page1.mouse.up()
    await expect(page1.getByTestId('terminal')).toHaveCount(0)
    trigger.pull()
    await expect.poll(() => alive(app1, Number(pid))).toBe(false)

    const landed = page2.getByTestId('terminal')
    await expect(landed).toContainText('last-42', { timeout: 15_000 })
    await expect(landed).toContainText('[process exited]')
    await expect(landed).toHaveAttribute('data-pty-pid', pid ?? '')
  })
})

test('edits made in the source while the destination is still inserting survive in its saved layout', async ({
  userDataDir
}) => {
  // Main recorded the source's post-detach snapshot only once the insert
  // settled — after the source's own later saves — so a split made while a
  // busy destination held the insert vanished from main's copy of the source
  // and from layout.json, though the window still showed it.
  seedSettingsFile(userDataDir, { persistLayoutOnExit: true })
  await withApp(userDataDir, async (app1, page1) => {
    await openTerminal(initialPane(page1))
    const page2 = await openNewPaneTreeWindow(app1, page1)
    await placeWindowsSideBySide(app1, page1, page2)
    await hoverIntoWindow(app1, headerOf(initialPane(page1)), page2, initialPane(page2))

    holdRendererBusy(page2, 4000)
    await page1.waitForTimeout(150)
    await page1.mouse.up()
    await expect(page1.getByTestId('terminal')).toHaveCount(0)
    // A's pane is now a placeholder; split it while B is still busy, and let
    // A's debounced save land.
    await splitHorizontal(initialPane(page1))
    await expect(page1.getByTestId('empty-pane')).toHaveCount(2)
    await page1.waitForTimeout(900)

    await expect(page2.getByTestId('terminal')).toHaveCount(1, { timeout: 10_000 })
    await page1.waitForTimeout(300)
    const file = JSON.parse(readFileSync(path.join(userDataDir, 'layout.json'), 'utf-8')) as {
      windows: { layout: { root: unknown } }[]
    }
    const leafCounts = file.windows.map(
      (entry) => JSON.stringify(entry.layout.root).match(/"type":"empty"/g)?.length ?? 0
    )
    // A holds its two split halves; B holds the terminal and no placeholder.
    expect([...leafCounts].sort()).toEqual([0, 2])
  })
})

test('a Settings window over the cursor keeps the pane-tree window beneath it from receiving the drop', async ({
  page,
  electronApp
}) => {
  // Only pane-tree windows were in main's stacking order, so a window
  // covered by Settings still took the hover, previewing and committing the
  // drop where the user could not see it.
  await openTerminal(initialPane(page))
  const page2 = await openNewPaneTreeWindow(electronApp, page)
  await placeWindowsSideBySide(electronApp, page, page2)
  const settings = await openSettingsWindow(electronApp, page)
  const bounds2 = await windowContentBounds(electronApp, page2)
  // Over the middle of B, and reported visible: under E2E_HIDDEN no window
  // is ever shown, so main's own answer is stubbed.
  const reportVisible = (visible: boolean | null) =>
    electronApp.evaluate(
      ({ BrowserWindow }, { url, answer, rect }) => {
        const win = BrowserWindow.getAllWindows().find(
          (candidate) => candidate.webContents.getURL() === url
        )
        if (!win) throw new Error(`No BrowserWindow found for ${url}`)
        win.setBounds(rect)
        if (answer === null) Reflect.deleteProperty(win, 'isVisible')
        else Object.defineProperty(win, 'isVisible', { value: () => answer, configurable: true })
      },
      {
        url: settings.url(),
        answer: visible,
        rect: {
          x: Math.round(bounds2.x + bounds2.width / 2 - 300),
          y: Math.round(bounds2.y + bounds2.height / 2 - 220),
          width: 600,
          height: 440
        }
      }
    )
  await reportVisible(true)

  await engageCrossWindowDrag(electronApp, headerOf(initialPane(page)))
  await setCrossWindowCursorPoint(electronApp, {
    x: bounds2.x + bounds2.width / 2,
    y: bounds2.y + bounds2.height / 2
  })
  const preview = page2.locator('.empty-pane-drop-target')
  await page.waitForTimeout(200)
  await expect(preview).toHaveCount(0)

  // Not over the cursor any more (hidden): the hover lands.
  await reportVisible(false)
  await expect(preview).toBeVisible()

  await setCrossWindowCursorPoint(electronApp, OFFSCREEN_POINT)
  await expect(preview).toHaveCount(0)
  await page.mouse.up()
  await expect(page.getByTestId('terminal')).toHaveCount(1)
})

test('list-panes refuses while a window reloads and leaves a crashed one out, never answering partially', async ({
  page,
  electronApp
}) => {
  // Listing asks every window. One that could not answer used to hold the
  // call for the relay budget and then be left out of an ok answer — an
  // owned pane in it read as gone, and the documented remedy for a gone
  // pane is to open it again.
  const { env } = await openAgentSession(page, electronApp)
  const paneId = await createAgentPane(env, '--url', 'about:blank')
  const page2 = await openNewPaneTreeWindow(electronApp, page)
  const reportLoading = (loading: boolean | null) =>
    electronApp.evaluate(
      ({ BrowserWindow }, { url, answer }) => {
        const contents = BrowserWindow.getAllWindows().find(
          (candidate) => candidate.webContents.getURL() === url
        )?.webContents
        if (!contents) throw new Error(`No BrowserWindow found for ${url}`)
        if (answer === null) Reflect.deleteProperty(contents, 'isLoading')
        else
          Object.defineProperty(contents, 'isLoading', { value: () => answer, configurable: true })
      },
      { url: page2.url(), answer: loading }
    )

  await reportLoading(true)
  const refused = await runTabsCtl(['list-panes'], env)
  expect(refused.ok).toBe(false)
  expect(refused.error).toContain('try again')

  await reportLoading(null)
  const listed = await runTabsCtl(['list-panes'], env)
  expect(listed.result?.panes?.map((pane) => pane.paneId)).toEqual([paneId])

  // A crashed window, unlike a reloading one, would never answer: it is left
  // out rather than refusing every listing for as long as it stays open.
  await page2.close()
  const page3 = await openNewPaneTreeWindow(electronApp, page)
  await onWindowOf(electronApp, page3, 'crash')
  const withCrashed = await runTabsCtl(['list-panes'], env)
  expect(withCrashed.error).toBeUndefined()
  expect(withCrashed.result?.panes?.map((pane) => pane.paneId)).toEqual([paneId])
})

/** A file a shell loop can wait on: `pull()` creates it. Removed with its directory at exit. */
function triggerFile(): { path: string; pull: () => void } {
  const dir = mkdtempSync(path.join(tmpdir(), 'tabs-e2e-trigger-'))
  const file = path.join(dir, 'go')
  process.once('exit', () => rmSync(dir, { recursive: true, force: true }))
  return { path: file, pull: () => writeFileSync(file, '') }
}
