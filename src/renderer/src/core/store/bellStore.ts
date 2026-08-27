import type { NodeId } from '@shared/model/types'
import { create } from 'zustand'
import { useLayoutStore } from './layoutStore'

export interface BellState {
  /**
   * Leaf pane ids with an unseen bell — flashes their pane/tab handle until
   * the user looks at that pane (today only TerminalRenderer.tsx rings it, but
   * nothing here is terminal-specific and any type may). That is why both
   * indicators are labelled just "Bell": the store holds no type, and the tab
   * indicator stands for a whole subtree, so naming one would claim a
   * precision it doesn't have.
   */
  ringing: Set<NodeId>
  /**
   * Reports a bell in `id`. No-ops when the user is looking at that pane at
   * this instant — it is the active pane AND this window has OS focus. Pane
   * activity alone is not enough: the active pane's bell almost always fires
   * while the user is away in another app (a long command finishing), and
   * gating on `activePaneId` alone swallowed exactly those. The flip side —
   * a bell in the pane the user is typing in right now (zsh's completion
   * beep, most commonly) — must NOT flag, or the user's own pane would
   * flash at them mid-keystroke, which is why this isn't an unconditional
   * ring either.
   */
  ring: (id: NodeId) => void
  clear: (id: NodeId) => void
}

/**
 * Ephemeral per-pane bell state — separate from `layoutStore` for the same
 * reason as `navFlashStore`: a momentary visual cue, not part of the layout
 * tree. Unlike navFlashStore's single global value, a bell is per-pane and
 * several panes can be ringing at once, so this is keyed by NodeId.
 */
export const useBellStore = create<BellState>()((set) => ({
  ringing: new Set(),
  ring: (id) =>
    set((state) => {
      if (id === useLayoutStore.getState().activePaneId && document.hasFocus()) return state
      if (state.ringing.has(id)) return state
      const next = new Set(state.ringing)
      next.add(id)
      return { ringing: next }
    }),
  clear: (id) =>
    set((state) => {
      if (!state.ringing.has(id)) return state
      const next = new Set(state.ringing)
      next.delete(id)
      return { ringing: next }
    })
}))

// The other half of ring()'s "looking at it" test: a bell that rang in the
// active pane while the window was unfocused clears the moment the window is
// focused again — the pane the user lands on is the ringing one, so they've
// seen it. Panes that aren't active keep their bells; those clear through
// core's focus-follows-active (PaneFocusFollower → handle.focus(), see the
// terminal's focus handle). Module scope like settingsStore's onChange
// mirror: one listener per renderer for the process's lifetime.
window.addEventListener('focus', () => {
  useBellStore.getState().clear(useLayoutStore.getState().activePaneId)
})
