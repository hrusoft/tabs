import { randomUUID } from 'node:crypto'
import { readdirSync, unlinkSync } from 'node:fs'
import * as net from 'node:net'
import { dirname, join } from 'node:path'
import { StringDecoder } from 'node:string_decoder'
import { RELAY_HEADROOM_MS } from '@tabs/plugin-sdk/main/relayHeadroom'
import { validateJsonSchema } from '@tabs/plugin-sdk/shared/jsonSchema'
import type { WebContents } from 'electron'
import { CONTENT_TYPE_MANIFESTS } from '../shared/content/registry'
import { controlVerbSpecFor } from '../shared/controlSpecRegistry'
import { CORE_CONTROL_VERB_SPECS, CORE_LIMITS } from '../shared/coreControlSpec'
import type {
  BatchStep,
  ControlRequest,
  ControlResponse,
  CoreControlRequest,
  OwnershipChange,
  RelayedControlRequest,
  RelayedControlResponse
} from '../shared/externalControl'
import { CONTROL_REQUEST_TYPES, MAX_BATCH_SIZE, PANE_GONE_ERROR } from '../shared/externalControl'
import { IpcChannel } from '../shared/ipc'
import { describeCommand, indexLineFor } from './controlDescribe'
import { buildRequestFromEnvelope } from './controlEnvelope'
import { controlSocketPath, parseControlSocketPid } from './controlSocket'
import type { MainControlContext, MainControlVerbTable } from './controlVerbs'
import {
  mainControlVerb,
  registerMainControlVerbs,
  verbBudgetFor,
  withVerbDeadline
} from './controlVerbs'
import { onRendererMessage, registerSyncGetter } from './ipcListeners'
import { forEachLiveWindow } from './liveWindows'
import { getPaneHost, hasPaneHost } from './paneHostRegistry'
import { createRendererRelay } from './rendererRelay'
import { getSettings } from './settings'

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

/** Requests relayed to a renderer, awaiting its reply — see relayToRenderer. */
const relay = createRendererRelay<RelayedControlRequest, RelayedControlResponse>(
  IpcChannel.externalControlRequest
)

/**
 * Margin a relay budget keeps above a renderer-side wait it must outlive —
 * now defined in packages/plugin-sdk/main/relayHeadroom.ts (imported at top), re-exported
 * here for every existing importer.
 */
export { RELAY_HEADROOM_MS }

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
    const change: OwnershipChange = { paneId, owned }
    win.webContents.send(IpcChannel.externalControlOwnershipChanged, change)
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
 * The pane-tree windows as external control needs them, injected by
 * `registerExternalControlServer` — windows.ts cannot be imported here
 * without a cycle back through the plugin context.
 */
interface ControlWindows {
  /** The renderer of the live window whose layout holds `paneId`, if any holds it. */
  rendererHolding(paneId: string): WebContents | undefined
  /** Every live pane-tree window's renderer. */
  allRenderers(): WebContents[]
}

let controlWindows: ControlWindows = {
  rendererHolding: () => undefined,
  allRenderers: () => []
}

/**
 * Asks a renderer to actually do the work — main has no live tree of its own
 * (see layoutStore.ts) — and waits for its reply, tagged with a fresh
 * requestId so the answer can be matched back up (main → renderer is
 * otherwise fire-and-forget only). Resolves with an error instead of
 * rejecting if that renderer isn't live or never answers, since every caller
 * here is a socket connection expecting a `ControlResponse`, not a thrown
 * exception.
 */
function relayInto(
  webContents: WebContents | undefined,
  callerId: string,
  request: ControlRequest
): Promise<ControlResponse> {
  if (!webContents || webContents.isDestroyed()) {
    return Promise.resolve({ ok: false, error: 'not running inside a Tabs pane' })
  }
  const requestId = randomUUID()
  const timeoutMs = verbBudgetFor(request) ?? DEFAULT_RELAY_TIMEOUT_MS
  // The relay's one refusal: its timeout, or a send that never reached the
  // window (rendererRelay.ts), so the wording covers both.
  const unanswered: RelayedControlResponse = {
    requestId,
    response: { ok: false, error: 'the window did not answer (timed out, or unreachable)' }
  }
  return relay
    .send(webContents, callerId, { requestId, request }, unanswered, timeoutMs)
    .then((reply) => reply.response)
}

/**
 * A verb's relay. One naming a `targetPaneId` goes to the window holding that
 * pane: each renderer finds panes only in its own tree, and a pane an agent
 * owns can be dragged into another window than the agent's terminal. Every
 * other verb — and a target too new for main's copy of the layouts, which is
 * still in the window that created it — goes to the caller's own window.
 */
function relayToRenderer(callerId: string, request: ControlRequest): Promise<ControlResponse> {
  const targetHost =
    'targetPaneId' in request ? controlWindows.rendererHolding(request.targetPaneId) : undefined
  return relayInto(targetHost ?? getPaneHost(callerId), callerId, request)
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
 * There is deliberately no batch-wide deadline (its `timeoutMs` below is
 * infinite). Each step runs on its own verb's budget — every sub-request goes
 * back through dispatchTypedRequest — a wait step's budget is the caller's to size,
 * and cutting a batch off midway would discard the transcript that is its
 * whole point.
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
    const response = await dispatchTypedRequest({ ...sub, paneId: request.paneId })
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
    // No batch-wide deadline — see handleBatch.
    timeoutMs: Number.POSITIVE_INFINITY,
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
    handle: async (request) => {
      // Every window, not only the caller's: an owned pane may have been
      // dragged into another one. All of them or nothing: a list missing one
      // window's panes reads as "your pane is gone", and SKILL.md's remedy for
      // that is to open it again — a duplicate. A window mid-reload is
      // refused at once rather than waited on, since it will answer shortly.
      // A crashed one is left out: nothing in it can be driven until the
      // window goes, and refusing for it would refuse forever.
      const renderers = controlWindows
        .allRenderers()
        .filter((webContents) => !webContents.isCrashed())
      if (renderers.length === 0) return { ok: false, error: 'not running inside a Tabs pane' }
      if (renderers.some((webContents) => webContents.isLoading())) {
        return {
          ok: false,
          error: 'a window is reloading, so its panes cannot be listed; try again'
        }
      }
      const responses = await Promise.all(
        renderers.map((webContents) => relayInto(webContents, request.paneId, request))
      )
      const failed = responses.find((response) => !response.ok)
      if (failed) return failed
      // A renderer answers with every pane a type could list — it has no
      // notion of ownership — so the narrowing to this caller's own panes
      // happens here, before anything reaches the socket.
      const panes = responses
        .flatMap((response) => {
          const listed = response.ok ? response.result?.panes : undefined
          return Array.isArray(listed) ? listed : []
        })
        .filter(isListedPane)
        .filter((pane) => ownerOf.get(pane.paneId) === request.paneId)
      return { ok: true, result: { panes } }
    }
  },
  capabilities: {
    timeoutMs: DEFAULT_RELAY_TIMEOUT_MS,
    handle: () => {
      const disabled = new Set(getSettings().disabledContentTypes)
      const capabilities = [
        {
          id: 'core',
          displayName: 'Core',
          enabled: true,
          commands: CORE_CONTROL_VERB_SPECS.map(indexLineFor)
        },
        ...CONTENT_TYPE_MANIFESTS.map((manifest) => ({
          id: manifest.type,
          displayName: manifest.displayName,
          enabled: !disabled.has(manifest.type),
          commands: (manifest.controlVerbs ?? []).map(indexLineFor)
        }))
      ]
      return { ok: true, result: { capabilities } }
    }
  },
  describe: {
    timeoutMs: DEFAULT_RELAY_TIMEOUT_MS,
    handle: (request) => {
      // Core has no manifest of its own (it isn't a content type), and no
      // guide — SKILL.md's own preamble already covers everything about its
      // six verbs, so a second copy here would only be something to drift.
      // It does have its own numeric constants (maxBatchRequests), served
      // the same way a content type's are.
      if (request.capability === 'core') {
        return {
          ok: true,
          result: {
            capability: 'core',
            limits: CORE_LIMITS,
            commands: CORE_CONTROL_VERB_SPECS.map(describeCommand)
          }
        }
      }
      const manifest = CONTENT_TYPE_MANIFESTS.find((m) => m.type === request.capability)
      if (!manifest) {
        return {
          ok: false,
          error: `unknown capability "${request.capability}" — run capabilities to list them`
        }
      }
      return {
        ok: true,
        result: {
          capability: manifest.type,
          ...(manifest.guide ? { guide: manifest.guide } : {}),
          ...(manifest.limits ? { limits: manifest.limits } : {}),
          commands: (manifest.controlVerbs ?? []).map(describeCommand)
        }
      }
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
 * shares, runs the verb's own wire-schema check, then hands off to whichever
 * content type claimed the verb.
 *
 * Everything type-specific now lives behind that registry lookup — the reason
 * this function names no verb but its own. Two callers reach it: a `batch`
 * sub-request, which arrives already wire-shaped (see handleBatch — batch
 * payloads are raw protocol requests, not friendlier `{command, args}`
 * envelopes, by design), and `handleEnvelope` below, once it has turned a
 * caller's `{command, args}` into exactly this shape.
 */
async function dispatchTypedRequest(request: unknown): Promise<ControlResponse> {
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

  // Structural validation against the verb's own declared wire schema — the
  // one check every verb gets whether it arrived as a caller-typed request
  // (a batch sub-request, or a client that speaks the wire protocol
  // directly) or was assembled by controlEnvelope.ts from a {command, args}
  // envelope. A verb with no spec (there should be none — every one declares
  // one, core's own six included, see coreControlSpec.ts) skips this rather
  // than refusing, since a missing spec is a gap in the app, not the caller's
  // mistake.
  const spec = controlVerbSpecFor(request.type)
  if (spec) {
    // paneId is real on every request but deliberately absent from every
    // spec's wire schema (the app fills it in from the caller's environment,
    // never the caller — see ControlVerbSpec's doc), so it's stripped before
    // validating against a schema that closes the object with
    // additionalProperties: false.
    const { paneId: _paneId, ...withoutPaneId } = request
    const schemaError = validateJsonSchema(withoutPaneId, spec.wire, 'request')
    if (schemaError) return { ok: false, error: schemaError }
  }

  // The error boundary controlVerbs.ts promises handlers ("a throw becomes an
  // error response"), mirroring the renderer's installExternalControl. It has
  // to live here rather than at the socket: a batch sub-request never touches
  // the socket, and a throw escaping this call would unwind handleBatch,
  // discarding the transcript and stoppedAt index the batch contract promises.
  try {
    // Bounded past the verb's budget — see withVerbDeadline.
    return await withVerbDeadline(
      Promise.resolve(verb.handle(request, contextFor(request.paneId))),
      request.type,
      verbBudgetFor(request) ?? DEFAULT_RELAY_TIMEOUT_MS,
      RELAY_HEADROOM_MS
    )
  } catch (error) {
    return { ok: false, error: String(error) }
  }
}

/**
 * Whether `value` is shaped like a `{command, args, paneId}` envelope — the
 * only shape the socket accepts at the top level now (`tabs-ctl` ships no
 * command-specific knowledge; see resources/skills/tabs/scripts/tabs-ctl and
 * controlEnvelope.ts). `args`/`cwd` are optional on the wire (a command with
 * no flags, or a caller with no cwd to offer) and default to `{}`/`''`.
 */
function isControlEnvelope(
  value: unknown
): value is { command: string; args?: unknown; paneId: string; cwd?: string } {
  if (typeof value !== 'object' || value === null) return false
  const candidate = value as Record<string, unknown>
  return typeof candidate.command === 'string' && typeof candidate.paneId === 'string'
}

/**
 * The socket's actual entry point: turns a caller's `{command, args, paneId,
 * cwd}` envelope into a typed request (controlEnvelope.ts) and dispatches it
 * through the exact same validated path a `batch` sub-request goes through —
 * so a coercion bug can never let an envelope-built request skip a check a
 * hand-typed one gets.
 */
async function handleEnvelope(raw: unknown): Promise<ControlResponse> {
  if (!isControlEnvelope(raw)) {
    return { ok: false, error: 'expected a {command, args, paneId} envelope' }
  }
  const args =
    typeof raw.args === 'object' && raw.args !== null ? (raw.args as Record<string, unknown>) : {}
  const built = buildRequestFromEnvelope(raw.command, args, raw.paneId, raw.cwd ?? '')
  if (built.error !== undefined || built.request === undefined) {
    return { ok: false, error: built.error ?? 'could not build a request from that envelope' }
  }
  return dispatchTypedRequest(built.request)
}

/** Wires a renderer's reply (see preload's ExternalControlApi.respond) back to its pending relayToRenderer promise. */
function registerRelayResponseListener(): void {
  onRendererMessage(
    IpcChannel.externalControlResponse,
    (_event, payload: RelayedControlResponse) => {
      relay.resolve(payload)
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
  relay.refuse()
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
 * connects to: one newline-delimited JSON `{command, args, paneId, cwd}`
 * envelope per connection (see handleEnvelope/controlEnvelope.ts — the CLI
 * carries no command-specific knowledge of its own), one `ControlResponse`
 * back, then the server closes it — matching tabs-ctl's one-shot,
 * exit-after-one-command design. Starts unconditionally at app launch
 * regardless of whether the skill has ever been installed (cheap, and inert
 * until something actually connects).
 *
 * Called from whenReady *after* registerContentModules, so every content
 * type's verbs are claimed before the socket can accept a request for one.
 */
export function registerExternalControlServer(windows: ControlWindows): void {
  controlWindows = windows
  registerRelayResponseListener()
  registerOwnershipSyncIpc()

  const socketPath = controlSocketPath()
  sweepControlSockets(dirname(socketPath))

  const server = net.createServer((socket) => {
    // A decoder rather than a per-chunk `toString`: a large request arrives in
    // several chunks, and a multi-byte character split across a boundary
    // would otherwise decode as U+FFFD on both sides — valid JSON still, so
    // the corrupted text would reach the page with no error at all.
    const decoder = new StringDecoder('utf8')
    let buffer = ''
    let received = 0
    // One request per connection: anything after the first line is ignored
    // rather than run as a second request against an already-ending socket.
    let answered = false
    socket.on('data', (chunk: Buffer) => {
      if (answered) return
      received += chunk.byteLength
      buffer += decoder.write(chunk)
      const newlineIndex = buffer.indexOf('\n')
      if (newlineIndex === -1) {
        if (received > MAX_REQUEST_BYTES) {
          answered = true
          socket.end(`${JSON.stringify({ ok: false, error: 'request too large' })}\n`)
          buffer = ''
        }
        return
      }
      answered = true
      const line = buffer.slice(0, newlineIndex)
      buffer = ''

      let envelope: unknown
      try {
        envelope = JSON.parse(line)
      } catch {
        socket.end(`${JSON.stringify({ ok: false, error: 'invalid JSON' })}\n`)
        return
      }

      handleEnvelope(envelope)
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
