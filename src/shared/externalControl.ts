import type { ControlResponse, PluginControlRequest } from '@tabs/plugin-sdk/shared/externalControl'
import { CONTENT_TYPE_MANIFESTS } from './content/registry'

export type { ControlResponse, PluginControlRequest } from '@tabs/plugin-sdk/shared/externalControl'

/**
 * Wire protocol for the external control socket (see src/main/externalControl.ts)
 * that lets a CLI process spawned inside a Tabs terminal pane — the `tabs-ctl`
 * helper a skill invokes (see resources/skills/tabs) — ask the app to
 * create/control a pane. The socket has no other notion of "who is asking",
 * so every request carries the caller's own pane id (see terminal.ts's
 * TABS_PANE_ID env injection).
 *
 * This file is the *registry*: core's own verbs, the transport envelopes, and
 * the assembled `ControlRequest` union.
 *
 * A content type's verbs are **not** individually named here, and cannot be —
 * TypeScript cannot glob types, so there is no way to assemble a literal union
 * of every package's request shapes from the runtime census. Instead the
 * plugin half of `ControlRequest` is one generic shape
 * (`PluginControlRequest`): `type`/`paneId`/optional `targetPaneId`, plus
 * whatever else the verb needs, untyped. Core never reads a plugin-specific
 * field, so it loses nothing by not naming them; a package keeps (and gains)
 * full compile-time exhaustiveness through its own verb table, typed against
 * its own concrete union (`MainControlVerbTable<BrowserControlRequest>`,
 * `RendererControlVerbTable<BrowserControlRequest>`) — never against this
 * generic shape.
 *
 * `CONTROL_REQUEST_TYPES` — the full verb-name list, core's plus every
 * package's — is derived from the census (`CONTENT_TYPE_MANIFESTS`) at
 * runtime rather than from a hand-aggregated type, which is what makes adding
 * a content type's verbs touch no file outside its own package.
 *
 * One thing worth stating so nobody undoes it: several verbs declared here as
 * core's are registered by the browser content type (`activatePane`,
 * `closePane`, `listOwnedPanes`, `getPaneInfo` — see the renderer's verb
 * registry, and `ContentRendererDef.listSummaryForControl`/
 * `describeForControl`). Their request shapes name nothing about a page, so
 * they belong to core's protocol even while the browser happens to be the
 * only thing answering them. Which module answers a verb is a separate
 * question from which union declares it.
 */

/**
 * The verbs that belong to no content type: liveness, pane-tree operations
 * that name only pane ids, the batching envelope, and protocol discovery
 * (`capabilities`/`describe`, answered from the census — see
 * src/main/externalControl.ts).
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
  | { type: 'capabilities'; paneId: string }
  | { type: 'describe'; paneId: string; capability: string }

/** Every request the socket accepts: core's six, plus every content type's own. */
export type ControlRequest = CoreControlRequest | PluginControlRequest

/**
 * Core's verb names at runtime — the same compile-time trick each content
 * type's own union keeps for itself: a verb added to `CoreControlRequest`
 * without a key here fails to build, and a key naming a verb that no longer
 * exists fails too.
 */
const CORE_CONTROL_REQUEST_MARKER: Record<CoreControlRequest['type'], true> = {
  ping: true,
  activatePane: true,
  closePane: true,
  listOwnedPanes: true,
  getPaneInfo: true,
  batch: true,
  capabilities: true,
  describe: true
}

/**
 * Every verb name, available at runtime rather than only to the type checker
 * — core's eight (checked at compile time above) plus every package's declared
 * `controlVerbs`, read from the census. This is what keeps the CLI, the
 * renderer's coverage gate and main's `unhandledMainControlVerbs` gate honest
 * without any file naming a content type: add a verb to a package's manifest
 * and its own request union, and it appears here for free.
 */
export const CONTROL_REQUEST_TYPES: string[] = [
  ...Object.keys(CORE_CONTROL_REQUEST_MARKER),
  ...CONTENT_TYPE_MANIFESTS.flatMap((manifest) =>
    (manifest.controlVerbs ?? []).map((spec) => spec.verb)
  )
]

/**
 * How many sub-requests one `batch` may carry. Bounds the work a single
 * socket connection can ask for. Defined in its own leaf module
 * (`controlLimits.ts`) and re-exported here so this file's existing
 * importers see no change; `coreControlSpec.ts` imports the leaf directly,
 * since it must not pull in this file's own module-scope census read (see
 * that module's constant for why).
 */
export { MAX_BATCH_SIZE } from './controlLimits'

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

/** Main's broadcast over `externalControlOwnershipChanged` when a pane gains or loses an owner. */
export interface OwnershipChange {
  paneId: string
  owned: boolean
}
