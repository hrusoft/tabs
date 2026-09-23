import type { KeyboardEvent } from 'react'
import { useEffect, useRef } from 'react'
import { focusPane } from './core/registry/paneHandles'
import { useLayoutStore } from './core/store/layoutStore'
import { useModalStore } from './core/store/modalStore'

/** What Tab/Shift+Tab cycle between — the same rough set every focus-trap implementation uses. */
const FOCUSABLE_SELECTOR = [
  'a[href]',
  'button:not([disabled])',
  'input:not([disabled])',
  'select:not([disabled])',
  'textarea:not([disabled])',
  '[tabindex]:not([tabindex="-1"])'
].join(',')

function focusableElements(container: HTMLElement): HTMLElement[] {
  return Array.from(container.querySelectorAll<HTMLElement>(FOCUSABLE_SELECTOR))
}

/**
 * The app's single reusable modal dialog — backdrop, title, an arbitrary
 * body slot, Escape-or-backdrop-to-dismiss, and a focus trap — mounted once
 * in App.tsx, store-driven like `ContextMenu`/`CommandPalette`. Opened only
 * through `openModal` (core/modal.ts); this component owns nothing but
 * presentation and the focus lifecycle.
 *
 * Like `CommandPalette`, this steals real DOM focus onto its own container
 * the instant it opens (see the effect below) rather than relying on a
 * capture-phase listener: a native menu action can fire with a `<webview>`
 * guest focused (a separate `WebContents`, invisible to any listener in this
 * window), so the only way to guarantee this dialog can be typed into is to
 * physically move focus out of the guest first.
 *
 * Focus restoration on close deliberately does **not** call `.focus()` on
 * whatever `document.activeElement` was before opening — if that happened to
 * be a `<webview>` mid-reparent, Electron's overridden `focus()` throws
 * (CLAUDE.md's guest-churn gotcha), and a throw from this effect would
 * unmount the whole app. Instead this hands focus back to the active pane
 * through `focusPane`, the same route `CommandPalette`'s own dismissal uses —
 * it goes through `dispatchFocus`'s try/catch and a no-op `handle?.focus?.()`
 * when there's nothing mounted for that id, so there is no separate
 * "fall back to something else" branch: a missing active pane already
 * degrades to doing nothing.
 */
export function ModalHost() {
  const modal = useModalStore((state) => state.modal)
  const containerRef = useRef<HTMLDivElement>(null)

  useEffect(() => {
    if (modal) containerRef.current?.focus()
    return () => {
      if (modal) focusPane(useLayoutStore.getState().activePaneId)
    }
    // Re-run only when the modal itself changes identity (open -> null, or a
    // new descriptor object from a fresh `openModal` call) — not on every
    // store tick, since `modal` is the whole value already.
  }, [modal])

  if (!modal) return null

  function handleKeyDown(event: KeyboardEvent<HTMLDivElement>): void {
    if (!modal) return
    if (event.key === 'Escape') {
      event.preventDefault()
      modal.onDismiss()
      return
    }
    if (event.key !== 'Tab') return
    const container = containerRef.current
    if (!container) return
    const focusable = focusableElements(container)
    if (focusable.length === 0) {
      // Nothing inside to hand focus to — keep it on the container itself
      // rather than letting Tab escape to whatever's behind the backdrop.
      event.preventDefault()
      return
    }
    const first = focusable[0]
    const last = focusable[focusable.length - 1]
    const current = document.activeElement
    if (event.shiftKey) {
      if (current === first || current === container) {
        event.preventDefault()
        last?.focus()
      }
    } else if (current === last) {
      event.preventDefault()
      first?.focus()
    }
  }

  return (
    // Backdrop click-to-dismiss, same pattern as ContextMenu/CommandPalette;
    // Escape (handled below, on the panel) is the keyboard equivalent.
    // biome-ignore lint/a11y/noStaticElementInteractions: see above
    // biome-ignore lint/a11y/useKeyWithClickEvents: see above
    <div className="modal-backdrop" data-testid="modal-backdrop" onClick={() => modal.onDismiss()}>
      {/* Swallows the backdrop's onClick so clicks inside the panel don't dismiss it. The
          panel itself needs no suppression: it carries role="dialog" plus its own
          onKeyDown, which is what those two rules ask for. */}
      <div
        ref={containerRef}
        tabIndex={-1}
        className="modal"
        role="dialog"
        aria-modal="true"
        aria-label={modal.title}
        data-testid={modal.testId ?? 'modal'}
        onClick={(event) => event.stopPropagation()}
        onKeyDown={handleKeyDown}
      >
        <h2 className="modal-title">{modal.title}</h2>
        {modal.body}
      </div>
    </div>
  )
}
