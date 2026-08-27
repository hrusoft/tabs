import type { PluginIpc } from '../../../renderer/src/plugin/api'
import { BrowserGuestEvent } from '../shared/ipc'

/**
 * Makes a press inside a browser pane's page activate that pane, the way
 * clicking any other pane's content already does through `Pane`'s own
 * `onClick`.
 *
 * The press cannot be seen from this process at all — a `<webview>` guest
 * emits no host DOM event, not even a `focus` on the element — so main watches
 * the guest's input pipeline and sends the pane id over the `browserGuest`
 * bridge channel (see src/plugins/browser/main/guestActivation.ts, which holds
 * the measurements).
 *
 * The subscription lives here rather than in core for the same reason
 * guestNavKeys.ts's does: the channel is the browser's, and core depending on
 * a bridge namespace named after one content type is exactly the coupling that
 * inverts. Core needs no new export either — `setActivePane` is the same store
 * action `Pane` calls.
 *
 * Routing through `setActivePane` rather than doing anything float-specific is
 * also what keeps a floating browser pane cheap to raise: the store's own raise
 * reorders `state.floating` only, and `FloatingLayer` renders in a stable
 * id-sorted order with an explicit `z-index`, so the raise moves no element and
 * cannot reload the guest page (see CLAUDE.md).
 *
 * Kept free of any import from browserExternalControl.ts on purpose — the
 * suppression flag below lives here rather than there so the jsdom/Chromium
 * tiers can install this forwarder (registerTestContent.ts) without dragging
 * the verb module's graph in behind it, the same property that lets them
 * install guestNavKeys.ts's.
 */

/**
 * How many of this app's own input injections are in flight against a guest.
 *
 * A counter rather than a boolean because two socket clients can have verbs
 * running at once, and the inner one finishing must not clear the outer one's
 * scope.
 */
let injecting = 0

/**
 * Marks the app as injecting input into a guest until the returned release is
 * called; while marked, guest presses do not activate their pane.
 *
 * Needed because an injected `mouseDown` is indistinguishable from the user's
 * at the guest — measured: `webview.sendInputEvent` produces the identical
 * `mouseMove, mouseDown, mouseUp` sequence a real click does, so nothing at
 * the observation point can tell them apart and the app has to say so itself.
 * The one difference that *is* observable (a synthetic event carries
 * `globalX`/`globalY` of 0) is undocumented and would mis-fire for a real
 * click at the top-left screen pixel — deliberately not built on.
 *
 * The caller is `withHostFocusRestored` in browserExternalControl.ts, which
 * wraps exactly the verbs that inject a press.
 */
export function suppressGuestActivation(): () => void {
  injecting++
  let released = false
  return () => {
    if (released) return
    released = true
    injecting--
  }
}

/**
 * Subscribes to guest presses and activates their pane. The bridge's
 * unsubscriber is dropped, not returned — registration happens once per window
 * at module scope and is never undone (see installGuestNavForwarding).
 *
 * Both dependencies are parameters rather than reads of this package's
 * context so the non-Electron test tiers can install the forwarder without
 * activating the package (registerTestContent.ts passes core's own
 * setActivePane and a browser-scoped ipc it builds itself; this package's
 * activate passes its context's) — the same injection shape as
 * installGuestNavForwarding, and the same reason this module holds its own
 * suppression flag instead of importing the verb module's.
 */
export function installGuestActivation(
  ipc: PluginIpc,
  activatePane: (paneId: string) => void
): void {
  ipc.on(BrowserGuestEvent.pointerDown, (paneId) => {
    // An agent driving this pane must not steal the active pane out from under
    // the user. Accepted residual: a genuine user click into that same guest
    // during the ~50ms an input verb holds this is swallowed — see the note on
    // withHostFocusRestored.
    if (injecting > 0) return
    // No wasRecentlyDragged/isSplitResizing guard, unlike Pane's onClick: a
    // pane drag or split resize captures the pointer on the host, so the guest
    // never sees a press from one.
    activatePane(paneId as string)
  })
}
