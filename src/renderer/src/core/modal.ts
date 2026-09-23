import type { ReactNode } from 'react'
import { useModalStore } from './store/modalStore'

/**
 * The one exported way to open the reusable modal shell (`Modal.tsx`) —
 * imperative and promise-returning, so it can be called from anywhere a
 * dialog's result is needed, not just from a mounted component: a menu
 * forward's effect (see caffeinate/installCaffeinate.ts), a plain click
 * handler, or a content package's own action handler, through
 * `RendererPluginContext.dialogs` (`plugin/context.ts`), which wraps
 * `confirmDialog`/`alertDialog`/`chooseDialog` (core/dialogs.tsx) rather than
 * this function directly.
 *
 * `render` is invoked exactly once, synchronously, right here — never by
 * `ModalHost` on a later re-render — so the `ReactNode` it returns is a
 * stable element reference for the whole time the modal is open: any
 * `useState` inside it (a form's field values) survives untouched until
 * `resolve` is called and the modal unmounts. `resolve` both settles the
 * promise and closes the modal; nothing else does.
 *
 * `dismissValue` is what Escape or a backdrop click resolves to, so every
 * caller states its own "the user backed out" answer up front instead of the
 * shell guessing one (`false` for a confirm, `null` for a choose-or-cancel).
 *
 * **Only one modal may be open at a time, and a second call while one is
 * already open is refused rather than replacing it**: it resolves
 * immediately with its own `dismissValue`, touching neither the store nor
 * the open modal's `body` in any way. The alternative — settling the old
 * modal's promise to make room — was rejected on both sides: whatever is
 * awaiting the *existing* modal's result didn't ask to be cancelled just
 * because something else wants a turn, and replacing `body` would call
 * `render` again, mounting a fresh element that discards whatever the user
 * had already typed into the one on screen (a half-filled Caffeinate dialog,
 * say). Refusing the newcomer is the one option that disturbs nothing
 * already open.
 *
 * This stays the only helper *here* — the confirm/alert/choose shapes are
 * built on top of it in core/dialogs.tsx rather than folded into this file,
 * so a caller whose body doesn't fit any of those three (a form with several
 * fields, say — see caffeinate/CaffeinateDialog.tsx) still has this primitive
 * to reach for directly. See Modal.test.tsx for two test-only render
 * functions, predating core/dialogs.tsx, that proved the shell needed no
 * change for either the confirm or the choose shape before either was built.
 */
export function openModal<T>(options: {
  title: string
  testId?: string | undefined
  dismissValue: T
  render: (resolve: (value: T) => void) => ReactNode
}): Promise<T> {
  if (useModalStore.getState().modal !== null) {
    return Promise.resolve(options.dismissValue)
  }
  return new Promise<T>((settle) => {
    const resolve = (value: T): void => {
      useModalStore.getState().close()
      settle(value)
    }
    useModalStore.getState().open({
      title: options.title,
      testId: options.testId,
      body: options.render(resolve),
      onDismiss: () => resolve(options.dismissValue)
    })
  })
}
