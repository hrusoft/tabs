import type { NodeId } from '@shared/model/types'
import { create } from 'zustand'
import type { PaneCreationAction } from '../registry/registry'

/**
 * Which step of the picker is showing, and the data that step needs — a
 * discriminated union rather than separate optional fields, so `action`
 * cannot be read while still on the type step and there is nothing to
 * invalidate when moving between steps.
 */
export type CommandPaletteStep =
  | { kind: 'closed' }
  | { kind: 'type'; targetPaneId: NodeId }
  | { kind: 'placement'; targetPaneId: NodeId; action: PaneCreationAction }

interface CommandPaletteState {
  step: CommandPaletteStep
  open: (targetPaneId: NodeId) => void
  chooseType: (action: PaneCreationAction) => void
  close: () => void
}

/**
 * Ephemeral open/closed state for the Cmd+P content-creation overlay —
 * separate from `layoutStore` for the same reason `navFlashStore` and
 * `contextMenuStore` are: transient UI, not part of the persisted layout.
 */
export const useCommandPaletteStore = create<CommandPaletteState>()((set) => ({
  step: { kind: 'closed' },
  open: (targetPaneId) => set({ step: { kind: 'type', targetPaneId } }),
  chooseType: (action) =>
    set((state) =>
      state.step.kind === 'closed'
        ? state
        : { step: { kind: 'placement', targetPaneId: state.step.targetPaneId, action } }
    ),
  close: () => set({ step: { kind: 'closed' } })
}))
