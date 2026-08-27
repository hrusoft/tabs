import { PANE_BUTTON } from '../src/shared/paneDomAttrs'
import { REATTACH_GRACE_MS } from '../src/shared/reattach'
import {
  dockedPanes,
  floatingWindows,
  moveWindowBy,
  stackOrder,
  unpin,
  windowPane
} from './helpers/floating'
import { requireBox } from './helpers/geometry'
import { expect, test, withApp } from './helpers/launch'
import { clickPaneRoot, headerOf, initialPane, splitHorizontal } from './helpers/pane'
import { alive, openTerminal } from './helpers/terminal'

// Only the tests whose subject is the integration remain here: a real pty
// surviving the unpin, and floating state surviving a real quit and relaunch
// from disk. The window mechanics (unpin/re-pin, move, resize, z-order,
// docking rules, cmd+arrow/cmd+T scoping) live in
// e2e/browser/floating.spec.ts.

test('a floating window keeps its terminal alive and its pid across the unpin', async ({
  page,
  electronApp
}) => {
  await splitHorizontal(initialPane(page))
  const docked = dockedPanes(page)
  // docked.nth(0) is root's own always-present tab-group wrapper (see
  // ensureTabsRoot in tree.ts); the split's first child is nth(1).
  const term = await openTerminal(docked.nth(1))
  const pid = await term.getAttribute('data-pty-pid')

  await unpin(headerOf(docked.nth(1)))
  await expect(floatingWindows(page)).toHaveCount(1)

  // Past the reattach grace window, so a genuine teardown would have landed.
  await page.waitForTimeout(REATTACH_GRACE_MS * 2)
  expect(await alive(electronApp, Number(pid))).toBe(true)
  await expect(floatingWindows(page).getByTestId('terminal')).toHaveAttribute(
    'data-pty-pid',
    pid ?? ''
  )

  // Incidental setup, so close the shell rather than leave it for the quit.
  await clickPaneRoot(windowPane(floatingWindows(page).first()), PANE_BUTTON.close)
  await expect(floatingWindows(page)).toHaveCount(0)
})

test('floating panes survive a relaunch, in the same stack order and geometry', async ({
  userDataDir
}) => {
  const { frontId, movedBox, order1 } = await withApp(userDataDir, async (_app1, page1) => {
    await splitHorizontal(initialPane(page1))
    const docked1 = dockedPanes(page1)
    // docked1.nth(0) is root's own wrapper, permanently. Unpinning the split's
    // sole remaining leaf each time collapses the split back down to it, so
    // it stays at nth(1) across both calls rather than needing to shift.
    await unpin(headerOf(docked1.nth(1)))
    await unpin(headerOf(docked1.nth(1)))
    await expect(floatingWindows(page1)).toHaveCount(2)

    // Move one window somewhere unmistakable, so geometry is verifiable.
    const front = floatingWindows(page1).nth(1)
    const id = (await front.getAttribute('data-floating-id')) ?? ''
    await moveWindowBy(headerOf(windowPane(front)), 140, 90)
    return { frontId: id, movedBox: await requireBox(front), order1: await stackOrder(page1) }
  })

  await withApp(userDataDir, async (_app2, page2) => {
    await expect(floatingWindows(page2)).toHaveCount(2)
    const restored = await requireBox(page2.locator(`[data-floating-id="${frontId}"]`))
    expect(restored.x).toBeCloseTo(movedBox.x, 0)
    expect(restored.y).toBeCloseTo(movedBox.y, 0)
    expect(await stackOrder(page2)).toEqual(order1)
  })
})
