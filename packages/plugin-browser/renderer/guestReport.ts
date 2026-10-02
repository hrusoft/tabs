/**
 * Reporting which guest `WebContents` currently backs a browser pane — the
 * mapping every webContentsId-keyed feature resolves a pane through (network
 * capture, click-to-activate, popup ownership, the will-navigate allowlist).
 *
 * A module of its own, small as it is, because the hard part is *when* the id
 * can be read and that is not testable through a `<webview>`: this tier has no
 * Electron. Splitting the decision from the DOM wiring lets the contract be
 * asserted deterministically (see __tests__/guestReport.test.ts), where the
 * e2e tier can only observe the race it protects against.
 */

/**
 * Builds the reporter for one pane. `readGuestId` is expected to **throw**
 * until the guest is really attached — that is the whole reason this exists —
 * and `send` is the bridge call.
 *
 * The trap it encodes: `<webview>`'s `did-attach` event is *not* late enough to
 * read the id. `getWebContentsId()` throws "The WebView must be attached to the
 * DOM and the dom-ready event emitted before this method can be called" right
 * up until the guest exists, and measurement says that is not a same-tick
 * ordering quirk — at `did-attach` it throws, in the following *microtask* it
 * still throws, and it first succeeds on the next *macrotask*. Only the very
 * first browser pane of a window wins the synchronous attempt.
 *
 * Calling it bare inside a DOM event handler therefore threw where nothing
 * surfaces it, and the report was silently never sent: main simply never
 * learned the pane's guest, and every feature above behaved as if the pane had
 * none. Click-to-activate was the first one whose failure was visible.
 *
 * So the returned `report` is safe to call from as many points as it takes, and
 * the caller calls it from three (see BrowserRenderer): synchronously at
 * `did-attach`, on the next macrotask, and at `dom-ready` — the precondition
 * Electron's own error message names, and the backstop for a page slow enough
 * to lose the other two. Repeat calls are free; only a genuinely new guest id
 * sends.
 */
export function createGuestReporter(
  paneId: string,
  readGuestId: () => number,
  send: (paneId: string, guestId: number) => void
): () => void {
  let reported: number | null = null
  return () => {
    let guestId: number
    try {
      guestId = readGuestId()
    } catch {
      // Not attached yet — a later call from one of the caller's other
      // report points wins. Swallowed rather than logged: this is the
      // expected state for the first attempt on every pane but the first.
      return
    }
    // A structural reparent builds a *new* guest under the same element, so
    // a changed id is news and must be re-sent; an unchanged one is one of
    // the redundant report points and is dropped, which is what keeps this
    // at one IPC per guest rather than one per navigation.
    if (guestId === reported) return
    reported = guestId
    send(paneId, guestId)
  }
}
