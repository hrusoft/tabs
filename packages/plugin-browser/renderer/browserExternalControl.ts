import type { RendererControlVerbTable, RendererPluginContext } from '@tabs/plugin-sdk/renderer/api'
import type { ControlResponse } from '@tabs/plugin-sdk/shared/externalControl'
import type { BrowserControlRequest } from '../shared/externalControl'
import {
  handleClick,
  handleFormInput,
  handleHover,
  handleKey,
  handleScroll,
  handleType,
  withHostFocusRestored
} from './inputVerbs'
import {
  handleCreateBrowserPane,
  handleHistoryStep,
  handleNavigate,
  handleReload
} from './navigationVerbs'
import { handleFind, handleGetPageText, handleReadPage, handleScreenshot } from './readVerbs'
import { handleExecuteJavaScript, handleReadConsoleMessages } from './scriptVerbs'
import { withWebview } from './verbSupport'
import { handleAssert, handleWaitFor } from './waitVerbs'

/**
 * The browser pane's contribution to the external-control protocol: every verb
 * that drives a `<webview>` guest, its own createBrowserPane, and the stubs
 * for the verbs main answers alone. `activatePane`/`closePane`/
 * `listOwnedPanes`/`getPaneInfo` are core's own verbs now (see
 * src/renderer/src/content/externalControl.ts) — this package's only
 * contribution to them is the `listSummaryForControl`/`describeForControl`
 * hooks on `browserContentDef.ts`.
 *
 * Core owns only the transport and the dispatch registry; everything that
 * knows what a browser *is* lives in this package. The handlers live by
 * family beside this file — navigationVerbs, readVerbs, inputVerbs,
 * scriptVerbs, waitVerbs, over targeting and verbSupport — and this file only
 * registers them, which is also where the cross-cutting wrappers (withWebview,
 * withHostFocusRestored) are applied.
 *
 * The page-load and webview-mount waits (LOAD_WAIT_MS / MOUNT_WAIT_MS) live in
 * ../shared/externalControl.ts so main's relay budgets are derived from them
 * rather than hand-synced above them.
 */

/**
 * A verb main answers in full and never relays, so this window has nothing to
 * do but exist for it.
 *
 * The stub is still this type's to supply rather than core's: the coverage
 * gate is over every verb in the protocol (see `unhandledControlVerbs`), so an
 * unclaimed name would have to be stubbed in core's own module under this
 * type's name — exactly the coupling the registry split removed. Reaching one
 * of these means a request was relayed that shouldn't have been, which is a
 * wiring bug in main's verb table, hence the flat error rather than a silent
 * success.
 *
 * One helper rather than three literals: the three that need it
 * (readNetworkRequests, captureNetworkBodies, saveResource) differ only in the
 * verb name. Core's `batch` stub reads the same but
 * stays its own: it lives on the other side of the plugin boundary, and its
 * reason differs — batch is *decomposed* in main into sub-requests that are
 * each relayed here individually, not answered there.
 */
function answeredInMain(verb: string): () => ControlResponse {
  return () => ({ ok: false, error: `${verb} is handled in the main process` })
}

// The input verbs run under the focus guard — the guest side of a click or
// focus() pulls host focus onto the webview element (see
// withHostFocusRestored), and these are the verbs that trigger it.
const click = withWebview(handleClick)
const type = withWebview(handleType)
const key = withWebview(handleKey)
const formInput = withWebview(handleFormInput)
// hover takes the full guard even though only half of it can fire, and that
// is deliberate rather than copied. The *activation* half is inert by
// construction: main's guest-activation listener bails on anything that
// isn't a `mouseDown` (see main/guestActivation.ts and the measured
// event-type table in CLAUDE.md), and hover sends only `mouseMove`. The
// *focus* half is not — a page's own mouseenter handler is free to call
// el.focus(), which pulls host focus onto the <webview> exactly as a click's
// does, and that is the whole reason this wrapper exists. Taking the pair is
// cheaper than a hover-only variant that would have to be re-audited every
// time either half changes.
const hover = withWebview(handleHover)

/**
 * Every verb this content type answers, as one table — the renderer's
 * counterpart to main's `BROWSER_CONTROL_VERBS`. Annotated with this type's
 * own request union, so a verb added to `BrowserControlRequest` without an
 * entry here fails to build, and an entry naming a verb the union no longer
 * has fails too — the same guarantee the old sequence of individual
 * `registerControlVerb` calls could only check at runtime (via
 * `unhandledControlVerbs`).
 */
const BROWSER_CONTROL_VERBS: RendererControlVerbTable<BrowserControlRequest> = {
  createBrowserPane: handleCreateBrowserPane,
  navigate: withWebview(handleNavigate),
  reload: withWebview(handleReload),
  goBack: withWebview((webview, request) =>
    handleHistoryStep(webview, 'back', request.targetPaneId)
  ),
  goForward: withWebview((webview, request) =>
    handleHistoryStep(webview, 'forward', request.targetPaneId)
  ),
  // activatePane/closePane/listOwnedPanes/getPaneInfo are core's own verbs
  // now — see src/renderer/src/content/externalControl.ts — answered off
  // this package's listSummaryForControl/describeForControl hooks
  // (browserContentDef.ts) rather than registered here.
  screenshot: withWebview(handleScreenshot),
  getPageText: withWebview(handleGetPageText),
  readPage: withWebview(handleReadPage),
  find: withWebview(handleFind),
  click: (request) => withHostFocusRestored(() => click(request)),
  hover: (request) => withHostFocusRestored(() => hover(request)),
  type: (request) => withHostFocusRestored(() => type(request)),
  key: (request) => withHostFocusRestored(() => key(request)),
  scroll: withWebview(handleScroll),
  readConsoleMessages: handleReadConsoleMessages,
  executeJavaScript: withWebview(handleExecuteJavaScript),
  // No focus guard: waitFor injects no input and focuses nothing — it only
  // watches. withWebview alone, like the read verbs above. assert is its
  // single-shot twin and shares the reasoning.
  waitFor: withWebview(handleWaitFor),
  assert: withWebview(handleAssert),
  formInput: (request) => withHostFocusRestored(() => formInput(request)),
  // The three main answers alone, each because it owns the machinery: the
  // webRequest capture (readNetworkRequests), the CDP body session
  // (captureNetworkBodies, see main/networkBodyCapture.ts), and the fetch
  // routes plus the file sink (saveResource). See `answeredInMain`.
  readNetworkRequests: answeredInMain('readNetworkRequests'),
  captureNetworkBodies: answeredInMain('captureNetworkBodies'),
  saveResource: answeredInMain('saveResource')
}

/**
 * Claims every verb this content type answers. Called once from this
 * package's `activate`, i.e. only when the browser type is actually
 * registered — a build without it answers these verbs with core's
 * "no handler" error rather than silently doing nothing.
 */
export function registerBrowserControlVerbs(ctx: RendererPluginContext): void {
  ctx.registerControlVerbs(BROWSER_CONTROL_VERBS)
}
