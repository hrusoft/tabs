import { act, screen, within } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { afterEach, expect, test } from 'vitest'
import { contentRegistry } from '../core/registry/registry'
import { initialPane, panes } from '../testing/domQueries'
import { renderApp } from '../testing/renderApp'
import {
  registerSecondStubType,
  SECOND_STUB_TYPE,
  STUB_TYPE,
  unregisterSecondStubType
} from '../testing/stubContent'

/**
 * The toolbar an empty pane shows in place of a placeholder — what it offers
 * and what pressing one does. The *geometry* of the row (32x32, shared edges,
 * only the ends rounded) has no meaning without real layout and lives in
 * e2e/browser/empty-pane-toolbar.spec.ts instead.
 *
 * Every expectation is derived from the content registry rather than written
 * out, so adding a content type changes what these assert without editing
 * them — which is the whole point of the toolbar reading `createAction` off
 * the registry instead of keeping a list.
 *
 * Every test states its own `disabledContentTypes` rather than inheriting it
 * from DEFAULT_SETTINGS.
 */

/** The set of buttons the registry says an empty pane must currently offer. */
function expectedToolbarTestIds(): string[] {
  return contentRegistry
    .list()
    .flatMap((def) => (def.createAction ? [`empty-${def.createAction.testId}`] : []))
}

function toolbarButtonTestIds(): string[] {
  const toolbar = screen.getByTestId('empty-pane-toolbar')
  return within(toolbar)
    .getAllByRole('button')
    .map((button) => button.dataset.testid ?? '')
}

afterEach(unregisterSecondStubType)

test('an empty pane offers exactly the creation actions the registry carries', () => {
  renderApp({ settings: { disabledContentTypes: [] } })
  registerSecondStubType()

  // Derived on both sides: two types today, three the moment one registers.
  expect(toolbarButtonTestIds()).toEqual(expectedToolbarTestIds())
  expect(toolbarButtonTestIds()).toHaveLength(2)
  // The placeholder sentence is gone — it is the toolbar's fallback now, not
  // its companion.
  expect(screen.getByTestId('empty-pane')).not.toHaveTextContent('Settings')
})

test("a toolbar button carries the content type's own label and icon", () => {
  renderApp({ settings: { disabledContentTypes: [] } })

  const button = screen.getByTestId('empty-pane-new-stub-button')
  // Both come off createAction, so a type gets them by declaring the pane
  // header button it already had to declare.
  expect(button).toHaveAttribute('aria-label', 'New stub')
  expect(button).toHaveAttribute('title', 'New stub')
  expect(button).toHaveTextContent('▣')
})

test('pressing one fills the pane in place rather than opening anything beside it', async () => {
  renderApp({ settings: { disabledContentTypes: [] } })
  const user = userEvent.setup()
  // Root's own wrapping tab group, plus the one real (empty) pane in its tab.
  expect(panes()).toHaveLength(2)
  expect(screen.getAllByRole('tab')).toHaveLength(1)

  await user.click(within(initialPane()).getByTestId('empty-pane-new-stub-button'))

  // Same slot, new content: no new pane, no new tab, and the placeholder gone.
  expect(panes()).toHaveLength(2)
  expect(screen.getAllByRole('tab')).toHaveLength(1)
  expect(screen.getByTestId('stub-content')).toBeVisible()
  expect(screen.queryByTestId('empty-pane')).not.toBeInTheDocument()
})

test('pressing one leaves the pane it filled active, not some stale id', async () => {
  renderApp({ settings: { disabledContentTypes: [] } })
  const user = userEvent.setup()

  await user.click(within(initialPane()).getByTestId('empty-pane-new-stub-button'))

  // The click bubbling into Pane's own activate handler would aim
  // setActivePane at the leaf this call just replaced.
  expect(initialPane()).toHaveClass('pane-active')
})

test('a disabled content type contributes no button', () => {
  renderApp({ settings: { disabledContentTypes: [STUB_TYPE] } })
  registerSecondStubType()

  expect(toolbarButtonTestIds()).toEqual(['empty-pane-new-stub-two-button'])
})

// "Re-enabling from another window restores the button" is pinned once, in
// content-types.test.tsx: both surfaces render from the same
// useCreationActions gate, so the mechanism under test there — settingsStore
// mirroring — covers this toolbar identically.

test('disabling every content type replaces the row with the way back to Settings', () => {
  renderApp({ settings: { disabledContentTypes: [] } })
  registerSecondStubType()

  act(() => {
    window.__fakeApi?.emitSettingsChange({ disabledContentTypes: [STUB_TYPE, SECOND_STUB_TYPE] })
  })

  // No empty row left behind, and the sentence names where the state came from
  // — the pane is otherwise a dead end, since its header's creation group is
  // gone for the same reason.
  expect(screen.queryByTestId('empty-pane-toolbar')).not.toBeInTheDocument()
  expect(screen.getByTestId('empty-pane')).toHaveTextContent(
    'No content types are enabled — turn one on in Settings → General → Content types.'
  )
})
