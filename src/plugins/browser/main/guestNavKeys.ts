import type { WebContents } from 'electron'
import { platform } from '../../../main/plugin/api'
import type { NavDirection } from '../../../shared/model/navigation'
import { navDirectionForChord } from '../../../shared/shortcuts'
import { BrowserGuestEvent } from '../shared/ipc'
import { sendToEmbedder } from './guestSend'
import { browserMainCtx } from './pluginContext'

/**
 * The third place a nav binding is enforced, alongside the renderer's keydown
 * handler (content/spatialNav.ts) and the application menu (menu.ts's
 * buildMenu) — see shared/shortcuts.ts for the whole picture.
 *
 * It exists because a focused `<webview>` guest swallows every keydown before
 * the host page can see it, so without this spatial navigation could move
 * focus *into* a browser pane but never back out. That makes it a
 * keyboard-shortcut concern that merely happens to act on guests: it shares
 * nothing with the guest↔pane mapping in browserGuestRegistry.ts, which is why
 * it lives in its own module and manages its own state end to end.
 */

/**
 * Which direction (if any) a guest keypress should move focus. The adapter from
 * Electron's `Input` to a `KeyChord` is all that's specific to this enforcer —
 * the action table and the matching rule are shared with the renderer's own
 * handler (see navDirectionForChord).
 */
function navDirectionFor(input: Electron.Input): NavDirection | undefined {
  return navDirectionForChord(
    browserMainCtx.get().settings.get(),
    {
      code: input.code,
      meta: input.meta,
      ctrl: input.control,
      alt: input.alt,
      shift: input.shift
    },
    platform
  )
}

/**
 * Forwards cmd/ctrl+arrow presses out of a focused guest to the window hosting
 * it. The modifier check mirrors the renderer's exactly: the platform modifier
 * exclusively, with no alt/shift.
 *
 * Called from `main/index.ts`'s `wireGuest`, which hangs off
 * `did-attach-webview`, not from the guest registry's `setGuest`: that event
 * fires synchronously as Electron attaches the guest, strictly before the
 * renderer's own `did-attach` DOM event can fire and send its fire-and-forget
 * attach report. Wiring off the renderer's report instead left a window where a
 * guest was already focused and typable but had no escape path yet — a keypress
 * landing there is swallowed, not delayed, since this is a one-shot event
 * forward with nothing to retry. Taking the guest `WebContents` directly (rather
 * than a `webContentsId` to re-resolve) mirrors what the caller already has in
 * hand at that event.
 *
 * Rebinding a nav action without updating this would leave navigation working
 * everywhere *except* inside a browser pane — which reads as a browser-pane bug
 * rather than a shortcut one, so both sides resolve from shared/shortcuts.ts.
 */
export function wireNavKeyForwarding(guest: WebContents): void {
  guest.on('before-input-event', (event, input) => {
    if (input.type !== 'keyDown') return
    const direction = navDirectionFor(input)
    if (!direction) return
    event.preventDefault()
    sendToEmbedder(guest, BrowserGuestEvent.navKey, direction)
  })
}
