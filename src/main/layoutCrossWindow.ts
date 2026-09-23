import { randomUUID } from 'node:crypto'
import type { BrowserWindow, Point, Rectangle, WebContents } from 'electron'
import { screen } from 'electron'
import { IpcChannel } from '../shared/ipc'
import type {
  CrossWindowDetachRequest,
  CrossWindowDetachResponse,
  CrossWindowDragArmed,
  CrossWindowDragContent,
  CrossWindowDragHoverTarget,
  CrossWindowInsertRequest,
  CrossWindowInsertResponse,
  CrossWindowMessageFromMain,
  CrossWindowMessageFromRenderer
} from '../shared/layoutCrossWindow'
import type { DragSubject, DropTarget } from '../shared/model/drag'
import { onRendererMessage } from './ipcListeners'
import { applyExternalSnapshot } from './layout'
import { createRendererRelay } from './rendererRelay'
import {
  getPaneTreeWindows,
  livePaneTreeWindow,
  onPaneTreeWindowClosed,
  type WindowId,
  windowIdForWebContents,
  windowsFrontToBack
} from './windows'

/**
 * The cross-window pane-drag protocol: dragging a pane out of one pane-tree
 * window and dropping it into another, with the same dock-zone semantics as
 * an in-window drag. Main is a broker only and never touches a tree: the
 * detach in the source and the insert in the destination run as ordinary
 * layoutStore actions in those renderers, and main relays the requests and
 * awaits the replies (`rendererRelay.ts`).
 *
 * Main polls the real cursor because no window can see the drag arrive. OS
 * mouse capture delivers every pointer event to the window that received
 * the press, even with the cursor over another window, so a destination
 * never gets a `pointermove`; only `screen.getCursorScreenPoint()` knows
 * where the cursor is. Main polls it while a drag is armed, tells the
 * hovered window, and the source's real `pointerup` commits against the
 * last known hover.
 *
 * Nothing here times out. A request already sent is still performed by a
 * slow renderer, so acting on a timeout acts on a mutation that happens
 * anyway — content detached and inserted nowhere, or rolled back into the
 * source *and* inserted late in the destination. Relays settle on their
 * reply, on their window closing, or on its renderer crashing or reloading
 * (see `relayTo`), and the poll ends the drag if the source stops being a
 * live, loaded, un-crashed renderer.
 */

/** How often main asks the OS where the cursor is while a drag is armed. Cheap and synchronous. */
const HOVER_POLL_MS = 16

/**
 * How often a hover is re-sent while the cursor holds still. Each one costs
 * the hovered window a hit test, two drag-store writes and a reply, so it is
 * sent when the point or window changes; this refresh only re-resolves a
 * target that moved under a still cursor (a pane closing, a split resizing).
 */
const HOVER_REFRESH_MS = 250

interface PendingCrossWindowDrag {
  sourceWindowId: WindowId
  subject: DragSubject
  title: string
  pollTimer: ReturnType<typeof setInterval>
  /** Which *other* window the cursor is over, and the dock target it last reported for that point. */
  hover: { windowId: WindowId; target: DropTarget | null } | null
  /** The last hover sent to that window, so a still cursor is not re-sent every tick. */
  lastSent: { x: number; y: number; at: number } | null
}

/** At most one cross-window drag at a time, like dragController.ts's one gesture at a time. */
let pendingDrag: PendingCrossWindowDrag | null = null

/**
 * e2e only: the cursor point the poll reads instead of the real one.
 * Playwright cannot move a real cursor across two native windows, and faking
 * the destination's arrival instead would test only the shortcut.
 */
let cursorOverrideForTests: Point | null = null

/** e2e only — see `cursorOverrideForTests`. */
export function setCrossWindowCursorPointForTests(point: Point | null): void {
  cursorOverrideForTests = point
}

function currentCursorPoint(): Point {
  return cursorOverrideForTests ?? screen.getCursorScreenPoint()
}

function contains(bounds: Rectangle, point: Point): boolean {
  return (
    point.x >= bounds.x &&
    point.x < bounds.x + bounds.width &&
    point.y >= bounds.y &&
    point.y < bounds.y + bounds.height
  )
}

/** Sends `message` to `windowId` if it is still a live pane-tree window. */
function sendTo(windowId: WindowId, message: CrossWindowMessageFromMain): void {
  livePaneTreeWindow(windowId)?.webContents.send(IpcChannel.layoutCrossWindowFromMain, message)
}

/**
 * Renderers whose current document has said it is listening (`ready`),
 * until that document goes — a navigation or a crash. What `rendererAnswers`
 * rests on: a loaded page is not yet a listening one (App subscribes from an
 * effect), and a request it never hears waits forever.
 */
const listening = new WeakSet<WebContents>()
const watchedForNavigation = new WeakSet<WebContents>()

function markListening(webContents: WebContents): void {
  listening.add(webContents)
  if (watchedForNavigation.has(webContents)) return
  watchedForNavigation.add(webContents)
  webContents.on('did-start-navigation', (details) => {
    if (details.isMainFrame && !details.isSameDocument) listening.delete(webContents)
  })
  webContents.on('render-process-gone', () => listening.delete(webContents))
}

/**
 * Whether `win`'s renderer can take part at all: its current document has
 * said it is listening, and it is neither crashed nor mid-(re)load.
 * `<webview>` guest loads do not count; only the window's own document.
 */
function rendererAnswers(win: BrowserWindow): boolean {
  const { webContents } = win
  return listening.has(webContents) && !webContents.isCrashed() && !webContents.isLoading()
}

/**
 * Whether `win` could be the window under the cursor during `source`'s drag
 * at all — its frame alone cannot say. A minimized window still reports the
 * place it was minimized from, and on macOS a native-fullscreen window has a
 * Space to itself, which a source that is not fullscreen cannot be on (two
 * fullscreen windows may share one in Split View, so that pair stays
 * allowed). A window on another ordinary Space is not detectable from here.
 * One mid-crash or mid-reload has no DOM to resolve a target against.
 */
function canReceiveHover(win: BrowserWindow, source: BrowserWindow): boolean {
  if (win.isDestroyed() || win.isMinimized()) return false
  if (process.platform === 'darwin' && win.isFullScreen() && !source.isFullScreen()) return false
  return rendererAnswers(win)
}

/**
 * Polled while a drag is pending: tells the *other* window the cursor is
 * inside about the hover (whenever the point moves, and every
 * `HOVER_REFRESH_MS` while it holds still; once on exit),
 * and ends the drag if the source can no longer end it itself.
 *
 * A point inside the source's own bounds is the source's. The window that
 * received the press is frontmost for the whole gesture, so a window under
 * that point is occluded, and hovering it would commit into a window the
 * user cannot see. Two *other* windows overlapping: the frontmost of them
 * wins, by main's own tracking of the stacking order (see
 * `windowsFrontToBack`) — Electron has no "topmost window at a point", and
 * the first-created one, which asking in creation order found, is the one
 * underneath a cascade. A visible Settings or About window in front of the
 * point hides everything under it the same way.
 */
function pollHover(drag: PendingCrossWindowDrag): void {
  const sourceWin = livePaneTreeWindow(drag.sourceWindowId)
  if (!sourceWin || !rendererAnswers(sourceWin)) {
    clearPendingDrag()
    return
  }

  const point = currentCursorPoint()
  let hoveredId: WindowId | null = null
  let hoveredWin: BrowserWindow | null = null
  if (!contains(sourceWin.getBounds(), point)) {
    for (const { win, windowId } of windowsFrontToBack()) {
      if (win === sourceWin) continue
      if (windowId === undefined) {
        // Settings or About in front of the point hides whatever is under it.
        if (win.isVisible() && !win.isMinimized() && contains(win.getBounds(), point)) break
        continue
      }
      if (!canReceiveHover(win, sourceWin)) continue
      if (contains(win.getContentBounds(), point)) {
        hoveredId = windowId
        hoveredWin = win
        break
      }
    }
  }

  const previousId = drag.hover?.windowId ?? null
  if (hoveredId !== previousId) {
    if (previousId) sendTo(previousId, { type: 'hover-end' })
    drag.hover = hoveredId ? { windowId: hoveredId, target: null } : null
    drag.lastSent = null
  }

  if (hoveredId && hoveredWin) {
    const bounds = hoveredWin.getContentBounds()
    // Screen points are DIPs; the renderer resolves targets in CSS pixels,
    // which a zoomed page (View → Zoom In) scales.
    const zoom = hoveredWin.webContents.getZoomFactor()
    const x = (point.x - bounds.x) / zoom
    const y = (point.y - bounds.y) / zoom
    const now = Date.now()
    const last = drag.lastSent
    if (last && last.x === x && last.y === y && now - last.at < HOVER_REFRESH_MS) return
    drag.lastSent = { x, y, at: now }
    sendTo(hoveredId, { type: 'hover', subject: drag.subject, title: drag.title, x, y })
  }
}

/** Clears the pending drag and tells every window `cancel` — the hovered one drops its preview, the source drops a session that never got its release. */
function clearPendingDrag(): void {
  if (!pendingDrag) return
  clearInterval(pendingDrag.pollTimer)
  pendingDrag = null
  for (const windowId of getPaneTreeWindows().keys()) sendTo(windowId, { type: 'cancel' })
}

/** Detach/insert requests into a renderer, keyed by window so a closing window refuses its own. */
const relay = createRendererRelay<
  CrossWindowDetachRequest | CrossWindowInsertRequest,
  CrossWindowDetachResponse | CrossWindowInsertResponse
>(IpcChannel.layoutCrossWindowFromMain)

/**
 * Relays `request` into `windowId`'s renderer. Besides its reply or its
 * window closing, a request settles as refused when that renderer crashes
 * or reloads while it is pending (the relay's own rule): without that, a
 * detach already performed in the source would wait forever for an insert
 * nobody performs — no rollback, no `release-result`, and the source's next
 * save persisting the tree without the content.
 */
function relayTo<R extends CrossWindowDetachResponse | CrossWindowInsertResponse>(
  windowId: WindowId,
  request: CrossWindowDetachRequest | CrossWindowInsertRequest,
  refused: R
): Promise<R> {
  const win = livePaneTreeWindow(windowId)
  // Refused up front, not only by the relay: a reload that has already
  // committed fires no further `did-navigate` for it to hear.
  if (!win || !rendererAnswers(win)) return Promise.resolve(refused)
  return relay.send(win.webContents, windowId, request, refused)
}

function requestDetach(
  windowId: WindowId,
  subject: DragSubject
): Promise<CrossWindowDetachResponse> {
  const requestId = randomUUID()
  return relayTo(
    windowId,
    { type: 'detach-request', requestId, subject },
    { type: 'detach-response', requestId, ok: false }
  )
}

function requestInsert(
  windowId: WindowId,
  content: CrossWindowDragContent,
  placement: CrossWindowInsertRequest['placement']
): Promise<CrossWindowInsertResponse> {
  const requestId = randomUUID()
  return relayTo(
    windowId,
    { type: 'insert-request', requestId, content, placement },
    { type: 'insert-response', requestId, ok: false }
  )
}

/**
 * Once the source's real release confirms a hover target: detach from the
 * source, insert into the destination, persist each side as it answers, or
 * roll back into the source if the destination refuses — then tell the
 * source whether it committed, which decides whether its ghost flies home
 * or vanishes.
 */
async function commitCrossWindowDrag(
  drag: PendingCrossWindowDrag,
  destWindowId: WindowId,
  target: DropTarget
): Promise<void> {
  const releaseResult = (committed: boolean): void =>
    sendTo(drag.sourceWindowId, { type: 'release-result', committed })

  const detached = await requestDetach(drag.sourceWindowId, drag.subject)
  if (!detached.ok) {
    releaseResult(false)
    return
  }
  // Recorded now, not once the insert settles: the source's own saves keep
  // arriving meanwhile, and applying this older snapshot after them would
  // roll main's copy of the source back past whatever the user did there —
  // a pane opened while a busy destination held the insert would be missing
  // from the close confirmation and from the next launch.
  applyExternalSnapshot(drag.sourceWindowId, detached.snapshot)

  const inserted = await requestInsert(destWindowId, detached.content, { kind: 'dock', target })
  if (inserted.ok) {
    applyExternalSnapshot(destWindowId, inserted.snapshot)
    // No hover-end for the destination: the release already broadcast
    // `cancel`, and one sent this late would end the preview of whatever
    // drag the user started over it meanwhile.
    releaseResult(true)
    return
  }

  // Refused, or closed before answering — the source already detached, so
  // put the content back where it came from.
  releaseResult(false)
  const rolledBack = await requestInsert(drag.sourceWindowId, detached.content, {
    kind: 'anchor',
    anchor: detached.anchor
  })
  if (rolledBack.ok) applyExternalSnapshot(drag.sourceWindowId, rolledBack.snapshot)
}

function handleArmed(sourceWindowId: WindowId, message: CrossWindowDragArmed): void {
  // With no other window there is nothing to hover: no poll, no pending
  // drag. A release still gets its answer (handleRelease, not recognizing
  // the drag, says "not committed").
  if (pendingDrag || getPaneTreeWindows().size < 2) return
  const drag: PendingCrossWindowDrag = {
    sourceWindowId,
    subject: message.subject,
    title: message.title,
    // Guarded: a throw from a timer callback is an uncaught main-process
    // exception, which Electron answers with its native error modal.
    pollTimer: setInterval(() => {
      try {
        pollHover(drag)
      } catch (error) {
        console.error('[tabs] cross-window hover poll failed; ending the drag:', error)
        clearPendingDrag()
      }
    }, HOVER_POLL_MS),
    hover: null,
    lastSent: null
  }
  pendingDrag = drag
}

/** Only the currently hovered window's report counts — a stale one from a window the hover just left must not overwrite it. */
function handleHoverTarget(windowId: WindowId, message: CrossWindowDragHoverTarget): void {
  if (!pendingDrag?.hover || windowId !== pendingDrag.hover.windowId) return
  pendingDrag.hover.target = message.target
}

/** Only the source may cancel its own drag. */
function handleCancel(windowId: WindowId): void {
  if (pendingDrag?.sourceWindowId === windowId) clearPendingDrag()
}

function handleRelease(windowId: WindowId): void {
  if (!pendingDrag || pendingDrag.sourceWindowId !== windowId) {
    // Already cleared by a concurrent cancel — the window is still owed the
    // answer its ghost is waiting on (dragController's resolveDeferredRelease).
    sendTo(windowId, { type: 'release-result', committed: false })
    return
  }
  const drag = pendingDrag
  const hover = drag.hover
  clearPendingDrag()
  if (hover?.target) {
    // Nothing in it rejects; if something ever does, the source's ghost is
    // still owed its answer.
    commitCrossWindowDrag(drag, hover.windowId, hover.target).catch((error: unknown) => {
      console.error('[tabs] cross-window drop failed:', error)
      sendTo(windowId, { type: 'release-result', committed: false })
    })
  } else {
    sendTo(windowId, { type: 'release-result', committed: false })
  }
}

function handleDetachResponse(windowId: WindowId, response: CrossWindowDetachResponse): void {
  if (relay.resolve(response) || !response.ok) return
  // A successful detach nobody awaits is content removed with no insert
  // coming. Nothing in the protocol produces it; put it straight back.
  void requestInsert(windowId, response.content, {
    kind: 'anchor',
    anchor: response.anchor
  }).then((restored) => {
    if (restored.ok) applyExternalSnapshot(windowId, restored.snapshot)
  })
}

/** Wires the whole protocol's IPC surface. Call once, alongside `registerLayoutIpc`. */
export function registerLayoutCrossWindowIpc(): void {
  onRendererMessage(
    IpcChannel.layoutCrossWindowFromRenderer,
    (event, message: CrossWindowMessageFromRenderer) => {
      const windowId = windowIdForWebContents(event.sender)
      if (!windowId) return
      switch (message.type) {
        case 'ready':
          markListening(event.sender)
          break
        case 'armed':
          handleArmed(windowId, message)
          break
        case 'hover-target':
          handleHoverTarget(windowId, message)
          break
        case 'cancel':
          handleCancel(windowId)
          break
        case 'release':
          handleRelease(windowId)
          break
        case 'detach-response':
          handleDetachResponse(windowId, message)
          break
        case 'insert-response':
          relay.resolve(message)
          break
        default: {
          const unhandled: never = message
          throw new Error(`unhandled cross-window message: ${JSON.stringify(unhandled)}`)
        }
      }
    }
  )

  // A closing window answers every relay waiting on it, and ends a pending
  // drag it was the source or live hover of.
  onPaneTreeWindowClosed((closedId) => {
    relay.refuse(closedId)
    if (pendingDrag?.sourceWindowId === closedId || pendingDrag?.hover?.windowId === closedId) {
      clearPendingDrag()
    }
  })
}

/** e2e only: clears this module's state between tests; a relay still waiting is refused, never left dangling. */
export function resetCrossWindowDragForTests(): void {
  clearPendingDrag()
  cursorOverrideForTests = null
  relay.refuse()
}
