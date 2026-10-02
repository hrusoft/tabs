import type {
  AlertDialogOptions,
  ChooseDialogOptions,
  ConfirmDialogOptions
} from '@tabs/plugin-sdk/renderer/dialogs'
import { useState } from 'react'

export type {
  AlertDialogOptions,
  ChooseDialogOptions,
  ConfirmDialogOptions
} from '@tabs/plugin-sdk/renderer/dialogs'

import { openModal } from './modal'

/**
 * Three small, purpose-shaped dialogs built on the one reusable modal shell
 * (`openModal`, core/modal.ts) — the shell itself ships no `confirm`/`choose`
 * helpers on purpose (see its own comment); these are the concrete shapes a
 * content-type package needs: a plain confirm (e.g. warning that an action
 * will leave something in a risky state), a single-select choose (picking one
 * of several named options), and a one-button alert (surfacing a failure that
 * must reach the user rather than fail silently — see `alertDialog`'s own
 * comment on why that is a distinct shape from `confirmDialog` rather than
 * `confirmDialog` with its Cancel button hidden). The git tree's checkout
 * feature is the first real caller of all three, but none of the three is
 * shaped around it specifically.
 *
 * All three are exposed to content-type packages through the renderer plugin
 * context's `dialogs` member (`plugin/context.ts`), the same
 * wraps-a-core-singleton shape `bell`/`contextMenu` already use — packages
 * never import this module directly (see the plugin boundary ledger).
 */

function DialogMessage({ children }: { children: string }) {
  // white-space: pre-wrap (global.css) is what keeps a multi-line message —
  // notably a checkout refusal's full git stderr — readable as the several
  // lines it is, tabs and all, rather than collapsed onto one.
  return <p className="modal-message">{children}</p>
}

function DialogActions({ children }: { children: React.ReactNode }) {
  return <div className="modal-actions">{children}</div>
}

/** A plain yes/no dialog. Resolves `false` on Cancel, Escape or a backdrop click — the same value, on purpose, so a caller need not tell them apart. */
export function confirmDialog(options: ConfirmDialogOptions): Promise<boolean> {
  return openModal<boolean>({
    title: options.title,
    testId: options.testId,
    dismissValue: false,
    render: (resolve) => (
      <div className="modal-body">
        <DialogMessage>{options.message}</DialogMessage>
        <DialogActions>
          <button type="button" className="modal-button" onClick={() => resolve(false)}>
            {options.cancelLabel ?? 'Cancel'}
          </button>
          <button
            type="button"
            className="modal-button modal-button-primary"
            onClick={() => resolve(true)}
          >
            {options.confirmLabel ?? 'OK'}
          </button>
        </DialogActions>
      </div>
    )
  })
}

/**
 * A one-button dialog for something the user must acknowledge rather than
 * decide — a checkout that git refused, say. A separate shape from
 * `confirmDialog` with its Cancel button hidden, deliberately: a package
 * reading this API sees an alert as an alert, not as a confirm dialog held in
 * a particular configuration. They share only their message paragraph and
 * button styling, both trivial.
 */
export function alertDialog(options: AlertDialogOptions): Promise<void> {
  return openModal<void>({
    title: options.title,
    testId: options.testId,
    dismissValue: undefined,
    render: (resolve) => (
      <div className="modal-body">
        <DialogMessage>{options.message}</DialogMessage>
        <DialogActions>
          <button
            type="button"
            className="modal-button modal-button-primary"
            onClick={() => resolve()}
          >
            {options.okLabel ?? 'OK'}
          </button>
        </DialogActions>
      </div>
    )
  })
}

function ChooseBody({
  message,
  options,
  confirmLabel,
  cancelLabel,
  onResolve
}: {
  message: string
  options: string[]
  confirmLabel: string
  cancelLabel: string
  onResolve: (value: string | null) => void
}) {
  const [value, setValue] = useState(options[0] ?? '')
  return (
    <div className="modal-body">
      <DialogMessage>{message}</DialogMessage>
      <select
        className="modal-select"
        data-testid="dialog-choose-select"
        value={value}
        onChange={(event) => setValue(event.target.value)}
      >
        {options.map((option) => (
          <option key={option} value={option}>
            {option}
          </option>
        ))}
      </select>
      <DialogActions>
        <button type="button" className="modal-button" onClick={() => onResolve(null)}>
          {cancelLabel}
        </button>
        <button
          type="button"
          className="modal-button modal-button-primary"
          onClick={() => onResolve(value)}
        >
          {confirmLabel}
        </button>
      </DialogActions>
    </div>
  )
}

/**
 * A single-select dialog: a `<select>` defaulted to the first option, plus
 * confirm/cancel. Resolves the chosen option's string, or `null` on Cancel,
 * Escape or a backdrop click. `options` must be non-empty — the caller's
 * responsibility, since an empty choice is a caller bug, not a dialog state.
 */
export function chooseDialog(options: ChooseDialogOptions): Promise<string | null> {
  return openModal<string | null>({
    title: options.title,
    testId: options.testId,
    dismissValue: null,
    render: (resolve) => (
      <ChooseBody
        message={options.message}
        options={options.options}
        confirmLabel={options.confirmLabel ?? 'OK'}
        cancelLabel={options.cancelLabel ?? 'Cancel'}
        onResolve={resolve}
      />
    )
  })
}
