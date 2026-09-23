import type { ControlResponse } from '@shared/externalControl'
import { PANE_GONE_ERROR } from '@shared/externalControl'
import type { WebviewTag } from 'electron'
import { PANE_NOT_MOUNTED_ERROR } from '../shared/externalControl'
import { BROWSER_TYPE } from '../shared/manifest'
import { type BrowserPaneHandle, getBrowserPane } from './browserControl'
import { browserCtx } from './pluginContext'

/**
 * Shared plumbing for the browser's control verbs: resolving a request's target
 * pane to its live `<webview>`, and the one way any verb reaches a guest
 * script (`evalInGuest`).
 */

/**
 * Why `targetPaneId` can't be driven as a browser pane, or null if it can.
 *
 * The two cases are reported apart because they mean opposite things to a
 * caller and only this process can tell them apart. Main's ownership check
 * (`ownerOf`, src/main/externalControl.ts) keeps its grant until a `closePane`
 * verb succeeds, so a pane the *user* closed by hand still passes there and
 * arrives here as a live request against an id that no longer resolves — and
 * that, not a type mismatch, is overwhelmingly what fires: main only ever
 * grants ids it saw `createBrowserPane` create, and node ids are uuids, so a
 * granted id cannot later name some other kind of pane. Answering both with
 * "not a browser pane" would tell an agent its pane was the wrong kind when
 * it is in fact gone.
 */
export function browserPaneError(targetPaneId: string): string | null {
  const node = browserCtx.get().layout.findNode(targetPaneId)
  // The same sentence core's main answers for a pane the *caller* closed —
  // shared rather than restated, because an agent shouldn't have to recognise
  // two spellings of "it's gone". See PANE_GONE_ERROR.
  if (!node) return PANE_GONE_ERROR
  if (node.type !== BROWSER_TYPE) return 'target is not a browser pane'
  return null
}

/**
 * Resolves a request's `targetPaneId` to its mounted pane handle, or to the
 * error the caller should return instead. Ownership was already checked in
 * main (see src/main/externalControl.ts) — what's checked here is the two
 * things only this process can know: that the pane still exists as a browser
 * pane, and that a `BrowserRenderer` is currently mounted for it.
 */
export function resolveBrowserHandle(
  targetPaneId: string
): { handle: BrowserPaneHandle } | { error: string } {
  const paneError = browserPaneError(targetPaneId)
  if (paneError) return { error: paneError }
  const handle = getBrowserPane(targetPaneId)
  if (!handle) return { error: PANE_NOT_MOUNTED_ERROR }
  return { handle }
}

/**
 * `resolveBrowserHandle`, then the handle's live `<webview>` — what every
 * read/input verb ultimately acts on. A mounted pane can still briefly lack
 * a guest (mid-attach), which reports the same way as not mounted at all.
 */
function resolveWebview(targetPaneId: string): { webview: WebviewTag } | { error: string } {
  const resolved = resolveBrowserHandle(targetPaneId)
  if ('error' in resolved) return resolved
  const webview = resolved.handle.webview()
  if (!webview) return { error: PANE_NOT_MOUNTED_ERROR }
  return { webview }
}

/**
 * Wraps a handler in the resolve step every guest verb shares: the request's
 * `targetPaneId` becomes the mounted pane's live `<webview>`, or the caller
 * gets the error instead of the handler running. Cross-cutting concerns wrap
 * handlers at the registration site (browserExternalControl.ts) — the same idiom as
 * withHostFocusRestored — so no handler body restates the prologue.
 */
export function withWebview<R extends { targetPaneId: string }>(
  handle: (webview: WebviewTag, request: R) => ControlResponse | Promise<ControlResponse>
): (request: R) => Promise<ControlResponse> {
  return async (request) => {
    const target = resolveWebview(request.targetPaneId)
    if ('error' in target) return { ok: false, error: target.error }
    return handle(target.webview, request)
  }
}

/**
 * What a verb answers when the guest can't run script at all. Electron's own
 * rejection — "Error invoking remote method 'GUEST_VIEW_MANAGER_CALL': Script
 * failed to execute…" — names nothing a caller can act on.
 */
const GUEST_SCRIPT_UNAVAILABLE =
  'the page could not run script — it may be mid-navigation, showing an error page, or a viewer (such as the PDF viewer) that runs none'

/**
 * `executeJavaScript` with a rejection turned into GUEST_SCRIPT_UNAVAILABLE,
 * rather than escaping to the dispatch boundary as Electron's plumbing text.
 * Every guest round trip the verbs make goes through here; a caller for whom
 * the answer is optional (reporting, never a gate) degrades on `error`.
 */
export async function evalInGuest<T>(
  webview: WebviewTag,
  script: string
): Promise<{ value: T } | { error: string }> {
  try {
    return { value: (await webview.executeJavaScript(script)) as T }
  } catch {
    return { error: GUEST_SCRIPT_UNAVAILABLE }
  }
}

/**
 * `evalInGuest` for a script that answers with an outcome object of its own
 * making, which the caller then reads fields off. A non-object answer — a
 * page that replaced a built-in the script relies on — is refused as such
 * rather than surfacing as a TypeError reading `.resolved` off null.
 */
export async function evalOutcomeInGuest<T extends object>(
  webview: WebviewTag,
  script: string
): Promise<{ value: T } | { error: string }> {
  const run = await evalInGuest<unknown>(webview, script)
  if ('error' in run) return run
  if (typeof run.value !== 'object' || run.value === null) {
    return {
      error:
        "the page's answer was not the shape this verb expects — the page may have replaced a built-in the verb relies on"
    }
  }
  return { value: run.value as T }
}

/** A wire string that names something: present, a string, and not blank. */
export function namedString(value: unknown): value is string {
  return typeof value === 'string' && value.trim() !== ''
}
