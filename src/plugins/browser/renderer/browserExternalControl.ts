import type { ControlResponse } from '@shared/externalControl'
import type { RendererPluginContext } from '../../../renderer/src/plugin/api'
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
import {
  handleActivatePane,
  handleClosePane,
  handleListOwnedPanes,
  handlePaneInfo
} from './paneVerbs'
import { handleFind, handleGetPageText, handleReadPage, handleScreenshot } from './readVerbs'
import { handleExecuteJavaScript, handleReadConsoleMessages } from './scriptVerbs'
import { withWebview } from './verbSupport'
import { handleAssert, handleWaitFor } from './waitVerbs'

/**
 * The browser pane's contribution to the external-control protocol: every verb
 * that drives a `<webview>` guest, its own createBrowserPane, the four core
 * pane-tree verbs whose targets are browser panes by definition (activatePane,
 * closePane, listOwnedPanes, getPaneInfo), and the stubs for the verbs main
 * answers alone.
 *
 * Core owns only the transport and the dispatch registry (see
 * src/renderer/src/content/externalControl.ts); everything that knows what a
 * browser *is* lives in this package. The handlers live by family beside this
 * file — navigationVerbs, paneVerbs, readVerbs, inputVerbs, scriptVerbs,
 * waitVerbs, over targeting and verbSupport — and this file only registers
 * them, which is also where the cross-cutting wrappers (withWebview,
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

/**
 * Claims every verb this content type answers. Called once from this
 * package's `activate`, i.e. only when the browser type is actually
 * registered — a build without it answers these verbs with core's
 * "no handler" error rather than silently doing nothing.
 */
export function registerBrowserControlVerbs(ctx: RendererPluginContext): void {
  const { registerControlVerb } = ctx
  registerControlVerb('createBrowserPane', handleCreateBrowserPane)
  registerControlVerb('navigate', withWebview(handleNavigate))
  registerControlVerb('reload', withWebview(handleReload))
  registerControlVerb(
    'goBack',
    withWebview((webview, request) => handleHistoryStep(webview, 'back', request.targetPaneId))
  )
  registerControlVerb(
    'goForward',
    withWebview((webview, request) => handleHistoryStep(webview, 'forward', request.targetPaneId))
  )
  registerControlVerb('activatePane', handleActivatePane)
  registerControlVerb('closePane', handleClosePane)
  registerControlVerb('listOwnedPanes', handleListOwnedPanes)
  registerControlVerb('getPaneInfo', withWebview(handlePaneInfo))
  registerControlVerb('screenshot', withWebview(handleScreenshot))
  registerControlVerb('getPageText', withWebview(handleGetPageText))
  registerControlVerb('readPage', withWebview(handleReadPage))
  registerControlVerb('find', withWebview(handleFind))
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
  registerControlVerb('click', (request) => withHostFocusRestored(() => click(request)))
  registerControlVerb('hover', (request) => withHostFocusRestored(() => hover(request)))
  registerControlVerb('type', (request) => withHostFocusRestored(() => type(request)))
  registerControlVerb('key', (request) => withHostFocusRestored(() => key(request)))
  registerControlVerb('scroll', withWebview(handleScroll))
  registerControlVerb('readConsoleMessages', handleReadConsoleMessages)
  registerControlVerb('executeJavaScript', withWebview(handleExecuteJavaScript))
  // No focus guard: waitFor injects no input and focuses nothing — it only
  // watches. withWebview alone, like the read verbs above. assert is its
  // single-shot twin and shares the reasoning.
  registerControlVerb('waitFor', withWebview(handleWaitFor))
  registerControlVerb('assert', withWebview(handleAssert))
  registerControlVerb('formInput', (request) => withHostFocusRestored(() => formInput(request)))
  // The three main answers alone, each because it owns the machinery: the
  // webRequest capture (readNetworkRequests), the CDP body session
  // (captureNetworkBodies, see main/networkBodyCapture.ts), and the fetch
  // routes plus the file sink (saveResource). See `answeredInMain`.
  registerControlVerb('readNetworkRequests', answeredInMain('readNetworkRequests'))
  registerControlVerb('captureNetworkBodies', answeredInMain('captureNetworkBodies'))
  registerControlVerb('saveResource', answeredInMain('saveResource'))
}
