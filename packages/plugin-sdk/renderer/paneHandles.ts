/**
 * `PaneHandle`/`PaneCapabilities` — the pure contract a mounted pane's
 * instance satisfies. The registry itself (the `handles` map,
 * `registerPaneHandle`/`getPaneHandle`/`getPaneCapability`,
 * `PaneFocusFollower`) is stateful and stays core-owned, in
 * `src/renderer/src/core/registry/paneHandles.ts`, which imports these
 * types back.
 */

/**
 * Which mounted component instance backs each pane id right now, and what
 * content-neutral things can be asked of it — the renderer-side twin of
 * main's paneHostRegistry ("which WebContents backs this pane id"). Content
 * renderers register on mount and unregister on unmount; a pane with no
 * mounted renderer (closed, or its tab never rendered) simply has no handle.
 *
 * Every member is a getter or a closure over refs rather than a captured
 * value: the handle is registered once per pane id, but what it resolves to
 * (the live xterm instance, the live `<webview>` element) is replaced
 * underneath it as the pane reattaches and renavigates.
 */
export interface PaneHandle {
  /**
   * Takes DOM focus for this pane's content. Core calls it when the pane
   * becomes active, and at registration when it already is (a restored
   * layout, a fresh split — the store activates the new pane before its
   * renderer mounts). Implementations must leave focus alone when the user
   * already holds it inside this pane's own chrome (e.g. the browser's
   * address bar), which a click on that chrome will have focused before the
   * pane activation lands. A throw is isolated (see `dispatchFocus`), but a
   * content type that expects one should still say so where it can act on it.
   */
  focus?: () => void
  /**
   * Releases focus this pane's content still holds, when it stops being
   * active. Implementations must guard — by the time a deactivation runs,
   * focus may already belong to the next pane.
   */
  blur?: () => void
  /**
   * Content-specific surface, kept out of the core interface. The content
   * type's own module narrows it (see browserControl.ts) so e.g. external
   * control keeps reaching a browser's live webview while core stays
   * type-agnostic. Capabilities core itself dispatches are narrowed here
   * instead — see getPaneCapability.
   */
  extension?: unknown
}

/**
 * The capabilities core itself dispatches to a mounted pane, as a single
 * record: a content type claims one by exposing a method of that name on its
 * handle's `extension`.
 *
 * - `clear` — clears the pane's screen and scrollback, so scrolling up
 *   afterwards shows nothing. What Clear Buffer (Cmd/Ctrl+K) acts on.
 * - `refresh` — re-reads whatever this pane is showing, in place, with no
 *   loading flash for content that's already on screen. What Refresh
 *   (Cmd/Ctrl+R) acts on.
 * - `captureTransferState` — a serialized snapshot of this pane's visual
 *   state, for the same content type to restore into a fresh instance in
 *   another window (content/crossWindowDrag.ts reads it before a move's
 *   detach). A plain string on the moved leaf's `config`: core relays it,
 *   never inspects it. Undefined when the type has nothing to preserve (a
 *   browser pane's URL already lives in its config).
 * - `prepareCrossWindowDetach` — the pane is about to unmount because it is
 *   moving to another window, not closing. For a type whose reattach cache
 *   would otherwise treat that unmount as "gone, dispose the remote
 *   resource" (the terminal's pty). Returns an undo, run if the detach then
 *   fails, so a primed pane cannot leak its resource on a later real close.
 */
export interface PaneCapabilities {
  clear: () => void
  refresh: () => void
  captureTransferState: () => string | undefined
  prepareCrossWindowDetach: () => (() => void) | undefined
}
