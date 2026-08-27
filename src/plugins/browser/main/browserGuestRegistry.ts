import { session, type WebContents, webContents } from 'electron'
import type { MainPluginIpc } from '../../../main/plugin/api'
import { BrowserGuestMethod } from '../shared/ipc'
import { dropGuestBodySession, reapplyBodyCapture } from './networkBodyCapture'
import type { NetworkEntry, NetworkReadOptions } from './networkLog'
import {
  forgetGuestRequests,
  listRequests,
  recordRequestStart,
  recordRequestUpdate,
  resetNetworkLogsForTests
} from './networkLog'

/**
 * Which guest `WebContents` currently backs each browser pane, reported by
 * the renderer (see preload's BrowserGuestApi) because only it knows both
 * halves of the mapping: the pane id is a layout-tree concept that never
 * reaches main, and `webContentsId` is read off the live `<webview>` element.
 *
 * Main-process capture that Electron keys by `webContentsId` — `session
 * .webRequest`'s `details.webContentsId` is the one this exists for — has no
 * other way back to a pane id.
 *
 * **The id is not stable for a pane's lifetime.** A structural DOM
 * disconnect/reconnect of the `<webview>` (a drag-and-drop pane move, a tab
 * group collapsing or expanding) doesn't merely reload the guest page: it
 * destroys the guest `WebContents` object and builds a new one with a new id,
 * while the element itself survives via browserRegistry.ts's reattach cache.
 * Verified empirically (2 → 3 across a real reparent, with exactly one
 * `did-attach` firing), which is why the renderer re-reports on *every*
 * `did-attach` and everything keyed by a guest id here is rebuilt from
 * scratch when it does.
 */
const guestOf = new Map<string, number>()

/** Reverse of `guestOf`, so a webContentsId-keyed Electron event can find its pane in O(1). */
const paneOf = new Map<number, string>()

function setGuest(paneId: string, webContentsId: number): void {
  clearGuest(paneId)
  guestOf.set(paneId, webContentsId)
  paneOf.set(webContentsId, paneId)
  // A pane whose caller enabled body capture keeps it across guest churn:
  // the intent is per pane, the CDP session is per guest, and this report is
  // the moment the new guest becomes attributable. The reparented page began
  // loading before this report landed, so a body completing in that gap is
  // missed — the documented degradation, not a bug to fix here.
  reapplyBodyCapture(paneId, webContentsId)
}

function clearGuest(paneId: string): void {
  const previous = guestOf.get(paneId)
  if (previous !== undefined) {
    paneOf.delete(previous)
    // A replaced guest's captured requests are unreachable from here on —
    // nothing can resolve that id back to a pane — so drop them rather than
    // hold them for the rest of the app's life. Its CDP body session goes
    // with it: the session was per-guest-lifetime anyway.
    forgetGuestRequests(previous)
    dropGuestBodySession(previous)
    isGuest.delete(previous)
  }
  guestOf.delete(paneId)
}

/** The live guest `WebContents` id for `paneId`, or undefined if no browser pane is mounted for it. */
export function getGuestWebContentsId(paneId: string): number | undefined {
  return guestOf.get(paneId)
}

/**
 * The live guest `WebContents` object for `paneId` — what save-resource needs
 * to reach the guest's session (net.request), its debugger (blob bytes) and
 * its main world (element-src resolution). Undefined when no browser pane is
 * mounted, or the id no longer resolves to a live WebContents.
 */
export function getGuestWebContents(paneId: string): WebContents | undefined {
  const id = guestOf.get(paneId)
  if (id === undefined) return undefined
  return webContents.fromId(id) ?? undefined
}

/** The pane a guest `WebContents` belongs to — for demultiplexing webContentsId-keyed events. */
export function getPaneIdForGuest(webContentsId: number): string | undefined {
  return paneOf.get(webContentsId)
}

/**
 * Whether a webContents id belongs to a `<webview>` guest, asked of Electron
 * rather than of `paneOf`.
 *
 * That distinction is the whole reason capture works on a page's very first
 * load: a guest issues its document request the moment it attaches, before
 * the renderer has had a chance to report which pane it belongs to, so gating
 * capture on the pane mapping silently dropped every main-frame request.
 * Electron already knows the type at that instant.
 *
 * Memoized because this runs per request event, and ids are never reused
 * within a run — `clearGuest` evicts the entry when a guest goes away. Only
 * a *resolved* answer is memoized: caching a `fromId` miss would brand that
 * id non-guest for the life of the run, which for a guest asked about one
 * event too early is exactly the silent first-load capture loss this module
 * exists to prevent.
 */
const isGuest = new Map<number, boolean>()

function isGuestWebContents(id: number | undefined): id is number {
  if (id === undefined || id < 0) return false
  const cached = isGuest.get(id)
  if (cached !== undefined) return cached
  const contents = webContents.fromId(id)
  if (!contents) return false
  const resolved = contents.getType() === 'webview'
  isGuest.set(id, resolved)
  return resolved
}

/**
 * Captures request metadata for every registered guest, off one set of
 * session-wide listeners demultiplexed by `details.webContentsId`.
 *
 * One listener set, not one per pane, because `session.webRequest` allows
 * only a single listener per event — registering a second silently replaces
 * the first. Anything else in the app that ever needs `webRequest` on the
 * default session has to be folded in here rather than added alongside.
 *
 * The default session is the right one: a `<webview>` with no `partition`
 * attribute (BrowserRenderer sets none) shares it with the host, so guest
 * traffic passes through here. Host traffic does too, and is dropped —
 * `getPaneIdForGuest` only resolves ids the renderer has registered.
 */
function registerNetworkCapture(): void {
  const { webRequest } = session.defaultSession

  webRequest.onBeforeRequest((details, callback) => {
    if (isGuestWebContents(details.webContentsId)) {
      recordRequestStart(details.webContentsId, details.id, {
        method: details.method,
        url: details.url,
        resourceType: details.resourceType,
        startedAt: details.timestamp
      })
    }
    // Always continue the request untouched — this is observation only, and
    // a listener that forgets to call back hangs every request in the app.
    callback({})
  })

  webRequest.onBeforeSendHeaders((details, callback) => {
    if (isGuestWebContents(details.webContentsId)) {
      recordRequestUpdate(details.id, { requestHeaders: details.requestHeaders })
    }
    callback({ requestHeaders: details.requestHeaders })
  })

  webRequest.onCompleted((details) => {
    if (!isGuestWebContents(details.webContentsId)) return
    recordRequestUpdate(details.id, {
      status: details.statusCode,
      responseHeaders: flattenHeaders(details.responseHeaders),
      completedAt: details.timestamp
    })
  })

  webRequest.onErrorOccurred((details) => {
    if (!isGuestWebContents(details.webContentsId)) return
    recordRequestUpdate(details.id, { error: details.error, completedAt: details.timestamp })
  })
}

/** The requests captured for whichever guest currently backs `paneId`. */
export function listRequestsForPane(paneId: string, options: NetworkReadOptions): NetworkEntry[] {
  return listRequests(guestOf.get(paneId), options)
}

/** Response headers arrive as name → value*[]*; join them into the flat shape the protocol returns. */
function flattenHeaders(
  headers: Record<string, string[]> | undefined
): Record<string, string> | undefined {
  if (!headers) return undefined
  const flat: Record<string, string> = {}
  for (const [name, values] of Object.entries(headers)) {
    flat[name] = Array.isArray(values) ? values.join(', ') : String(values)
  }
  return flat
}

/** Wires the renderer's attach/detach reports and the network capture. Call once, at app startup. */
export function registerBrowserGuestIpc(ipc: MainPluginIpc): void {
  ipc.on(BrowserGuestMethod.attached, (_event, paneId, webContentsId) => {
    setGuest(paneId as string, webContentsId as number)
  })
  ipc.on(BrowserGuestMethod.detached, (_event, paneId) => {
    clearGuest(paneId as string)
  })
  registerNetworkCapture()
}

/** Drops every mapping and captured request — see src/main/e2e.ts's reset. */
export function resetBrowserGuestsForTests(): void {
  guestOf.clear()
  paneOf.clear()
  isGuest.clear()
  resetNetworkLogsForTests()
}
