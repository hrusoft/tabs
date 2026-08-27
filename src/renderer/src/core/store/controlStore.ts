import type { NodeId } from '@shared/model/types'
import { create } from 'zustand'

export interface ControlState {
  /**
   * Pane ids currently owned by another pane through the external-control
   * ownership ledger (see src/main/externalControl.ts's `ownerOf`) — a pane
   * an agent created via tabs-ctl and can still target. Generalizes
   * bellStore's shape (content-agnostic, keyed by NodeId) to a different
   * signal: unlike a bell, there is no renderer-imperative writer here (no
   * `ring`/`clear` equivalent) — ownership is decided in main, so this store
   * only mirrors it, seeded from a synchronous snapshot at module init
   * (mirrors layoutStore/settingsStore's getSync-then-subscribe pattern) and
   * kept live by onOwnershipChanged.
   */
  controlled: Set<NodeId>
  setControlled: (id: NodeId, owned: boolean) => void
}

export const useControlStore = create<ControlState>()((set) => ({
  controlled: new Set(window.api.externalControl.getOwnedPanesSync()),
  setControlled: (id, owned) =>
    set((state) => {
      if (state.controlled.has(id) === owned) return state
      const next = new Set(state.controlled)
      if (owned) next.add(id)
      else next.delete(id)
      return { controlled: next }
    })
}))

// One listener per renderer for the process's lifetime — same module-scope
// shape as bellStore's own window 'focus' listener.
window.api.externalControl.onOwnershipChanged((paneId, owned) => {
  useControlStore.getState().setControlled(paneId, owned)
})
