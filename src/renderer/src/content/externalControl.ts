import type { ControlRequest, ControlResponse } from '@shared/externalControl'
import { CONTROL_REQUEST_TYPES } from '@shared/externalControl'

/**
 * The renderer's half of the external control socket: transport, a registry of
 * verb handlers, and dispatch between them.
 *
 * Deliberately knows nothing about what any verb does. Almost the whole
 * protocol drives `<webview>` guests, and every one of those verbs lives with
 * the browser content type (src/plugins/browser/renderer/browserExternalControl.ts), which
 * claims them at registration time; core keeps only the two verbs that are
 * about no content type at all.
 *
 * That includes the verbs main answers alone: a type still owes this window a
 * handler for one (the coverage gate below is over the whole protocol, not
 * over what gets relayed), and it registers that itself rather than leaving a
 * stub here with its name on it.
 */

type ControlVerb = ControlRequest['type']

/**
 * What a verb handler is. It receives its own narrowed request and *returns*
 * the answer — it is never handed the transport, so it cannot reply twice,
 * reply late, or fail to reply. That invariant lives in exactly one place
 * (installExternalControl below), which is also what lets a handler throw
 * freely: the throw becomes the error response.
 */
type ControlVerbHandler<V extends ControlVerb = ControlVerb> = (
  request: Extract<ControlRequest, { type: V }>
) => ControlResponse | Promise<ControlResponse>

/**
 * How a handler is held once stored. Not `ControlVerbHandler` itself: handlers
 * are contravariant in their request, so one written for a single verb is not
 * assignable to one accepting the whole union. Widening at the boundary is
 * sound by construction — the map is keyed by verb name and `handleRequest`
 * only ever calls the entry found under `request.type`, so a handler can only
 * receive the request shape it was registered for.
 */
type StoredHandler = (request: ControlRequest) => ControlResponse | Promise<ControlResponse>

const handlers = new Map<ControlVerb, StoredHandler>()

/**
 * Claims `verb` for `handler`.
 *
 * A duplicate is a conflict rather than a remount, and throws — the same rule
 * as contentRegistry and the settings-page registry. The consequence worth
 * knowing: a verb name has exactly one owner, so two content types could not
 * both offer `activatePane`. That is the right trade while the protocol is as
 * browser-shaped as it is — main only ever grants a `targetPaneId` to whoever
 * created it via `createBrowserPane` — but it is a real ceiling, not an
 * oversight.
 *
 * Registration is one-way on purpose: a content type claims its verbs once, at
 * registration, and nothing in the app has ever needed to give one back. Main's
 * own registry says the same thing from the other side (see
 * `resetMainControlVerbsForTests`, which exists only so a unit test can start
 * from a clean map and is deliberately never called at runtime).
 */
export function registerControlVerb<V extends ControlVerb>(
  verb: V,
  handler: ControlVerbHandler<V>
): void {
  if (handlers.has(verb)) {
    throw new Error(`Control verb handler already registered for "${verb}"`)
  }
  handlers.set(verb, handler as unknown as StoredHandler)
}

/**
 * Verbs in the wire protocol that nothing in this window answers.
 *
 * This exists because the registry gave up a compile-time guarantee. The verb
 * switch it replaced was exhaustive over `ControlRequest`, so adding a verb to
 * the union without implementing it here failed to build — one of the three
 * legs of the chain described on CONTROL_REQUEST_TYPES. A Map keyed by name
 * cannot be checked that way, so the check moved to a test, which asserts this
 * is empty once the built-in content types have registered (see
 * content/__tests__/externalControlVerbs.test.tsx). That catches both halves:
 * a verb added to the protocol with no handler, and a handler that exists but
 * whose registration never runs.
 */
export function unhandledControlVerbs(): ControlVerb[] {
  return CONTROL_REQUEST_TYPES.filter((verb) => !handlers.has(verb))
}

// Core's own verbs, registered here at module scope rather than switched on
// below. One dispatch mechanism instead of two is what keeps
// `unhandledControlVerbs` honest: a separate hand-written list of "verbs core
// answers" would be one more thing to keep in sync with the code answering
// them. Module scope is safe here in a way a cross-module import side effect
// would not be — this is the registry's own module initialising its own state.
registerControlVerb('ping', () => ({ ok: true }))
// Decomposed in main into its individual sub-requests, each of which is
// relayed here on its own — a batch never arrives whole.
registerControlVerb('batch', () => ({
  ok: false,
  error: 'batch is handled in the main process'
}))

function handleRequest(request: ControlRequest): ControlResponse | Promise<ControlResponse> {
  const handler = handlers.get(request.type)
  // Only reachable for a verb whose content type isn't registered in this
  // build; a complete app answers every name in the protocol (see the test
  // behind unhandledControlVerbs).
  if (!handler) {
    return { ok: false, error: `no handler is registered for "${request.type}" in this window` }
  }
  return handler(request)
}

/**
 * Wires main's relayed pane-tree requests (see src/main/externalControl.ts)
 * to this window's layout store — the only process that actually holds the
 * live tree (main is a persistence sink, not a live copy — see
 * layoutStore.ts). Install once, alongside installPaneShortcuts (App.tsx).
 *
 * A handler that throws (a guest that navigated away mid-capture, a page
 * whose script threw) answers with an error rather than leaving main's
 * relay to time out — the caller is a socket waiting on a ControlResponse,
 * and a real error message beats a five-second silence.
 */
export function installExternalControl(): () => void {
  return window.api.externalControl.onRequest((requestId, request) => {
    Promise.resolve()
      .then(() => handleRequest(request))
      .then(
        (response) => window.api.externalControl.respond(requestId, response),
        (error: unknown) =>
          window.api.externalControl.respond(requestId, { ok: false, error: String(error) })
      )
  })
}
