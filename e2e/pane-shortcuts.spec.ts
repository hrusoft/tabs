import { dockedPanes, floatingWindows } from './helpers/floating'
import { expect, test } from './helpers/launch'
import { clickMenuItem } from './helpers/menu'
import { closePane, headerOf, initialPane, splitHorizontal } from './helpers/pane'
import { openTerminal, typeAndEnter } from './helpers/terminal'

// What remains here is the wiring the other tiers can't reach: real native
// menu items driving the shortcuts.* IPC into the renderer (CDP keyboard
// never hits macOS menu key-equivalents — see helpers/menu.ts), and Cmd/Ctrl+K
// against a real pty buffer. The shortcut *handlers* are covered in
// src/renderer/src/__tests__/pane-shortcuts.test.tsx by firing the same
// callbacks directly — the tests below are deliberate double coverage,
// proving menu → IPC → handler end to end for each of the four pane-creation
// shortcuts. New Unpinned Pane's spawn geometry is real-layout territory and
// stays in e2e/browser/floating.spec.ts; this only proves the menu reaches it.

test('Cmd/Ctrl+T opens a new tab in the active pane, same as its + button', async ({
  page,
  electronApp
}) => {
  // Wait for the UI before invoking the menu: the shortcut listener is
  // installed on React mount, and firstWindow() resolves before that — a
  // menu click racing ahead of mount is dropped, which no human pressing
  // Cmd+T on a visible window can reproduce.
  await expect(initialPane(page)).toBeVisible()

  await clickMenuItem(electronApp, 'New Tab', page)

  // The active pane is root's own tab's content, so opening a new tab there
  // adds a sibling tab directly to root's own group instead of nesting a new
  // one (see openContent's tab-parent branch in tree.ts) — still one tablist,
  // now with two tabs.
  await expect(page.getByRole('tablist')).toHaveCount(1)
  await expect(page.getByRole('tab')).toHaveCount(2)
})

test('New Horizontal Split and New Vertical Split menu items split the active pane', async ({
  page,
  electronApp
}) => {
  await expect(initialPane(page)).toBeVisible()

  // Root's own wrapper, plus the split's two panes. Root's own single tab
  // ("Tabs") is always there regardless of what its content splits into.
  await clickMenuItem(electronApp, 'New Horizontal Split', page)
  await expect(page.getByTestId('pane')).toHaveCount(3)
  await expect(page.getByRole('tab')).toHaveCount(1)

  // Re-activate the original pane (nth(1) — root's wrapper permanently
  // occupies nth(0)) so the second split targets it rather than whichever
  // new pane the first split just activated.
  await headerOf(initialPane(page)).click()
  await clickMenuItem(electronApp, 'New Vertical Split', page)
  await expect(page.getByTestId('pane')).toHaveCount(4)
  await expect(page.getByRole('tab')).toHaveCount(1)
})

test('New Unpinned Pane menu item opens a new pane as a floating window, never docking it', async ({
  page,
  electronApp
}) => {
  await expect(initialPane(page)).toBeVisible()

  await clickMenuItem(electronApp, 'New Unpinned Pane', page)

  await expect(floatingWindows(page)).toHaveCount(1)
  // Root's own wrapper plus the one real pane — the docked side is untouched.
  await expect(dockedPanes(page)).toHaveCount(2)
})

test("Cmd/Ctrl+K clears the active pane's terminal, and does nothing on a pane that isn't one", async ({
  page,
  electronApp
}) => {
  await splitHorizontal(initialPane(page))
  const panes = page.getByTestId('pane')
  // Root's own wrapper stays pane 0; the split activated its own new (empty)
  // pane, nth(2) — the terminal goes in the untouched original, nth(1).
  const term = await openTerminal(panes.nth(1))
  await typeAndEnter(term, 'echo clear-marker')
  await expect(term).toContainText('clear-marker')

  // An empty pane is active: nothing there answers Cmd/Ctrl+K, and the
  // terminal beside it must not be cleared by proxy.
  await headerOf(panes.nth(2)).click()
  await expect(panes.nth(2)).toHaveClass(/pane-active/)
  await clickMenuItem(electronApp, 'Clear Buffer', page)

  // Round-trips through the real shell before re-checking the first marker,
  // so a wrongly-dispatched clear has had every chance to land — asserting
  // straight after the menu click would pass on timing alone. Typing into the
  // terminal also makes its pane the active one again.
  await typeAndEnter(term, 'echo second-marker')
  await expect(term).toContainText('second-marker')
  await expect(term).toContainText('clear-marker')
  await expect(panes.nth(1)).toHaveClass(/pane-active/)

  await clickMenuItem(electronApp, 'Clear Buffer', page)

  await expect(term).not.toContainText('clear-marker')
  await expect(term).not.toContainText('second-marker')

  // Close the terminal rather than leaving a live shell for the fixture's
  // teardown to quit past — see the note on `openTerminal`.
  await closePane(panes.nth(1))
})

test('both shortcuts act on whichever pane is active, not a fixed slot', async ({
  page,
  electronApp
}) => {
  await splitHorizontal(initialPane(page))
  const panes = page.getByTestId('pane')
  // Root's own wrapper stays pane 0; the split activated its own new pane,
  // nth(2) — put the terminal there.
  const term = await openTerminal(panes.nth(2))
  await expect(panes.nth(2)).toHaveClass(/pane-active/)

  // Re-activate the empty pane (the split's untouched original, nth(1))
  // before invoking the shortcut.
  await headerOf(panes.nth(1)).click()
  await expect(panes.nth(1)).toHaveClass(/pane-active/)

  await clickMenuItem(electronApp, 'Close Pane', page)

  // The empty pane (active) closed, collapsing the split back to the
  // terminal's own leaf sitting directly in root's tab again — root's own
  // wrapper plus that one surviving pane.
  await expect(page.getByTestId('pane')).toHaveCount(2)
  await expect(term).toBeVisible()

  // Close the surviving terminal too, rather than leaving a live shell for
  // the fixture's teardown to quit past — see the note on `openTerminal`.
  await closePane(initialPane(page))
})
