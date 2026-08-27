import { PANE_BUTTON } from '@shared/paneDomAttrs'
import { act, screen, within } from '@testing-library/react'
import { afterEach, expect, test } from 'vitest'
import { headerOf, initialPane } from '../testing/domQueries'
import { renderApp } from '../testing/renderApp'
import {
  registerSecondStubType,
  SECOND_STUB_TYPE,
  STUB_TYPE,
  unregisterSecondStubType
} from '../testing/stubContent'

/**
 * Turning a content type off, from the pane chrome's side.
 *
 * Driven against the stub content type rather than the terminal or the
 * browser: those two live behind xterm and the `<webview>` tag, which this
 * tier deliberately cannot import (see testing/registerTestContent.ts). That
 * costs nothing here — the gate honours plain list membership for any type at
 * all, which is exactly why it does not consult the census (see
 * shared/content/enablement.ts). The one case the real pair is needed for —
 * that disabling the *first* registered type promotes the real next one — is
 * covered in the Electron tier, where both actually exist.
 *
 * Every test states its own `disabledContentTypes` rather than inheriting it
 * from DEFAULT_SETTINGS.
 */

/** A second creation-capable type, so "which one is the root button" is a real question. */
afterEach(unregisterSecondStubType)

test('a disabled content type contributes no creation button', () => {
  renderApp({ settings: { disabledContentTypes: [STUB_TYPE] } })

  const header = headerOf(initialPane())
  expect(within(header).queryByTestId('pane-new-stub-button')).not.toBeInTheDocument()
  // Only the creation group goes: split/tab and close/clear are core chrome and
  // have nothing to do with which content types exist.
  expect(within(header).getByTestId(PANE_BUTTON.splitHorizontal)).toBeInTheDocument()
  expect(within(header).getByTestId(PANE_BUTTON.close)).toBeInTheDocument()
})

test('an enabled content type still contributes one while a different type is disabled', () => {
  renderApp({ settings: { disabledContentTypes: ['some-other-type'] } })

  expect(within(headerOf(initialPane())).getByTestId('pane-new-stub-button')).toBeInTheDocument()
})

test('re-enabling a type from another window restores its button without a reload', () => {
  renderApp({ settings: { disabledContentTypes: [STUB_TYPE] } })
  expect(
    within(headerOf(initialPane())).queryByTestId('pane-new-stub-button')
  ).not.toBeInTheDocument()

  // The real cross-window path: the Settings window writes, main broadcasts
  // settings:changed, and this window's store mirrors it (see settingsStore).
  act(() => {
    window.__fakeApi?.emitSettingsChange({ disabledContentTypes: [] })
  })

  expect(within(headerOf(initialPane())).getByTestId('pane-new-stub-button')).toBeInTheDocument()
})

test('disabling the first registered type promotes the next one to the root button', () => {
  renderApp({ settings: { disabledContentTypes: [] } })
  registerSecondStubType()

  // With both enabled, registration order holds: the stub is the root and the
  // second type sits in its dropdown.
  const before = headerOf(initialPane())
  expect(within(before).getByTestId('pane-new-stub-button')).not.toHaveAttribute('role', 'menuitem')
  expect(within(before).getByTestId('pane-new-stub-two-button')).toHaveAttribute('role', 'menuitem')

  act(() => {
    window.__fakeApi?.emitSettingsChange({ disabledContentTypes: [STUB_TYPE] })
  })

  // The survivor is now the always-visible root button, and — being the only
  // one left — carries no dropdown at all.
  const after = headerOf(initialPane())
  expect(within(after).queryByTestId('pane-new-stub-button')).not.toBeInTheDocument()
  const root = within(after).getByTestId('pane-new-stub-two-button')
  expect(root).not.toHaveAttribute('role', 'menuitem')
  expect(within(after).queryByTestId('pane-new-stub-two-button-menu-item')).not.toBeInTheDocument()
})

test('disabling every content type drops the creation group entirely', () => {
  renderApp({ settings: { disabledContentTypes: [] } })
  registerSecondStubType()

  act(() => {
    window.__fakeApi?.emitSettingsChange({ disabledContentTypes: [STUB_TYPE, SECOND_STUB_TYPE] })
  })

  const header = headerOf(initialPane())
  expect(within(header).queryByTestId('pane-new-stub-button')).not.toBeInTheDocument()
  expect(within(header).queryByTestId('pane-new-stub-two-button')).not.toBeInTheDocument()
  // Deliberately allowed rather than guarded against: every new pane is empty
  // until the user re-enables something, which is recoverable from Settings.
  // The group is simply omitted — PaneHeaderControls already guarded that case
  // for a build registering no content types at all.
  // The wrapper (root's own tab group) plus the one real pane it holds.
  expect(screen.getAllByTestId('pane')).toHaveLength(2)
  expect(within(header).getByTestId(PANE_BUTTON.splitHorizontal)).toBeInTheDocument()
})
