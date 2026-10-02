import type { ControlResponse } from '@tabs/plugin-sdk/shared/externalControl'
import type { WebviewTag } from 'electron'
import { PANE_NOT_MOUNTED_ERROR } from '../shared/externalControl'
import { BROWSER_TYPE } from '../shared/manifest'
import { type BrowserPaneHandle, getBrowserPane } from './browserControl'
import { delay } from './pageWait'
import { browserCtx } from './pluginContext'

/**
 * Shared plumbing for the browser's control verbs: resolving a request's target
 * pane to its live `<webview>`, and the one way any verb reaches a guest
 * script (`evalInGuest`).
 */

/**
 * Why `targetPaneId` can't be driven as a browser pane, or null if it can. A
 * thin wrapper over the shared `ctx.resolveControlTarget` — see its doc on
 * `plugin/api.ts` for why the two failure cases (gone vs. wrong type) are
 * reported apart.
 */
export function browserPaneError(targetPaneId: string): string | null {
  const resolved = browserCtx.get().resolveControlTarget(targetPaneId, BROWSER_TYPE)
  return 'error' in resolved ? resolved.error : null
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

/** How long guestViewport waits for the page before falling back to the host's measurement. */
const VIEWPORT_READ_BUDGET_MS = 500

/** The page's own coordinate space, and how many image pixels a CSS pixel of it is. */
export interface GuestViewport {
  /** The page's `innerWidth`/`innerHeight` — the CSS-pixel space `click --x/--y` and `read-page` rects live in. */
  width: number
  height: number
  /** The page's `devicePixelRatio` — image pixels per CSS pixel in a `capturePage()` result. */
  scaleFactor: number
}

function isPositiveNumber(value: unknown): value is number {
  return typeof value === 'number' && Number.isFinite(value) && value > 0
}

/**
 * The viewport and scale factor the `screenshot` and `pane-info` verbs report,
 * read from the page itself rather than derived from the host element.
 *
 * Both used to be derived, and both came out slightly wrong whenever the
 * pane's width was not a whole number of CSS pixels — which a split or a
 * dragged separator makes it most of the time. The `<webview>` element was
 * 345.4px wide; Chromium gave the page a 346px `innerWidth` (measured: it
 * rounds the guest viewport *up* — 693.5 → 694, 600.25 → 601) while the host
 * reported `Math.round(345.4)` = 345, so `viewport` disagreed with the space
 * a coordinate click is in by a pixel. And `scaleFactor` was the captured
 * image's width over that rounded width — 691 / 345 = 2.0029 on a 2x screen,
 * a ratio no display has. The page's own `innerWidth`/`innerHeight` and
 * `devicePixelRatio` are exact by definition.
 *
 * The fallback (a page that can't run script — an error page mid-recovery,
 * a PDF viewer — or one too busy to answer within VIEWPORT_READ_BUDGET_MS)
 * reproduces the page's rounding from the host element and takes the host's
 * own ratio, the best available without the page. The budget is there
 * because `pane-info` used to be host reads alone, answerable even for a page
 * wedged in a script loop, and must stay so.
 */
export async function guestViewport(webview: WebviewTag): Promise<GuestViewport> {
  const run = await Promise.race([
    evalInGuest<unknown>(
      webview,
      '[window.innerWidth, window.innerHeight, window.devicePixelRatio]'
    ),
    delay(VIEWPORT_READ_BUDGET_MS).then(() => ({ error: 'the page did not answer in time' }))
  ])
  if (!('error' in run) && Array.isArray(run.value)) {
    const [width, height, scaleFactor] = run.value as unknown[]
    if (isPositiveNumber(width) && isPositiveNumber(height) && isPositiveNumber(scaleFactor)) {
      return { width, height, scaleFactor }
    }
  }
  const rect = webview.getBoundingClientRect()
  return {
    width: Math.ceil(rect.width),
    height: Math.ceil(rect.height),
    scaleFactor: window.devicePixelRatio
  }
}
