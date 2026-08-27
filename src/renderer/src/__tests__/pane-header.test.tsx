import { PANE_BUTTON } from '@shared/paneDomAttrs'
import { act, screen, within } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { expect, test, vi } from 'vitest'
import { contentRegistry } from '../core/registry/registry'
import { dockedPanes, headerOf, initialPane, panes } from '../testing/domQueries'
import {
  clickPaneButton,
  closePane,
  openNewTab,
  openNewUnpinnedTab,
  splitHorizontal,
  wrapInTabGroup
} from '../testing/paneActions'
import { renderApp } from '../testing/renderApp'
import { registerSecondStubType, STUB_TYPE, unregisterSecondStubType } from '../testing/stubContent'

// Ported from e2e/pane-header.spec.ts, with stub content standing in where a
// terminal was only "some non-empty content". The tests whose subject is the
// pty itself (close/clear killing the shell, reattach surviving a wrap) stay
// in the Electron tier.
//
// initialPane() (panes()[1]) is the real pane a fresh render exercises —
// see app.test.tsx's header comment for why root's own tab-group button
// (panes()[0]'s bar) refuses Split/Wrap in tab group, and why "New tab" on
// a pane already sitting inside root's tab joins root's own bar rather than
// nesting a fresh group.

test('every pane wears chrome: a titled bar, or the tab strip standing in for one', async () => {
  renderApp()
  const user = userEvent.setup()
  // Root's own chrome is a tab strip, not a titled bar — only the leaf
  // inside it gets a real .pane-header.
  expect(screen.getAllByTestId('pane-header')).toHaveLength(1)
  expect(screen.getByTestId('pane-header')).toHaveTextContent('Empty pane')
  expect(screen.getAllByRole('tablist')).toHaveLength(1)
  // The bar hosts the group pane's own controls.
  expect(within(headerOf(panes()[0]!)).getByTestId(PANE_BUTTON.close)).toBeVisible()

  // Filling the blank tab retitles its pane's bar to what it now holds.
  await clickPaneButton(user, initialPane(), 'pane-new-stub-button')
  expect(screen.getByTestId('pane-header')).toHaveTextContent('Stub')
})

test("clicking a pane's title bar activates that pane", async () => {
  renderApp()
  const user = userEvent.setup()
  await splitHorizontal(user, initialPane())
  expect(panes()[2]).toHaveClass('pane-active')

  await user.click(headerOf(panes()[1]!))

  expect(panes()[1]).toHaveClass('pane-active')
  expect(panes()[2]).not.toHaveClass('pane-active')
})

test('closing the root pane resets it to a fresh empty pane', async () => {
  renderApp()
  const user = userEvent.setup()
  await clickPaneButton(user, initialPane(), 'pane-new-stub-button')
  expect(screen.getByTestId('stub-content')).toBeVisible()

  await closePane(user, panes()[0]!)

  expect(panes()).toHaveLength(2)
  expect(screen.queryByTestId('stub-content')).not.toBeInTheDocument()
  expect(screen.getByTestId('empty-pane')).toBeVisible()
  // The root never actually disappears — it's still a tab group, just back
  // to its single default tab.
  expect(screen.getAllByRole('tablist')).toHaveLength(1)
})

test("closing a tab's content pane closes the tab itself, collapsing a two-tab group", async () => {
  renderApp()
  const user = userEvent.setup()
  await openNewTab(user, initialPane())
  expect(screen.getAllByRole('tab')).toHaveLength(2)
  expect(panes()).toHaveLength(3)

  // Pane 2 is the active tab's content. Its close routes through the tab,
  // so the group collapses to the survivor instead of stranding a
  // one-tab bar the way removing the bare node would.
  await closePane(user, panes()[2]!)

  // Root never stops being a tab group — it's just back to one tab.
  expect(screen.getAllByRole('tab')).toHaveLength(1)
  expect(panes()).toHaveLength(2)
  expect(screen.getAllByTestId('empty-pane')).toHaveLength(1)
})

test('closing the active pane in a 3-way split focuses its true neighbor, not the leftmost pane', async () => {
  renderApp()
  const user = userEvent.setup()
  await splitHorizontal(user, initialPane())
  await splitHorizontal(user, panes()[2]!)
  expect(panes()).toHaveLength(4)
  expect(panes()[3]).toHaveClass('pane-active')

  await closePane(user, panes()[3]!)

  // The middle pane (C's real left neighbor) gets focus — not the leftmost
  // pane, which a naive "first pane in the tree" fallback would pick.
  expect(panes()).toHaveLength(3)
  expect(panes()[2]).toHaveClass('pane-active')
  expect(panes()[1]).not.toHaveClass('pane-active')
})

test('closing a non-active pane never steals focus from the active one', async () => {
  renderApp()
  const user = userEvent.setup()
  await splitHorizontal(user, initialPane())
  await splitHorizontal(user, panes()[2]!)
  expect(panes()).toHaveLength(4)

  await user.click(headerOf(panes()[1]!))
  expect(panes()[1]).toHaveClass('pane-active')

  // Close the middle pane from its own header — not the active one.
  await closePane(user, panes()[2]!)

  expect(panes()).toHaveLength(3)
  expect(panes()[1]).toHaveClass('pane-active')
})

test('the tab-group control nests an existing group inside a new one', async () => {
  renderApp()
  const user = userEvent.setup()
  // Root's own header refuses Wrap in tab group (see isDockedRoot in
  // PaneHeaderControls), so a genuine "existing group" to nest has to come
  // from a split child instead.
  await splitHorizontal(user, initialPane())
  await openNewTab(user, panes()[2]!)
  expect(screen.getAllByRole('tablist')).toHaveLength(2)

  await wrapInTabGroup(user, panes()[2]!)

  // The old group became the sole tab of a fresh outer group, titled for
  // what it holds — three tab strips now: root's, the new outer wrapper's,
  // and the original nested one.
  expect(screen.getAllByRole('tablist')).toHaveLength(3)
  const groupTabs = screen
    .getAllByRole('tab')
    .filter((tab) => tab.textContent?.includes('Tab group'))
  expect(groupTabs).toHaveLength(1)
})

test('the split-group dropdown opens a new pane as an unpinned floating window', async () => {
  renderApp()
  const user = userEvent.setup()

  await openNewUnpinnedTab(user, initialPane())

  expect(screen.getAllByTestId('floating-window')).toHaveLength(1)
  // The docked layout never saw the new pane — it landed straight in the
  // floating list, not via a dock-then-unpin round trip.
  expect(dockedPanes()).toHaveLength(2)
})

test("a third registered content type appears in the content group's dropdown, not as a new root button", async () => {
  renderApp()
  const user = userEvent.setup()

  registerSecondStubType()

  try {
    const header = headerOf(panes()[0]!)
    // The first-registered content type (the stub content tests always run
    // with) stays the visible root button.
    expect(within(header).getByTestId('pane-new-stub-button')).toBeInTheDocument()

    // The newly-registered type shows up as a menu item, not a sibling root
    // button — registry order drives the dropdown, not a hardcoded list.
    const item = within(header).getByTestId('pane-new-stub-two-button')
    expect(item).toHaveAttribute('role', 'menuitem')

    await user.click(item)
    expect(screen.getByTestId('stub-two-content')).toBeVisible()
  } finally {
    unregisterSecondStubType()
  }
})

// --- The docked root's own chrome acts on the tab it is showing ---
//
// `closePane`/`clearPane` aimed at the root group used to mean the whole
// window: `removeNode` on the root resets the entire tree to one placeholder,
// so a single press on the window's own title bar — or Cmd+W while that bar
// held focus, which is a legitimate active pane — destroyed every tab, every
// pane and every process in the window at once. The store redirects both onto
// the top-level tab being shown instead (see `redirectFromDockedRoot`), the
// same way Split and Wrap already did. With one tab open the outcome is
// unchanged (see "closing the root pane resets it to a fresh empty pane"
// above); these pin the case where it differs.

/** Root's own bar, plus two more top-level tabs beside the first — three in all. */
async function threeTopLevelTabs(user: ReturnType<typeof userEvent.setup>): Promise<void> {
  await clickPaneButton(user, initialPane(), 'pane-new-stub-button')
  await openNewTab(user, panes()[0]!)
  await openNewTab(user, panes()[0]!)
  expect(screen.getAllByRole('tab')).toHaveLength(3)
  expect(screen.getAllByTestId('stub-content')).toHaveLength(3)
}

test('the root bar closes the top-level tab it is showing, not every tab in the window', async () => {
  renderApp()
  const user = userEvent.setup()
  await threeTopLevelTabs(user)

  await closePane(user, panes()[0]!)

  // Exactly one tab gone. Backgrounded tabs stay mounted, so the surviving
  // content is countable even while hidden.
  expect(screen.getAllByRole('tab')).toHaveLength(2)
  expect(screen.getAllByTestId('stub-content')).toHaveLength(2)
})

test('Cmd+W with the root tab bar focused closes that tab, not the window', async () => {
  renderApp()
  const user = userEvent.setup()
  await threeTopLevelTabs(user)

  // Clicking the root bar's own blank space activates the group itself — the
  // state in which Cmd+W used to resolve to the whole layout.
  await user.click(headerOf(panes()[0]!))
  expect(panes()[0]).toHaveClass('pane-active')

  // The handler confirms before closing, so it settles a microtask later.
  await act(async () => {
    window.__fakeApi?.fireShortcut('close-pane')
  })

  expect(screen.getAllByRole('tab')).toHaveLength(2)
  expect(screen.getAllByTestId('stub-content')).toHaveLength(2)
})

test('the root bar asks about the tab it would close, not about the whole window', async () => {
  renderApp()
  const user = userEvent.setup()
  await threeTopLevelTabs(user)

  // The confirmation only runs when some leaf's type can block, exactly as a
  // terminal with a live process does — so the stub claims it here.
  const confirmClose = vi.fn().mockResolvedValue(false)
  window.api.pane.confirmClose = confirmClose
  const def = contentRegistry.get(STUB_TYPE)
  if (!def) throw new Error('stub type is not registered')
  const restore = def.mayBlockClose
  def.mayBlockClose = true
  try {
    await closePane(user, panes()[0]!)

    // One id: the content of the tab about to close. Asking about the root
    // group would list all three panes and then close one of them.
    expect(confirmClose).toHaveBeenCalledExactlyOnceWith([expect.any(String)])
    // And declining really does close nothing.
    expect(screen.getAllByRole('tab')).toHaveLength(3)
    expect(screen.getAllByTestId('stub-content')).toHaveLength(3)
  } finally {
    def.mayBlockClose = restore
  }
})
