import type { ControlRequest, ControlResponse } from '../shared/externalControl'
import { CONTROL_REQUEST_TYPES } from '../shared/externalControl'

/**
 * The main process's registry of external-control verb handlers — main's twin
 * of the renderer's registry (src/renderer/src/content/externalControl.ts).
 *
 * It exists so that core's socket half (externalControl.ts) can own transport,
 * validation, pane ownership and the relay, while knowing nothing about what
 * any individual verb *means* — core names no verb but its own six.
 * Deliberately no verb count here: a count is a second thing to keep true,
 * and one already rotted once.
 *
 * ## Why a table per type rather than one call per verb
 *
 * A content type contributes its verbs as a single `MainControlVerbTable` keyed
 * by its own request union, which makes the registration **exhaustive at
 * compile time**: a verb added to that union without an entry fails to build,
 * and an entry naming a verb the union no longer has fails too. That is the
 * same guarantee the old `Record<ControlRequest['type'], number>` timeout table
 * gave, kept rather than traded away — and it is stronger than the renderer's
 * equivalent, which registers one verb at a time into a Map and therefore had
 * to move its exhaustiveness check to a runtime test.
 *
 * `unhandledMainControlVerbs` still exists because the compiler cannot see the
 * other half: a table that is complete but whose `registerMainControlVerbs`
 * call never runs (a content module dropped from contentTypes.ts, a
 * registration moved out of `register()`) is a build-clean, runtime-broken app.
 * That is what the e2e gate asserts against.
 */

type ControlVerb = ControlRequest['type']

/**
 * What core lends a verb handler. Deliberately tiny: the two capabilities that
 * genuinely live in core's half and cannot be reimplemented by a content type
 * — the renderer relay (whose pending-request bookkeeping and per-verb budget
 * are core's) and the ownership ledger's grant side.
 *
 * There is no revoke here on purpose. Ownership is dropped by `closePane`,
 * which is a core verb, so revoking stays internal to core's own module rather
 * than becoming surface a content type could get wrong.
 */
export interface MainControlContext {
  /**
   * Asks the renderer hosting the caller's pane to answer this request, on the
   * budget registered for its verb. Resolves with an error response rather
   * than rejecting — every caller is a socket connection expecting a
   * `ControlResponse`.
   */
  relay(request: ControlRequest): Promise<ControlResponse>
  /**
   * Records that `paneId` was created by, and therefore belongs to,
   * `ownerPaneId` — the check every `targetPaneId`-bearing verb is gated on.
   * Call it only once the pane genuinely exists.
   */
  grantOwnership(paneId: string, ownerPaneId: string): void
}

/**
 * A verb's main-side implementation. It receives its own narrowed request and
 * *returns* the answer — it never touches the socket, so it cannot reply twice
 * or fail to reply. A throw becomes an error response (see handleRequest).
 */
type MainControlVerbHandler<V extends ControlVerb> = (
  request: Extract<ControlRequest, { type: V }>,
  context: MainControlContext
) => ControlResponse | Promise<ControlResponse>

export interface MainControlVerb<V extends ControlVerb> {
  /**
   * How long the renderer may take before the socket caller is told it timed
   * out. Only consulted for verbs that actually relay; one answered entirely
   * in main still declares it, so the table stays a complete description of
   * the verb rather than two lists to keep aligned.
   *
   * A budget must outlive any renderer-side wait it covers — the renderer's
   * own timeout answer is far more useful than a bare relay timeout, so the
   * relay must always fire later.
   *
   * The function form is for a verb whose wait is *per-request* — `waitFor`
   * carries its own `timeoutMs` field, so a static number would have to be
   * sized for the ceiling and leave a 3-second wait hanging five minutes on a
   * dead renderer. It receives the verb's own narrowed request and is
   * evaluated once per relay (see relayToRenderer), which is also what lets a
   * long wait inside a `batch` get exactly its own budget: each sub-request
   * relays individually, so the arithmetic composes with no further plumbing.
   * The invariant is the caller's to keep: derive the returned number from
   * the same clamped wait the renderer will actually run, plus
   * RELAY_HEADROOM_MS.
   */
  timeoutMs: number | ((request: Extract<ControlRequest, { type: V }>) => number)
  /**
   * Whether this verb may appear inside a `batch`. Defaults to true.
   *
   * `false` is for verbs whose effect depends on evaluation order within the
   * batch — `createBrowserPane` registers a new pane's ownership partway
   * through, so whether a later sub-request may target it would depend on
   * where it sits in the list. Core refuses those without naming any of them
   * (see handleBatch), which is why this is a property of the verb rather than
   * a check in core.
   */
  batchable?: boolean
  handle: MainControlVerbHandler<V>
}

/**
 * Every verb of one request union, with its budget and handler. Annotate a
 * content type's table with its own union (`MainControlVerbTable<FooRequest>`)
 * and the compiler enforces that it covers exactly that union's verbs.
 */
export type MainControlVerbTable<R extends { type: ControlVerb }> = {
  [V in R['type']]: MainControlVerb<V>
}

/**
 * How a verb is held once stored. Not `MainControlVerb` itself: handlers are
 * contravariant in their request, so one written for a single verb is not
 * assignable to one accepting the whole union. Widening at the boundary is
 * sound by construction — the map is keyed by verb name and dispatch only ever
 * calls the entry found under `request.type`, so a handler can only receive the
 * request shape it was registered for.
 */
interface StoredVerb {
  timeoutMs: number | ((request: ControlRequest) => number)
  batchable: boolean
  handle: (
    request: ControlRequest,
    context: MainControlContext
  ) => ControlResponse | Promise<ControlResponse>
}

const verbs = new Map<ControlVerb, StoredVerb>()

/**
 * Claims every verb in `table`. Called once per content type, from its
 * main `activate` (see plugin/api.ts); core registers its own at module
 * scope.
 *
 * A duplicate throws rather than replacing — the same rule as the renderer's
 * verb registry and contentRegistry. Two content types cannot both offer a
 * verb name, which is a real ceiling rather than an oversight: main grants a
 * `targetPaneId` only to whoever created that pane, so a verb name has exactly
 * one meaningful owner today.
 */
export function registerMainControlVerbs<R extends { type: ControlVerb }>(
  table: MainControlVerbTable<R>
): void {
  for (const [verb, def] of Object.entries(table) as [
    ControlVerb,
    MainControlVerb<ControlVerb>
  ][]) {
    if (verbs.has(verb)) {
      throw new Error(`Main control verb already registered for "${verb}"`)
    }
    verbs.set(verb, {
      // Same widening as `handle` below, sound for the same reason: the
      // function form only ever receives the request found under its own key.
      timeoutMs: def.timeoutMs as StoredVerb['timeoutMs'],
      batchable: def.batchable ?? true,
      handle: def.handle as StoredVerb['handle']
    })
  }
}

/**
 * Verbs in the wire protocol that nothing in this process claims.
 *
 * The runtime half of the guarantee — see this module's header for why the
 * compile-time half cannot cover it. Asserted empty by an e2e test against a
 * real app, which is the only tier where every content module has actually
 * registered.
 */
export function unhandledMainControlVerbs(): ControlVerb[] {
  return CONTROL_REQUEST_TYPES.filter((verb) => !verbs.has(verb))
}

/** The registered verb, or undefined for a name no content type in this build claims. */
export function mainControlVerb(verb: ControlVerb): StoredVerb | undefined {
  return verbs.get(verb)
}

/**
 * The relay budget for `request`, with the function form evaluated against the
 * request itself. The one place a per-request budget is turned into a number
 * (relayToRenderer calls this), kept beside the registry so the evaluation
 * cannot fork from the type that allows it. Undefined for an unclaimed verb —
 * the relay owns its own fallback.
 */
export function relayBudgetFor(request: ControlRequest): number | undefined {
  const stored = verbs.get(request.type)
  if (!stored) return undefined
  return typeof stored.timeoutMs === 'function' ? stored.timeoutMs(request) : stored.timeoutMs
}

/**
 * Unit tests only: empties the registry so a test can register its own verbs
 * against a known-clean map. Never called from the app or from e2e's reset —
 * clearing it at runtime would leave the socket answering nothing.
 */
export function resetMainControlVerbsForTests(): void {
  verbs.clear()
}
