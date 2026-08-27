import {
  entryPaneId,
  type NavDirection,
  type NavTarget,
  navTarget,
  pickSpatialTarget,
  pickWrapTarget
} from '@shared/model/navigation'
import { findNode } from '@shared/model/tree'
import type { ContentNode, NodeId } from '@shared/model/types'
import { PANE_ATTR } from '@shared/paneDomAttrs'
import { navDirectionForChord } from '@shared/shortcuts'
import { platform } from '../core/platform'
import { useDragStore } from '../core/store/dragStore'
import { ownerRootOf, useLayoutStore } from '../core/store/layoutStore'
import { useNavFlashStore } from '../core/store/navFlashStore'
import { useSettingsStore } from '../core/store/settingsStore'
import { paneDomRect } from './paneDom'

/**
 * Cmd+arrow (ctrl+arrow off mac, or whatever the user has rebound it to — see
 * shared/shortcuts.ts) moves pane focus one step through the layout
 * hierarchy: `navTarget` walks up from the active pane to the first ancestor
 * with somewhere to go in the pressed direction — a sibling across a split, or
 * the next tab of an enclosing group (left/right only; up/down never reveal a
 * hidden tab) — and the DOM then decides which pane inside that subtree to
 * land on, so entering a column from the bottom row stays in the bottom row.
 * A press that runs off the outermost container wraps it around, and if even
 * that has nowhere to go, focus wraps to the pane at the opposite edge of the
 * window. Every handled press flashes the direction indicator (unless
 * disabled in Settings), even when there is nowhere to go.
 *
 * Navigation stays inside one tree: from a docked pane it only ever reaches
 * docked panes, from a pane in a floating window only panes in that same
 * window. A float has no hierarchical relationship to the docked layout, so
 * any crossing rule would be pure geometry — which is exactly what the "a
 * move crosses one boundary of the layout hierarchy" contract in
 * `navTarget` exists to avoid. Crossing between the two is a click.
 */

/** Installs the window-level navigation key handler; returns its uninstaller. */
export function installSpatialNav(): () => void {
  // Capture phase so navigation wins over xterm's own keydown handling on a
  // focused terminal.
  window.addEventListener('keydown', onKeyDown, { capture: true })
  return () => {
    window.removeEventListener('keydown', onKeyDown, { capture: true })
  }
}

/**
 * The direction `event` is bound to, if any. Every modifier must match exactly
 * — see matchesBinding. The adapter from `KeyboardEvent` to a `KeyChord` is all
 * that's specific to this enforcer; the action table and the matching rule are
 * shared with main's guest handler (see navDirectionForChord). Bindings are read
 * per keypress, so a rebind made in the Settings window applies live —
 * settingsStore already mirrors cross-window changes.
 */
function navDirectionFor(event: KeyboardEvent): NavDirection | undefined {
  return navDirectionForChord(
    useSettingsStore.getState(),
    {
      code: event.code,
      meta: event.metaKey,
      ctrl: event.ctrlKey,
      alt: event.altKey,
      shift: event.shiftKey
    },
    platform
  )
}

function onKeyDown(event: KeyboardEvent): void {
  const direction = navDirectionFor(event)
  if (!direction) return
  if (useDragStore.getState().drag !== null) return
  if (isTextEditingTarget(event.target)) return
  event.preventDefault()
  event.stopPropagation()
  dispatchNavChord(direction)
}

/**
 * One accepted navigation press, whatever surfaced it.
 *
 * Exported because core cannot subscribe to every source itself: a focused
 * `<webview>` guest swallows every keydown before this window sees it, so its
 * presses arrive over a browser-specific bridge channel that only the browser
 * content type should know about. It forwards them here instead (see
 * src/plugins/browser/renderer/guestNavKeys.ts) — already matched against the bindings by
 * main, since the guest's keydown never reaches this process at all.
 *
 * The chord → direction decision itself is never duplicated: both enforcers
 * that make it go through `navDirectionForChord` (see shared/shortcuts.ts).
 * What arrives here is a decision already taken.
 */
export function dispatchNavChord(direction: NavDirection): void {
  if (useDragStore.getState().drag !== null) return
  if (useSettingsStore.getState().showNavFlash) {
    useNavFlashStore.getState().trigger(direction)
  }
  navigate(direction)
}

/**
 * True for text fields the arrows should keep editing rather than navigate
 * away from.
 *
 * Content types opt out with `data-nav-text-input="false"` on an element that
 * would otherwise look like a text field — the contract exists for content
 * that wears an `<input>`/`<textarea>` for reasons of its own while still
 * wanting the app to claim the navigation chord. A terminal is the case today:
 * xterm.js focuses a hidden helper textarea, and Cmd+Arrow there means "move
 * to the next pane", not "move the caret" (see TerminalRenderer).
 *
 * Opt-out rather than opt-in on purpose. The positive polarity would require
 * every genuine text field in the app — the browser address bar, the inline
 * title editor, every Settings input — to mark itself, and a missed one breaks
 * text editing in a way nobody would trace back to here.
 */
function isTextEditingTarget(target: EventTarget | null): boolean {
  if (!(target instanceof HTMLElement)) return false
  if (target.dataset.navTextInput === 'false') return false
  return (
    target instanceof HTMLInputElement ||
    target instanceof HTMLTextAreaElement ||
    target.isContentEditable
  )
}

function navigate(direction: NavDirection): void {
  const state = useLayoutStore.getState()
  const { activePaneId, setActivePane, activateTab } = state
  // The tree the active pane lives in — the docked root, or the floating
  // window holding it. Everything downstream is scoped to this one tree.
  const owner = ownerRootOf(state, activePaneId)
  const target = navTarget(owner, activePaneId, direction)
  if (!target) {
    const wrap = findWrapTarget(owner, activePaneId, direction)
    if (wrap) setActivePane(wrap)
    return
  }
  if (target.tabSwitch) {
    activateTab(target.tabSwitch.groupId, target.tabSwitch.tabId)
    // The tab's content subtree survives activateTab by reference — and is
    // still hidden (so unmeasurable) at this point — so the entry pane comes
    // from the tree already in hand.
    setActivePane(entryPaneId(target.node, direction))
    return
  }
  setActivePane(entryPane(target, activePaneId, direction))
}

/**
 * The pane focus lands on when entering `target.node`: among the panes
 * visible inside that subtree, the one nearest the edge the movement crossed
 * — measured from the DOM, so moving into a column of panes lands in the row
 * the movement came from rather than always its first child. Falls back to
 * the model's own entry pane when there is nothing to measure (an off-screen
 * active pane, or a subtree with no visible pane in it).
 */
function entryPane(target: NavTarget, activePaneId: NodeId, direction: NavDirection): NodeId {
  const currentRect = paneDomRect(activePaneId)
  const fallback = (): NodeId => entryPaneId(target.node, direction)
  if (!currentRect) return fallback()
  // A split renders no pane of its own (see ContentView), so subtree
  // membership comes from the model rather than DOM containment.
  const candidates = visiblePanesIn(target.node).filter((pane) => pane.id !== activePaneId)
  const picked = target.wrapped
    ? pickWrapTarget(currentRect, candidates, direction)
    : pickSpatialTarget(currentRect, candidates, direction)
  return picked ?? fallback()
}

/**
 * The innermost visible panes belonging to `subtree`. Membership comes from
 * the model, not DOM containment — which is what keeps navigation inside one
 * tree, since a floating window's panes carry `data-dock-id` like any other
 * and would otherwise turn up in every query.
 */
function visiblePanesIn(subtree: ContentNode): Array<{ id: NodeId; rect: DOMRect }> {
  return innermostVisiblePanes().filter((pane) => findNode(subtree, pane.id) !== null)
}

/**
 * The innermost visible panes, measured from the live DOM — the model stores
 * no geometry, but every pane div carries `data-dock-id` (see `Pane`). Hidden
 * tabs have zero-size rects and drop out, and a pane wrapping another visible
 * pane (a tab group around its active tab's content) yields to the pane
 * inside it. The element rides along only for that containment filter; the
 * navigation model downstream reads just `id` and `rect`.
 */
function innermostVisiblePanes(): Array<{ id: NodeId; rect: DOMRect; el: HTMLElement }> {
  const all = Array.from(document.querySelectorAll<HTMLElement>(`[${PANE_ATTR.dock}]`))
    .map((el) => ({
      el,
      id: el.getAttribute(PANE_ATTR.dock) ?? '',
      rect: el.getBoundingClientRect()
    }))
    .filter(({ rect }) => rect.width > 0 && rect.height > 0)
  return all.filter(
    (pane) => !all.some((other) => other.el !== pane.el && pane.el.contains(other.el))
  )
}

/**
 * The pane to wrap to when no ancestor of the active pane has anywhere to go
 * in `direction`, not even by wrapping around — e.g. pressing up from a pane
 * that spans the window's full height, whose ancestors are all laid out the
 * other way. Every other visible pane *of the same tree* is eligible (see
 * `pickWrapTarget`), landing on the one nearest the active pane's own
 * row/column so a press always goes somewhere on screen rather than silently
 * doing nothing.
 */
function findWrapTarget(
  owner: ContentNode,
  activePaneId: NodeId,
  direction: NavDirection
): NodeId | null {
  const currentRect = paneDomRect(activePaneId) ?? { left: 0, top: 0, right: 0, bottom: 0 }
  const candidates = visiblePanesIn(owner).filter((pane) => pane.id !== activePaneId)
  return pickWrapTarget(currentRect, candidates, direction)
}
