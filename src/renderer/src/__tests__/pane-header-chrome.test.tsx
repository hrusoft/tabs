import { PANE_BUTTON } from '@shared/paneDomAttrs'
import { screen, within } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { expect, test } from 'vitest'
import { headerOf, initialPane } from '../testing/domQueries'
import { fillEmptyPane } from '../testing/paneActions'
import { renderApp } from '../testing/renderApp'
import {
  registerStubHeaderChromeType,
  unregisterStubHeaderChromeType
} from '../testing/stubContent'

// Generic-mechanism coverage for ContentRendererDef.HeaderControl/HeaderTitle
// (registry.ts) against a synthetic stub type — proves the wiring in
// Pane.tsx/PaneHeaderControls.tsx itself, independent of the terminal's and
// browser's own real implementations (which get their own behavioral tests).

test('a plain content type contributes no HeaderControl and keeps the default title', async () => {
  renderApp()
  const user = userEvent.setup()
  await fillEmptyPane(user, initialPane(), 'pane-new-stub-button')

  const header = headerOf(initialPane())
  expect(within(header).queryByTestId('stub-header-control')).not.toBeInTheDocument()
  expect(within(header).queryByTestId('stub-header-title')).not.toBeInTheDocument()
  expect(within(header).getByText('Stub')).toBeVisible()
})

test('a HeaderControl renders leftmost in the header controls row, ahead of Split horizontally', async () => {
  renderApp()
  const user = userEvent.setup()
  registerStubHeaderChromeType()
  try {
    await fillEmptyPane(user, initialPane(), 'pane-new-stub-header-chrome-button')
    const header = headerOf(initialPane())
    const control = within(header).getByTestId('stub-header-control')
    const splitButton = within(header).getByTestId(PANE_BUTTON.splitHorizontal)

    // DOCUMENT_POSITION_FOLLOWING on the split button means it comes *after*
    // the stub control in document order — structure-agnostic, so it holds
    // whichever of the two ends up nested inside its own wrapper.
    expect(
      control.compareDocumentPosition(splitButton) & Node.DOCUMENT_POSITION_FOLLOWING
    ).toBeTruthy()
  } finally {
    unregisterStubHeaderChromeType()
  }
})

test("a HeaderControl's press reaches the pane's own registered capability", async () => {
  renderApp()
  const user = userEvent.setup()
  registerStubHeaderChromeType()
  try {
    await fillEmptyPane(user, initialPane(), 'pane-new-stub-header-chrome-button')
    const header = headerOf(initialPane())
    expect(screen.getByTestId('stub-clear-count')).toHaveTextContent('0')

    await user.click(within(header).getByTestId('stub-header-control'))

    expect(screen.getByTestId('stub-clear-count')).toHaveTextContent('1')
  } finally {
    unregisterStubHeaderChromeType()
  }
})

test("a HeaderTitle replaces the pane's entire title slot", async () => {
  renderApp()
  const user = userEvent.setup()
  registerStubHeaderChromeType()
  try {
    await fillEmptyPane(user, initialPane(), 'pane-new-stub-header-chrome-button')
    const header = headerOf(initialPane())

    expect(within(header).getByTestId('stub-header-title')).toBeInTheDocument()
    expect(header.querySelector('.pane-title')).not.toBeInTheDocument()
  } finally {
    unregisterStubHeaderChromeType()
  }
})
