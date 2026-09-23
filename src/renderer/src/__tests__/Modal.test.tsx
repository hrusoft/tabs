import { act, screen, within } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { useState } from 'react'
import { expect, test } from 'vitest'
import { openModal } from '../core/modal'
import { initialPane } from '../testing/domQueries'
import { fillEmptyPane } from '../testing/paneActions'
import { renderApp } from '../testing/renderApp'

// The shell's own tests, independent of any concrete dialog — the caffeinate
// form (src/renderer/src/caffeinate/CaffeinateDialog.tsx) is the shell's one
// real caller, but the shell's own contract (backdrop, focus in/out, Escape,
// the Tab trap) is tested against trivial bodies here so a regression in the
// shell can't hide behind the caffeinate form's own behaviour.

test('opening a modal moves focus into it, and Escape resolves dismissValue and hands focus back to the active pane', async () => {
  renderApp()
  const user = userEvent.setup()
  // A leaf with real content to focus back onto — a fresh pane starts empty
  // (its own toolbar, no focusable stub-content), so this is what makes the
  // restore assertion below meaningful rather than vacuous.
  await fillEmptyPane(user, initialPane(), 'pane-new-stub-button')

  let result!: Promise<boolean>
  act(() => {
    result = openModal<boolean>({
      title: 'Test modal',
      dismissValue: false,
      render: (resolve) => (
        <button type="button" onClick={() => resolve(true)}>
          OK
        </button>
      )
    })
  })

  const dialog = screen.getByTestId('modal')
  expect(dialog).toHaveFocus()

  await user.keyboard('{Escape}')

  expect(await result).toBe(false)
  expect(screen.queryByTestId('modal')).not.toBeInTheDocument()
  // The same route CommandPalette's own dismissal uses (focusPane), not
  // whatever raw element happened to have focus before the modal opened —
  // see Modal.tsx's module comment for why (a <webview> guest mid-reparent
  // throws on a verbatim .focus()).
  expect(within(initialPane()).getByTestId('stub-content')).toHaveFocus()
})

/** A form body with its own local state, to prove a refused second open never touches it. */
function StatefulBody({ onDone }: { onDone: (value: string) => void }) {
  const [value, setValue] = useState('')
  return (
    <div>
      <p>first form</p>
      <input
        data-testid="first-field"
        value={value}
        onChange={(event) => setValue(event.target.value)}
      />
      <button type="button" onClick={() => onDone(value)}>
        Done
      </button>
    </div>
  )
}

test('opening a modal while one is already open refuses the newcomer and leaves the first completely untouched', async () => {
  renderApp()
  const user = userEvent.setup()

  let firstResult!: Promise<string>
  act(() => {
    firstResult = openModal<string>({
      title: 'First',
      dismissValue: 'dismissed-first',
      render: (resolve) => <StatefulBody onDone={resolve} />
    })
  })
  expect(screen.getByText('First')).toBeInTheDocument()
  expect(screen.getByText('first form')).toBeInTheDocument()

  // Typed before the second (refused) open, to prove it survives untouched —
  // a replace-in-place implementation would remount StatefulBody and lose it.
  await user.type(screen.getByTestId('first-field'), 'hello')

  let secondResult!: Promise<string | null>
  act(() => {
    secondResult = openModal<string | null>({
      title: 'Second',
      dismissValue: null,
      render: () => <p>second form</p>
    })
  })

  // The newcomer is refused immediately, resolving with its own dismissValue —
  // never the first modal's, and never left hanging.
  expect(await secondResult).toBeNull()

  // The first modal is exactly as it was: same title, same body, same typed value.
  expect(screen.getByText('First')).toBeInTheDocument()
  expect(screen.queryByText('Second')).not.toBeInTheDocument()
  expect(screen.queryByText('second form')).not.toBeInTheDocument()
  expect(screen.getByTestId('first-field')).toHaveValue('hello')

  await user.click(screen.getByText('Done'))
  expect(await firstResult).toBe('hello')
})

test('clicking the backdrop dismisses; clicking inside the panel does not', async () => {
  renderApp()
  const user = userEvent.setup()

  let result!: Promise<string | null>
  act(() => {
    result = openModal<string | null>({
      title: 'Backdrop test',
      dismissValue: null,
      render: (resolve) => (
        <button type="button" onClick={() => resolve('picked')}>
          Pick
        </button>
      )
    })
  })

  await user.click(screen.getByTestId('modal'))
  expect(screen.getByTestId('modal')).toBeInTheDocument()

  await user.click(screen.getByTestId('modal-backdrop'))
  expect(await result).toBeNull()
  expect(screen.queryByTestId('modal')).not.toBeInTheDocument()
})

test('Tab and Shift+Tab cycle within an open modal instead of escaping it', async () => {
  renderApp()
  const user = userEvent.setup()

  act(() => {
    void openModal<void>({
      title: 'Multi-field',
      dismissValue: undefined,
      render: () => (
        <>
          <button type="button" data-testid="field-a">
            A
          </button>
          <button type="button" data-testid="field-b">
            B
          </button>
          <button type="button" data-testid="field-c">
            C
          </button>
        </>
      )
    })
  })

  const a = screen.getByTestId('field-a')
  const b = screen.getByTestId('field-b')
  const c = screen.getByTestId('field-c')

  // The container itself has focus first (see the test above); Tab enters the body.
  await user.tab()
  expect(a).toHaveFocus()
  await user.tab()
  expect(b).toHaveFocus()
  await user.tab()
  expect(c).toHaveFocus()
  // Wraps back to the first rather than escaping to a pane behind the modal.
  await user.tab()
  expect(a).toHaveFocus()

  await user.tab({ shift: true })
  expect(c).toHaveFocus()
})

// Proof the shell needs no change for either a plain confirm or a
// single-select choose — these render functions are test-only and predate
// core/dialogs.tsx's real confirmDialog/chooseDialog/alertDialog, which now
// ship all three shapes for any package to use (see core/modal.ts's
// comment).

function confirmTest(message: string): Promise<boolean> {
  return openModal<boolean>({
    title: 'Confirm',
    dismissValue: false,
    render: (resolve) => (
      <div className="modal-body">
        <p>{message}</p>
        <div className="modal-actions">
          <button type="button" className="modal-button" onClick={() => resolve(false)}>
            Cancel
          </button>
          <button
            type="button"
            className="modal-button modal-button-primary"
            onClick={() => resolve(true)}
          >
            OK
          </button>
        </div>
      </div>
    )
  })
}

test('a confirm-shaped dialog needs no shell change: two buttons resolving true/false', async () => {
  renderApp()
  const user = userEvent.setup()

  let result!: Promise<boolean>
  act(() => {
    result = confirmTest('Are you sure?')
  })

  expect(screen.getByText('Are you sure?')).toBeInTheDocument()
  await user.click(screen.getByText('OK'))
  expect(await result).toBe(true)
})

function ChooseBody({
  options,
  onPick
}: {
  options: string[]
  onPick: (value: string | null) => void
}) {
  const [value, setValue] = useState(options[0] ?? '')
  return (
    <div className="modal-body">
      <select
        data-testid="choose-select"
        value={value}
        onChange={(event) => setValue(event.target.value)}
      >
        {options.map((option) => (
          <option key={option} value={option}>
            {option}
          </option>
        ))}
      </select>
      <div className="modal-actions">
        <button type="button" className="modal-button" onClick={() => onPick(null)}>
          Cancel
        </button>
        <button
          type="button"
          className="modal-button modal-button-primary"
          onClick={() => onPick(value)}
        >
          Checkout
        </button>
      </div>
    </div>
  )
}

function chooseTest(options: string[]): Promise<string | null> {
  return openModal<string | null>({
    title: 'Pick a branch',
    dismissValue: null,
    render: (resolve) => <ChooseBody options={options} onPick={resolve} />
  })
}

test('a single-select choose-shaped dialog needs no shell change: a <select> plus Checkout/Cancel', async () => {
  renderApp()
  const user = userEvent.setup()

  let result!: Promise<string | null>
  act(() => {
    result = chooseTest(['main', 'feature/foo'])
  })

  await user.selectOptions(screen.getByTestId('choose-select'), 'feature/foo')
  await user.click(screen.getByText('Checkout'))
  expect(await result).toBe('feature/foo')
})

test('choosing Cancel resolves null, the same value Escape would', async () => {
  renderApp()
  const user = userEvent.setup()

  let result!: Promise<string | null>
  act(() => {
    result = chooseTest(['main'])
  })

  await user.click(screen.getByText('Cancel'))
  expect(await result).toBeNull()
})
