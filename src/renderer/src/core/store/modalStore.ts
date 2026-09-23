import type { ReactNode } from 'react'
import { create } from 'zustand'

/**
 * What `ModalHost` (Modal.tsx) renders for the one modal that may be open at
 * a time. `body` is built once, up front, by `openModal` (core/modal.ts) — the
 * store only ever holds the finished element, never a function it would have
 * to re-invoke, so a form's own `useState` inside `body` survives untouched
 * across every store update until `close()` unmounts it.
 */
export interface ModalDescriptor {
  title: string
  testId?: string | undefined
  body: ReactNode
  /** Escape or a backdrop click — never called by anything inside `body` itself, which closes through `openModal`'s own `resolve`. */
  onDismiss: () => void
}

export interface ModalState {
  modal: ModalDescriptor | null
  open: (descriptor: ModalDescriptor) => void
  close: () => void
}

/**
 * Ephemeral open/closed state for the single reusable modal shell — the same
 * shape as `contextMenuStore`/`commandPaletteStore`, and deliberately a
 * *different* store from either: a modal, a context menu and the command
 * palette can each be open independently (nothing here refuses to open
 * because one of the others is), and callers that need "is anything blocking
 * open" (see spatialNav.ts) read this store specifically for the modal case.
 */
export const useModalStore = create<ModalState>()((set) => ({
  modal: null,
  open: (descriptor) => set({ modal: descriptor }),
  close: () => set({ modal: null })
}))
