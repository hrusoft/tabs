import { create } from 'zustand'

export interface ContextMenuItem {
  label: string
  onSelect: () => void
}

export interface ContextMenuState {
  menu: { x: number; y: number; items: ContextMenuItem[] } | null
  open: (x: number, y: number, items: ContextMenuItem[]) => void
  close: () => void
}

/**
 * Ephemeral open/closed state for the single right-click context menu —
 * separate from `layoutStore` for the same reason `dragStore` and
 * `navFlashStore` are: transient UI, not part of the persisted layout.
 */
export const useContextMenuStore = create<ContextMenuState>()((set) => ({
  menu: null,
  open: (x, y, items) => set({ menu: { x, y, items } }),
  close: () => set({ menu: null })
}))
