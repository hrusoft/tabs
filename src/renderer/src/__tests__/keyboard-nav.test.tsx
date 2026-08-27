import { act, fireEvent, screen } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { expect, test } from 'vitest'
import { headerOf, initialPane, panes } from '../testing/domQueries'
import { openNewTab, splitHorizontal } from '../testing/paneActions'
import { renderApp } from '../testing/renderApp'

// Ported from e2e/keyboard-nav.spec.ts — only the tests whose behavior is
// model-driven. The rect-driven entry/wrap tests live in
// e2e/browser/keyboard-nav.spec.ts (jsdom rects are all zeros, so a pass here
// would be vacuous — spatialNav would only ever exercise its model fallback);
// the terminal-focus and webview tests stay on Electron.
//
// initialPane() (panes()[1]) is the active pane in a fresh render, already
// sitting inside root's own tab — see app.test.tsx's header comment.

// jsdom's navigator.platform is '' → spatialNav's platform is 'other', so the
// navigation modifier under test here is Ctrl (the non-mac binding).
//
// `code` as well as `key`: bindings are stored and matched by physical key
// (see shared/shortcuts.ts), and a real KeyboardEvent always carries both.
// For the arrows the two happen to be identical.
function pressNav(code: string, held: Partial<KeyboardEventInit> = {}): void {
  fireEvent.keyDown(window, { key: code, code, ctrlKey: true, ...held })
}

/**
 * Dispatches a nav press *at* a specific element, so the handler sees it as
 * `event.target` — which is what `isTextEditingTarget` inspects. Bubbles to
 * the window listener like a real keystroke would.
 */
function pressNavOn(target: Element, code: string): void {
  fireEvent.keyDown(target, { key: code, code, ctrlKey: true, bubbles: true })
}

/** A focusable text field parked in the document, optionally opting out of the text-field heuristic. */
function textFieldIn(pane: Element, navTextInput?: string): HTMLTextAreaElement {
  const field = document.createElement('textarea')
  if (navTextInput !== undefined) field.setAttribute('data-nav-text-input', navTextInput)
  pane.appendChild(field)
  return field
}

test('navigating past the edge cycles through the tabs, wrapping', async () => {
  renderApp()
  const user = userEvent.setup()
  await openNewTab(user, initialPane())
  await openNewTab(user, initialPane())
  // Root started with one tab of its own, so two clicks make three.
  const tabs = screen.getAllByRole('tab')
  expect(tabs).toHaveLength(3)
  expect(tabs[2]).toHaveAttribute('aria-selected', 'true')

  // Focus sits on the last tab's content with nothing beside it, so every
  // horizontal press cycles the group, wrapping at its ends.
  pressNav('ArrowRight')
  expect(tabs[0]).toHaveAttribute('aria-selected', 'true')

  pressNav('ArrowRight')
  expect(tabs[1]).toHaveAttribute('aria-selected', 'true')

  pressNav('ArrowLeft')
  expect(tabs[0]).toHaveAttribute('aria-selected', 'true')

  // Vertical presses never cycle tabs — one pane per tab means there is
  // nothing above or below to move to at all.
  pressNav('ArrowDown')
  expect(tabs[0]).toHaveAttribute('aria-selected', 'true')

  pressNav('ArrowUp')
  expect(tabs[0]).toHaveAttribute('aria-selected', 'true')
})

test('switching a tab with the mouse focuses its content; re-clicking the active tab focuses the group', async () => {
  renderApp()
  const user = userEvent.setup()
  await openNewTab(user, initialPane())
  await openNewTab(user, initialPane())
  const tabs = screen.getAllByRole('tab')
  const group = panes()[0]

  // The newest tab is active after the two new-tab clicks, so its content
  // pane starts active and the group does not.
  expect(panes()[3]).toHaveClass('pane-active')
  expect(group).not.toHaveClass('pane-active')

  // Switching to tab 0 (the original pane) is a real switch: focus moves
  // straight to its content pane, no second click needed.
  await user.click(tabs[0]!)
  expect(panes()[1]).toHaveClass('pane-active')
  expect(group).not.toHaveClass('pane-active')

  // Re-clicking the now-active tab doesn't switch anything, so the click
  // bubbles up and focuses the group instead, same as clicking its chrome.
  await user.click(tabs[0]!)
  expect(group).toHaveClass('pane-active')
  expect(panes()[1]).not.toHaveClass('pane-active')
})

test('a navigation press flashes the direction indicator, then removes it', () => {
  renderApp()

  pressNav('ArrowRight')
  const flash = screen.getByTestId('nav-flash')
  expect(flash).toHaveAttribute('data-direction', 'right')

  // The overlay unmounts itself when the fade finishes; jsdom runs no CSS
  // animations, so deliver the animationend the fade would produce.
  fireEvent.animationEnd(flash)
  expect(screen.queryByTestId('nav-flash')).not.toBeInTheDocument()
})

// A rebound nav shortcut has to reach the renderer's own keydown handler,
// which reads its bindings from settings on every press (see spatialNav.ts).
// Main enforces the same four bindings a second time for focused <webview>
// guests — that copy can only be exercised on Electron, and is covered in
// e2e/keyboard-shortcuts.spec.ts.
test('a rebound navigation shortcut moves focus, and the default no longer does', async () => {
  renderApp({ settings: { shortcuts: { 'nav-right': { mod: true, alt: true, code: 'KeyL' } } } })
  const user = userEvent.setup()
  await splitHorizontal(user, initialPane())
  await user.click(headerOf(panes()[1]!))
  expect(panes()[1]).toHaveClass('pane-active')

  // The combination it used to be on is now bound to nothing at all.
  pressNav('ArrowRight')
  expect(panes()[1]).toHaveClass('pane-active')

  pressNav('KeyL', { altKey: true })
  expect(panes()[2]).toHaveClass('pane-active')
})

// Clearing a binding must leave the action reachable by other means but
// unreachable by key — the menu item stays, the keypress does nothing.
test('an unbound navigation shortcut does nothing', async () => {
  renderApp({ settings: { shortcuts: { 'nav-right': null } } })
  const user = userEvent.setup()
  await splitHorizontal(user, initialPane())
  await user.click(headerOf(panes()[1]!))
  expect(panes()[1]).toHaveClass('pane-active')

  pressNav('ArrowRight')
  expect(panes()[1]).toHaveClass('pane-active')
})

// A content type that wears a text field for its own reasons — xterm's hidden
// helper textarea being the real case (see TerminalRenderer) — opts out of the
// "arrows are editing this" heuristic with data-nav-text-input="false". Core
// names no content type for this; the terminal-focus half is on Electron,
// where a real xterm can be focused (e2e/keyboard-nav.spec.ts).
test('a text field marked data-nav-text-input="false" does not swallow a nav press', async () => {
  renderApp()
  const user = userEvent.setup()
  await splitHorizontal(user, initialPane())
  await user.click(headerOf(panes()[1]!))
  expect(panes()[1]).toHaveClass('pane-active')

  const optedOut = textFieldIn(panes()[1]!, 'false')
  pressNavOn(optedOut, 'ArrowRight')
  expect(panes()[2]).toHaveClass('pane-active')
})

test('an ordinary text field still keeps the arrows for editing', async () => {
  renderApp()
  const user = userEvent.setup()
  await splitHorizontal(user, initialPane())
  await user.click(headerOf(panes()[1]!))
  expect(panes()[1]).toHaveClass('pane-active')

  // Same press, same place, no marker: the field wins and focus stays put.
  const plain = textFieldIn(panes()[1]!)
  pressNavOn(plain, 'ArrowRight')
  expect(panes()[1]).toHaveClass('pane-active')
})

// A focused <webview> guest swallows every keydown before this window sees it,
// so main matches the chord and forwards the direction over the browserGuest
// channel. Core no longer subscribes to that channel itself — the browser
// content type does, at registration (src/plugins/browser/renderer/guestNavKeys.ts),
// and the stub content stands in for it here. Without that inversion working,
// this press reaches nothing at all.
test('a nav press forwarded out of a guest navigates, without any keydown', async () => {
  renderApp()
  const user = userEvent.setup()
  await splitHorizontal(user, initialPane())
  await user.click(headerOf(panes()[1]!))
  expect(panes()[1]).toHaveClass('pane-active')

  // Wrapped in act(): unlike fireEvent, this arrives from outside React
  // entirely — the bridge callback updates the store directly, and without
  // act() the re-render it schedules hasn't happened when the class is read.
  act(() => window.__fakeApi?.emitNavKey('right'))
  expect(panes()[2]).toHaveClass('pane-active')

  act(() => window.__fakeApi?.emitNavKey('left'))
  expect(panes()[1]).toHaveClass('pane-active')
})
