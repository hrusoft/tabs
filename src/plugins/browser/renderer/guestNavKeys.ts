import type { NavDirection } from '@shared/model/navigation'
import type { PluginIpc } from '../../../renderer/src/plugin/api'
import { BrowserGuestEvent } from '../shared/ipc'

/**
 * Feeds core's spatial navigation the presses it structurally cannot hear.
 *
 * A focused `<webview>` guest swallows every keydown before the host window
 * sees it, so without this, navigation could move focus *into* a browser pane
 * but never back out. Main watches the guest instead (`before-input-event`,
 * see src/plugins/browser/main/guestNavKeys.ts) and sends the matched direction over the
 * `browserGuest` bridge channel.
 *
 * The subscription lives here rather than in spatialNav.ts because that
 * channel is the browser's: core depending on a bridge namespace named after
 * one content type is exactly the coupling this inverts. Core exposes
 * `dispatchNavChord`; whoever has presses to contribute brings them.
 *
 * Both dependencies are parameters rather than reads of this package's
 * context so the non-Electron test tiers can install the forwarder without
 * activating the package (registerTestContent.ts passes core's own
 * dispatchNavChord and a browser-scoped ipc it builds itself; this package's
 * activate passes its context's). Same shape as installGuestActivation, and
 * for the same reason.
 *
 * Note this is the renderer half of a binding enforced in three places at once
 * — see the three-enforcer note in CLAUDE.md. The chord matching itself is not
 * duplicated here: main has already done it through the shared
 * `navDirectionForChord`, so what arrives is a direction, not a key.
 */
export function installGuestNavForwarding(
  ipc: PluginIpc,
  dispatch: (direction: NavDirection) => void
): void {
  // The bridge's unsubscriber is dropped, not returned: registration happens
  // once per window at module scope and is never undone, the same one-way shape
  // as registerControlVerb and registerSettingsPage.
  ipc.on(BrowserGuestEvent.navKey, dispatch as (...args: unknown[]) => void)
}
