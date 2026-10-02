import type { WebContents } from 'electron'
import { BrowserGuestEvent } from '../shared/ipc'
import { getPaneIdForGuest } from './browserGuestRegistry'
import { sendToEmbedder } from './guestSend'

/**
 * Makes clicking into a browser pane's page activate that pane, the way
 * clicking any other pane's content does.
 *
 * It needs main at all because **a press inside a `<webview>` guest produces
 * no host DOM event of any kind**. Measured directly, with capture-phase
 * listeners on `window` for focus/focusin/pointerdown/mousedown/click/wheel
 * *and* direct focus/blur listeners on the `<webview>` element: a real click
 * in the middle of a guest logged nothing at all, while the same instrumentation
 * logged five events for a click on the pane's own address bar. `Pane`'s
 * `onClick` is therefore not merely out-propagated — it is unreachable, so the
 * activation has to be observed on the guest `WebContents` and sent back.
 *
 * Sibling of guestNavKeys.ts and deliberately a separate module from it: that
 * one earns its isolation by needing nothing but the chord table, while this
 * one needs the guest→pane mapping in browserGuestRegistry.ts. The mapping is
 * read per *event*, never at attach — the renderer reports it only after this
 * handler has already run (see main/index.ts, whose `will-navigate` and
 * popup handlers resolve it the same way).
 */

/**
 * Reports a press inside `guest`'s page to the window hosting it.
 *
 * Called from `main/index.ts`'s `wireGuest`, which owns the once-per-guest
 * rule for every wiring here, and which hangs off `did-attach-webview` — the only
 * hook that survives the guest-id churn: a structural reparent (a pane drag, a
 * tab group collapsing) destroys the guest `WebContents` and builds a new one,
 * and the event fires again for the replacement. Verified by measurement —
 * wrapping a browser pane in a tab group took the guest from id 2 to id 3, the
 * event fired for both, and a click after the reparent registered on id 3.
 *
 * `input-event` rather than `webContents.on('focus')`: the latter **never
 * fires for a guest on macOS**, measured across a click that visibly moved
 * `document.activeElement` to the `<webview>` and across a programmatic
 * `webview.focus()`. That matches Electron's own note that having focus means
 * being the window's first responder — which a guest never is.
 *
 * Filtering on `mouseDown` is what satisfies "scrolling must not activate"
 * structurally rather than heuristically. Measured event types for a wheel or
 * trackpad scroll over a guest: `mouseMove`, `mouseWheel`, `gestureScrollBegin`,
 * `gestureScrollUpdate`, `mouseWheel`, `gestureScrollEnd` — a scroll simply
 * never produces the type this listens for, so a background browser pane can be
 * scrolled while staying inactive, exactly like a background macOS window.
 *
 * **Any press activates, and that is a decision, not an oversight.** A
 * scrollbar drag is a `mouseDown` (measured), as are right- and middle-clicks,
 * and all of them activate — which is what macOS does when you click a
 * background window's scrollbar. Don't "fix" this by hit-testing the press
 * against the scrollbar gutter: it costs a round-trip into the guest per press
 * and gets overlay-scrollbar geometry wrong anyway, to protect an interaction
 * the ticket never asked to protect.
 */
export function wireGuestActivation(guest: WebContents): void {
  guest.on('input-event', (_event, input) => {
    // First line on purpose: this fires for every input event routed to the
    // guest, one per mouse move while hovering (measured 40 for 40 moves, with
    // no raw-pointer coalescing to soften it), so everything below must be
    // behind the cheapest possible test.
    if (input.type !== 'mouseDown') return
    const paneId = getPaneIdForGuest(guest.id)
    if (paneId === undefined) return
    sendToEmbedder(guest, BrowserGuestEvent.pointerDown, paneId)
  })
}
