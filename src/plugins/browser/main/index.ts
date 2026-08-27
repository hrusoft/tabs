import type { BrowserWindow, WebContents } from 'electron'
import type { MainPluginContext, MainPluginModule } from '../../../main/plugin/api'
import { resetAgentFileSweepForTests } from './agentFiles'
import { registerBrowserControlVerbs } from './browserExternalControl'
import {
  getPaneIdForGuest,
  registerBrowserGuestIpc,
  resetBrowserGuestsForTests
} from './browserGuestRegistry'
import { wireGuestActivation } from './guestActivation'
import { resetGuestDebuggersForTests } from './guestDebugger'
import { wireNavKeyForwarding } from './guestNavKeys'
import { resetNetworkBodyCaptureForTests } from './networkBodyCapture'
import { browserMainCtx } from './pluginContext'
import { isAllowedUrl } from './urlPolicy'

/**
 * Everything about `<webview>` guests in the pane-tree window: that the window
 * permits them at all, the terms any guest is attached on, and what an embedded
 * page may then do.
 *
 * All three live here together, and that is the security argument rather than a
 * tidiness one. `webviewTag` is a window-*creation* option, so it arrives
 * through `windowPreferences` (core merges it in createWindow) while the
 * hardening arrives through `wireWindow` — but both come from this module, so a
 * build without this content type registered does not permit webviews *at all*,
 * and has nothing left to harden. The alternative — core granting the
 * capability unconditionally so it can guarantee the hardening — makes core's
 * window carry one content type's requirement forever, and gives the next
 * type needing a constructor flag nowhere to put it.
 */

/**
 * Guests already wired, so a repeated attach of the same guest can't stack a
 * second set of listeners. Ids are never reused within a run, and each entry
 * evicts itself when its guest is destroyed — the same self-managing shape as
 * shortcuts.ts's `watched`, so nothing outside this module knows it exists.
 */
const wiredGuests = new Set<number>()

/**
 * Everything that hangs off a single guest `WebContents`, wired exactly once.
 *
 * The dedupe lives here rather than inside each wiring because it is one rule
 * about one object, not a per-listener concern: each wiring below would
 * otherwise keep its own id set, its own `destroyed` eviction and its own
 * test-reset, and the third one would copy all three again.
 *
 * The two forwarding wirings report back through `sendToEmbedder`
 * (guestSend.ts) for the same reason: it states once why the embedder is the
 * target and why the send is guarded, so neither rule is restated beside
 * each `send`.
 */
function wireGuest(guest: WebContents): void {
  if (wiredGuests.has(guest.id)) return
  wiredGuests.add(guest.id)
  // A destroyed guest takes its own listeners with it, so only the dedupe
  // entry needs releasing — and it releases itself here rather than being
  // evicted by the pane registry's clearGuest, which would tie these
  // listeners' lifetime to the renderer's *pane detach report* rather than to
  // the guest itself.
  guest.once('destroyed', () => wiredGuests.delete(guest.id))
  // Wired here rather than off the renderer's own attach report so there's no
  // window where a guest is already focused and typable but has no escape path
  // yet — see wireNavKeyForwarding's doc comment.
  wireNavKeyForwarding(guest)
  wireGuestActivation(guest)
  // Mirrors the host window's own popup policy: a target=_blank link or
  // window.open() inside an embedded page opens in the OS's real browser
  // instead of silently no-op'ing (Electron denies webview popups by default
  // with no handler attached). Agent-owned panes are the exception — a page
  // an agent is driving must not be able to reach outside its pane into the
  // user's real browser, so its popups are denied without the external open.
  // Ownership is resolved per event, not at attach: the guest registers with
  // main only after the attach handler that reaches here has already run.
  guest.setWindowOpenHandler((details) => {
    const ctx = browserMainCtx.get()
    const paneId = getPaneIdForGuest(guest.id)
    if (!(paneId !== undefined && ctx.isOwnedPane(paneId))) ctx.openExternalUrl(details.url)
    return { action: 'deny' }
  })
  // For agent-owned panes, re-apply the verb-level scheme allowlist to
  // navigations the *page* starts (location.href from execute-js, a link
  // click) — without this, the file:// front-door check in
  // externalControl.ts has an open back door. User panes are left alone;
  // this constrains only what an agent's own pane can be steered to.
  guest.on('will-navigate', (event, url) => {
    const paneId = getPaneIdForGuest(guest.id)
    if (paneId !== undefined && browserMainCtx.get().isOwnedPane(paneId) && !isAllowedUrl(url)) {
      event.preventDefault()
    }
  })
}

function wireBrowserGuests(window: BrowserWindow): void {
  // Defense in depth for the `webviewTag` this module asks for: BrowserRenderer
  // never sets a preload/nodeintegration attribute on its own <webview>
  // elements, so guests already get Electron's secure defaults — this refuses
  // to honor either if something ever tried to smuggle them onto the element.
  window.webContents.on('will-attach-webview', (_event, webPreferences) => {
    delete webPreferences.preload
    webPreferences.nodeIntegration = false
  })
  // Every guest wiring hangs off this same event, and must: a structural
  // reparent destroys the guest and builds a new one, and this is where the
  // replacement is handed over (see wireGuestActivation). Everything
  // per-guest lives inside wireGuest so the dedupe covers it by construction
  // — a wiring registered here directly would stack on a repeated attach,
  // which for will-navigate means N preventDefault guards on the security
  // path.
  window.webContents.on('did-attach-webview', (_event, contents) => {
    wireGuest(contents)
  })
}

/**
 * The browser package's main-process entry. Guest IPC registers first, then
 * this type's external-control verbs — the latter must be claimed before
 * registerExternalControlServer starts accepting socket connections, which
 * whenReady's ordering guarantees (see contentTypes.ts).
 */
export function activate(ctx: MainPluginContext): MainPluginModule {
  browserMainCtx.set(ctx)
  registerBrowserGuestIpc(ctx.ipc)
  registerBrowserControlVerbs(ctx)
  return {
    /** Without this the pane-tree window ignores `<webview>` elements entirely. */
    windowPreferences: { webviewTag: true },
    wireWindow: wireBrowserGuests,
    /**
     * Every map here is keyed by a guest's webContents id, and every one of
     * those is invalid the moment the renderer reloads — which is exactly what
     * the reset does next. resetBrowserGuestsForTests also clears the network
     * log, which is keyed the same way.
     */
    resetForTests() {
      resetBrowserGuestsForTests()
      // Body capture first releases its leases in an orderly way; the
      // debugger reset after it force-detaches whatever survived.
      resetNetworkBodyCaptureForTests()
      resetGuestDebuggersForTests()
      resetAgentFileSweepForTests()
      wiredGuests.clear()
    }
  }
}
