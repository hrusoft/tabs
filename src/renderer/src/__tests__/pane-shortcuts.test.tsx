import { act, screen } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { expect, test } from 'vitest'
import { unhandledShortcutActions } from '../content/paneShortcuts'
import { dockedPanes, initialPane } from '../testing/domQueries'
import { clickPaneButton } from '../testing/paneActions'
import { renderApp } from '../testing/renderApp'

test('every menu-forwarded shortcut action has a renderer handler', () => {
  // main's paneShortcutItem forwards *any* action id on one channel, and
  // HANDLERS is a Partial<Record> — so a new menu-layer action without an
  // entry compiles fine and dies silently. Same gate as the app's two verb
  // registries (externalControlVerbs.test.tsx, unhandledMainControlVerbs).
  expect(unhandledShortcutActions()).toEqual([])
})

// Ported from e2e/pane-shortcuts.spec.ts. The fake bridge's `fireShortcut`
// invokes exactly the callbacks the real File/Edit menu items drive over IPC
// (shortcuts.onShortcut, dispatched through the HANDLERS table in
// paneShortcuts.ts); the menu→IPC wiring itself keeps a real-Electron smoke
// test in e2e/pane-shortcuts.spec.ts. New Unpinned Pane's spawn geometry (the
// section of the active pane the newUnpinnedPanePosition setting names, with
// spacing) needs real layout and stays in e2e/browser/floating.spec.ts; this
// only checks the functional contract — a floating window appears, the docked
// layout doesn't.
// Cmd/Ctrl+K's clear stays on Electron too: its subject is the real pty
// buffer. Settings are seeded through the fake bridge instead of a Settings
// window — the cross-window round-trip is settings.spec.ts's subject.
//
// The active pane in a fresh render is initialPane() (panes()[1]), already
// sitting inside root's own tab — see app.test.tsx's header comment for why
// that means a new top-level tab joins root's bar rather than nesting one.

test('Cmd/Ctrl+T opens a new tab in the active pane, same as its + button', async () => {
  renderApp()

  await act(async () => {
    window.__fakeApi?.fireShortcut('new-tab')
  })

  // The active pane already sits inside root's own tab, so the shortcut
  // joins that bar rather than wrapping it in a fresh one.
  expect(screen.getAllByRole('tablist')).toHaveLength(1)
  expect(screen.getAllByRole('tab')).toHaveLength(2)
})

test('Cmd/Ctrl+W closes the active pane, same as its × button', async () => {
  renderApp()
  const user = userEvent.setup()
  await clickPaneButton(user, initialPane(), 'pane-new-stub-button')
  expect(screen.getByTestId('stub-content')).toBeVisible()

  await act(async () => {
    window.__fakeApi?.fireShortcut('close-pane')
  })

  // Root never stops being a tab group — closing its only tab's content
  // just resets that tab to a blank pane.
  expect(screen.queryByTestId('stub-content')).not.toBeInTheDocument()
  expect(screen.getByTestId('empty-pane')).toBeVisible()
})

test('Cmd/Ctrl+Shift+T splits the active pane horizontally, same as its split button', async () => {
  renderApp()

  await act(async () => {
    window.__fakeApi?.fireShortcut('split-horizontal')
  })

  // Root's own tab, plus the new split-off pane beside the original.
  expect(screen.getAllByRole('tab')).toHaveLength(1)
  expect(screen.getAllByTestId('empty-pane')).toHaveLength(2)
})

test('Cmd/Ctrl+Alt+T splits the active pane vertically, same as its split button', async () => {
  renderApp()

  await act(async () => {
    window.__fakeApi?.fireShortcut('split-vertical')
  })

  expect(screen.getAllByRole('tab')).toHaveLength(1)
  expect(screen.getAllByTestId('empty-pane')).toHaveLength(2)
})

test('Cmd/Ctrl+Alt+Shift+T opens a new pane directly as an unpinned floating window', async () => {
  renderApp()

  await act(async () => {
    window.__fakeApi?.fireShortcut('new-unpinned-pane')
  })

  expect(screen.getAllByTestId('floating-window')).toHaveLength(1)
  // The docked layout never saw the new pane — it landed straight in the
  // floating list, not via a dock-then-unpin round trip.
  expect(dockedPanes()).toHaveLength(2)
})

test('closing the last floating pane returns focus to the docked pane, not the root tab group', async () => {
  renderApp()

  await act(async () => {
    window.__fakeApi?.fireShortcut('new-unpinned-pane')
  })

  await act(async () => {
    window.__fakeApi?.fireShortcut('close-pane')
  })

  expect(screen.queryByTestId('floating-window')).not.toBeInTheDocument()
  // Root's own wrapper is a legitimate active pane in general, but falling
  // back onto it here would focus the window's chrome instead of the tab it
  // shows — the docked content pane must end up active instead.
  expect(dockedPanes()[0]).not.toHaveClass('pane-active')
  expect(initialPane()).toHaveClass('pane-active')
})
