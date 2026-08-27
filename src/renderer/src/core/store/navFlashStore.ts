import type { NavDirection } from '@shared/model/navigation'
import { create } from 'zustand'

export interface NavFlashState {
  /** The latest cmd+arrow press; `nonce` remounts the overlay so a press mid-fade restarts it. */
  flash: { direction: NavDirection; nonce: number } | null
  trigger: (direction: NavDirection) => void
  clear: () => void
}

/**
 * Ephemeral keyboard-navigation feedback state — separate from `layoutStore`
 * because it describes a momentary visual cue, not part of the layout tree.
 */
export const useNavFlashStore = create<NavFlashState>()((set) => ({
  flash: null,
  trigger: (direction) =>
    set((state) => ({ flash: { direction, nonce: (state.flash?.nonce ?? 0) + 1 } })),
  clear: () => set({ flash: null })
}))
