import { randomUUID } from 'node:crypto'
import { readdirSync, unlinkSync } from 'node:fs'
import * as net from 'node:net'
import { dirname, join } from 'node:path'
import type {
  BatchStep,
  ControlRequest,
  ControlResponse,
  CoreControlRequest,
  RelayedControlRequest,
  RelayedControlResponse
} from '../shared/externalControl'
import { CONTROL_REQUEST_TYPES, MAX_BATCH_SIZE, PANE_GONE_ERROR } from '../shared/externalControl'
import { IpcChannel } from '../shared/ipc'
import { controlSocketPath, parseControlSocketPid } from './controlSocket'
import type { MainControlContext, MainControlVerbTable } from './controlVerbs'
import { mainControlVerb, registerMainControlVerbs, relayBudgetFor } from './controlVerbs'
import { onRendererMessage, registerSyncGetter } from './ipcListeners'
import { forEachLiveWindow } from './liveWindows'
import { getPaneHost, hasPaneHost } from './paneHostRegistry'

/**
 * Child pane id → the pane id that created it — the only panes a caller may
 * target. Not persisted: a control session's whole lifetime is bound to one
 * app run.
 *
 * Deliberately permanent for that run: an entry is never expired or
 * re-scoped, only dropped when the pane is closed through `closePane`. A pane
 * an agent created once therefore stays readable and scriptable by it
 * indefinitely, including after the user has since navigated it somewhere
 * else by hand. That is an accepted product tradeoff, documented plainly in
 * the skill's own SKILL.md rather than left implicit.
 *
 * Written by content types only through `grantOwnership` on the verb context
 * (see controlVerbs.ts) — a type that creates panes needs the grant, and
 * nothing else, since every read of this map is a core check.
 */
const ownerOf = new Map<string, string>()

interface Pending {
  resolve: (response: ControlResponse) => void
  timer: ReturnType<typeof setTimeout>
}

/** Requests relayed to a renderer, awaiting its reply — see relayToRenderer. */
const pending = new Map<string, Pending>()

/**
 * Margin a relay budget keeps above a renderer-side wait it must outlive.
 * Exported because the budgets that need it are declared by the content types
 * whose verbs do the waiting (see each type's MainControlVerbTable), while the
 * relay it applies to is core's.
 */
export const RELAY_HEADROOM_MS = 5000

/**
 * Budget for a verb that relays without declaring a wait of its own — a pure
 * store read or tree mutation, which should answer in single-digit
 * milliseconds. Every core verb prices itself at this; the `??` fallback in
 * relayToRenderer is strictly defensive.
 */
const DEFAULT_RELAY_TIMEOUT_MS = 5000

/** Whether some control session owns `paneId` — i.e. it is an agent-created pane. */
export function isOwnedPane(paneId: string): boolean {
  return ownerOf.has(paneId)
}

/**
 * Pushes a live ownership grant/release to every open window, so a
 * renderer's pane-controlled indicator (see controlStore.ts) stays in sync
 * without polling. A broadcast rather than something routed through
 * getPaneHost/relayToRenderer: unlike a verb's relay there is no caller
 * waiting on a reply, and the target pane may be in any window — sending to
 * all is simplest and costs nothing, since a renderer holding no node with
 * that id just ignores it (see controlStore's setControlled).
 */
function broadcastOwnership(paneId: string, owned: boolean): void {
  forEachLiveWindow((win) => {
    win.webContents.send(IpcChannel.externalControlOwnershipChanged, { paneId, owned })
  })
}

/**
 * Records that `paneId` was created by, and therefore belongs to,
 * `ownerPaneId`. The single writer behind both `MainControlContext.grantOwnership`
 * (a verb handler's ctx, scoped to the request it's answering) and
 * `MainPluginContext.grantOwnership` (a package's own context, callable
 * outside a verb handler entirely — see createBrowserPane's early report,
 * which exists to close the window between a pane's creation and the verb's
 * full relay response, during which the popup-deny and scheme-allowlist
 * guards read this ledger as empty).
 */
export function grantOwnership(paneId: string, ownerPaneId: string): void {
  ownerOf.set(paneId, ownerPaneId)
  broadcastOwnership(paneId, true)
}

/**
 * Drops `paneId`'s ledger entry, if it has one, and broadcasts the release —
 * the single writer paired with grantOwnership so every mutation of `ownerOf`
 * pushes to the renderer side. Guarded on the delete actually removing
 * something so a redundant call (there is none today, but nothing enforces
 * that) doesn't broadcast a release nobody granted.
 */
function releaseOwnership(paneId: string): void {
  const owner = ownerOf.get(paneId)
  if (owner === undefined) return
  ownerOf.delete(paneId)
  rememberClosed(paneId, owner)
  broadcastOwnership(paneId, false)
}

/**
 * Panes a caller closed itself, and who closed them — so a later request for
 * one can be told it is *gone* rather than that it was never theirs.
 *
 * The ownership check below has to run before anything else and has to be
 * uniform: a pane id is a persisted layout id, not a per-boot credential, so
 * answering an unowned id differently depending on whether such a pane exists
 * would leak pane liveness to a caller with no claim on it. That is why the
 * fix is not a reordering. A tombstone keeps the boundary exactly where it was
 * and only changes the wording for the one caller who already knew the pane
 * existed — because they created it, and then closed it.
 *
 * Deliberately per-boot and unexpiring within one, like `ownerOf` itself; the
 * cap is only so a session that opens and closes panes in a loop cannot grow
 * this without bound. Oldest out first, which is the right end to lose: a
 * caller is overwhelmingly likely to follow up on the pane it just closed.
 */
const closedBy = new Map<string, string>()

const CLOSED_PANE_MEMORY = 100

function rememberClosed(paneId: string, ownerPaneId: string): void {
  closedBy.set(paneId, ownerPaneId)
  // One `set` can only ever push it one over, so this evicts at most once.
  if (closedBy.size > CLOSED_PANE_MEMORY) {
    const oldest = closedBy.keys().next().value
    if (oldest !== undefined) closedBy.delete(oldest)
  }
}

/**
 * Asks the renderer that owns the caller's window to actually mutate the pane
 * tree — main has no live tree of its own (see layoutStore.ts) — and waits
 * for its reply, tagged with a fresh requestId so the answer can be matched
 * back up (main → renderer is otherwise fire-and-forget only). Resolves with
 * an error instead of rejecting if the caller's pane isn't live or the
 * renderer never answers, since every caller here is a socket connection
 * expecting a `ControlResponse`, not a thrown exception.
 */
function relayToRenderer(callerId: string, request: ControlRequest): Promise<ControlResponse> {
  const webContents = getPaneHost(callerId)
  if (!webContents || webContents.isDestroyed()) {
    return Promise.resolve({ ok: false, error: 'not running inside a Tabs pane' })
  }
  const requestId = randomUUID()
  const timeoutMs = relayBudgetFor(request) ?? DEFAULT_RELAY_TIMEOUT_MS
  return new Promise((resolve) => {
    const timer = setTimeout(() => {
      pending.delete(requestId)
      resolve({ ok: false, error: 'timed out waiting for a response' })
    }, timeoutMs)
    pending.set(requestId, { resolve, timer })
    const payload: RelayedControlRequest = { requestId, request }
    webContents.send(IpcChannel.externalControlRequest, payload)
  })
}

/**
 * The capabilities core lends every verb handler, built per request so `relay`
 * can carry the caller's pane id without each handler having to thread it
 * through.
 */
function contextFor(callerId: string): MainControlContext {
  return {
    relay: (request) => relayToRenderer(callerId, request),
    grantOwnership
  }
}

/** Shape a renderer answers `listOwnedPanes` with, before main narrows it to owned panes. */
interface ListedPane {
  paneId: string
  url: string
  title: string
}

function isListedPane(value: unknown): value is ListedPane {
  return (
    typeof value === 'object' && value !== null && typeof (value as ListedPane).paneId === 'string'
  )
}

/**
 * Runs a batch's sub-requests in order and answers with a transcript: one
 * `steps` entry per request, aligned index-for-index — what ran, whether it
 * succeeded, how long it took, and its result (see `BatchStep` in
 * shared/externalControl.ts).
 *
 * By default the first failure stops the batch, because a batch is usually a
 * *sequence* — click this, then read what it produced — where continuing past
 * a failed step reports confidently on a state that was never reached.
 * `stoppedAt` names the failed index, and every later entry is a
 * `{ skipped: true }` marker rather than absent, so the transcript stays
 * aligned to what was sent. `continueOnError` is for the other kind of batch
 * — many independent reads of one page — where one failing step shouldn't
 * discard the rest: every step runs, failures stay visible per entry, and
 * `stoppedAt` is absent.
 *
 * Two shapes are refused outright rather than supported. A nested `batch`
 * buys nothing over a flat one and makes the size bound meaningless. And a
 * verb whose registration marks it unbatchable is refused by name it supplies
 * rather than one core knows — `createBrowserPane` is the case that exists
 * today (it registers a new pane's ownership partway through, so whether a
 * later sub-request may target it would depend on evaluation order), but core
 * names no verb to say so.
 *
 * Each sub-request runs as the batch's own caller: `paneId` is overwritten
 * rather than trusted, so a batch can't be used to smuggle a request that
 * claims to come from some other pane.
 *
 * There is deliberately no batch-wide deadline. Each relaying step runs on
 * its own verb's budget (relayToRenderer prices per sub-request — the batch's
 * own `timeoutMs` below is never consulted, since this handler never relays),
 * a wait step's budget is the caller's to size, and cutting a batch off
 * midway would discard the transcript that is its whole point.
 */
async function handleBatch(
  request: Extract<ControlRequest, { type: 'batch' }>
): Promise<ControlResponse> {
  if (!Array.isArray(request.requests)) {
    return { ok: false, error: 'batch requires a list of requests' }
  }
  if (request.requests.length > MAX_BATCH_SIZE) {
    return { ok: false, error: `a batch may hold at most ${MAX_BATCH_SIZE} requests` }
  }
  for (const sub of request.requests) {
    // Checked ahead of the generic unbatchable test below so nesting keeps its
    // own message, which SKILL.md quotes.
    if (sub.type === 'batch') return { ok: false, error: 'a batch cannot contain another batch' }
    if (mainControlVerb(sub.type)?.batchable === false) {
      return { ok: false, error: `${sub.type} cannot be used inside a batch` }
    }
  }

  const continueOnError = request.continueOnError === true
  const steps: BatchStep[] = []
  let stoppedAt: number | undefined
  for (const [index, sub] of request.requests.entries()) {
    if (stoppedAt !== undefined) {
      steps.push({ type: sub.type, skipped: true })
      continue
    }
    const startedAt = Date.now()
    const response = await handleRequest({ ...sub, paneId: request.paneId })
    steps.push({ type: sub.type, durationMs: Date.now() - startedAt, ...response })
    // `ok` on the batch itself reports that the batch *ran*, not that every
    // step succeeded — reporting a failed step as `ok: false` would discard
    // the transcript already collected, which is the useful part. tabs-ctl
    // still exits non-zero when any step failed, so the shell contract holds.
    if (!response.ok && !continueOnError) stoppedAt = index
  }
  return { ok: true, result: stoppedAt === undefined ? { steps } : { steps, stoppedAt } }
}

/**
 * Core's own verbs: liveness, the batching envelope, and the pane-tree
 * operations that name only pane ids. Registered at module scope rather than
 * from a lifecycle hook — this is the registry's own process registering its
 * own verbs, not a cross-module import side effect — so it cannot be ordered
 * after a content type's registration by accident.
 *
 * `activatePane`/`getPaneInfo` are straight pass-throughs; the other two touch
 * the ownership ledger, which is why they are core's rather than any type's
 * even though the browser is what answers them in the renderer today.
 */
const CORE_CONTROL_VERBS: MainControlVerbTable<CoreControlRequest> = {
  ping: { timeoutMs: DEFAULT_RELAY_TIMEOUT_MS, handle: () => ({ ok: true }) },
  batch: {
    timeoutMs: DEFAULT_RELAY_TIMEOUT_MS,
    batchable: false,
    handle: (request) => handleBatch(request)
  },
  activatePane: {
    timeoutMs: DEFAULT_RELAY_TIMEOUT_MS,
    handle: (request, ctx) => ctx.relay(request)
  },
  getPaneInfo: {
    timeoutMs: DEFAULT_RELAY_TIMEOUT_MS,
    handle: (request, ctx) => ctx.relay(request)
  },
  closePane: {
    timeoutMs: DEFAULT_RELAY_TIMEOUT_MS,
    handle: async (request, ctx) => {
      const response = await ctx.relay(request)
      // Drop the ownership entry only once the pane is genuinely gone, so a
      // failed close doesn't strand a still-live pane as unownable.
      if (response.ok) releaseOwnership(request.targetPaneId)
      return response
    }
  },
  listOwnedPanes: {
    timeoutMs: DEFAULT_RELAY_TIMEOUT_MS,
    handle: async (request, ctx) => {
      const response = await ctx.relay(request)
      if (!response.ok) return response
      // The renderer answers with every pane a type could list — it has no
      // notion of ownership — so the narrowing to this caller's own panes
      // happens here, before anything reaches the socket.
      const listed = response.result?.panes
      const panes = (Array.isArray(listed) ? listed : [])
        .filter(isListedPane)
        .filter((pane) => ownerOf.get(pane.paneId) === request.paneId)
      return { ok: true, result: { panes } }
    }
  }
}

registerMainControlVerbs(CORE_CONTROL_VERBS)

function isControlRequest(value: unknown): value is ControlRequest {
  return (
    typeof value === 'object' &&
    value !== null &&
    CONTROL_REQUEST_TYPES.includes((value as { type?: unknown }).type as ControlRequest['type'])
  )
}

/**
 * Validates untyped wire input, enforces the two boundary checks every verb
 * shares, then hands off to whichever content type claimed the verb.
 *
 * Everything type-specific now lives behind that registry lookup — the reason
 * this function names no verb but its own.
 */
async function handleRequest(request: unknown): Promise<ControlResponse> {
  // What arrives here is untyped wire input — a raw socket client, or a
  // `batch` sub-request assembled from caller JSON — so an unknown type has to
  // be rejected at runtime rather than trusted to be a member of the union.
  if (!isControlRequest(request)) {
    const type = (request as { type?: unknown } | null | undefined)?.type
    return {
      ok: false,
      error: `unknown request type: ${typeof type === 'string' ? type : '(none)'}`
    }
  }

  // Every request type carries paneId; a caller whose pane no longer has a
  // live host (or never was one — someone connecting to the socket directly)
  // is rejected uniformly here, before any type-specific logic runs.
  if (!hasPaneHost(request.paneId)) {
    return { ok: false, error: 'not running inside a Tabs pane' }
  }

  // Likewise for ownership: every verb that names a `targetPaneId` may only
  // act on a pane this caller created. Enforced once here rather than per
  // handler, so a verb a content type adds cannot ship without the check —
  // the one boundary that keeps a control session from reading or driving
  // panes belonging to the user or to another agent.
  if ('targetPaneId' in request && ownerOf.get(request.targetPaneId) !== request.paneId) {
    // One exception, and only for the caller who already knew this pane
    // existed: they created it and then closed it themselves, so "not the
    // owner" sends them hunting an auth problem instead of reading the
    // documented "it's gone, list and reopen" recovery. Every other caller —
    // including one that never owned it — still gets the uniform refusal, so
    // this leaks nothing about panes that are not the asker's own.
    if (closedBy.get(request.targetPaneId) === request.paneId) {
      return { ok: false, error: PANE_GONE_ERROR }
    }
    return { ok: false, error: 'not the owner of this pane' }
  }

  const verb = mainControlVerb(request.type)
  // Only reachable for a verb whose content type isn't registered in this
  // build; a complete app claims every name in the protocol (see the e2e gate
  // behind unhandledMainControlVerbs).
  if (!verb) {
    return { ok: false, error: `no handler is registered for "${request.type}"` }
  }
  // The error boundary controlVerbs.ts promises handlers ("a throw becomes an
  // error response"), mirroring the renderer's installExternalControl. It has
  // to live here rather than at the socket: a batch sub-request never touches
  // the socket, and a throw escaping this call would unwind handleBatch,
  // discarding the transcript and stoppedAt index the batch contract promises.
  try {
    return await verb.handle(request, contextFor(request.paneId))
  } catch (error) {
    return { ok: false, error: String(error) }
  }
}

/** Wires a renderer's reply (see preload's ExternalControlApi.respond) back to its pending relayToRenderer promise. */
function registerRelayResponseListener(): void {
  onRendererMessage(
    IpcChannel.externalControlResponse,
    (_event, payload: RelayedControlResponse) => {
      const entry = pending.get(payload.requestId)
      if (!entry) return
      pending.delete(payload.requestId)
      clearTimeout(entry.timer)
      entry.resolve(payload.response)
    }
  )
}

/**
 * Synchronous like layout:get-sync/settings:get-sync: controlStore.ts reads
 * this at module init so a pane already owned when a renderer (re)loads —
 * e.g. mid-session — shows its indicator from the first render rather than
 * popping in once a live grant/release happens to arrive.
 */
function registerOwnershipSyncIpc(): void {
  registerSyncGetter(IpcChannel.externalControlOwnershipGetSync, () => [...ownerOf.keys()])
}

/**
 * Forgets every pane-ownership grant, and abandons any relay still in flight
 * — see src/main/e2e.ts's reset. Without this a pane id created in one test
 * stayed owned for the whole shared app's life, so a later test could target
 * a pane that no longer existed.
 *
 * Deliberately does not touch the verb registry: registration happens once at
 * startup, and clearing it would leave the socket answering nothing for every
 * later test in the file.
 */
export function resetExternalControlForTests(): void {
  ownerOf.clear()
  closedBy.clear()
  for (const entry of pending.values()) clearTimeout(entry.timer)
  pending.clear()
}

/**
 * More than any legitimate request needs (a full 50-request batch of scripts
 * is well under 1MB); a connection that exceeds it without ever sending a
 * newline is not a client worth buffering for.
 */
const MAX_REQUEST_BYTES = 10 * 1024 * 1024

/**
 * Whether some process currently holds `pid`. EPERM counts as alive — the
 * pid exists, it just isn't ours to signal — because the only safe reaction
 * to "someone else's process" is to leave its socket alone.
 */
function isProcessAlive(pid: number): boolean {
  try {
    process.kill(pid, 0)
    return true
  } catch (error) {
    return (error as NodeJS.ErrnoException).code === 'EPERM'
  }
}

/**
 * Removes control sockets left behind by boots that are no longer running.
 *
 * The sockets are per-pid (see controlSocketPath) precisely so that two
 * instances sharing a userData dir never touch each other's: one whose pid
 * is still live belongs to a running instance and is left strictly alone.
 * A file bearing *our* pid is stale by definition — this pid was reused
 * after a boot that crashed before its socket was cleaned up — and must go
 * or listen() below fails with EADDRINUSE. A dead pid's file is refuse from
 * a crashed or killed boot; nothing can be listening on it.
 */
function sweepControlSockets(dir: string): void {
  let names: string[]
  try {
    names = readdirSync(dir)
  } catch {
    return
  }
  for (const name of names) {
    const pid = parseControlSocketPid(name)
    if (pid === undefined) continue
    if (pid !== process.pid && isProcessAlive(pid)) continue
    try {
      unlinkSync(join(dir, name))
    } catch {
      // Racing another sweep, or already gone — listen() surfaces anything real.
    }
  }
}

/**
 * Starts the Unix socket a `tabs-ctl` CLI call (see resources/skills/tabs)
 * connects to: one newline-delimited JSON `ControlRequest` per connection,
 * one `ControlResponse` back, then the server closes it — matching
 * tabs-ctl's one-shot, exit-after-one-command design. Starts unconditionally
 * at app launch regardless of whether the skill has ever been installed
 * (cheap, and inert until something actually connects).
 *
 * Called from whenReady *after* registerContentModules, so every content
 * type's verbs are claimed before the socket can accept a request for one.
 */
export function registerExternalControlServer(): void {
  registerRelayResponseListener()
  registerOwnershipSyncIpc()

  const socketPath = controlSocketPath()
  sweepControlSockets(dirname(socketPath))

  const server = net.createServer((socket) => {
    let buffer = ''
    socket.on('data', (chunk: Buffer) => {
      buffer += chunk.toString('utf-8')
      const newlineIndex = buffer.indexOf('\n')
      if (newlineIndex === -1) {
        if (buffer.length > MAX_REQUEST_BYTES) {
          socket.end(`${JSON.stringify({ ok: false, error: 'request too large' })}\n`)
          buffer = ''
        }
        return
      }
      const line = buffer.slice(0, newlineIndex)
      buffer = ''

      let request: unknown
      try {
        request = JSON.parse(line)
      } catch {
        socket.end(`${JSON.stringify({ ok: false, error: 'invalid JSON' })}\n`)
        return
      }

      handleRequest(request)
        .then((response) => socket.end(`${JSON.stringify(response)}\n`))
        .catch((error) => socket.end(`${JSON.stringify({ ok: false, error: String(error) })}\n`))
    })
    socket.on('error', () => {
      // A client disconnecting mid-write (e.g. tabs-ctl killed) is not
      // exceptional — nothing to clean up beyond letting this socket go.
    })
  })

  // Not decoration, and not the same thing as the per-connection handler
  // above. An 'error' event on an EventEmitter with no listener is *rethrown*,
  // so a failed listen() — ENAMETOOLONG on a long userData path (macOS caps a
  // Unix socket path at 104 bytes), EACCES, an EADDRINUSE the pid sweep raced
  // — would escape as an uncaught main-process exception, which Electron
  // answers with the native "A JavaScript error occurred in the main process"
  // modal. Under E2E_HIDDEN that dialog has no parent window, so it renders on
  // screen and nothing, Playwright included, can click it. Exactly the failure
  // mode persist.ts exists to prevent, and the same answer: degrade loudly in
  // the log, never take the app down. An app with no control socket still
  // works — every feature but the agent skill is unaffected.
  server.on('error', (error) => {
    console.error('[tabs] external control socket unavailable:', error)
  })

  server.listen(socketPath)
}
