import type { NodeId } from '@shared/model/types'
import type { PointerEvent as ReactPointerEvent } from 'react'
import type { ContextMenuItem } from '../../core/store/contextMenuStore'
import { startPaneDrag } from '../dragController'
import type { FloatingWindowContext } from './floatingContext'
import { startFloatingMove } from './floatingDrag'
import { repinFloatingWindow, unpinPaneAt } from './unpin'

/**
 * Window-chrome behavior shared by the two chrome hosts, `Pane`'s header and
 * `TabBar` — one place for the fork both must make identically: is this node
 * the pane a floating window is built around (its `rootNodeId`), a node
 * nested inside one, or a docked node?
 */

/**
 * Pointer-down on a pane's chrome: a floating window's own chrome moves the
 * window; chrome on any other pane dock-drags it within its own tree — except
 * the root pane, which has nowhere else to go.
 */
export function chromePointerDown(
  event: ReactPointerEvent<HTMLElement>,
  floating: FloatingWindowContext | null,
  nodeId: NodeId,
  isRoot: boolean,
  title: string
): void {
  if (floating && floating.rootNodeId === nodeId) {
    startFloatingMove(event, floating.floatId)
    return
  }
  if (isRoot) return
  startPaneDrag(event, nodeId, title)
}

/**
 * The chrome menu's Pin/Unpin entry: Pin for a floating window's own chrome,
 * Unpin for a docked node, and nothing for a node nested inside a floating
 * window — the store rejects unpinning those (see `unpinPane`), and no entry
 * beats a dead one. `originId` names the node to measure when the unpinned
 * node has no rect of its own (a backgrounded tab's content).
 */
export function pinOrUnpinItem(
  floating: FloatingWindowContext | null,
  nodeId: NodeId,
  originId?: NodeId
): ContextMenuItem | null {
  if (floating) {
    return floating.rootNodeId === nodeId
      ? { label: 'Pin', onSelect: () => repinFloatingWindow(floating.floatId) }
      : null
  }
  return { label: 'Unpin', onSelect: () => unpinPaneAt(nodeId, originId) }
}
