import type { LayoutSnapshot } from './layout'
import type { DragSubject, DropTarget } from './model/drag'
import type { FloatAnchor } from './model/floating'
import type { ContentNode, Tab } from './model/types'

/**
 * Wire shapes for the cross-window pane-drag protocol; the design is in
 * main/layoutCrossWindow.ts, the renderer half in content/crossWindowDrag.ts.
 * One discriminated union per direction over one channel each way, not a
 * channel per message: this is a state machine, each end dispatches its
 * union in one exhaustive `switch`, and a message added here without a
 * handler fails to compile.
 */

/**
 * What crosses from the source to a destination — a bare pane (any
 * `ContentNode`, a whole tab group included) or a tab, matching
 * `DragSubject`'s two kinds.
 */
export type CrossWindowDragContent = { kind: 'pane'; node: ContentNode } | { kind: 'tab'; tab: Tab }

/** The content subtree `content` carries: the pane itself, or the tab's content. */
export function dragContentNode(content: CrossWindowDragContent): ContentNode {
  return content.kind === 'pane' ? content.node : content.tab.content
}

/**
 * The `config` key a leaf's captured visual state travels under while it
 * crosses windows (see `PaneCapabilities.captureTransferState`). Transient:
 * written on detach, consumed at the destination's mount, never persisted —
 * it can hold a terminal's scrollback (see layoutStore's `layoutSnapshotOf`).
 */
export const CROSS_WINDOW_TRANSFER_STATE_KEY = 'crossWindowTransferState'

// ---------------------------------------------------------------------------
// Renderer → main
// ---------------------------------------------------------------------------

/**
 * This window's renderer is listening for main's side of the protocol. A
 * loaded page is not enough: the listener is installed from App's effect,
 * which can run after the load finishes, and a request sent before it is
 * dropped unheard — with no timeout to end the wait.
 */
interface CrossWindowRendererReady {
  type: 'ready'
}

/** A drag has engaged in this window; main starts tracking the cursor for it. */
export interface CrossWindowDragArmed {
  type: 'armed'
  subject: DragSubject
  title: string
}

/** The hovered window's resolved dock target for the current hover point, if any. */
export interface CrossWindowDragHoverTarget {
  type: 'hover-target'
  target: DropTarget | null
}

/** The source released with no local target; main answers with `release-result`. */
interface CrossWindowDragRelease {
  type: 'release'
}

/**
 * From the source: its drag ended locally. From main: the pending drag is
 * over, for any reason — sent to every window; one with no drag state
 * ignores it.
 */
interface CrossWindowDragCancel {
  type: 'cancel'
}

export type CrossWindowDetachResponse =
  | {
      type: 'detach-response'
      requestId: string
      ok: true
      content: CrossWindowDragContent
      /** Where it came from, for a rollback if the destination's insert then fails. */
      anchor: FloatAnchor
      /** The source's resulting layout, for main to persist at once. */
      snapshot: LayoutSnapshot
    }
  | { type: 'detach-response'; requestId: string; ok: false }

export type CrossWindowInsertResponse =
  | { type: 'insert-response'; requestId: string; ok: true; snapshot: LayoutSnapshot }
  | { type: 'insert-response'; requestId: string; ok: false }

/** Everything a renderer sends main over `IpcChannel.layoutCrossWindowFromRenderer`. */
export type CrossWindowMessageFromRenderer =
  | CrossWindowRendererReady
  | CrossWindowDragArmed
  | CrossWindowDragHoverTarget
  | CrossWindowDragRelease
  | CrossWindowDragCancel
  | CrossWindowDetachResponse
  | CrossWindowInsertResponse

// ---------------------------------------------------------------------------
// Main → renderer
// ---------------------------------------------------------------------------

/**
 * The drag is hovering this window at a LOCAL point, in its own CSS pixels
 * (translated from screen coordinates, and the window's zoom, by main). Sent
 * when the cursor moves over it, and periodically while it holds still;
 * carries the subject because a window learns of a drag only when hovered.
 */
export interface CrossWindowDragHover {
  type: 'hover'
  subject: DragSubject
  title: string
  x: number
  y: number
}

/** The drag has left this window, or ended. */
interface CrossWindowDragHoverEnd {
  type: 'hover-end'
}

/** Main's answer to the source's `release`: did a cross-window drop commit? */
interface CrossWindowDragReleaseResult {
  type: 'release-result'
  committed: boolean
}

/** Main asking the source to detach `subject` from its own tree. */
export interface CrossWindowDetachRequest {
  type: 'detach-request'
  requestId: string
  subject: DragSubject
}

/** Insert `content` at a drop target, or back at its captured anchor (the rollback after a destination refused). */
export interface CrossWindowInsertRequest {
  type: 'insert-request'
  requestId: string
  content: CrossWindowDragContent
  placement: { kind: 'dock'; target: DropTarget } | { kind: 'anchor'; anchor: FloatAnchor }
}

/** Everything main sends a renderer over `IpcChannel.layoutCrossWindowFromMain`. */
export type CrossWindowMessageFromMain =
  | CrossWindowDragHover
  | CrossWindowDragHoverEnd
  | CrossWindowDragReleaseResult
  | CrossWindowDragCancel
  | CrossWindowDetachRequest
  | CrossWindowInsertRequest
