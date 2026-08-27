import type { NodeId } from '@shared/model/types'
import { isSplit, isTabs } from '@shared/model/types'
import { useLayoutEffect, useRef } from 'react'
import { findNodeAnywhere, useLayoutStore } from '../store/layoutStore'

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
 *
 * Deliberately separate from `reattachRegistry`: that one caches an instance
 * *across* an unmount for a grace period, while this one tracks what is
 * mounted *right now* — and acquiring from the reattach registry outside
 * React, without a matching release, would leak its grace timer. Both are
 * needed; neither substitutes for the other.
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

const handles = new Map<NodeId, PaneHandle>()

/**
 * Calls a handle's `focus`/`blur` without letting a content type take the
 * window down with it.
 *
 * Every call site below is a layout effect or runs inside one, and React
 * answers a throw from a layout effect by unmounting the whole tree: the
 * window goes blank, and because `persistLayout` is debounced, whatever the
 * user had just done never reaches disk — so the next launch restores the
 * state from before it and the whole thing reads as a crash rather than as a
 * focus bug. That is not hypothetical; it is what a `<webview>` whose guest
 * was momentarily gone did (see BrowserRenderer's focusGuest), and the reason
 * the isolation belongs *here* is that the browser is only the content type
 * that found it. Focus is a best-effort side effect, not something core can
 * act on the failure of, so the same boundary main's control dispatch draws
 * around a verb handler — a throw becomes a report, never a crash — is the
 * right one for a pane handle too.
 */
function dispatchFocus(handle: PaneHandle | undefined, method: 'focus' | 'blur'): void {
  try {
    handle?.[method]?.()
  } catch (error) {
    console.error(`pane handle ${method}() threw`, error)
  }
}

/**
 * Registers the mounted handle for `id`; returns the unregister function. A
 * reattach is routine, not a conflict: the guard makes a stale disposer (an
 * old mount unregistering after its replacement registered) a no-op, the
 * same idiom as main's paneHostRegistry.
 */
export function registerPaneHandle(id: NodeId, handle: PaneHandle): () => void {
  handles.set(id, handle)
  // A pane that mounts already-active focuses itself — the activation
  // happened before any renderer existed to hear about it. Agent-created
  // panes are exempt: an agent opening a pane must not yank the keyboard
  // away from the terminal the user is typing in (the same stance as
  // externalControl's withHostFocusRestored and its focus-stealing e2e test).
  const state = useLayoutStore.getState()
  if (id === state.activePaneId) {
    const node = findNodeAnywhere(state, id)
    const agentCreated =
      node !== null && !isTabs(node) && !isSplit(node) && node.agentCreated === true
    if (!agentCreated) dispatchFocus(handle, 'focus')
  }
  return () => {
    if (handles.get(id) === handle) handles.delete(id)
  }
}

/**
 * Hands the keyboard back to a pane's content — what a transient overlay calls
 * on the way out (see CommandPalette.tsx). Goes through the same isolation as
 * core's own focus dispatch, so a content type that throws can't escape into
 * whichever caller happens to be on the stack.
 */
export function focusPane(id: NodeId): void {
  dispatchFocus(getPaneHandle(id), 'focus')
}

/** The mounted handle for `id`, or undefined if no renderer currently holds that pane. */
export function getPaneHandle(id: NodeId): PaneHandle | undefined {
  return handles.get(id)
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
 */
export interface PaneCapabilities {
  clear: () => void
  refresh: () => void
}

/**
 * The named capability a mounted pane offers, or undefined if it offers none.
 *
 * Duck-typed on the extension rather than checked against the pane's content
 * type on purpose: these are core capabilities any content type may claim by
 * exposing the method, which is why the narrowing lives here rather than in
 * the implementing module — today's only implementer shouldn't be what a
 * second one has to import through. One lookup for every capability rather
 * than a getter per name, so the next one core dispatches (stop, print) is a
 * key on `PaneCapabilities` and a shortcut binding, not another copy of this
 * function. On a pane that offers none (a browser asked to clear, an empty
 * pane) the shortcut is a silent no-op rather than an error.
 */
export function getPaneCapability<K extends keyof PaneCapabilities>(
  id: NodeId,
  capability: K
): PaneCapabilities[K] | undefined {
  const extension = getPaneHandle(id)?.extension as Partial<PaneCapabilities> | undefined
  const method = extension?.[capability]
  return typeof method === 'function' ? method.bind(extension) : undefined
}

/**
 * Makes keyboard focus follow the active-pane highlight for every content
 * type: keyboard navigation (unlike a click) moves the highlight without any
 * pointer event for the content to focus on, so typing would otherwise keep
 * landing in the previously focused pane. Renders nothing — App mounts it
 * once (last, so its effect runs after every other in the commit).
 *
 * **A component with a layout effect, rather than the plain store
 * subscription this used to be, because *when* the focus lands is the whole
 * problem.** A tab switch writes two values back to back — `activateTab` then
 * `setActivePane` (TabBar.tsx, spatialNav.ts) — and a store subscriber runs
 * synchronously between the write and React's commit, i.e. while the tab being
 * revealed still carries `hidden` (TabsRenderer.tsx), which is `display:
 * none`. `focus()` there is *silently* refused, so the pane's content never
 * got the keyboard while the highlight moved anyway: a TUI in the newly shown
 * terminal rendered unfocused and swallowed nothing typed at it. A split never
 * showed the bug — both panes are visible throughout — and neither did opening
 * a *new* tab, whose fresh pane self-focuses from `registerPaneHandle` below,
 * already after the commit. A layout effect runs after that same commit and
 * before paint, so the pane it focuses is on screen with no unfocused frame.
 *
 * Deliberately not a `queueMicrotask`/`requestAnimationFrame` deferral of the
 * old subscriber: microtask ordering depends on which zustand listener
 * registered first, which shifts as panes mount and remount, and rAF is
 * throttled for a window that is never shown — which is exactly how the e2e
 * suite runs the app.
 *
 * Reads the id through a selector rather than wrapping `setActivePane`,
 * because `withOwner` re-resolves `activePaneId` on close/normalize without
 * anyone calling the action. Its own component rather than a hook in App:
 * App subscribes only to `state.root`, and adding `activePaneId` there would
 * re-render the whole content tree on every activation.
 */
export function PaneFocusFollower(): null {
  const activePaneId = useLayoutStore((state) => state.activePaneId)
  const previous = useRef(activePaneId)
  useLayoutEffect(() => {
    // Also what makes StrictMode's remount a no-op rather than a spurious
    // focus: the ref is re-seeded with the current id.
    if (previous.current === activePaneId) return
    const deactivated = previous.current
    previous.current = activePaneId
    dispatchFocus(getPaneHandle(deactivated), 'blur')
    focusPane(activePaneId)
  }, [activePaneId])
  return null
}
