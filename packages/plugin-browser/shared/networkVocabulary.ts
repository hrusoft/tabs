/**
 * The closed vocabularies `read-network`'s `--method`/`--resource-type`
 * filters accept. Process-agnostic (no Electron import), so they live here
 * rather than in main/networkLog.ts, which enforces them — that module
 * re-exports both for its existing callers, and this package's control spec
 * (shared/controlSpec.ts) reads them directly for `describe`'s documentation,
 * without pulling Electron into a shared file.
 */

/**
 * HTTP methods `session.webRequest` reports. `CONNECT`/`TRACE` are
 * unreachable methods for `fetch`/`XMLHttpRequest`, so a page can never
 * originate one — but they stay in the accepted set for completeness:
 * refusing a spec-legal value that would just always match nothing is a
 * worse trade than allowing it.
 */
export const NETWORK_METHODS: readonly string[] = [
  'GET',
  'HEAD',
  'POST',
  'PUT',
  'DELETE',
  'OPTIONS',
  'PATCH',
  'CONNECT',
  'TRACE'
]

/**
 * Electron's `session.webRequest` resourceType union (electron.d.ts, e.g.
 * `OnBeforeRequestListenerDetails`) — exactly the values `registerNetworkCapture`
 * (browserGuestRegistry.ts) stores on every entry, so this is a closed set
 * to validate against, not an illustrative one. There is no `fetch` or
 * `worker` value in this API: `fetch`/`XMLHttpRequest` traffic both report
 * as `xhr`.
 */
export const NETWORK_RESOURCE_TYPES: readonly string[] = [
  'mainFrame',
  'subFrame',
  'stylesheet',
  'script',
  'image',
  'font',
  'object',
  'xhr',
  'ping',
  'cspReport',
  'media',
  'webSocket',
  'other'
]
