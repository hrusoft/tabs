import { installGuestActivation } from '../../../plugins/browser/renderer/guestActivation'
import { installGuestNavForwarding } from '../../../plugins/browser/renderer/guestNavKeys'
import { registerStructuralContent } from '../content/registerStructural'
import { dispatchNavChord } from '../content/spatialNav'
import { contentRegistry } from '../core/registry/registry'
import { useLayoutStore } from '../core/store/layoutStore'
import { createRendererPluginContext } from '../plugin/context'
import { stubContentDef } from './stubContent'

/**
 * The test tiers' stand-in for registerBuiltins: the same structural renderers
 * in the same order (shared outright, see registerStructural.ts), but with the
 * stub def where terminal and browser would be — deliberately NOT
 * registerBuiltins itself, whose import would pull in TerminalRenderer (xterm
 * and its CSS) and BrowserRenderer (the Electron-only `<webview>` tag).
 * Idempotent under the same guard registerBuiltins uses.
 *
 * The stub stands in for both of the browser's guest forwarders too. That is
 * real coverage, not bookkeeping: since core stopped subscribing to the guest
 * channels itself, `window.api.browserGuest.onNavKey` and `.onPointerDown` are
 * reached only through a content type's registration, and this is the cheapest
 * tier that can exercise those paths (drive them with `__fakeApi.emitNavKey` /
 * `emitGuestPointerDown`). Importing them here is safe where importing the
 * browser's renderer would not be — each is a few lines over the bridge and
 * pulls in no `<webview>`, which is why guestActivation.ts holds its own
 * suppression flag instead of importing it from the verb module. They take
 * their dependencies as parameters for exactly this tier's benefit: here
 * core's own dispatchNavChord/setActivePane are passed directly with a
 * browser-scoped ipc built on the spot (context creation is side-effect
 * free), where the browser package's activate passes its own context's —
 * same wiring, no activation needed.
 */
export function registerTestContent(): void {
  if (contentRegistry.has('tabs')) return
  registerStructuralContent()
  contentRegistry.register(stubContentDef)
  const browserIpc = createRendererPluginContext('browser').ipc
  installGuestNavForwarding(browserIpc, dispatchNavChord)
  installGuestActivation(browserIpc, (paneId) => useLayoutStore.getState().setActivePane(paneId))
}
