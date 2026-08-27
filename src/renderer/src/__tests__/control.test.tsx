import { act, screen, within } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { afterEach, expect, test, vi } from 'vitest'
import { headerOf, initialPane } from '../testing/domQueries'
import { clickPaneButton, openNewTab } from '../testing/paneActions'
import { renderApp } from '../testing/renderApp'

afterEach(() => {
  vi.restoreAllMocks()
})

// Generalizes bell.test.tsx's coverage to the control indicator: the same
// content-agnostic push shape — here simulated through the fake bridge's
// emitOwnershipChanged, mirroring the real ledger's grantOwnership/
// releaseOwnership broadcast (see controlStore.ts and
// src/main/externalControl.ts) — driving the same lead-position icon and
// pane-content-border pulse. What's under test here is the one deliberate
// difference from the bell: a controlled pane never marks a parent tab.

test('an owned pane shows the control indicator even backgrounded, and never flags its parent tab', async () => {
  renderApp()
  const user = userEvent.setup()
  await clickPaneButton(user, initialPane(), 'pane-new-stub-button')
  const controlledPane = initialPane()
  const controlledId = controlledPane.getAttribute('data-dock-id') ?? ''

  // "New tab" on the content pane adds a sibling tab to root's own group and
  // focuses it, backgrounding tab 1 before it's marked controlled — the
  // bell's equivalent test (bell.test.tsx) asserts the tab DOES flag; this
  // asserts it never does.
  await openNewTab(user, initialPane())

  const tabs = screen.getAllByRole('tab')
  expect(tabs).toHaveLength(2)
  expect(tabs[0]).not.toHaveClass('tab-active')

  act(() => {
    window.__fakeApi?.emitOwnershipChanged(controlledId, true)
  })

  // The pane itself is marked, backgrounded or not (getByTestId doesn't
  // care that its tab panel is currently hidden)...
  expect(controlledPane).toHaveClass('pane-controlled')
  expect(within(headerOf(controlledPane)).getByTestId('pane-control-icon')).toBeInTheDocument()
  // ...but its parent tab carries no equivalent marker, unlike a bell.
  expect(within(tabs[0]!).queryByTestId('tab-control-icon')).not.toBeInTheDocument()
})

test('releasing ownership clears the control indicator', () => {
  renderApp()
  const id = initialPane().getAttribute('data-dock-id') ?? ''

  act(() => {
    window.__fakeApi?.emitOwnershipChanged(id, true)
  })
  expect(initialPane()).toHaveClass('pane-controlled')
  expect(within(headerOf(initialPane())).getByTestId('pane-control-icon')).toBeInTheDocument()

  act(() => {
    window.__fakeApi?.emitOwnershipChanged(id, false)
  })
  expect(initialPane()).not.toHaveClass('pane-controlled')
  expect(within(headerOf(initialPane())).queryByTestId('pane-control-icon')).not.toBeInTheDocument()
})

test('the control indicator is suppressed while its setting is off', () => {
  renderApp({ settings: { enableControlIndicator: false } })
  const id = initialPane().getAttribute('data-dock-id') ?? ''

  act(() => {
    window.__fakeApi?.emitOwnershipChanged(id, true)
  })

  expect(initialPane()).not.toHaveClass('pane-controlled')
  expect(within(headerOf(initialPane())).queryByTestId('pane-control-icon')).not.toBeInTheDocument()
})
