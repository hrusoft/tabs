import type { ContentNode, DockZone, NodeId } from '@tabs/plugin-sdk/shared/model/types'
import { findNode, findTab } from './tree'

/** What is being dragged: a tab out of its bar, or a whole pane by its header. Shared with main, which relays it between windows. */
export type DragSubject =
  | { kind: 'tab'; tabId: NodeId; sourceGroupId: NodeId }
  | { kind: 'pane'; paneId: NodeId }

/** Where a drag would land, resolved by the window whose tree it names; main relays it opaquely. */
export type DropTarget =
  | { kind: 'tab-bar'; groupId: NodeId; index: number }
  | { kind: 'empty-pane'; paneId: NodeId }
  | { kind: 'dock'; targetId: NodeId; zone: DockZone }

/**
 * The content subtree `subject` names in `root` — the pane node itself, or the
 * tab's content — or null when it no longer resolves there.
 */
export function subjectSubtree(root: ContentNode, subject: DragSubject): ContentNode | null {
  return subject.kind === 'pane'
    ? findNode(root, subject.paneId)
    : (findTab(root, subject.tabId)?.tab.content ?? null)
}
