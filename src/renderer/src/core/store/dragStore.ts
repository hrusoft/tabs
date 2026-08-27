import type { DockZone, NodeId } from '@shared/model/types'
import { create } from 'zustand'

export type DropTarget =
  | { kind: 'tab-bar'; groupId: NodeId; index: number }
  | { kind: 'empty-pane'; paneId: NodeId }
  | { kind: 'dock'; targetId: NodeId; zone: DockZone }

/** What is being dragged: a tab out of its bar, or a whole pane by its header. */
export type DragSubject =
  | { kind: 'tab'; tabId: NodeId; sourceGroupId: NodeId }
  | { kind: 'pane'; paneId: NodeId }

export interface DragInfo {
  subject: DragSubject
  title: string
  x: number
  y: number
  target: DropTarget | null
  /** `returning` is the fly-back after a targetless release: the ghost is animating home. */
  phase: 'active' | 'returning'
  returnTo: { x: number; y: number } | null
}

export interface DragState {
  drag: DragInfo | null
  beginDrag: (subject: DragSubject, title: string, x: number, y: number) => void
  setPointer: (x: number, y: number) => void
  setTarget: (target: DropTarget | null) => void
  startReturn: (x: number, y: number) => void
  endDrag: () => void
}

/**
 * Ephemeral pointer-drag UI state — separate from `layoutStore` because it
 * describes an in-progress gesture, not part of the persisted layout tree.
 */
export const useDragStore = create<DragState>()((set) => ({
  drag: null,
  beginDrag: (subject, title, x, y) =>
    set({
      drag: { subject, title, x, y, target: null, phase: 'active', returnTo: null }
    }),
  setPointer: (x, y) =>
    set((state) => (state.drag?.phase === 'active' ? { drag: { ...state.drag, x, y } } : state)),
  setTarget: (target) =>
    set((state) => (state.drag?.phase === 'active' ? { drag: { ...state.drag, target } } : state)),
  startReturn: (x, y) =>
    set((state) =>
      state.drag
        ? { drag: { ...state.drag, phase: 'returning', returnTo: { x, y }, target: null } }
        : state
    ),
  endDrag: () => set({ drag: null })
}))
