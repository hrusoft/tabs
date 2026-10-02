import type {
  MainControlContext,
  MainControlVerb,
  MainControlVerbTable
} from '@tabs/plugin-sdk/main/controlVerbTable'
import type { ControlRequest, ControlResponse } from '../shared/externalControl'
import { CONTROL_REQUEST_TYPES } from '../shared/externalControl'

export type {
  MainControlContext,
  MainControlVerb,
  MainControlVerbTable
} from '@tabs/plugin-sdk/main/controlVerbTable'

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
 * call never runs (a package's main `activate` that never calls
 * `ctx.registerControlVerbs`) is a build-clean, runtime-broken app.
 * That is what the e2e gate asserts against.
 */

type ControlVerb = ControlRequest['type']

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
    MainControlVerb<ControlVerb, ControlRequest>
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
 * The budget for `request`, with the function form evaluated against the
 * request itself. The one place a per-request budget is turned into a number
 * (relayToRenderer and handleRequest's deadline both call this), kept beside
 * the registry so the evaluation cannot fork from the type that allows it.
 * Undefined for an unclaimed verb — each caller owns its own fallback.
 */
export function verbBudgetFor(request: ControlRequest): number | undefined {
  const stored = verbs.get(request.type)
  if (!stored) return undefined
  return typeof stored.timeoutMs === 'function' ? stored.timeoutMs(request) : stored.timeoutMs
}

/**
 * Answers for a handler that outlives its verb's budget, so the socket caller
 * is never left waiting on one that never settles — the relay has its own
 * timer, but a verb answered in main (a fetch, a guest script that navigated
 * away mid-evaluation) had nothing. Fires `graceMs` after the budget, so a
 * relay's own timeout answer lands first. A non-finite budget opts out. The
 * handler itself cannot be cancelled; its late answer is simply dropped.
 */
export function withVerbDeadline(
  work: Promise<ControlResponse>,
  verb: ControlVerb,
  budgetMs: number,
  graceMs: number
): Promise<ControlResponse> {
  if (!Number.isFinite(budgetMs)) return work
  let timer: ReturnType<typeof setTimeout> | undefined
  const deadline = new Promise<ControlResponse>((resolve) => {
    timer = setTimeout(
      () => resolve({ ok: false, error: `${verb} timed out after ${budgetMs}ms` }),
      budgetMs + graceMs
    )
  })
  return Promise.race([work, deadline]).finally(() => clearTimeout(timer))
}

/**
 * Unit tests only: empties the registry so a test can register its own verbs
 * against a known-clean map. Never called from the app or from e2e's reset —
 * clearing it at runtime would leave the socket answering nothing.
 */
export function resetMainControlVerbsForTests(): void {
  verbs.clear()
}
