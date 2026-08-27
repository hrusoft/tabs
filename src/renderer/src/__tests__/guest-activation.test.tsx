import { act } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { expect, test } from 'vitest'
import { suppressGuestActivation } from '../../../plugins/browser/renderer/guestActivation'
import { headerOf, initialPane, panes } from '../testing/domQueries'
import { splitHorizontal } from '../testing/paneActions'
import { renderApp } from '../testing/renderApp'

// The renderer half of click-to-activate for browser panes. Whether a real
// press inside a `<webview>` produces the message at all is an Electron-tier
// question (e2e/browser.spec.ts) — what is testable here, and cheapest here,
// is what the renderer does once the message arrives: which pane it activates,
// and the suppression that keeps an agent's injected click from stealing the
// active pane. The stub content stands in for the browser exactly as it does
// for nav-key forwarding (see testing/registerTestContent.ts).
//
// initialPane() (panes()[1]) is the active pane in a fresh render, already
// sitting inside root's own tab — see app.test.tsx's header comment.

/** The pane id `Pane` publishes on its own element, which is what main sends back. */
function paneIdOf(pane: HTMLElement): string {
  const id = pane.dataset.dockId
  if (!id) throw new Error('pane has no data-dock-id')
  return id
}

test('a press forwarded out of a guest activates that pane', async () => {
  renderApp()
  const user = userEvent.setup()
  await splitHorizontal(user, initialPane())
  await user.click(headerOf(panes()[1]!))
  expect(panes()[1]).toHaveClass('pane-active')

  // Wrapped in act() for the same reason emitNavKey is: this arrives from
  // outside React entirely, so the re-render it schedules hasn't happened when
  // the class is read.
  act(() => window.__fakeApi?.emitGuestPointerDown(paneIdOf(panes()[2]!)))
  expect(panes()[2]).toHaveClass('pane-active')

  act(() => window.__fakeApi?.emitGuestPointerDown(paneIdOf(panes()[1]!)))
  expect(panes()[1]).toHaveClass('pane-active')
})

// The guarantee behind e2e/external-control.spec.ts's "driving a pane never
// steals keyboard focus from the terminal": an injected mouseDown is
// indistinguishable from the user's at the guest, so the app marks its own
// injections instead. Without this, an agent's click would move the
// active-pane highlight and focus-follows-active would put the keyboard in the
// webview — the exact theft that test exists to catch.
test('a press is ignored while this app is the one injecting input', async () => {
  renderApp()
  const user = userEvent.setup()
  await splitHorizontal(user, initialPane())
  await user.click(headerOf(panes()[1]!))
  expect(panes()[1]).toHaveClass('pane-active')

  const allowActivationAgain = suppressGuestActivation()
  act(() => window.__fakeApi?.emitGuestPointerDown(paneIdOf(panes()[2]!)))
  expect(panes()[1]).toHaveClass('pane-active')

  allowActivationAgain()
  act(() => window.__fakeApi?.emitGuestPointerDown(paneIdOf(panes()[2]!)))
  expect(panes()[2]).toHaveClass('pane-active')
})

// Overlapping verbs are ordinary — two socket clients can each have one in
// flight — so the mark is a counter, not a flag. A boolean would let the
// inner release re-open the outer scope.
test('overlapping injections each hold the suppression until the last releases', async () => {
  renderApp()
  const user = userEvent.setup()
  await splitHorizontal(user, initialPane())
  await user.click(headerOf(panes()[1]!))

  const releaseOuter = suppressGuestActivation()
  const releaseInner = suppressGuestActivation()
  releaseInner()
  act(() => window.__fakeApi?.emitGuestPointerDown(paneIdOf(panes()[2]!)))
  expect(panes()[1]).toHaveClass('pane-active')

  releaseOuter()
  act(() => window.__fakeApi?.emitGuestPointerDown(paneIdOf(panes()[2]!)))
  expect(panes()[2]).toHaveClass('pane-active')
})
