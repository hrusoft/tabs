import type {
  CrossWindowDetachRequest,
  CrossWindowDragContent,
  CrossWindowDragHover,
  CrossWindowInsertRequest,
  CrossWindowMessageFromMain,
  CrossWindowMessageFromRenderer
} from '@shared/layoutCrossWindow'
import { CROSS_WINDOW_TRANSFER_STATE_KEY } from '@shared/layoutCrossWindow'
import type { DropTarget } from '@shared/model/drag'
import { subjectSubtree } from '@shared/model/drag'
import { canDockExternalTarget, mapLeaves } from '@shared/model/tree'
import type { ContentNode, NodeId } from '@tabs/plugin-sdk/shared/model/types'
import { collectLeaves } from '@tabs/plugin-sdk/shared/model/types'
import { getPaneCapability } from '../core/registry/paneHandles'
import { useDragStore } from '../core/store/dragStore'
import { type LayoutState, layoutSnapshotOf, useLayoutStore } from '../core/store/layoutStore'
import {
  abortSession,
  emptyPaneTargetAt,
  resolveDeferredRelease,
  resolveDockTargetAt,
  tabBarTargetAt,
  targetByPrecedence
} from './dragController'

/**
 * The renderer half of the cross-window pane-drag protocol (design in
 * main/layoutCrossWindow.ts). Installed once per window, it mostly answers
 * main: as the hovered window it drives the drag overlay from the point main
 * reports and reports the resolved target back; as the source or the
 * destination it performs the detach or insert main asks for through the
 * ordinary layoutStore actions.
 */

/** Currently tracking a live hover from main — this window is a candidate drop destination right now. */
let hovering = false

function send(message: CrossWindowMessageFromRenderer): void {
  window.api.layout.sendCrossWindow(message)
}

/**
 * The target a pane from another window would land on at (x, y), in the
 * in-window resolver's own order (`targetByPrecedence`): tab bars, then edge
 * dock zones, then empty panes, then center docking. The dock half is the in-window resolver itself
 * (`resolveDockTargetAt`) — the same point lands the same place, group-edge
 * band and enclosing-group merge included — judged by
 * `canDockExternalTarget`, since the self-containment rules an in-window
 * subject is checked against need it to be in this tree; so is the tab-bar
 * half (`tabBarTargetAt`), with nothing departing. An empty pane is
 * its own target, as in-window: a center dock there would walk up to an
 * enclosing group and open a tab beside the placeholder instead of filling
 * it. No spring-loading.
 */
function resolveExternalDockTarget(x: number, y: number): DropTarget | null {
  const root = useLayoutStore.getState().root
  const el = document.elementFromPoint(x, y)

  const accepts = (targetId: NodeId): boolean => canDockExternalTarget(root, targetId)
  return targetByPrecedence({
    tabBar: () => tabBarTargetAt(root, el, x, accepts, () => null),
    dock: () => resolveDockTargetAt(root, root, el, x, y, accepts),
    emptyPane: () => emptyPaneTargetAt(el, accepts)
  })
}

/** Starts or updates the overlay from main's point, and reports the resolved target back — main needs it the instant the source releases. */
function handleHover(message: CrossWindowDragHover): void {
  if (!hovering) {
    hovering = true
    useDragStore.getState().beginDrag(message.subject, message.title, message.x, message.y)
  } else {
    useDragStore.getState().setPointer(message.x, message.y)
  }
  const target = resolveExternalDockTarget(message.x, message.y)
  useDragStore.getState().setTarget(target)
  send({ type: 'hover-target', target })
}

function handleHoverEnd(): void {
  if (!hovering) return
  hovering = false
  useDragStore.getState().endDrag()
}

function handleDragCancel(): void {
  handleHoverEnd()
  // This window's own session, if it is the source and never got its release.
  abortSession()
}

/**
 * Captures and primes every leaf under the moving content before the tree
 * mutation unmounts them — every leaf, since a group dragged by its header
 * carries every terminal inside it, each with a pty to keep alive. `undo`
 * reverses the priming if the detach then fails. A throw partway through
 * reverses the leaves already primed before it propagates: a primed pane
 * skips its dispose on its next real close, so one left primed leaks its pty.
 */
function prepareLeaves(content: ContentNode): {
  transferStates: Map<NodeId, string>
  undo: () => void
} {
  const transferStates = new Map<NodeId, string>()
  const undos: (() => void)[] = []
  const undo = (): void => {
    for (const reverse of undos) reverse()
  }
  try {
    for (const leaf of collectLeaves(content)) {
      const state = getPaneCapability(leaf.id, 'captureTransferState')?.()
      if (state !== undefined) transferStates.set(leaf.id, state)
      const reverse = getPaneCapability(leaf.id, 'prepareCrossWindowDetach')?.()
      if (reverse) undos.push(reverse)
    }
  } catch (error) {
    undo()
    throw error
  }
  return { transferStates, undo }
}

/** Stamps each leaf's captured snapshot onto the content about to cross windows; the destination's renderer consumes it at mount. */
function withTransferState(
  content: CrossWindowDragContent,
  transferStates: ReadonlyMap<NodeId, string>
): CrossWindowDragContent {
  if (transferStates.size === 0) return content
  const stamp = (node: ContentNode): ContentNode =>
    mapLeaves(node, (leaf) => {
      const state = transferStates.get(leaf.id)
      if (state === undefined) return leaf
      return { ...leaf, config: { ...leaf.config, [CROSS_WINDOW_TRANSFER_STATE_KEY]: state } }
    })
  return content.kind === 'pane'
    ? { kind: 'pane', node: stamp(content.node) }
    : { kind: 'tab', tab: { ...content.tab, content: stamp(content.tab.content) } }
}

function handleDetachRequest(request: CrossWindowDetachRequest): void {
  let prepared: ReturnType<typeof prepareLeaves> | null = null
  let result: ReturnType<LayoutState['extractForCrossWindowMove']> = null
  try {
    // Before the detach: a live instance is gone the instant it unmounts,
    // and the priming is what that unmount's cleanup reads.
    const content = subjectSubtree(useLayoutStore.getState().root, request.subject)
    if (content) {
      prepared = prepareLeaves(content)
      // A stale local session, if this window is the source.
      abortSession()
      result = useLayoutStore.getState().extractForCrossWindowMove(request.subject)
    }
  } catch (error) {
    console.error('[tabs] cross-window detach failed:', error)
  }
  // The reply says what happened to the tree, whatever threw on the way:
  // content that left it must reach main, or it is in no window at all. The
  // store action's own result is that fact (see setReportingCommit).
  if (!result) {
    prepared?.undo()
    send({ type: 'detach-response', requestId: request.requestId, ok: false })
    return
  }
  send({
    type: 'detach-response',
    requestId: request.requestId,
    ok: true,
    content: withTransferState(result.content, prepared?.transferStates ?? new Map()),
    anchor: result.anchor,
    snapshot: layoutSnapshotOf(useLayoutStore.getState())
  })
}

function handleInsertRequest(request: CrossWindowInsertRequest): void {
  let inserted = false
  try {
    const store = useLayoutStore.getState()
    if (request.placement.kind === 'dock') {
      inserted = store.insertFromCrossWindowMove(request.content, request.placement.target)
    } else {
      store.reinsertAtAnchor(request.content, request.placement.anchor)
      inserted = true
    }
  } catch (error) {
    console.error('[tabs] cross-window insert failed:', error)
  }
  // As for a detach: the reply is whether the tree changed, which main
  // either persists or answers with a rollback into the source.
  send(
    inserted
      ? {
          type: 'insert-response',
          requestId: request.requestId,
          ok: true,
          snapshot: layoutSnapshotOf(useLayoutStore.getState())
        }
      : { type: 'insert-response', requestId: request.requestId, ok: false }
  )
}

/** Everything main can say, dispatched exhaustively — a message added to the union without a case here fails to compile. */
function handleMessage(message: CrossWindowMessageFromMain): void {
  switch (message.type) {
    case 'hover':
      handleHover(message)
      break
    case 'hover-end':
      handleHoverEnd()
      break
    case 'release-result':
      resolveDeferredRelease(message.committed)
      break
    case 'cancel':
      handleDragCancel()
      break
    case 'detach-request':
      handleDetachRequest(message)
      break
    case 'insert-request':
      handleInsertRequest(message)
      break
    default: {
      const unhandled: never = message
      throw new Error(`unhandled cross-window message: ${JSON.stringify(unhandled)}`)
    }
  }
}

/** Wires this window into the protocol. Call once, alongside the app's other installXxx effects. */
export function installCrossWindowDrag(): () => void {
  const unsubscribe = window.api.layout.onCrossWindow(handleMessage)
  // After subscribing: main sends nothing that needs an answer before this.
  send({ type: 'ready' })
  return () => {
    unsubscribe()
    handleHoverEnd()
  }
}
