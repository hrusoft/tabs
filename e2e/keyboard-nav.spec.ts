import { dataPage, navigateTo, openBrowser } from './helpers/browser'
import { guestText } from './helpers/guest'
import { expect, test } from './helpers/launch'
import { activatePane, closePane, initialPane, openNewTab, splitHorizontal } from './helpers/pane'
import { MOD_INPUT_MODIFIER, MOD_KEY } from './helpers/platform'
import { openTerminal } from './helpers/terminal'

// Only the tests whose subject is the integration remain here: keyboard focus
// handing off into and out of a real pty's xterm and a real <webview> guest.
// The model-driven navigation tests live in
// src/renderer/src/__tests__/keyboard-nav.test.tsx; the rect-driven
// entry/wrap ones in e2e/browser/keyboard-nav.spec.ts.

test('cmd+arrow navigates away from a focused terminal', async ({ page }) => {
  // Root's own wrapper is permanently pane 0 (see ensureTabsRoot in
  // tree.ts); splitting the initial pane puts the original leaf at 1 and the
  // new sibling at 2.
  await splitHorizontal(initialPane(page))
  const panes = page.getByTestId('pane')
  const term = await openTerminal(panes.nth(1))

  // Put the keyboard in the shell, where xterm handles keydown itself; the
  // capture-phase navigation handler must still win.
  await term.click()
  await expect(panes.nth(1)).toHaveClass(/pane-active/)

  await page.keyboard.press(`${MOD_KEY}+ArrowRight`)
  await expect(panes.nth(2)).toHaveClass(/pane-active/)

  // Close the terminal opened as setup above, rather than leaving a live
  // shell for the fixture's teardown to quit past — see the note on
  // openTerminal in e2e/helpers/terminal.ts.
  await closePane(panes.nth(1))
})

test('typing follows cmd+arrow into the newly focused terminal', async ({ page }) => {
  // Root's own wrapper is permanently pane 0 (see ensureTabsRoot in
  // tree.ts); splitting the initial pane puts the original leaf at 1 and the
  // new sibling at 2.
  await splitHorizontal(initialPane(page))
  const panes = page.getByTestId('pane')
  await openTerminal(panes.nth(1))
  await openTerminal(panes.nth(2))
  const terms = page.getByTestId('terminal')

  await terms.nth(0).click()
  await page.keyboard.type('echo in-first-shell')
  await page.keyboard.press('Enter')
  await expect(terms.nth(0)).toContainText('in-first-shell')

  // Navigating right must hand the keyboard to the second shell, not just
  // the highlight.
  await page.keyboard.press(`${MOD_KEY}+ArrowRight`)
  await expect(panes.nth(2)).toHaveClass(/pane-active/)
  await expect(terms.nth(1).locator('.xterm-helper-textarea')).toBeFocused()

  await page.keyboard.type('echo in-second-shell')
  await page.keyboard.press('Enter')
  await expect(terms.nth(1)).toContainText('in-second-shell')
  await expect(terms.nth(0)).not.toContainText('in-second-shell')

  // Close both terminals opened as setup above, rather than leaving live
  // shells for the fixture's teardown to quit past — see the note on
  // openTerminal in e2e/helpers/terminal.ts. Closing pane 2 collapses the
  // split, leaving the first terminal's pane as root's sole tab again — the
  // same node initialPane names, now back in that slot.
  await closePane(panes.nth(2))
  await expect(page.getByTestId('pane')).toHaveCount(2)
  await closePane(initialPane(page))
})

test('typing follows a tab switch into the shell it reveals, by click and by chord', async ({
  page
}) => {
  // The tab half of the test above, and a different mechanism underneath: a
  // backgrounded tab's panel is `hidden`, so the pane core focuses on
  // activation is `display: none` at that instant unless the focus waits for
  // React's commit (see PaneFocusFollower in core/registry/paneHandles.ts).
  // focus() is refused silently there, so the highlight moved to a shell that
  // never received a keystroke. Only a real xterm shows it: the stub's DOM
  // twin covers the same wiring in e2e/browser/pane-focus.spec.ts.
  const term1 = await openTerminal(initialPane(page))
  // "New tab" clones the origin pane's own type, so tab 2 opens its own shell
  // — and lands active, backgrounding the first.
  await openNewTab(initialPane(page))
  const panes = page.getByTestId('pane')
  // Root's own wrapper (0), then the two tabs' content panes.
  await expect(panes).toHaveCount(3)
  const term2 = panes.nth(2).getByTestId('terminal')
  await expect(term2).toContainText('~', { timeout: 20_000 })

  // Clicking a tab must hand the keyboard to the shell it reveals — no click
  // into the pane itself, which would focus it the ordinary way and make this
  // pass vacuously.
  await page.getByRole('tab').nth(0).click()
  await expect(panes.nth(1)).toHaveClass(/pane-active/)
  await expect(term1.locator('.xterm-helper-textarea')).toBeFocused()
  await page.keyboard.type('echo in-first-shell')
  await page.keyboard.press('Enter')
  await expect(term1).toContainText('in-first-shell')

  // And the chord that walks the group does the same. Note the second shell's
  // text is only asserted once its own tab is showing again: reading a
  // `display: none` terminal returns xterm's measurement scratch rather than
  // its buffer.
  await page.keyboard.press(`${MOD_KEY}+ArrowRight`)
  await expect(panes.nth(2)).toHaveClass(/pane-active/)
  await expect(term2.locator('.xterm-helper-textarea')).toBeFocused()
  await page.keyboard.type('echo in-second-shell')
  await page.keyboard.press('Enter')
  await expect(term2).toContainText('in-second-shell')
  await expect(term2).not.toContainText('in-first-shell')

  // Close both shells opened as setup above — see the note on openTerminal in
  // e2e/helpers/terminal.ts. Emptying tab 2 closes the tab behind it, leaving
  // the first terminal's pane as root's sole tab again.
  await closePane(panes.nth(2))
  await expect(page.getByTestId('pane')).toHaveCount(2)
  await closePane(initialPane(page))
})

test('typing follows cmd+arrow into a browser pane, and cmd+arrow escapes it again', async ({
  page,
  electronApp
}) => {
  // Hermetic probe page (see dataPage): an autofocused input that mirrors
  // whatever is typed into #status.
  const probePage = dataPage(
    'Focus probe',
    '<input id="field" autofocus><div id="status">idle</div>' +
      '<script>document.getElementById("field").addEventListener("input", (event) => {' +
      'document.getElementById("status").textContent = "typed:" + event.target.value })</script>'
  )

  // Root's own wrapper is permanently pane 0 (see ensureTabsRoot in
  // tree.ts); splitting the initial pane puts the original leaf at 1 and the
  // new sibling at 2.
  await splitHorizontal(initialPane(page))
  const panes = page.getByTestId('pane')
  const browser = await openBrowser(panes.nth(2))
  await navigateTo(browser, probePage)
  await expect.poll(() => guestText(electronApp, '#status')).toBe('idle')

  await activatePane(panes.nth(1))
  await expect(panes.nth(1)).toHaveClass(/pane-active/)

  // Navigating right must hand the keyboard to the page, not just the
  // highlight — the browser pane's handle focuses its guest.
  await page.keyboard.press(`${MOD_KEY}+ArrowRight`)
  await expect(panes.nth(2)).toHaveClass(/pane-active/)
  await expect
    .poll(() => page.evaluate(() => document.activeElement?.tagName ?? 'none'))
    .toBe('WEBVIEW')
  await page.keyboard.type('hello')
  await expect.poll(() => guestText(electronApp, '#status')).toBe('typed:hello')

  // And out again. The press is injected into the guest itself: a focused
  // guest swallows every keydown before the host window's own handler can
  // see it, so escaping relies on main's before-input-event forwarding (see
  // src/plugins/browser/main/guestNavKeys.ts) — this asserts that path specifically,
  // not the window keydown listener.
  await electronApp.evaluate(({ webContents }, navModifier: 'meta' | 'control') => {
    const guest = webContents.getAllWebContents().find((wc) => wc.getType() === 'webview')
    if (!guest) throw new Error('no guest webview to inject into')
    guest.sendInputEvent({ type: 'keyDown', keyCode: 'Left', modifiers: [navModifier] })
    guest.sendInputEvent({ type: 'keyUp', keyCode: 'Left', modifiers: [navModifier] })
  }, MOD_INPUT_MODIFIER)
  await expect(panes.nth(1)).toHaveClass(/pane-active/)
  // The browser handle's blur released the guest's grip on the keyboard.
  await expect
    .poll(() => page.evaluate(() => document.activeElement?.tagName ?? 'none'))
    .not.toBe('WEBVIEW')
})
