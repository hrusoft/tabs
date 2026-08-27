import { act, screen, within } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { afterEach, expect, test, vi } from 'vitest'
import { useBellStore } from '../core/store/bellStore'
import { headerOf, initialPane, panes } from '../testing/domQueries'
import { clickPaneButton, openNewTab, splitHorizontal } from '../testing/paneActions'
import { renderApp } from '../testing/renderApp'

afterEach(() => {
  vi.restoreAllMocks()
})

// Ported from e2e/bell.spec.ts's backgrounded-tab test. The bell is raised
// straight on the content-agnostic bellStore — exactly what the terminal's
// onBell does (TerminalRenderer.tsx) — so what's under test here is the core
// half: TabBar's containment rendering (any leaf under a background tab
// rings its tab), persistence past the old one-shot flash, and the clear on
// focus via core's pane-handle wiring (PaneFocusFollower → handle.focus(),
// which the stub implements the same way the terminal does). The real
// pty→xterm→onBell wiring keeps its own Electron test in e2e/bell.spec.ts.
//
// initialPane() (panes()[1]) is the active pane in a fresh render, already
// sitting inside root's own tab (panes()[0]) — see app.test.tsx's header
// comment for why that means "New tab" here joins root's bar directly.

test('a bell inside a backgrounded tab flags the tab and clears when its pane is focused', async () => {
  renderApp()
  const user = userEvent.setup()
  await clickPaneButton(user, initialPane(), 'pane-new-stub-button')
  const ringingLeafId = initialPane().getAttribute('data-dock-id') ?? ''

  // "New tab" on the content pane adds a sibling tab to root's own group and
  // focuses it, backgrounding tab 1 before its bell rings.
  await openNewTab(user, initialPane())

  const tabs = screen.getAllByRole('tab')
  expect(tabs).toHaveLength(2)
  expect(tabs[0]).not.toHaveClass('tab-active')

  act(() => {
    useBellStore.getState().ring(ringingLeafId)
  })
  expect(within(tabs[0]!).getByTestId('tab-bell-icon')).toBeInTheDocument()

  // Outlives the old 0.8s one-shot flash — the actual regression this test
  // guards against (the highlight used to fade back out on its own here).
  await new Promise((resolve) => setTimeout(resolve, 1200))
  expect(within(tabs[0]!).getByTestId('tab-bell-icon')).toBeInTheDocument()

  await user.click(tabs[0]!)

  expect(tabs[0]).toHaveClass('tab-active')
  expect(within(tabs[0]!).queryByTestId('tab-bell-icon')).not.toBeInTheDocument()
})

// The attended check lives in ring() itself (bellStore.ts): a bell is dropped
// only when the user is looking at that pane at that instant — active pane
// AND focused window. These three pin the matrix the old `activePaneId`-only
// gate got wrong: it swallowed every bell that rang in the active pane while
// the user was away in another app, which in practice is most of them (a long
// command finishing while you read the browser).

test('a bell in the active pane is dropped while the window is focused', () => {
  renderApp()
  vi.spyOn(document, 'hasFocus').mockReturnValue(true)
  const activeId = initialPane().getAttribute('data-dock-id') ?? ''

  act(() => {
    useBellStore.getState().ring(activeId)
  })

  expect(initialPane()).not.toHaveClass('pane-alert')
  expect(useBellStore.getState().ringing.size).toBe(0)
})

test('a bell in the active pane flags it while the window is unfocused, and clears when the window refocuses', () => {
  renderApp()
  vi.spyOn(document, 'hasFocus').mockReturnValue(false)
  const activeId = initialPane().getAttribute('data-dock-id') ?? ''

  act(() => {
    useBellStore.getState().ring(activeId)
  })

  const header = headerOf(initialPane())
  expect(initialPane()).toHaveClass('pane-alert')
  expect(within(header).getByTestId('pane-bell-icon')).toBeInTheDocument()

  // Coming back to the app with the ringing pane active counts as seeing it.
  act(() => {
    window.dispatchEvent(new Event('focus'))
  })

  expect(initialPane()).not.toHaveClass('pane-alert')
})

test("refocusing the window leaves an inactive pane's bell ringing", async () => {
  renderApp()
  const user = userEvent.setup()
  await splitHorizontal(user, initialPane())
  // The split auto-activates the new pane, leaving the original (panes()[1])
  // inactive.
  const ringingId = panes()[1]!.getAttribute('data-dock-id') ?? ''
  await user.click(panes()[2]!)

  act(() => {
    useBellStore.getState().ring(ringingId)
  })
  expect(panes()[1]).toHaveClass('pane-alert')

  act(() => {
    window.dispatchEvent(new Event('focus'))
  })

  // Only the pane the user lands on is "seen" — this one still wants a look.
  expect(panes()[1]).toHaveClass('pane-alert')
})
