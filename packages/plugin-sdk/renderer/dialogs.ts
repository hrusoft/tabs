/**
 * The three dialog shapes a content-type package may open through
 * `RendererPluginContext.dialogs` — pure option bags, no further coupling.
 * The implementations (`confirmDialog`/`alertDialog`/`chooseDialog`, built
 * on the app's one reusable modal shell) stay core-owned, in
 * `src/renderer/src/core/dialogs.tsx`, which imports these types back.
 */

interface DialogOptionsBase {
  title: string
  message: string
  /** Distinguishes this dialog's rendered panel in tests — becomes the modal's own `data-testid`. */
  testId?: string
}

export interface ConfirmDialogOptions extends DialogOptionsBase {
  confirmLabel?: string
  cancelLabel?: string
}

export interface AlertDialogOptions extends DialogOptionsBase {
  okLabel?: string
}

export interface ChooseDialogOptions extends DialogOptionsBase {
  /** What the select lists, in the order shown — also each option's own value, since every caller here (branch/remote-ref names) already has unique labels. */
  options: string[]
  confirmLabel?: string
  cancelLabel?: string
}
