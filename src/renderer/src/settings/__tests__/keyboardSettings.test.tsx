import type { KeyBinding, ShortcutOverrides } from '@shared/shortcuts'
import { fireEvent, screen } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { expect, test } from 'vitest'
import { lastSettingsWrite, mountSettingsPage } from '../../testing/settingsPageFixture'
import { KeyboardSettings } from '../KeyboardSettings'

// The Settings window is its own entry point (settings-main.tsx), so this
// mounts the page directly rather than going through <App/> — there is no
// renderApp equivalent for it. The fake bridge is already installed by
// vitest.setup.ts; assertions read back through window.__fakeApi.
//
// jsdom reports a non-Mac navigator.platform, so the page's `platform` is
// 'other': the primary modifier is Ctrl and bindings format as 'Ctrl+…'.
// That's a property of the environment, not a choice — testing the macOS
// glyph path is shared/__tests__/shortcuts.test.ts's job.

function mount(shortcuts: ShortcutOverrides = {}): void {
  mountSettingsPage(KeyboardSettings, { shortcuts })
}

/** The last `shortcuts` record the page persisted. */
function lastWrite(): ShortcutOverrides | undefined {
  return lastSettingsWrite('shortcuts')
}

function chip(id: string): HTMLElement {
  return screen.getByTestId(`settings-shortcut-${id}`)
}

function search(): HTMLInputElement {
  return screen.getByTestId('settings-shortcut-search') as HTMLInputElement
}

test('lists every action at its default binding', () => {
  mount()
  expect(chip('new-tab')).toHaveTextContent('Ctrl+T')
  expect(chip('close-pane')).toHaveTextContent('Ctrl+W')
  expect(chip('clear-buffer')).toHaveTextContent('Ctrl+K')
  expect(chip('nav-left')).toHaveTextContent('Ctrl+←')
  // Nothing is overridden, so no row offers a Reset.
  expect(screen.queryByTestId('settings-shortcut-reset-new-tab')).not.toBeInTheDocument()
})

test('recording a combination writes it and disarms capture', async () => {
  mount()
  const user = userEvent.setup()

  await user.click(chip('new-tab'))
  expect(chip('new-tab')).toHaveTextContent('Press keys…')
  // Capture arms main's accelerator suspension for as long as it's recording —
  // without it macOS would eat the very combinations worth reassigning.
  expect(window.__fakeApi?.captureMode()).toBe(true)

  await user.keyboard('{Control>}{Alt>}n{/Alt}{/Control}')

  expect(lastWrite()).toEqual({ 'new-tab': { mod: true, alt: true, code: 'KeyN' } })
  expect(chip('new-tab')).toHaveTextContent('Ctrl+Alt+N')
  expect(window.__fakeApi?.captureMode()).toBe(false)
})

test('Escape cancels capture, leaving the binding untouched', async () => {
  mount()
  const user = userEvent.setup()

  await user.click(chip('new-tab'))
  await user.keyboard('{Escape}')

  expect(chip('new-tab')).toHaveTextContent('Ctrl+T')
  expect(window.__fakeApi?.settingsSets()).toHaveLength(0)
  expect(window.__fakeApi?.captureMode()).toBe(false)
})

test('clicking the armed chip again cancels, and unmounting releases capture', async () => {
  mount()
  const user = userEvent.setup()

  await user.click(chip('new-tab'))
  expect(window.__fakeApi?.captureMode()).toBe(true)
  await user.click(chip('new-tab'))
  expect(window.__fakeApi?.captureMode()).toBe(false)
  expect(chip('new-tab')).toHaveTextContent('Ctrl+T')
})

test('a modifier-less combination is refused, so no bare key is taken from a terminal', async () => {
  mount()
  const user = userEvent.setup()

  await user.click(chip('new-tab'))
  await user.keyboard('j')

  expect(window.__fakeApi?.settingsSets()).toHaveLength(0)
  expect(screen.getByText(/Add Ctrl or Alt/)).toBeInTheDocument()
  // Still armed: a rejected press is a correction, not a cancel.
  expect(chip('new-tab')).toHaveTextContent('Press keys…')
})

test('a combination the stock role menus own is refused', async () => {
  mount()
  const user = userEvent.setup()

  await user.click(chip('new-tab'))
  await user.keyboard('{Control>}c{/Control}')

  expect(window.__fakeApi?.settingsSets()).toHaveLength(0)
  expect(screen.getByText(/reserved by the system/)).toBeInTheDocument()
})

// Two menu items sharing a key equivalent is resolved silently and arbitrarily
// by macOS, so the invariant has to hold: the loser is unbound in the same
// single write, and told about.
test('recording a combination another action holds reassigns it, unbinding the loser', async () => {
  mount()
  const user = userEvent.setup()

  await user.click(chip('new-tab'))
  await user.keyboard('{Control>}k{/Control}')

  expect(lastWrite()).toEqual({
    'new-tab': { mod: true, code: 'KeyK' },
    'clear-buffer': null
  })
  expect(chip('new-tab')).toHaveTextContent('Ctrl+K')
  expect(chip('clear-buffer')).toHaveTextContent('Not set')
  expect(screen.getByText(/Taken from Clear Buffer/)).toBeInTheDocument()
})

test('clearing a binding stores an explicit unbinding, not an absent key', async () => {
  mount()
  const user = userEvent.setup()

  await user.click(screen.getByTestId('settings-shortcut-clear-new-tab'))

  expect(lastWrite()).toEqual({ 'new-tab': null })
  expect(chip('new-tab')).toHaveTextContent('Not set')
  // An unbound action is still overridden, so Reset is how you get it back.
  expect(screen.getByTestId('settings-shortcut-reset-new-tab')).toBeInTheDocument()
  expect(screen.getByTestId('settings-shortcut-clear-new-tab')).toBeDisabled()
})

test('resetting a row removes its override entirely', async () => {
  mount({ 'new-tab': { mod: true, code: 'KeyN' }, 'close-pane': null })
  const user = userEvent.setup()

  await user.click(screen.getByTestId('settings-shortcut-reset-new-tab'))

  expect(lastWrite()).toEqual({ 'close-pane': null })
})

test('recording an action back onto its own default drops the override', async () => {
  mount({ 'new-tab': { mod: true, code: 'KeyN' } })
  const user = userEvent.setup()

  await user.click(chip('new-tab'))
  await user.keyboard('{Control>}t{/Control}')

  expect(lastWrite()).toEqual({})
})

test('Restore Defaults clears every override at once', async () => {
  mount({ 'new-tab': { mod: true, code: 'KeyN' }, 'nav-left': null })
  const user = userEvent.setup()

  await user.click(screen.getByTestId('settings-shortcuts-restore-defaults'))

  expect(lastWrite()).toEqual({})
})

test('a second rebind keeps the first, rather than writing a stale record', async () => {
  mount()
  const user = userEvent.setup()

  await user.click(chip('new-tab'))
  await user.keyboard('{Control>}{Alt>}n{/Alt}{/Control}')
  await user.click(chip('nav-left'))
  await user.keyboard('{Control>}{Alt>}j{/Alt}{/Control}')

  const expected: Record<string, KeyBinding> = {
    'new-tab': { mod: true, alt: true, code: 'KeyN' },
    'nav-left': { mod: true, alt: true, code: 'KeyJ' }
  }
  expect(lastWrite()).toEqual(expected)
})

test('typing text filters the list to matching labels and descriptions', async () => {
  mount()
  const user = userEvent.setup()

  await user.type(search(), 'split')

  expect(chip('split-horizontal')).toBeInTheDocument()
  expect(chip('split-vertical')).toBeInTheDocument()
  expect(screen.queryByTestId('settings-shortcut-new-tab')).not.toBeInTheDocument()
  expect(screen.queryByTestId('settings-shortcut-nav-left')).not.toBeInTheDocument()
})

test('a group with no matches drops its own heading, not just its rows', async () => {
  mount()
  const user = userEvent.setup()

  await user.type(search(), 'split')

  expect(screen.queryByText('Navigation')).not.toBeInTheDocument()
})

test('typing a bound key combination filters to the shortcut bound to it, exactly', async () => {
  mount()
  const user = userEvent.setup()

  await user.type(search(), 'ctrl+t')

  expect(chip('new-tab')).toBeInTheDocument()
  // Ctrl+Shift+T and Ctrl+Alt+T are different combinations, not substrings.
  expect(screen.queryByTestId('settings-shortcut-split-horizontal')).not.toBeInTheDocument()
  expect(screen.queryByTestId('settings-shortcut-split-vertical')).not.toBeInTheDocument()
})

test('a combination query follows a rebind, not the shipped default', async () => {
  mount({ 'new-tab': { mod: true, code: 'KeyN' } })
  const user = userEvent.setup()

  await user.type(search(), 'ctrl+t')
  expect(screen.queryByTestId('settings-shortcut-new-tab')).not.toBeInTheDocument()

  await user.clear(search())
  await user.type(search(), 'ctrl+n')
  expect(chip('new-tab')).toBeInTheDocument()
})

test('the clear button empties the field and restores the full list', async () => {
  mount()
  const user = userEvent.setup()

  await user.type(search(), 'split')
  expect(screen.queryByTestId('settings-shortcut-new-tab')).not.toBeInTheDocument()

  await user.click(screen.getByTestId('settings-shortcut-search-clear'))

  expect(search()).toHaveValue('')
  expect(chip('new-tab')).toBeInTheDocument()
  expect(chip('split-horizontal')).toBeInTheDocument()
})

test('the clear button carries a hover tooltip, not just an accessible name', () => {
  mount()

  expect(screen.getByTestId('settings-shortcut-search-clear')).toHaveAttribute(
    'title',
    'Clear search'
  )
})

test('a query matching nothing shows the empty-state placeholder instead of a blank page', async () => {
  mount()
  const user = userEvent.setup()

  await user.type(search(), 'zzzzz')

  expect(screen.getByTestId('settings-shortcuts-empty')).toBeInTheDocument()
  expect(screen.queryByTestId('settings-shortcut-new-tab')).not.toBeInTheDocument()
})

// The heart of the ticket: pressing the actual combination while the search
// box is focused must type it out as search text, not perform it — and for
// a menu-layer action that's only possible with the native menu's
// accelerators suspended (see the capture-mode effect this reuses).
test('focusing the search box arms capture, and pressing a bound combination types it as text', async () => {
  mount()
  const user = userEvent.setup()

  await user.click(search())
  expect(window.__fakeApi?.captureMode()).toBe(true)

  await user.keyboard('{Control>}t{/Control}')

  expect(search()).toHaveValue('ctrl+t')
  // A search box, not the rebind flow: nothing was recorded or fired.
  expect(window.__fakeApi?.settingsSets()).toHaveLength(0)
})

test('blurring the search box disarms capture', async () => {
  mount()
  const user = userEvent.setup()

  await user.click(search())
  expect(window.__fakeApi?.captureMode()).toBe(true)

  await user.click(screen.getByRole('heading', { name: 'Keyboard' }))

  expect(window.__fakeApi?.captureMode()).toBe(false)
})

// Capture mode is one flag in main, owned by a single webContents with no
// refcount (see src/main/shortcuts.ts), and this page has two reasons to arm
// it. Both directions of the overlap are covered here because each fails
// silently: the accelerators come back while the UI still says it's
// recording, or the box refuses to accept text.
test('focusing the search box ends a chip recording rather than fighting it', async () => {
  mount()
  const user = userEvent.setup()

  await user.click(chip('new-tab'))
  expect(chip('new-tab')).toHaveTextContent('Press keys…')

  await user.click(search())

  // The chip stopped recording, so its window-level keydown listener is gone
  // and the field is typable — with capture still armed for the box itself.
  expect(chip('new-tab')).toHaveTextContent('Ctrl+T')
  expect(window.__fakeApi?.captureMode()).toBe(true)
  await user.type(search(), 'split')
  expect(search()).toHaveValue('split')
  expect(window.__fakeApi?.settingsSets()).toHaveLength(0)
})

// Pane navigation is enforced by content/spatialNav.ts's own window keydown
// listener, which this Settings window never installs in the first place
// (only App.tsx's main pane-tree window does) — so a nav combination typed
// here needs no special handling at all, it's just text like any other.
test('pressing a nav combination while searching types it as text too, without moving anything', async () => {
  mount()
  const user = userEvent.setup()

  await user.click(search())
  await user.keyboard('{Control>}{ArrowLeft}{/Control}')

  expect(search()).toHaveValue('ctrl+left')
})

test('pressing a combination inserts it at the cursor, not always at the end', () => {
  mount()
  const input = search()

  fireEvent.change(input, { target: { value: 'foobar' } })
  input.setSelectionRange(3, 3)
  fireEvent.keyDown(input, { code: 'KeyT', ctrlKey: true, key: 't' })

  expect(input).toHaveValue('fooctrl+tbar')
})

test('bare typing in the search box is untouched — no interception without a real modifier', async () => {
  mount()
  const user = userEvent.setup()

  // Shift alone (the capital letters) is ordinary typing too, not a chord.
  await user.type(search(), 'Close Pane')

  expect(search()).toHaveValue('Close Pane')
})
