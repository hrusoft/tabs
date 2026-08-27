import { expect, test } from './helpers/launch'
import { headerOf, initialPane, splitHorizontal } from './helpers/pane'
import { openTerminal, typeAndEnter } from './helpers/terminal'

// Only the real-byte wiring tests live here: a genuine `\a` from a real
// shell travelling pty → xterm onBell → bellStore (ring() drops a bell only
// when its pane is active AND the window focused — see bellStore.ts) →
// indicator, and the terminal handle clearing it on focus — plus the
// bell.ring IPC to main (see e2e/ipc-smoke.spec.ts's map). The
// backgrounded-tab indicator behavior is src/renderer/src/__tests__/
// bell.test.tsx's, driven through the same content-agnostic bellStore.
//
// Window focus is the one input the harness can't vary for real: the hidden
// CDP-driven window reports document.hasFocus() === true (focus emulation)
// even though the OS window is unfocused, so the unfocused-window test below
// stubs hasFocus and fires the window focus event itself — everything else
// (bytes, xterm, store, DOM) is the real path.

test('a bell on a non-focused pane keeps pulsing past the old one-shot duration, and clears on focus', async ({
  page
}) => {
  // Root's own wrapper is permanently pane 0 (see ensureTabsRoot in
  // tree.ts); splitting the initial pane puts the original leaf at 1 and the
  // new sibling at 2.
  await splitHorizontal(initialPane(page))
  const panes = page.getByTestId('pane')
  const term = await openTerminal(panes.nth(2))

  // Queue a delayed bell, then move focus to pane 1 before it fires — typing
  // into the terminal itself clicks (and so refocuses) pane 2, and ring()
  // drops a bell in the attended pane (active pane, focused window — which
  // the harness's focus emulation reports; see bellStore.ts), so a bell
  // fired immediately after typing would never flag.
  await typeAndEnter(term, "sleep 1 && printf '\\a'")
  await headerOf(panes.nth(1)).click()
  await expect(panes.nth(1)).toHaveClass(/pane-active/)

  const ringingPane = panes.nth(2)
  const header = headerOf(ringingPane)
  await expect(ringingPane).toHaveClass(/pane-alert/, { timeout: 3000 })
  await expect(header.getByTestId('pane-bell-icon')).toBeVisible()
  // The header itself no longer flashes — that's the whole point of this
  // change. The pulse now lives on the icon and on the pane's own content
  // border (its ::after overlay — see .pane-alert::after in global.css).
  expect(await header.evaluate((el) => getComputedStyle(el).animationName)).toBe('none')
  expect(
    await ringingPane.evaluate((el) => getComputedStyle(el, '::after').animationName)
  ).toContain('bell-pulse')
  expect(
    await header.getByTestId('pane-bell-icon').evaluate((el) => getComputedStyle(el).animationName)
  ).toContain('bell-pulse')

  // Outlives the old 0.8s one-shot flash — the actual regression this test
  // guards against (the highlight used to fade back out on its own here).
  await page.waitForTimeout(1200)
  await expect(ringingPane).toHaveClass(/pane-alert/)
  await expect(header.getByTestId('pane-bell-icon')).toBeVisible()

  await header.click()

  await expect(panes.nth(2)).toHaveClass(/pane-active/)
  await expect(ringingPane).not.toHaveClass(/pane-alert/)
  await expect(header.getByTestId('pane-bell-icon')).toHaveCount(0)
})

test('a bell in the active pane flags it while the window is unfocused, and clears on window focus', async ({
  page
}) => {
  const term = await openTerminal(initialPane(page))

  // The user is "away in another app": only the focus signal is stubbed —
  // the harness window structurally can't lose its emulated focus (see the
  // header comment). The bell rings in the ACTIVE pane, the case the old
  // activePaneId-only gate silently swallowed.
  await page.evaluate(() => {
    document.hasFocus = () => false
  })
  await typeAndEnter(term, "printf '\\a'")

  const ringingPane = initialPane(page)
  const header = headerOf(ringingPane)
  await expect(ringingPane).toHaveClass(/pane-alert/, { timeout: 3000 })
  await expect(ringingPane).toHaveClass(/pane-active/)
  await expect(header.getByTestId('pane-bell-icon')).toBeVisible()
  // This pane is both active and ringing at once — the one case where
  // .pane-active::after and .pane-alert::after both match the same ::after
  // slot. The cascade (declaration order, not z-index) is what keeps the
  // pulse running rather than the static accent rule silently winning; see
  // .pane-alert::after's comment.
  expect(
    await ringingPane.evaluate((el) => getComputedStyle(el, '::after').animationName)
  ).toContain('bell-pulse')

  // Outlives the old 0.8s one-shot flash here too.
  await page.waitForTimeout(1200)
  await expect(ringingPane).toHaveClass(/pane-alert/)

  // Coming back to the app with the ringing pane active counts as seeing it.
  await page.evaluate(() => {
    delete (document as { hasFocus?: () => boolean }).hasFocus
    window.dispatchEvent(new Event('focus'))
  })

  await expect(ringingPane).not.toHaveClass(/pane-alert/)
  await expect(header.getByTestId('pane-bell-icon')).toHaveCount(0)
})
