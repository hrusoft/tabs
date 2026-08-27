import type { NodeId } from '@shared/model/types'
import { createContext, useContext } from 'react'

export interface FloatingWindowContext {
  /** The floating window's own stable id (not its content's — see `FloatingPane.id`). */
  floatId: NodeId
  /** The node the window is built around, i.e. its outermost pane. */
  rootNodeId: NodeId
}

/**
 * Set for everything rendered inside a floating window. Its presence turns
 * that window's *outermost* pane chrome from a dock-drag handle into a
 * window-move handle, and swaps its context menu's "Unpin" for "Pin". Chrome
 * nested deeper inside keeps dock-dragging within the window — exactly as a
 * real window's title bar moves it while a divider inside it does not — which
 * is why consumers compare `rootNodeId` against their own node rather than
 * just checking for a context.
 */
export const FloatingContext = createContext<FloatingWindowContext | null>(null)

export function useFloatingWindow(): FloatingWindowContext | null {
  return useContext(FloatingContext)
}
