import { act, screen, within } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { afterEach, expect, test } from 'vitest'
import { dockedPanes, initialPane, panes } from '../testing/domQueries'
import { clickPaneButton } from '../testing/paneActions'
import { renderApp } from '../testing/renderApp'
import { registerSecondStubType, STUB_TYPE, unregisterSecondStubType } from '../testing/stubContent'

/**
 * Cmd/Ctrl+P's command palette: a two-step overlay (content type, then
 * placement) driven by the same `fireShortcut` mechanism as every other
 * `layer: 'menu'` action (see pane-shortcuts.test.tsx) — a raw
 * `fireEvent.keyDown` would not reach it, since menu-layer bindings are
 * enforced by the native menu, not a renderer keydown listener.
 *
 * Once open, the overlay is driven with `userEvent.keyboard`, which targets
 * `document.activeElement` — this is what exercises the palette's own
 * focus-steal (see CommandPalette.tsx): if it didn't move DOM focus onto
 * itself when it opened, these key presses would have nowhere real to land
 * in a browser pane's `<webview>` (that scenario itself needs a real guest
 * and stays in e2e/commandPalette.spec.ts).
 */

afterEach(unregisterSecondStubType)

test('Cmd/Ctrl+P opens the palette listing every enabled content type', async () => {
  renderApp()

  await act(async () => {
    window.__fakeApi?.fireShortcut('command-palette')
  })

  expect(screen.getByTestId('command-palette-backdrop')).toBeVisible()
  const item = screen.getByTestId('command-palette-item-pane-new-stub-button')
  // The type's plain displayName ('Stub'), not the button's imperative
  // label ('New stub') — see useCreationActions's own note on why.
  expect(item).toHaveTextContent('Stub')
  expect(item).toHaveTextContent('1')
})

test('Enter on the highlighted content type advances to the placement step', async () => {
  renderApp()
  const user = userEvent.setup()

  await act(async () => {
    window.__fakeApi?.fireShortcut('command-palette')
  })
  await user.keyboard('{Enter}')

  // The shared shortcut label with its "New " prefix dropped — every row
  // here is already about placing something new, so it read as noise.
  expect(screen.getByTestId('command-palette-item-new-tab')).toHaveTextContent('Tab')
  expect(screen.getByTestId('command-palette-item-split-horizontal')).toHaveTextContent(
    'Horizontal Split'
  )
  expect(screen.getByTestId('command-palette-item-split-vertical')).toHaveTextContent(
    'Vertical Split'
  )
  expect(screen.getByTestId('command-palette-item-new-unpinned-pane')).toHaveTextContent(
    'Unpinned Pane'
  )
  // Same icons as the pane header's own split/tab buttons (./icons) — not
  // just text rows.
  expect(screen.getByTestId('command-palette-item-new-tab').querySelector('svg')).toBeTruthy()
})

test('choosing a type then a placement creates and places the content, closing the overlay', async () => {
  renderApp()
  const user = userEvent.setup()
  expect(screen.getByTestId('empty-pane')).toBeVisible()

  await act(async () => {
    window.__fakeApi?.fireShortcut('command-palette')
  })
  await user.keyboard('{Enter}') // choose the (only) content type
  await user.keyboard('{Enter}') // choose the (first, highlighted) placement: New Tab

  // Same slot, new content — an empty target is filled in place (see
  // EmptyPaneRenderer's own header-button test for the identical contract).
  expect(panes()).toHaveLength(2)
  expect(screen.getByTestId('stub-content')).toBeVisible()
  expect(screen.queryByTestId('empty-pane')).not.toBeInTheDocument()
  expect(screen.queryByTestId('command-palette-backdrop')).not.toBeInTheDocument()
})

test('a digit key selects the corresponding item directly, without arrow navigation', async () => {
  renderApp()
  registerSecondStubType()
  const user = userEvent.setup()

  await act(async () => {
    window.__fakeApi?.fireShortcut('command-palette')
  })
  await user.keyboard('2') // second content type, skipping the first entirely
  await user.keyboard('{Enter}') // the highlighted (first) placement: New Tab

  // Proves item 2, not item 1, was the one chosen — its content is what got
  // created, not the first type's.
  expect(screen.getByTestId('stub-two-content')).toBeVisible()
  expect(screen.queryByTestId('stub-content')).not.toBeInTheDocument()
})

test('arrow keys move the highlight and wrap at the ends', async () => {
  renderApp()
  registerSecondStubType()
  const user = userEvent.setup()

  await act(async () => {
    window.__fakeApi?.fireShortcut('command-palette')
  })

  const first = screen.getByTestId('command-palette-item-pane-new-stub-button')
  const second = screen.getByTestId('command-palette-item-pane-new-stub-two-button')
  expect(first).toHaveClass('command-palette-item-highlighted')

  await user.keyboard('{ArrowDown}')
  expect(second).toHaveClass('command-palette-item-highlighted')
  expect(first).not.toHaveClass('command-palette-item-highlighted')

  await user.keyboard('{ArrowDown}')
  expect(first).toHaveClass('command-palette-item-highlighted')
})

test('Escape closes the overlay and returns focus to the pane that was active', async () => {
  renderApp()
  const user = userEvent.setup()
  // Fill and, by filling in place, focus the active pane's own content —
  // registerPaneHandle focuses on mount when its id is already active.
  await clickPaneButton(user, initialPane(), 'pane-new-stub-button')
  const content = screen.getByTestId('stub-content')
  expect(content).toHaveFocus()

  await act(async () => {
    window.__fakeApi?.fireShortcut('command-palette')
  })
  expect(content).not.toHaveFocus()

  await user.keyboard('{Escape}')

  expect(screen.queryByTestId('command-palette-backdrop')).not.toBeInTheDocument()
  expect(content).toHaveFocus()
})

test('clicking the backdrop closes the overlay, same as Escape', async () => {
  renderApp()
  const user = userEvent.setup()

  await act(async () => {
    window.__fakeApi?.fireShortcut('command-palette')
  })
  await user.click(screen.getByTestId('command-palette-backdrop'))

  expect(screen.queryByTestId('command-palette-backdrop')).not.toBeInTheDocument()
})

test('clicking an item selects it, same as Enter', async () => {
  renderApp()
  const user = userEvent.setup()

  await act(async () => {
    window.__fakeApi?.fireShortcut('command-palette')
  })
  await user.click(screen.getByTestId('command-palette-item-pane-new-stub-button'))
  await user.click(screen.getByTestId('command-palette-item-new-unpinned-pane'))

  expect(screen.getAllByTestId('floating-window')).toHaveLength(1)
  expect(dockedPanes()).toHaveLength(2)
})

test('when every content type is disabled, the palette shows the empty-state message', async () => {
  renderApp({ settings: { disabledContentTypes: [STUB_TYPE] } })

  await act(async () => {
    window.__fakeApi?.fireShortcut('command-palette')
  })

  // The active (empty) pane shows the identical sentence in its own
  // toolbar fallback, so scope the query to the palette itself.
  expect(
    within(screen.getByTestId('command-palette-backdrop')).getByText(
      'No content types are enabled — turn one on in Settings → General → Content types.'
    )
  ).toBeVisible()
})
