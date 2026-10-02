/**
 * The two pieces of the external-control wire protocol a content-type
 * package actually needs — split out of `src/shared/externalControl.ts`
 * (which stays core-owned: the assembled `ControlRequest` union, the core
 * verb list, `CONTROL_REQUEST_TYPES` (reads the runtime census), batching
 * and relay bookkeeping are all main-process/core-dispatch concerns a
 * package never touches — verified by grep across every content-type package
 * during issue #18's planning: no plugin file imports anything else from that
 * module).
 *
 * `PluginControlRequest` is deliberately generic rather than a literal
 * union: TypeScript cannot glob types, so there is no way to assemble a
 * literal union of every package's request shapes from the runtime census.
 * A package's own concrete union (e.g. `BrowserControlRequest`) narrows this
 * at the point it's actually used — see `ControlVerbHandler`/
 * `RendererControlVerbTable` (../renderer/controlVerbTable.ts) and
 * `MainControlVerb`/`MainControlVerbTable` (../main/controlVerbTable.ts).
 */

export type ControlResponse =
  | { ok: true; result?: Record<string, unknown> }
  | { ok: false; error: string }

/**
 * Every request a content-type package's own union can shape. Core
 * dispatches on `type` and enforces `paneId`/`targetPaneId` uniformly, and
 * reads nothing else; a package's own verb table narrows each request to
 * its concrete shape at the point it's actually handled.
 */
export interface PluginControlRequest {
  type: string
  paneId: string
  targetPaneId?: string
  [key: string]: unknown
}
