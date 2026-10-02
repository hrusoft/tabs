import type {
  ControlVerbHandler,
  RendererControlVerbTable
} from '@tabs/plugin-sdk/renderer/controlVerbTable'

export type {
  ControlVerbHandler,
  RendererControlVerbTable
} from '@tabs/plugin-sdk/renderer/controlVerbTable'

import type { ControlRequest, ControlResponse } from '@shared/externalControl'
import { CONTROL_REQUEST_TYPES, PANE_GONE_ERROR } from '@shared/externalControl'
import {
  type ContentNode,
  collectLeaves,
  isLeaf,
  type LeafContent
} from '@tabs/plugin-sdk/shared/model/types'
import { getPaneHandle } from '../core/registry/paneHandles'
import { contentRegistry } from '../core/registry/registry'
import { allRoots, findNodeAnywhere, useLayoutStore } from '../core/store/layoutStore'
import { revealPane } from './placement'

/**
 * The renderer's half of the external control socket: transport, a registry of
 * verb handlers, and dispatch between them.
 *
 * Deliberately knows nothing about what any verb does. Almost the whole
 * protocol drives `<webview>` guests, and every one of those verbs lives with
 * the browser content type (packages/plugin-browser/renderer/browserExternalControl.ts), which
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
  handler: ControlVerbHandler<V, ControlRequest>
): void {
  if (handlers.has(verb)) {
    throw new Error(`Control verb handler already registered for "${verb}"`)
  }
  handlers.set(verb, handler as unknown as StoredHandler)
}

/**
 * Claims every verb in `table` for this window. Called once per content type,
 * from its renderer `activate` — core's own six stay on the single-verb
 * `registerControlVerb` above, registered at module scope in this file.
 *
 * A duplicate throws, same rule as the single-verb form and as main's
 * registry: a verb name has exactly one owner.
 */
export function registerControlVerbs<R extends { type: string }>(
  table: RendererControlVerbTable<R>
): void {
  for (const [verb, handler] of Object.entries(table) as [string, StoredHandler][]) {
    if (handlers.has(verb)) {
      throw new Error(`Control verb handler already registered for "${verb}"`)
    }
    handlers.set(verb, handler)
  }
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
// Answered entirely in main from the census plus Settings.disabledContentTypes
// (src/main/externalControl.ts) — never relayed, but every verb still owes
// this window a handler (the coverage gate is over the whole protocol, not
// over what gets relayed), the same stub shape the browser package uses for
// its own main-only verbs (readNetworkRequests, etc.).
registerControlVerb('capabilities', () => ({
  ok: false,
  error: 'capabilities is handled in the main process'
}))
registerControlVerb('describe', () => ({
  ok: false,
  error: 'describe is handled in the main process'
}))

/**
 * The four pane-tree verbs that name only a pane id and so belong to core's
 * protocol even though, until a second content type declares
 * `listSummaryForControl`/`describeForControl`, the browser is the only thing
 * they can ever resolve in practice (main only grants a `targetPaneId` for a
 * pane some create verb actually made — see `ownerOf` in
 * src/main/externalControl.ts). `activatePane`/`closePane` are genuinely
 * type-agnostic pane-tree operations and check nothing beyond "does the node
 * still exist" — the old browser-only implementation's "is this a browser
 * pane" check added no real restriction (ownership already implied it) and
 * would only have been wrong once a second type existed.
 */
registerControlVerb('activatePane', (request) => {
  const node = findNodeAnywhere(useLayoutStore.getState(), request.targetPaneId)
  if (!node) return { ok: false, error: PANE_GONE_ERROR }
  revealPane(node.id)
  return { ok: true }
})

registerControlVerb('closePane', (request) => {
  const node = findNodeAnywhere(useLayoutStore.getState(), request.targetPaneId)
  if (!node) return { ok: false, error: PANE_GONE_ERROR }
  useLayoutStore.getState().closePane(node.id)
  return { ok: true }
})

/** Every leaf whose type opts into being listed, across every tree (docked root plus each floating window). */
function collectControllablePanes(node: ContentNode): Record<string, unknown>[] {
  return collectLeaves(node).flatMap((leaf: LeafContent) => {
    const summary = contentRegistry.get(leaf.type)?.listSummaryForControl?.(leaf)
    if (!summary) return []
    return [{ paneId: leaf.id, type: leaf.type, title: leaf.title ?? '', ...summary }]
  })
}

registerControlVerb('listOwnedPanes', () => {
  const panes = allRoots(useLayoutStore.getState()).flatMap(collectControllablePanes)
  return { ok: true, result: { panes } }
})

registerControlVerb('getPaneInfo', async (request) => {
  const node = findNodeAnywhere(useLayoutStore.getState(), request.targetPaneId)
  if (!node) return { ok: false, error: PANE_GONE_ERROR }
  // Structural nodes (tabs/split) are never reachable here in practice —
  // ownership is only ever granted for a pane a create verb actually made,
  // and every create verb makes a leaf — but this is the boundary that keeps
  // it true rather than assumed.
  if (!isLeaf(node)) {
    return { ok: false, error: 'target is not a pane that can be inspected' }
  }
  const def = contentRegistry.get(node.type)
  const described = await def?.describeForControl?.(node, getPaneHandle(node.id))
  if (!described) {
    return { ok: false, error: `${node.type} panes cannot be inspected with getPaneInfo` }
  }
  if ('error' in described) return { ok: false, error: described.error }
  return {
    ok: true,
    result: { paneId: node.id, type: node.type, title: node.title ?? '', ...described.fields }
  }
})

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
