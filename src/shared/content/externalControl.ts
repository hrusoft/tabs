import {
  BROWSER_CONTROL_REQUEST_MARKER,
  type BrowserControlRequest
} from '../../plugins/browser/shared/externalControl'

/**
 * Every external-control verb contributed by a content type, one line each —
 * the only place core's `ControlRequest` names a content type.
 *
 * Core's `ControlRequest` has to be the *combined* union — `batch` carries
 * `ControlRequest[]`, so it recurses through the whole protocol — but "the
 * combined union lives in core" and "core lists the types" are different
 * claims, and only the first one is forced. Core composes
 * `CoreControlRequest | ContentControlRequest`; adding a type edits this file
 * and no core one. There is no runtime-API equivalent to twin this against any
 * more: `window.api.content` (`../plugin/bridge.ts`) replaced the old per-type
 * `Api` intersection with one generic, untyped bridge, so this union is the
 * one place left where a content type's contribution to the wire protocol has
 * to stay a static, per-type shape — because `batch`'s recursion needs one.
 *
 * A type declares its verbs with itself (browser's are in
 * `../../plugins/browser/shared/externalControl.ts`, with the
 * `PageElement`/`ElementTarget` vocabulary they speak in). Note this is a
 * split of *types*, not of handlers: several verbs core declares are answered
 * by the browser content type, and which module registers which handler is a
 * separate question — see core's `../../main/externalControl.ts`.
 */
export type ContentControlRequest = BrowserControlRequest

/**
 * The same compile-time trick each half applies to its own list: composed from
 * the per-type markers rather than re-listing every verb, so a type whose
 * marker is missing here fails to build, and each type's own annotation fails on
 * a name that is not one of its verbs.
 */
export const CONTENT_CONTROL_REQUEST_MARKER: Record<ContentControlRequest['type'], true> = {
  ...BROWSER_CONTROL_REQUEST_MARKER
}
