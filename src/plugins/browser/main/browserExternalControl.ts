import type {
  MainControlContext,
  MainControlVerb,
  MainControlVerbTable,
  MainPluginContext
} from '../../../main/plugin/api'
import { RELAY_HEADROOM_MS } from '../../../main/plugin/api'
import type { ControlResponse } from '../../../shared/externalControl'
import type { BrowserControlRequest } from '../shared/externalControl'
import {
  ASSERT_CHECK_BUDGET_MS,
  clampWaitTimeout,
  EXECUTE_OUTPUT_KEY,
  LOAD_WAIT_MS,
  MOUNT_WAIT_MS,
  NETWORK_BODY_HARD_MAX,
  NETWORK_BODY_MAX,
  SCREENSHOT_BYTES_KEY
} from '../shared/externalControl'
import { BrowserMethod } from '../shared/ipc'
import { agentFileDir, sweepStaleAgentFiles, writeAgentOutput } from './agentFiles'
import {
  getGuestWebContents,
  getGuestWebContentsId,
  listRequestsForPane
} from './browserGuestRegistry'
import { disableBodyCapture, enableBodyCapture, isBodyCaptureLive } from './networkBodyCapture'
import { findCapturedBody, type NetworkEntry, networkFilterError, setBodyLimit } from './networkLog'
import { extensionFor, fetchResource, resolveElementSrc } from './resourceFetch'
import { isAllowedUrl } from './urlPolicy'

/** userData subdirectories the byte-producing verbs write into (swept independently). */
const SCREENSHOT_DIR = 'agent-screenshots'
const RESOURCE_DIR = 'agent-resources'
const EXECUTE_OUTPUT_DIR = 'agent-output'
const NETWORK_OUT_DIR = 'agent-network'
const NETWORK_BODY_DIR = 'agent-network-bodies'

/**
 * The three fixed budget tiers, for verbs whose cost has no renderer-side
 * bound to derive from (the load/wait verbs derive theirs instead — see the
 * table doc). Quick: one resolve round trip plus one injected event, or an
 * in-process read of main's own buffers. Read: reads and input that may
 * first reveal, scroll or settle the page (screenshot's reveal wait, type's
 * per-key pacing) — the renderer-side waits under these must stay far below
 * this number so their bounded failures reach the caller instead of a relay
 * timeout. Unbounded: caller-supplied code or a fetch of arbitrary size, the
 * longest budget of any verb.
 */
const QUICK_VERB_BUDGET_MS = 5000
const READ_VERB_BUDGET_MS = 15000
const UNBOUNDED_VERB_BUDGET_MS = 30000

/**
 * `--brief`'s projection: identity and outcome, no header maps.
 *
 * An allowlist rather than a delete-list, so a field added to `NetworkEntry`
 * later is absent from brief output until someone decides it belongs there —
 * the opposite default from "strip the two big ones", which would silently
 * start including whatever arrives next. `responseBody` is deliberately out:
 * `--brief` and `--with-bodies` answer opposite questions, and a caller asking
 * for both gets the small one.
 *
 * Written flat rather than as conditional spreads because every path out of
 * here is JSON — the socket response and the `--out` file both go through
 * JSON.stringify, which drops undefined-valued keys — so the wire shape is the
 * same either way, and this way the allowlist reads as the list it is.
 */
function toBriefEntry(entry: NetworkEntry): Partial<NetworkEntry> {
  return {
    seq: entry.seq,
    method: entry.method,
    url: entry.url,
    resourceType: entry.resourceType,
    status: entry.status,
    error: entry.error,
    startedAt: entry.startedAt,
    completedAt: entry.completedAt,
    count: entry.count,
    firstStartedAt: entry.firstStartedAt
  }
}

/**
 * The browser type's main-process external-control surface: what each of its
 * verbs costs in relay budget, and the four that need main to do something
 * beyond passing the request through to the renderer.
 *
 * This is the main-side twin of the renderer's
 * `src/plugins/browser/renderer/browserExternalControl.ts`, and it exists for
 * the same reason that one does: core names no verb but its own six, and
 * everything that knows what a browser costs lives with the browser.
 *
 * The protocol *types* live elsewhere on purpose: which module answers a
 * verb is a separate question from which union declares it (see
 * shared/externalControl.ts).
 */

/**
 * The write→error→result plumbing every byte-producing sink shares: write
 * through writeAgentOutput, answer the socket with the path plus whatever
 * the verb adds. The error stays a ControlResponse rather than a throw —
 * the caller is a socket owed one, and writeAgentOutput's message beats the
 * generic one handleRequest's boundary would synthesize.
 */
function respondWithFile(
  outPath: string | true | undefined,
  bytes: Uint8Array,
  options: { subdir: string; ext: string; what: string },
  result: (path: string) => Record<string, unknown>
): ControlResponse {
  const written = writeAgentOutput(outPath, bytes, options)
  if ('error' in written) return { ok: false, error: written.error }
  return { ok: true, result: result(written.path) }
}

/**
 * Turns the renderer's in-memory PNG into a file path, which is what the
 * socket caller actually gets. The bytes are dropped from the result here:
 * `tabs-ctl`'s stdout becomes the calling agent's context verbatim, so an
 * inline image would be both enormous and unreadable. The directory choice,
 * the TTL sweep and the vanished-userData guard now live in agentFiles.ts,
 * shared with save-resource.
 */
function writeScreenshot(response: ControlResponse): ControlResponse {
  if (!response.ok) return response
  const { [SCREENSHOT_BYTES_KEY]: bytes, ...rest } = response.result ?? {}
  if (!ArrayBuffer.isView(bytes)) {
    return { ok: false, error: 'the pane returned no image data' }
  }
  // No caller-named path here yet: screenshot has no `--out`, so it only
  // ever takes the generated form.
  const view = new Uint8Array(bytes.buffer, bytes.byteOffset, bytes.byteLength)
  return respondWithFile(
    undefined,
    view,
    { subdir: SCREENSHOT_DIR, ext: 'png', what: 'screenshot' },
    (path) => ({ ...rest, path })
  )
}

/**
 * `writeScreenshot`'s twin for `execute-js --out`: strips the full serialized
 * result the renderer stashed under EXECUTE_OUTPUT_KEY and turns it into a
 * file path — the value itself never reaches the socket on this path, which
 * is the whole point of the flag (an uncapped serialization in `tabs-ctl`'s
 * stdout would bury the calling agent's context exactly the way the inline
 * cap exists to prevent). A pass-through when the request didn't ask for a
 * file, so the inline path is byte-identical to what it always was.
 *
 * The `outPath` forms are `writeAgentOutput`'s, the same ones saveResource
 * gets: a caller-named path or a generated one under the swept
 * EXECUTE_OUTPUT_DIR — `.txt` for a raw string result and `.json` for
 * everything else, matching the renderer's `format`.
 */
function writeExecuteResult(
  response: ControlResponse,
  request: Extract<BrowserControlRequest, { type: 'executeJavaScript' }>
): ControlResponse {
  if (request.outPath === undefined || !response.ok) return response
  const { [EXECUTE_OUTPUT_KEY]: payload, ...rest } = response.result ?? {}
  if (typeof payload !== 'string') {
    return { ok: false, error: 'the pane returned no result payload' }
  }
  const bytes = Buffer.from(payload, 'utf8')
  return respondWithFile(
    request.outPath,
    bytes,
    { subdir: EXECUTE_OUTPUT_DIR, ext: rest.format === 'text' ? 'txt' : 'json', what: 'result' },
    (path) => ({ ...rest, path, bytes: bytes.byteLength })
  )
}

/**
 * `save-resource`: fetch a page resource's bytes (see resourceFetch.ts for the
 * per-scheme routes) and write them to disk, returning the path. Answered
 * entirely in main, like readNetworkRequests — main owns the fetch routes
 * (net.request, the CDP session), so nothing is relayed. Ownership and pane
 * liveness were already checked by core; what's left is that a guest is
 * actually mounted for this pane.
 */
async function handleSaveResource(
  request: Extract<BrowserControlRequest, { type: 'saveResource' }>
): Promise<ControlResponse> {
  const guest = getGuestWebContents(request.targetPaneId)
  if (!guest) return { ok: false, error: 'browser pane is not currently mounted' }

  // The wire doc promises exactly one of url/ref/selector, "enforced where
  // the request is handled" — a preference chain here would silently ignore
  // the losers, saving an artifact the caller didn't name.
  const givenUrl = request.url !== undefined && request.url.length > 0 ? request.url : undefined
  const hasRef = request.ref !== undefined
  const hasSelector = request.selector !== undefined
  const given = [
    givenUrl !== undefined && '--url',
    hasRef && '--ref',
    hasSelector && '--selector'
  ].filter((flag): flag is string => flag !== false)
  if (given.length > 1) {
    return {
      ok: false,
      error: `save-resource takes exactly one of --url, --ref or --selector — got ${given.join(' and ')}`
    }
  }

  let resourceUrl: string
  if (givenUrl !== undefined) {
    resourceUrl = givenUrl
  } else if (hasRef || hasSelector) {
    const resolved = await resolveElementSrc(guest, {
      ref: request.ref,
      selector: request.selector
    })
    if ('error' in resolved) return { ok: false, error: resolved.error }
    resourceUrl = resolved.url
  } else {
    return { ok: false, error: 'save-resource needs one of --url, --ref or --selector' }
  }

  const fetched = await fetchResource(guest, resourceUrl)
  if ('error' in fetched) return { ok: false, error: fetched.error }

  return respondWithFile(
    request.outPath,
    fetched.bytes,
    {
      subdir: RESOURCE_DIR,
      ext: extensionFor(resourceUrl, fetched.contentType, fetched.bytes),
      what: 'resource'
    },
    (path) => ({
      path,
      bytes: fetched.bytes.byteLength,
      ...(fetched.contentType ? { contentType: fetched.contentType } : {})
    })
  )
}

/**
 * `read-network`: list the capture buffer, or answer one of its two file
 * sub-questions (`--body-out`, `--out`). Answered entirely in main, which
 * owns the webRequest capture (see networkLog.ts / browserGuestRegistry.ts).
 */
function handleReadNetworkRequests(
  request: Extract<BrowserControlRequest, { type: 'readNetworkRequests' }>
): ControlResponse {
  // Same answer the renderer-side verbs give for a pane with no live
  // guest — an empty list would read as "no traffic", which is a
  // different claim entirely.
  const guestId = getGuestWebContentsId(request.targetPaneId)
  if (guestId === undefined) {
    return { ok: false, error: 'browser pane is not currently mounted' }
  }
  // Refused rather than silently matching nothing or (pattern) silently
  // falling back to a substring search: an empty list for a bad filter
  // would read as "no requests matched", a different claim entirely.
  const filterError = networkFilterError({
    method: request.method,
    status: request.status,
    resourceType: request.resourceType,
    pattern: request.pattern
  })
  if (filterError !== undefined) {
    return { ok: false, error: filterError }
  }
  // --body-out is a different question from "list the traffic", so it
  // answers with the file rather than folding a path into a request list
  // the caller did not ask for. Checked before the filters because it
  // names one entry by seq and the filters are irrelevant to it.
  if (request.bodyOutPath !== undefined || request.bodySeq !== undefined) {
    if (request.bodyOutPath === undefined || typeof request.bodySeq !== 'number') {
      return {
        ok: false,
        error: 'bodyOut needs both a seq to identify the entry and a path to write it to'
      }
    }
    const found = findCapturedBody(guestId, request.bodySeq)
    if ('error' in found) return { ok: false, error: found.error }
    const bytes = Buffer.from(found.body, 'utf8')
    return respondWithFile(
      request.bodyOutPath,
      bytes,
      { subdir: NETWORK_BODY_DIR, ext: 'txt', what: 'response body' },
      (path) => ({ path, bytes: bytes.byteLength, seq: request.bodySeq })
    )
  }

  const withBodies = request.withBodies === true
  const brief = request.brief === true
  const requests = listRequestsForPane(request.targetPaneId, {
    pattern: request.pattern,
    sinceSeq: request.sinceSeq,
    // Under --brief the read is asked not to *produce* what toBriefEntry
    // would drop, rather than to produce and then discard it: redaction
    // clones both header maps per entry and the body join is
    // entries×bodies, and neither survives the projection. Passing
    // unredacted here cannot leak anything — the headers are not in brief
    // output at all.
    unredacted: brief ? true : request.unredacted,
    method: request.method,
    status: request.status,
    failed: request.failed,
    resourceType: request.resourceType,
    withBodies: withBodies && !brief
  })
  const projected = brief ? requests.map(toBriefEntry) : requests
  // Only alongside --with-bodies, so the metadata read's shape is
  // byte-identical to what it always was. 'off' with no bodies on any
  // entry is the "you forgot capture-bodies" signal the skill points at —
  // reported from the live session, not the intent, so a failed re-attach
  // reads as what it is. Built once: the two sinks below answer the same
  // question and must not drift in how they answer it.
  const answer = {
    requests: projected,
    ...(withBodies
      ? { bodyCapture: isBodyCaptureLive(request.targetPaneId, guestId) ? 'on' : 'off' }
      : {})
  }

  // The file sink is the other half of the same size problem --brief
  // addresses: --brief makes the common query readable, --out keeps the
  // full form available without it landing in the caller's context.
  if (request.outPath !== undefined) {
    const payload = Buffer.from(JSON.stringify(answer, null, 2), 'utf8')
    return respondWithFile(
      request.outPath,
      payload,
      { subdir: NETWORK_OUT_DIR, ext: 'json', what: 'request log' },
      (path) => ({ path, bytes: payload.byteLength, count: projected.length })
    )
  }

  return { ok: true, result: answer }
}

/**
 * A verb main adds nothing to: ownership was already checked by core, and the
 * renderer owns the whole of the semantics. Most of this type's verbs are
 * these, which is why they read as one line each.
 */
function relayed<V extends BrowserControlRequest['type']>(timeoutMs: number): MainControlVerb<V> {
  return { timeoutMs, handle: (request, ctx) => ctx.relay(request) }
}

/**
 * The scheme allowlist gate the two URL-taking verbs share — one wrapper so
 * the check and its message can't fork between them (its other enforcement
 * point, main/index.ts's will-navigate guard, shares the predicate via
 * urlPolicy.ts).
 */
function withAllowedUrl<R extends { url: string }>(
  handle: (request: R, ctx: MainControlContext) => ControlResponse | Promise<ControlResponse>
): (request: R, ctx: MainControlContext) => ControlResponse | Promise<ControlResponse> {
  return (request, ctx) => {
    if (!isAllowedUrl(request.url)) {
      return { ok: false, error: `url not allowed: ${request.url}` }
    }
    return handle(request, ctx)
  }
}

/**
 * Every browser verb, with its relay budget.
 *
 * Annotated with this type's own request union, which makes the table
 * exhaustive at compile time: a verb added to `BrowserControlRequest` without
 * an entry here fails to build, and an entry naming a verb the union no longer
 * has fails too. That is the guarantee core's old combined `Record` gave,
 * kept rather than traded for the registry.
 *
 * The verbs that wait on the guest page get real headroom instead of dragging
 * every other verb up with them; those derived from a renderer-side bound are
 * expressed in terms of it rather than hand-synced above it, so the relay
 * always fires later than the renderer's own — a far more useful answer.
 */
const BROWSER_CONTROL_VERBS: MainControlVerbTable<BrowserControlRequest> = {
  createBrowserPane: {
    // Waits for the new pane's webview to mount, then for its first load.
    timeoutMs: MOUNT_WAIT_MS + LOAD_WAIT_MS + RELAY_HEADROOM_MS,
    // Not inside a batch: this registers a new pane's ownership partway
    // through, so whether a later sub-request may target it would depend on
    // evaluation order. Core enforces the refusal without knowing the name.
    batchable: false,
    handle: withAllowedUrl(async (request, ctx) => {
      const response = await ctx.relay(request)
      // Already granted by the paneCreated report registerBrowserControlVerbs
      // listens for (sent well before this relay resolves — see
      // handleCreateBrowserPane). Idempotent re-grant kept as a backstop for
      // the case that report is ever lost, not the primary path anymore.
      if (response.ok && typeof response.result?.paneId === 'string') {
        ctx.grantOwnership(response.result.paneId, request.paneId)
      }
      return response
    })
  },
  navigate: {
    // Two full load waits, not one: `retryOnRedirect` re-issues the navigation
    // once (see handleNavigate), so the renderer's own worst case is two
    // bounded attempts — and the relay must always be the one that fires
    // later, per the derivation rule above.
    timeoutMs: 2 * LOAD_WAIT_MS + RELAY_HEADROOM_MS,
    handle: withAllowedUrl((request, ctx) => ctx.relay(request))
  },
  reload: relayed(LOAD_WAIT_MS + RELAY_HEADROOM_MS),
  goBack: relayed(LOAD_WAIT_MS + RELAY_HEADROOM_MS),
  goForward: relayed(LOAD_WAIT_MS + RELAY_HEADROOM_MS),
  screenshot: {
    timeoutMs: READ_VERB_BUDGET_MS,
    handle: async (request, ctx) => writeScreenshot(await ctx.relay(request))
  },
  getPageText: relayed(READ_VERB_BUDGET_MS),
  readPage: relayed(READ_VERB_BUDGET_MS),
  find: relayed(READ_VERB_BUDGET_MS),
  click: relayed(QUICK_VERB_BUDGET_MS),
  // One resolve round trip and one injected event, like click.
  hover: relayed(QUICK_VERB_BUDGET_MS),
  type: relayed(READ_VERB_BUDGET_MS),
  key: relayed(QUICK_VERB_BUDGET_MS),
  scroll: relayed(QUICK_VERB_BUDGET_MS),
  readConsoleMessages: relayed(QUICK_VERB_BUDGET_MS),
  formInput: relayed(READ_VERB_BUDGET_MS),
  // Caller-supplied code with no bound on what it does — a fetch, a wait for
  // an animation — so this gets the longest budget of any verb. Main adds one
  // thing to the relay: the `--out` file sink (a pass-through without it).
  executeJavaScript: {
    timeoutMs: UNBOUNDED_VERB_BUDGET_MS,
    handle: async (request, ctx) => writeExecuteResult(await ctx.relay(request), request)
  },
  waitFor: {
    // Priced per request, not per verb: the wait is the request's own
    // (clamped) timeoutMs, so a 3-second wait whose renderer dies fails in
    // seconds instead of holding the socket for the 300s ceiling. Both sides
    // compute the same clampWaitTimeout of the same field, which is what
    // keeps "the relay always outlives the wait" true for every request —
    // the renderer's timeout answer names the condition that never held,
    // and must always beat this budget to the caller.
    timeoutMs: (request) => clampWaitTimeout(request.timeoutMs) + RELAY_HEADROOM_MS,
    handle: (request, ctx) => ctx.relay(request)
  },
  // waitFor's single-shot twin: its check is bounded by a renderer-side
  // constant rather than a caller wait, so the budget derives from that bound
  // the way the load verbs derive from LOAD_WAIT_MS.
  assert: relayed(ASSERT_CHECK_BUDGET_MS + RELAY_HEADROOM_MS),
  saveResource: {
    // Answered in main (like readNetworkRequests), never relayed — a fetch of
    // arbitrary size with no renderer-side wait to outlive, so it gets the
    // longest fixed budget of any verb, matching executeJavaScript's tier.
    timeoutMs: UNBOUNDED_VERB_BUDGET_MS,
    handle: (request) => handleSaveResource(request)
  },
  readNetworkRequests: {
    // Answered in-process from this type's own capture buffer; never relayed,
    // but it declares a budget like every other verb so the table stays a
    // complete description rather than two lists to keep aligned.
    timeoutMs: QUICK_VERB_BUDGET_MS,
    handle: (request) => handleReadNetworkRequests(request)
  },
  captureNetworkBodies: {
    // Answered in main, which owns the CDP session (see networkBodyCapture.ts).
    // One attach plus one Network.enable round trip — the in-process tier's
    // budget, like readNetworkRequests.
    timeoutMs: QUICK_VERB_BUDGET_MS,
    handle: async (request) => {
      if (request.enabled === false) {
        // Answered before the guest check, unlike --on: the pane's capture
        // *intent* is what makes reapplyBodyCapture re-attach on the next
        // guest, so an --off that failed for want of a mounted guest would
        // leave capture resurrecting itself against an explicit refusal.
        // disableBodyCapture already tolerates a missing guest id.
        const guestId = getGuestWebContentsId(request.targetPaneId)
        disableBodyCapture(request.targetPaneId, guestId)
        // The raised cap belongs to the capture session, not to the pane —
        // turning capture off and on again without asking for it must not
        // silently keep holding megabyte bodies.
        if (guestId !== undefined) setBodyLimit(guestId, undefined)
        return { ok: true, result: { enabled: false } }
      }
      const guest = getGuestWebContents(request.targetPaneId)
      if (!guest) return { ok: false, error: 'browser pane is not currently mounted' }
      let limit: number | undefined
      if (request.maxBodyChars !== undefined) {
        if (
          !Number.isInteger(request.maxBodyChars) ||
          request.maxBodyChars < 1 ||
          request.maxBodyChars > NETWORK_BODY_HARD_MAX
        ) {
          return {
            ok: false,
            error: `maxBodyChars must be a whole number between 1 and ${NETWORK_BODY_HARD_MAX}`
          }
        }
        limit = request.maxBodyChars
      }
      setBodyLimit(guest.id, limit)
      const outcome = await enableBodyCapture(request.targetPaneId, guest)
      if (outcome.error) return { ok: false, error: outcome.error }
      return {
        ok: true,
        result: { enabled: true, maxBodyChars: limit ?? NETWORK_BODY_MAX }
      }
    }
  }
}

/**
 * Claims this type's verbs, and sweeps the agent-file directories left by a
 * previous run.
 *
 * Called from the package's `activate`, i.e. from whenReady before the
 * control socket starts accepting connections. The launch-time sweep is here
 * because the 10-minute TTL is otherwise only enforced on the *next* write —
 * an agent's final screenshots or saved resources would outlive the promise in
 * the skill docs indefinitely without it.
 */
export function registerBrowserControlVerbs(ctx: MainPluginContext): void {
  ctx.registerControlVerbs(BROWSER_CONTROL_VERBS)
  // See handleCreateBrowserPane's matching send: reported the instant the
  // pane exists, well before createBrowserPane's own relay resolves, so the
  // popup-deny / scheme-allowlist guards in main/index.ts read isOwnedPane
  // as true for the guest's very first load rather than only once the
  // mount/load wait below has finished.
  ctx.ipc.on(BrowserMethod.paneCreated, (_event, paneId, ownerPaneId) => {
    ctx.grantOwnership(paneId as string, ownerPaneId as string)
  })
  // Deferred off the registration sequence, and guarded inside it. This runs
  // from whenReady, *before* createWindow — and it is a readdir plus a stat per
  // file across three directories, which an agent that screenshotted on a timer
  // can leave holding hundreds of entries. None of it needs to happen before
  // the first window exists, so it waits a tick rather than standing in front
  // of one. The guard is separate: a throw here (agentFileDir's own mkdir on an
  // unwritable userData dir) must not become an unhandled main-process
  // exception, which is the native error dialog persist.ts exists to avoid.
  setImmediate(() => {
    for (const subdir of [
      SCREENSHOT_DIR,
      RESOURCE_DIR,
      EXECUTE_OUTPUT_DIR,
      NETWORK_OUT_DIR,
      NETWORK_BODY_DIR
    ]) {
      try {
        sweepStaleAgentFiles(agentFileDir(subdir))
      } catch (error) {
        console.error(`[tabs] could not sweep stale ${subdir}:`, error)
      }
    }
  })
}
