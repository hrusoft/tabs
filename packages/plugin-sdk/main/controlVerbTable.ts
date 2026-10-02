import type { ControlResponse, PluginControlRequest } from '../shared/externalControl'

/**
 * What core lends a verb handler. Deliberately tiny: the two capabilities
 * that genuinely live in core's half and cannot be reimplemented by a
 * content type — the renderer relay (whose pending-request bookkeeping and
 * per-verb budget are core's) and the ownership ledger's grant side.
 *
 * There is no revoke here on purpose. Ownership is dropped by `closePane`,
 * which is a core verb, so revoking stays internal to core's own module
 * rather than becoming surface a content type could get wrong.
 *
 * `relay` is typed against `PluginControlRequest` rather than a per-caller
 * generic: every real request (core's own six, or any plugin's own concrete
 * union) is structurally `{ type: string; paneId: string; ... }`, which is
 * always assignable to `PluginControlRequest`'s open shape — so one
 * non-generic signature serves both core's own six verbs and every plugin's,
 * with no narrowing lost relative to relaying the exact request a handler
 * received.
 */
export interface MainControlContext {
  /**
   * Asks the renderer hosting the caller's pane to answer this request, on
   * the budget registered for its verb. Resolves with an error response
   * rather than rejecting — every caller is a socket connection expecting a
   * `ControlResponse`.
   */
  relay(request: PluginControlRequest): Promise<ControlResponse>
  /**
   * Records that `paneId` was created by, and therefore belongs to,
   * `ownerPaneId` — the check every `targetPaneId`-bearing verb is gated on.
   * Call it only once the pane genuinely exists.
   */
  grantOwnership(paneId: string, ownerPaneId: string): void
}

/**
 * A verb's main-side implementation. It receives its own narrowed request
 * and *returns* the answer — it never touches the socket, so it cannot
 * reply twice or fail to reply. A throw becomes an error response.
 */
type MainControlVerbHandler<V extends string, R extends { type: string }> = (
  request: Extract<R, { type: V }>,
  context: MainControlContext
) => ControlResponse | Promise<ControlResponse>

/**
 * `R` is the table's own request union. A plugin's table always supplies its
 * own concrete union explicitly (`MainControlVerbTable<FooRequest>`) — a
 * bare `PluginControlRequest` default is generic catch-all shape, so
 * `Extract<PluginControlRequest, { type: 'navigate' }>` resolves to `never`
 * for any concrete verb name; only narrowing against the package's own union
 * gives its handler a real request shape to work with. Core supplies its own
 * `ControlRequest` explicitly the same way, for its six built-in verbs.
 */
export interface MainControlVerb<
  V extends string,
  R extends { type: string } = PluginControlRequest
> {
  /**
   * How long the verb may take before the socket caller is told it timed
   * out. A relayed verb's relay times out at exactly this; core also cuts
   * off any handler still running past it. `Infinity` opts out, for a verb
   * whose sub-steps carry their own budgets (`batch`).
   *
   * The function form is for a verb whose wait is *per-request*.
   */
  timeoutMs: number | ((request: Extract<R, { type: V }>) => number)
  /**
   * Whether this verb may appear inside a `batch`. Defaults to true.
   *
   * `false` is for verbs whose effect depends on evaluation order within the
   * batch. Core refuses those without naming any of them, which is why this
   * is a property of the verb rather than a check in core.
   */
  batchable?: boolean
  handle: MainControlVerbHandler<V, R>
}

/**
 * Every verb of one request union, with its budget and handler. Annotate a
 * content type's table with its own union (`MainControlVerbTable<FooRequest>`)
 * and the compiler enforces that it covers exactly that union's verbs, each
 * narrowed to its own request shape (not a generic plugin catch-all — see
 * `MainControlVerb`'s doc).
 */
export type MainControlVerbTable<R extends { type: string }> = {
  [V in R['type']]: MainControlVerb<V, R>
}
