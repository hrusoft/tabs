import { type WebContents, webContents } from 'electron'
import { acquireGuestDebugger, type DebuggerLease } from './guestDebugger'
import { recordResponseBody } from './networkLog'

/**
 * Opt-in response-body capture: a persistent CDP `Network` session per guest,
 * held only for panes a caller explicitly enabled via `captureNetworkBodies`.
 *
 * ## Intent is per pane; the session is per guest
 *
 * A pane's guest `WebContents` churns on every structural reparent (see
 * browserGuestRegistry.ts), so "capture bodies for this pane" cannot be a
 * one-time attach. The pane-level intent lives here and the registry re-applies
 * it from `setGuest` — the renderer's did-attach report — whenever a new guest
 * arrives, and drops the old guest's session from `clearGuest`. The reparented
 * page starts reloading *before* that report lands, so a body that completes in
 * the gap (typically the new document's own) is missed: the entry keeps its
 * webRequest metadata and simply has no body, the same degradation as every
 * other failure here. Metadata capture never depends on this module.
 *
 * ## The session rides the shared refcounted lease
 *
 * Electron allows one debugger client per WebContents, and save-resource
 * attaches transiently for blob bytes — guestDebugger.ts refcounts so neither
 * feature can detach the other. This module holds its lease from enable until
 * `--off`, the pane's intent clearing, or the guest dying; a transient blob
 * save coming and going in between changes nothing.
 *
 * ## Why bodies are fetched on `Network.loadingFinished`
 *
 * `Network.getResponseBody` answers only while Chromium still retains the
 * resource; loadingFinished is the one reliable moment (measured in the spike
 * this rode in on). Anything that rejects there — a 204, a redirect, a body
 * evicted from the buffer, a session detached mid-flight — degrades to
 * metadata-only for that entry, never to a failed verb. Cross-origin no-CORS
 * sub-resources (a CDN image) come back *empty* by Chromium policy (ORB) even
 * though the fetch succeeds — a limitation the skill documents, with
 * save-resource as the escape hatch.
 */

/** Pane ids whose caller asked for bodies; survives guest churn, drives re-apply. */
const intents = new Set<string>()

/** What earlier CDP events said about a request, awaiting its loadingFinished. */
interface PendingResponse {
  method?: string | undefined
  url?: string | undefined
  status?: number | undefined
  mimeType?: string | undefined
  /**
   * Byte counts summed from `Network.dataReceived`, kept because
   * `getResponseBody` answers *empty* (not an error) for bodies Chromium
   * pipes straight to the renderer instead of buffering — image and other
   * binary payloads, measured — and `size: 0` for a response whose bytes
   * demonstrably arrived would be a lie. For exactly those direct-piped
   * bodies `dataLength` is also 0 (measured), so the wire-level
   * `encodedDataLength` sum (body plus transfer framing) is kept as the
   * last-resort approximation.
   */
  receivedBytes?: number | undefined
  encodedBytes?: number | undefined
}

interface BodySession {
  lease: DebuggerLease
  unsubscribe: () => void
  pending: Map<string, PendingResponse>
}

const sessions = new Map<number, BodySession>()

/**
 * Bound on the pending map so a page that starts requests it never finishes
 * (long-polls, aborted streams) cannot grow it without limit. Eviction is
 * oldest-first (Map insertion order); an evicted request that later finishes
 * simply records no body.
 */
const PENDING_CAP = 500

/**
 * Chromium-side retention buffers for Network.enable. A body larger than the
 * per-resource buffer is unavailable at getResponseBody time and degrades to
 * metadata-only — far larger than NETWORK_BODY_MAX on purpose, so truncation
 * happens in our classifier (explicit, size reported) rather than as a
 * silent CDP miss.
 */
const MAX_RESOURCE_BUFFER = 5_000_000
const MAX_TOTAL_BUFFER = 20_000_000

/**
 * Starts capturing bodies for `paneId`, attaching a CDP session to its
 * current guest. Resolves `{}` on success; `{ error }` when the debugger
 * cannot attach (DevTools already open on the guest is the expected case) or
 * the Network domain refuses — in both failure cases no intent is recorded,
 * so the caller's view ("it's off") matches reality and a later retry can
 * succeed.
 */
export async function enableBodyCapture(
  paneId: string,
  guest: WebContents
): Promise<{ error?: string }> {
  if (sessions.has(guest.id)) {
    // Already capturing this guest (an idempotent re-enable, or a second pane
    // id mapping onto the same guest); just record the intent.
    intents.add(paneId)
    return {}
  }
  let lease: DebuggerLease
  try {
    lease = await acquireGuestDebugger(guest)
  } catch (error) {
    return { error: error instanceof Error ? error.message : String(error) }
  }
  const session: BodySession = {
    lease,
    unsubscribe: lease.onEvent((method, params) => handleEvent(guest.id, method, params)),
    pending: new Map()
  }
  sessions.set(guest.id, session)
  try {
    await lease.send('Network.enable', {
      maxResourceBufferSize: MAX_RESOURCE_BUFFER,
      maxTotalBufferSize: MAX_TOTAL_BUFFER
    })
  } catch (error) {
    dropGuestBodySession(guest.id)
    return { error: `could not enable network capture: ${String(error)}` }
  }
  intents.add(paneId)
  return {}
}

/** `--off`: clears the pane's intent and releases its current guest's session. */
export function disableBodyCapture(paneId: string, guestId: number | undefined): void {
  intents.delete(paneId)
  if (guestId !== undefined) dropGuestBodySession(guestId)
}

/**
 * Drops the CDP session for one guest — its pane closed, a reparent replaced
 * it, or capture was turned off. Release is idempotent and safe after the
 * guest died (the shared lease manager already forgot it).
 */
export function dropGuestBodySession(guestId: number): void {
  const session = sessions.get(guestId)
  if (!session) return
  sessions.delete(guestId)
  session.unsubscribe()
  session.lease.release()
}

/**
 * Re-applies a pane's capture intent to the new guest a reparent produced.
 * Called by the registry's setGuest; fire-and-forget because setGuest is a
 * synchronous IPC report — a failed re-attach degrades to metadata-only (and
 * is logged, since nothing else will name it) while the intent survives for
 * the next attach.
 */
export function reapplyBodyCapture(paneId: string, guestId: number): void {
  if (!intents.has(paneId)) return
  const guest = webContents.fromId(guestId)
  if (!guest || guest.isDestroyed()) return
  void enableBodyCapture(paneId, guest).then((outcome) => {
    if (outcome.error) {
      console.warn(`[tabs] could not re-attach body capture for pane ${paneId}: ${outcome.error}`)
    }
  })
}

/**
 * Whether bodies are actually being captured for this pane right now — intent
 * alone is not enough, since a re-attach can have failed. This is what the
 * verb's `bodyCapture: 'on' | 'off'` reports; claiming 'on' on intent alone
 * would lie exactly when the caller most needs to know.
 */
export function isBodyCaptureLive(paneId: string, guestId: number | undefined): boolean {
  return intents.has(paneId) && guestId !== undefined && sessions.has(guestId)
}

function handleEvent(guestId: number, method: string, params: unknown): void {
  const session = sessions.get(guestId)
  if (!session) return
  const p = params as
    | {
        requestId?: string
        request?: { url?: string; method?: string }
        response?: { url?: string; status?: number; mimeType?: string }
        dataLength?: number
        encodedDataLength?: number
      }
    | undefined
  if (typeof p?.requestId !== 'string') return
  if (method === 'Network.requestWillBeSent') {
    if (!session.pending.has(p.requestId) && session.pending.size >= PENDING_CAP) {
      const oldest = session.pending.keys().next().value
      if (oldest !== undefined) session.pending.delete(oldest)
    }
    session.pending.set(p.requestId, {
      ...session.pending.get(p.requestId),
      method: p.request?.method,
      url: p.request?.url
    })
    return
  }
  if (method === 'Network.responseReceived') {
    const pending = session.pending.get(p.requestId)
    if (!pending) return
    pending.status = p.response?.status
    pending.mimeType = p.response?.mimeType
    return
  }
  if (method === 'Network.dataReceived') {
    const pending = session.pending.get(p.requestId)
    if (pending) {
      if (typeof p.dataLength === 'number') {
        pending.receivedBytes = (pending.receivedBytes ?? 0) + p.dataLength
      }
      if (typeof p.encodedDataLength === 'number') {
        pending.encodedBytes = (pending.encodedBytes ?? 0) + p.encodedDataLength
      }
    }
    return
  }
  if (method === 'Network.loadingFinished') {
    const pending = session.pending.get(p.requestId)
    session.pending.delete(p.requestId)
    if (pending?.url !== undefined && pending.method !== undefined) {
      void fetchBody(
        guestId,
        p.requestId,
        pending as PendingResponse & { url: string; method: string }
      )
    }
    return
  }
  if (method === 'Network.loadingFailed') {
    session.pending.delete(p.requestId)
  }
}

async function fetchBody(
  guestId: number,
  requestId: string,
  meta: PendingResponse & { url: string; method: string }
): Promise<void> {
  const session = sessions.get(guestId)
  if (!session) return
  try {
    const result = (await session.lease.send('Network.getResponseBody', { requestId })) as {
      body: string
      base64Encoded: boolean
    }
    recordResponseBody(guestId, {
      method: meta.method,
      url: meta.url,
      status: meta.status,
      mimeType: meta.mimeType,
      body: result.body,
      base64Encoded: result.base64Encoded,
      receivedBytes: meta.receivedBytes || meta.encodedBytes
    })
  } catch {
    // No body to give (204, redirect, evicted from the buffer) or the session
    // died mid-flight — this entry stays metadata-only, by design.
  }
}

/**
 * e2e reset: mutable main-process state, reset like the guest registry and
 * debugger leases beside it (see the browser module's resetForTests).
 */
export function resetNetworkBodyCaptureForTests(): void {
  for (const guestId of [...sessions.keys()]) dropGuestBodySession(guestId)
  intents.clear()
}
