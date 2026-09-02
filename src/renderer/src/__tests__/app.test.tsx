import { PANE_BUTTON } from '@shared/paneDomAttrs'
import { act, fireEvent, screen, within } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { expect, test } from 'vitest'
import { initialPane, panes } from '../testing/domQueries'
import { openNewTab, splitHorizontal, splitVertical } from '../testing/paneActions'
import { renderApp } from '../testing/renderApp'

// Ported from e2e/app.spec.ts — structural pane/tab-group behavior, all
// model + DOM. Not here: `opens a window titled Tabs` (real preload boot,
// e2e/ipc-smoke.spec.ts), and the dimming + nested-group-via-drag tests
// (computed CSS and real drag geometry — e2e/browser/app.spec.ts).
//
// Every fresh render already has one top-level tab (the docked root's own
// auto-wrap — see ensureTabsRoot in tree.ts): panes()[0] is that wrapper
// throughout every test below, and initialPane() (panes()[1]) is the real
// pane these tests exercise. Because that pane already sits inside root's
// own tab, "New tab" on it joins root's own bar rather than wrapping it in a
// fresh nested group — there is no such thing as an ungrouped pane out of
// the box any more. Tests that need one (to exercise the "New tab wraps a
// bare pane into a brand-new group" path) split first: a split child has no
// enclosing tab of its own, the same as the pre-invariant root did.

test('starts with a single top-level tab wrapping one empty pane, the pane active', () => {
  renderApp()
  expect(panes()).toHaveLength(2)
  expect(screen.getByTestId('empty-pane')).toBeVisible()
  expect(initialPane()).toHaveClass('pane-active')
  expect(panes()[0]).not.toHaveClass('pane-active')
  expect(screen.getAllByRole('tablist')).toHaveLength(1)
  expect(screen.getByRole('tab')).toHaveTextContent('Tabs')
})

test('New tab on the initial pane adds a sibling top-level tab', async () => {
  renderApp()
  const user = userEvent.setup()
  await openNewTab(user, initialPane())

  // Still just root's own tablist — the new tab joined it rather than
  // wrapping the pane in a fresh nested group, since the pane was already
  // sitting inside root's own tab.
  expect(screen.getAllByRole('tablist')).toHaveLength(1)
  const tabs = screen.getAllByRole('tab')
  expect(tabs).toHaveLength(2)
  expect(tabs[1]).toHaveAttribute('aria-selected', 'true')
  expect(tabs[0]).toHaveTextContent('Tabs')
  // A placeholder landing directly in root's own group reads "Tabs" like the
  // root's own default tab, wherever it was minted from — the window's own
  // tab strip, not a pane opened inside it (see tabTitler in layoutStore.ts).
  // "New Tab" is what the same placeholder reads in any nested group.
  expect(tabs[1]).toHaveTextContent('Tabs')
})

test('repeated New tab clicks on the initial pane keep adding top-level tabs', async () => {
  renderApp()
  const user = userEvent.setup()
  await openNewTab(user, initialPane())
  await openNewTab(user, initialPane())

  expect(screen.getAllByRole('tablist')).toHaveLength(1)
  const tabs = screen.getAllByRole('tab')
  expect(tabs).toHaveLength(3)
  expect(tabs[2]).toHaveAttribute('aria-selected', 'true')
})

// The per-tab close × is a different button from the pane-header close action
// (pane-header.test.tsx), and an IconButton like it: the label lands as the
// accessible name, the native `title` and the hover bubble together. jsdom can
// pin the first two; the bubble itself is measured in the Chromium tier
// (e2e/browser/tooltip.spec.ts).
test("a tab's close button is labeled with what it closes", async () => {
  renderApp()
  const user = userEvent.setup()
  await openNewTab(user, initialPane())

  const secondTab = screen.getAllByRole('tab')[1]!
  const closeButton = within(secondTab).getByRole('button', { name: 'Close Tabs' })
  expect(closeButton).toHaveAttribute('title', 'Close Tabs')
})

test('New tab on a genuinely ungrouped pane (a split child) wraps it into a nested tab group', async () => {
  renderApp()
  const user = userEvent.setup()
  await splitHorizontal(user, initialPane())
  // Neither split child has a tab wrapper of its own.
  await openNewTab(user, panes()[2]!)

  // Root's own tablist is untouched; a new, nested one opened just for the
  // split pane that got converted.
  const tablists = screen.getAllByRole('tablist')
  expect(tablists).toHaveLength(2)
  const nestedTabs = within(tablists[1]!).getAllByRole('tab')
  expect(nestedTabs).toHaveLength(1)
  expect(nestedTabs[0]).toHaveAttribute('aria-selected', 'true')
  expect(nestedTabs[0]).toHaveTextContent('New Tab')
})

test('clicking the root tab strip activates the wrapper pane, not its tab content', async () => {
  renderApp()
  const user = userEvent.setup()

  await user.click(screen.getAllByRole('tablist')[0]!)
  expect(panes()[0]).toHaveClass('pane-active')
  expect(initialPane()).not.toHaveClass('pane-active')
})

test('split creates a second pane and activates it', async () => {
  renderApp()
  const user = userEvent.setup()
  await splitHorizontal(user, initialPane())

  // The wrapper, the original pane, and the new split-off pane.
  expect(panes()).toHaveLength(3)
  expect(panes()[1]).not.toHaveClass('pane-active')
  expect(panes()[2]).toHaveClass('pane-active')
  expect(screen.getAllByTestId('empty-pane')).toHaveLength(2)
})

test("a pane's own header button acts on that pane even while a different pane is active", async () => {
  renderApp()
  const user = userEvent.setup()
  await splitHorizontal(user, initialPane())

  // The split auto-activated the second (new) pane.
  expect(panes()[2]).toHaveClass('pane-active')

  // Pane 1's own header button should still act on pane 1 directly, no
  // matter which pane is currently "active".
  await openNewTab(user, panes()[1]!)

  // Root's own tablist, plus the new nested one.
  expect(screen.getAllByRole('tablist')).toHaveLength(2)
  // The wrapper, pane 1 converted into a 1-tab group, its tab's own (new,
  // empty) content, and the untouched second split pane.
  expect(panes()).toHaveLength(4)
  expect(screen.getAllByTestId('empty-pane')).toHaveLength(2)

  // Split again, still targeting pane 1 (now the group) directly.
  await splitVertical(user, panes()[1]!)

  expect(screen.getAllByRole('tablist')).toHaveLength(2)
  // 5 panes: the wrapper, the tab group, its tab's content, the untouched
  // pane from the first split, and the new split-off pane.
  expect(panes()).toHaveLength(5)
})

test("selecting a tab's own content adds a sibling tab to its group, not a nested one", async () => {
  renderApp()
  const user = userEvent.setup()
  await openNewTab(user, initialPane())
  expect(screen.getAllByRole('tablist')).toHaveLength(1)
  expect(screen.getAllByRole('tab')).toHaveLength(2)

  // The tab's content is its own pane, nested inside the group's pane.
  expect(panes()).toHaveLength(3)
  await user.click(panes()[2]!)
  expect(panes()[2]).toHaveClass('pane-active')
  expect(panes()[1]).not.toHaveClass('pane-active')

  await openNewTab(user, panes()[2]!)

  // The new tab joined the bar this content already belongs to (root's
  // own), rather than nesting a second group inside it.
  expect(screen.getAllByRole('tablist')).toHaveLength(1)
  expect(screen.getAllByRole('tab')).toHaveLength(3)
  // The wrapper, tab 1's (hidden) content, tab 2's (hidden) content, and
  // tab 3's content.
  expect(panes()).toHaveLength(4)
})

test('closing the last tab of a converted pane empties it without collapsing the split', async () => {
  renderApp()
  const user = userEvent.setup()
  await splitVertical(user, initialPane())
  await openNewTab(user, panes()[2]!)
  expect(screen.getAllByRole('tablist')).toHaveLength(2)
  // The wrapper, the other split pane, the tab group itself, and its tab's
  // own content.
  expect(panes()).toHaveLength(4)

  const nestedTab = within(screen.getAllByRole('tablist')[1]!).getByRole('tab')
  await user.click(within(nestedTab).getByLabelText('Close New Tab'))

  // The split stays divided; the emptied pane just reverts to a placeholder.
  expect(panes()).toHaveLength(3)
  expect(screen.getAllByRole('tablist')).toHaveLength(1)
  expect(screen.getAllByTestId('empty-pane')).toHaveLength(2)
})

test('closing one tab of a two-tab group collapses it back to the remaining pane', async () => {
  renderApp()
  const user = userEvent.setup()
  await splitHorizontal(user, initialPane())
  await openNewTab(user, panes()[2]!)
  // Targets the tab's own content pane directly, exercising the "sibling tab
  // via a tab's own content" path rather than "via the group itself".
  await openNewTab(user, panes()[3]!)
  const tablists = screen.getAllByRole('tablist')
  expect(tablists).toHaveLength(2)
  const tabs = within(tablists[1]!).getAllByRole('tab')
  expect(tabs).toHaveLength(2)

  await user.click(within(tabs[1]!).getByLabelText('Close New Tab'))

  // The mirror of promotion: the group's slot is replaced by the survivor's
  // own content, so the nested tab bar is gone entirely, not just down to
  // one tab — only root's own tablist remains.
  expect(screen.getAllByRole('tablist')).toHaveLength(1)
  expect(panes()).toHaveLength(3)
  expect(screen.getAllByTestId('empty-pane')).toHaveLength(2)
})

test('closing one tab of a two-tab group inside a split collapses it without touching the split', async () => {
  renderApp()
  const user = userEvent.setup()
  await splitVertical(user, initialPane())
  await openNewTab(user, panes()[2]!)
  await openNewTab(user, panes()[3]!)
  const tablists = screen.getAllByRole('tablist')
  expect(tablists).toHaveLength(2)
  const tabs = within(tablists[1]!).getAllByRole('tab')
  expect(tabs).toHaveLength(2)
  // The wrapper, the other split pane, the tab group itself, and both tabs'
  // own content panes (inactive tabs stay mounted, just hidden).
  expect(panes()).toHaveLength(5)

  await user.click(within(tabs[1]!).getByLabelText('Close New Tab'))

  // The split stays divided; the collapsed pane holds the survivor directly.
  expect(panes()).toHaveLength(3)
  expect(screen.getAllByRole('tablist')).toHaveLength(1)
  expect(screen.getAllByTestId('empty-pane')).toHaveLength(2)
})

test("right-clicking a single-tab group's bar offers Ungroup, collapsing it back to the pane", async () => {
  renderApp()
  const user = userEvent.setup()
  await splitHorizontal(user, initialPane())
  await openNewTab(user, panes()[2]!)
  const tablists = screen.getAllByRole('tablist')
  expect(tablists).toHaveLength(2)

  fireEvent.contextMenu(tablists[1]!, { clientX: 40, clientY: 40 })
  await user.click(screen.getByRole('menuitem', { name: 'Ungroup' }))

  // The mirror of the auto-collapse on close: the group's slot is replaced
  // by its lone tab's own content, so the nested bar is gone entirely —
  // only root's own tablist remains.
  expect(screen.getAllByRole('tablist')).toHaveLength(1)
  expect(panes()).toHaveLength(3)
  expect(screen.getAllByTestId('empty-pane')).toHaveLength(2)
})

test('a tab group with more than one tab offers no Ungroup option on its bar', async () => {
  renderApp()
  const user = userEvent.setup()
  await splitHorizontal(user, initialPane())
  await openNewTab(user, panes()[2]!)
  await openNewTab(user, panes()[3]!)
  const tablists = screen.getAllByRole('tablist')
  expect(tablists).toHaveLength(2)
  expect(within(tablists[1]!).getAllByRole('tab')).toHaveLength(2)

  fireEvent.contextMenu(tablists[1]!, { clientX: 40, clientY: 40 })

  expect(screen.queryByRole('menuitem', { name: 'Ungroup' })).not.toBeInTheDocument()
})

test('the root tab group offers no Ungroup option on its own bar, at any tab count', () => {
  renderApp()

  fireEvent.contextMenu(screen.getAllByRole('tablist')[0]!, { clientX: 40, clientY: 40 })
  expect(screen.queryByRole('menuitem', { name: 'Ungroup' })).not.toBeInTheDocument()
})

test('an empty split pane can be closed from its title bar, collapsing the split', async () => {
  renderApp()
  const user = userEvent.setup()
  await splitHorizontal(user, initialPane())

  await user.click(within(panes()[1]!).getByTestId(PANE_BUTTON.close))

  expect(panes()).toHaveLength(2)
  expect(screen.getAllByTestId('empty-pane')).toHaveLength(1)
})

test('fullscreen is published as a single attribute on the shell, tracking the bridge', () => {
  // The publisher half of fullscreen handling: App stamps `data-fullscreen`
  // on the shell and nothing else in the tree reads the value — everything
  // that changes (the root bar's gutter and height) is CSS keyed off this
  // attribute, asserted with real styles in e2e/root-tab-bar.spec.ts.
  const { container } = renderApp()
  const shell = container.querySelector('.app-shell')
  expect(shell).not.toHaveAttribute('data-fullscreen')

  act(() => window.__fakeApi?.emitFullScreenChange(true))
  expect(shell).toHaveAttribute('data-fullscreen', 'true')

  act(() => window.__fakeApi?.emitFullScreenChange(false))
  expect(shell).not.toHaveAttribute('data-fullscreen')
})
