import {
  CONTENT_CONTROL_REQUEST_MARKER,
  type ContentControlRequest
} from './content/externalControl'

/**
 * Wire protocol for the external control socket (see src/main/externalControl.ts)
 * that lets a CLI process spawned inside a Tabs terminal pane — the `tabs-ctl`
 * helper a skill invokes (see resources/skills/tabs) — ask the app to
 * create/control a pane. The socket has no other notion of "who is asking",
 * so every request carries the caller's own pane id (see terminal.ts's
 * TABS_PANE_ID env injection).
 *
 * This file is the *registry*: core's own verbs, the transport envelopes, and
 * the assembled `ControlRequest` union. A content type's verbs are declared
 * with the type and reach core as one name through
 * src/shared/content/externalControl.ts, exactly as its `window.api` namespaces
 * reach `Api` through content/api.ts — so core names no type here.
 *
 * Two things about that split are worth stating so nobody undoes them:
 *
 * - It is a split of *types*, not of handlers. Several verbs declared here are
 *   registered by the browser content type (`activatePane`, `closePane`,
 *   `listOwnedPanes`, `getPaneInfo` — see the renderer's verb registry). Their
 *   request shapes name nothing about a page, so they belong to core's
 *   protocol even while the browser happens to be the only thing answering
 *   them. Which module registers which handler is a separate question from
 *   where a type lives.
 * - The *combined* union is assembled here because `batch` carries
 *   `ControlRequest[]`, i.e. it recurses through the whole protocol. That is
 *   why the combined union has to exist in core; it is not a reason for core to
 *   enumerate the halves, which is why the content half arrives pre-unioned.
 */

export type ControlResponse =
  | { ok: true; result?: Record<string, unknown> }
  | { ok: false; error: string }

/**
 * The verbs that belong to no content type: liveness, pane-tree operations
 * that name only pane ids, and the batching envelope.
 *
 * Every request carries `paneId` (the caller's own pane, for the ownership
 * check); one that acts on another pane also carries `targetPaneId`, which
 * must be a pane this caller created.
 */
export type CoreControlRequest =
  | { type: 'ping'; paneId: string }
  | { type: 'activatePane'; paneId: string; targetPaneId: string }
  | { type: 'closePane'; paneId: string; targetPaneId: string }
  | { type: 'listOwnedPanes'; paneId: string }
  | { type: 'getPaneInfo'; paneId: string; targetPaneId: string }
  | { type: 'batch'; paneId: string; requests: ControlRequest[]; continueOnError?: boolean }

/** Every request the socket accepts: core's, plus every content type's. */
export type ControlRequest = CoreControlRequest | ContentControlRequest

/**
 * Core's verb names at runtime — the same compile-time trick each content type
 * applies to its own list (see CONTENT_CONTROL_REQUEST_MARKER): a verb added to
 * `CoreControlRequest` without a key here fails to build, and a key naming a
 * verb that no longer exists fails too.
 */
const CORE_CONTROL_REQUEST_MARKER: Record<CoreControlRequest['type'], true> = {
  ping: true,
  activatePane: true,
  closePane: true,
  listOwnedPanes: true,
  getPaneInfo: true,
  batch: true
}

/**
 * Every verb name, available at runtime rather than only to the type checker.
 *
 * Composed from the per-type markers rather than re-listing every name, so the
 * exhaustiveness guarantee survives the protocol being split across files: the
 * `Record` annotation here fails if the two halves together miss a member of
 * `ControlRequest`, and each half's own annotation fails on a name that is not
 * a verb. That closes the last gap in the chain that keeps the CLI honest —
 * main's per-type verb tables are each annotated with their own union, so the
 * compiler forces every verb to declare a handler and a relay budget
 * (src/main/controlVerbs.ts), both processes back that with a runtime gate
 * against a registration that never ran (the renderer's
 * content/__tests__/externalControlVerbs.test.tsx, main's in
 * e2e/external-control.spec.ts), and `tabs-ctl`'s own command table is checked
 * against this list by src/shared/__tests__/tabsCtlDescribe.test.ts, which runs
 * the real shipped executable's `describe` output.
 */
const CONTROL_REQUEST_TYPE_MARKER: Record<ControlRequest['type'], true> = {
  ...CORE_CONTROL_REQUEST_MARKER,
  ...CONTENT_CONTROL_REQUEST_MARKER
}

export const CONTROL_REQUEST_TYPES = Object.keys(
  CONTROL_REQUEST_TYPE_MARKER
) as ControlRequest['type'][]

/** How many sub-requests one `batch` may carry. Bounds the work a single socket connection can ask for. */
export const MAX_BATCH_SIZE = 50

/**
 * What a verb aimed at a pane that is gone answers with — quoted verbatim in
 * the skill's own SKILL.md, which is why it is a constant rather than a string
 * literal in each place that can produce it.
 *
 * It has **two** producers, on opposite sides of the plugin boundary and for
 * opposite reasons, which is what makes the sharing load-bearing rather than
 * tidy: a content type's renderer says it when the id no longer resolves to a
 * pane (the user closed it by hand — ownership survives, so the request gets
 * that far), and core's main says it when the caller closed the pane itself
 * through `closePane` and the ownership grant is therefore gone. An agent
 * cannot be expected to recognise two spellings of one situation, and nothing
 * would catch them drifting apart.
 */
export const PANE_GONE_ERROR =
  'target pane no longer exists — it was closed; listOwnedPanes shows the panes still open'

/**
 * One entry in a batch's transcript (`result.steps`), aligned index-for-index
 * with the request list the caller sent: what ran (`type`), whether it
 * succeeded, how long it took, and the verb's own response fields. Steps after
 * the failure that stopped the batch are `{ skipped: true }` markers rather
 * than absent, so the alignment holds in every mode; under `continueOnError`
 * every step runs and nothing is skipped. Declared here beside the batch
 * request because it is wire shape a caller assembles against, not an
 * implementation detail of main's handler.
 */
export type BatchStep =
  | ({ type: ControlRequest['type']; durationMs: number } & ControlResponse)
  | { type: ControlRequest['type']; skipped: true }

/**
 * Main has no live pane tree of its own (see layoutStore.ts) and can only
 * push one-way events into a renderer, so a request that needs the tree
 * mutated goes out over `IpcChannel.externalControlRequest` tagged with a
 * `requestId`, and the renderer's answer comes back over
 * `externalControlResponse` tagged with the same id — main matches the two
 * up to resolve the socket caller's pending request.
 */
export interface RelayedControlRequest {
  requestId: string
  request: ControlRequest
}

export interface RelayedControlResponse {
  requestId: string
  response: ControlResponse
}
