import { act, screen } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { expect, test } from 'vitest'
import { alertDialog, chooseDialog, confirmDialog } from '../core/dialogs'
import { renderApp } from '../testing/renderApp'

/**
 * The three dialog shapes built on the modal shell (core/dialogs.tsx) —
 * tested here independent of any concrete caller, the same way Modal.test.tsx
 * tests the shell itself independent of any concrete dialog. The git tree's
 * checkout feature is a real caller, through `RendererPluginContext.dialogs`,
 * but nothing here is git-tree-specific.
 */

test('confirmDialog resolves true on confirm, false on cancel, and uses custom labels', async () => {
  renderApp()
  const user = userEvent.setup()

  let result!: Promise<boolean>
  act(() => {
    result = confirmDialog({
      title: 'Detach HEAD?',
      message: 'This will leave HEAD detached.',
      confirmLabel: 'Checkout',
      cancelLabel: 'Never mind'
    })
  })

  expect(screen.getByText('Detach HEAD?')).toBeInTheDocument()
  expect(screen.getByText('This will leave HEAD detached.')).toBeInTheDocument()
  expect(screen.getByText('Checkout')).toBeInTheDocument()
  await user.click(screen.getByText('Never mind'))

  expect(await result).toBe(false)
  expect(screen.queryByTestId('modal')).not.toBeInTheDocument()
})

test('confirmDialog resolves false on Escape, the same value Cancel would', async () => {
  renderApp()
  const user = userEvent.setup()

  let result!: Promise<boolean>
  act(() => {
    result = confirmDialog({ title: 'Sure?', message: 'Really?' })
  })

  await user.keyboard('{Escape}')

  expect(await result).toBe(false)
})

test('confirmDialog defaults its labels to OK/Cancel', async () => {
  renderApp()
  const user = userEvent.setup()

  let result!: Promise<boolean>
  act(() => {
    result = confirmDialog({ title: 'Sure?', message: 'Really?' })
  })

  expect(screen.getByText('Cancel')).toBeInTheDocument()
  await user.click(screen.getByText('OK'))

  expect(await result).toBe(true)
})

test('alertDialog shows exactly one button, and resolves through it', async () => {
  renderApp()
  const user = userEvent.setup()

  let result!: Promise<void>
  act(() => {
    result = alertDialog({ title: 'Checkout failed', message: 'git said no.' })
  })

  const dialog = screen.getByTestId('modal')
  expect(dialog.querySelectorAll('button')).toHaveLength(1)
  await user.click(screen.getByText('OK'))

  await result
  expect(screen.queryByTestId('modal')).not.toBeInTheDocument()
})

test('alertDialog also resolves on Escape, since there is nothing to cancel back to', async () => {
  renderApp()
  const user = userEvent.setup()

  let result!: Promise<void>
  act(() => {
    result = alertDialog({ title: 'Checkout failed', message: 'git said no.' })
  })

  await user.keyboard('{Escape}')

  await result
  expect(screen.queryByTestId('modal')).not.toBeInTheDocument()
})

test('alertDialog preserves a multi-line message verbatim, tabs and all', async () => {
  renderApp()

  const message =
    'error: Your local changes to the following files would be overwritten by checkout:\n\tconflict.txt\nPlease commit your changes or stash them before you switch branches.\nAborting'
  act(() => {
    void alertDialog({ title: 'Checkout failed', message })
  })

  // Rendered as one text node's content, not collapsed onto one line or split
  // across elements — the CSS (`white-space: pre-wrap`) is what makes this
  // read correctly on screen, checked separately by a real screenshot.
  expect(screen.getByText((_, element) => element?.textContent === message)).toBeInTheDocument()
})

test('chooseDialog defaults to the first option and resolves the picked one on confirm', async () => {
  renderApp()
  const user = userEvent.setup()

  let result!: Promise<string | null>
  act(() => {
    result = chooseDialog({
      title: 'Pick a branch',
      message: 'Several branches point at this commit.',
      options: ['main', 'feature/x'],
      confirmLabel: 'Checkout'
    })
  })

  const select = screen.getByTestId('dialog-choose-select') as HTMLSelectElement
  expect(select.value).toBe('main')

  await user.selectOptions(select, 'feature/x')
  await user.click(screen.getByText('Checkout'))

  expect(await result).toBe('feature/x')
})

test('chooseDialog resolves null on Cancel, leaving nothing chosen', async () => {
  renderApp()
  const user = userEvent.setup()

  let result!: Promise<string | null>
  act(() => {
    result = chooseDialog({ title: 'Pick a branch', message: 'Pick one.', options: ['main'] })
  })

  await user.click(screen.getByText('Cancel'))

  expect(await result).toBeNull()
})

test('a second dialog while one is open is refused, resolving immediately with its own dismiss value', async () => {
  renderApp()

  let first!: Promise<boolean>
  act(() => {
    first = confirmDialog({ title: 'First', message: 'one' })
  })

  let second!: Promise<string | null>
  act(() => {
    second = chooseDialog({ title: 'Second', message: 'two', options: ['a'] })
  })

  expect(await second).toBeNull()
  expect(screen.getByText('First')).toBeInTheDocument()
  expect(screen.queryByText('Second')).not.toBeInTheDocument()
  // First is still live and functions normally afterward.
  void first
})
