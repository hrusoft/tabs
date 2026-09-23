import type { ControlRequest, ControlResponse } from '@shared/externalControl'
import * as tree from '@shared/model/tree'
import type { ContentNode } from '@shared/model/types'
import type { WebviewTag } from 'electron'
import { BROWSER_TYPE } from '../shared/manifest'
import { getBrowserPane } from './browserControl'
import { browserCtx } from './pluginContext'
import { browserPaneError } from './verbSupport'

/**
 * The core pane-tree verbs whose targets are browser panes by definition:
 * activatePane, closePane, listOwnedPanes, getPaneInfo.
 */

/** Every browser leaf in the tree, with whatever URL/title the layout currently knows for it. */
function collectBrowserPanes(node: ContentNode): { paneId: string; url: string; title: string }[] {
  return tree
    .collectLeaves(node)
    .filter((leaf) => leaf.type === BROWSER_TYPE)
    .map((leaf) => ({
      paneId: leaf.id,
      url: (leaf.config.url as string | undefined) ?? '',
      title: leaf.title ?? ''
    }))
}

/**
 * Brings the pane onto the screen by activating every ancestor tab between it
 * and the root (see `revealPane`, which is core's — the pane-tree walk has
 * nothing browser-specific in it). Focus is deliberately left alone; this
 * makes the pane *visible*, chiefly so `screenshot` has a frame to capture —
 * a hidden guest paints nothing — and does not grab the user's keyboard.
 *
 * The browser check is this module's, not core's: main hands out a
 * `targetPaneId` only to the caller that created it via `createBrowserPane`
 * (see `ownerOf` in src/main/externalControl.ts), so "still a browser pane" is
 * that ownership model's own precondition rather than a rule about panes.
 */
export function handleActivatePane(
  request: Extract<ControlRequest, { type: 'activatePane' }>
): ControlResponse {
  const paneError = browserPaneError(request.targetPaneId)
  if (paneError) return { ok: false, error: paneError }
  browserCtx.get().layout.revealPane(request.targetPaneId)
  return { ok: true }
}

export function handleClosePane(
  request: Extract<ControlRequest, { type: 'closePane' }>
): ControlResponse {
  // Unlike the guest verbs this doesn't need a mounted renderer — closing a
  // pane is a pure tree operation — but it does need the id to still name a
  // browser pane, so a stale id can't close whatever now sits in its place.
  const paneError = browserPaneError(request.targetPaneId)
  if (paneError) return { ok: false, error: paneError }
  browserCtx.get().layout.closePane(request.targetPaneId)
  return { ok: true }
}

/**
 * Every browser pane in the layout — main narrows this to the ones the caller
 * actually owns before it answers the socket, since ownership lives there
 * (see `ownerOf` in src/main/externalControl.ts) and never reaches this
 * process.
 */
export function handleListOwnedPanes(): ControlResponse {
  // Every tree, not just the docked one: an agent's own pane must not
  // vanish from its list the moment the user unpins it.
  const panes = browserCtx.get().layout.allRoots().flatMap(collectBrowserPanes)
  return { ok: true, result: { panes } }
}

/**
 * The pane's live state, and the two things it used to report dishonestly.
 *
 * **`showingErrorPage`.** `getURL()` is Chromium's *visible* URL — the one the
 * address bar keeps after a failed navigation — not the committed document,
 * which is `chrome-error://chromewebdata/`. So a pane sitting on a network
 * error reported the URL that was asked for, with nothing to distinguish "I am
 * looking at the page I wanted" from "I am looking at an error page wearing
 * its address". `url` is deliberately left alone rather than switched to the
 * committed one: every caller compares it against what they navigated to, and
 * the internal scheme would tell them less than the ERR_* name does. The flag
 * and `loadError` are added beside it instead, read from the instance's own
 * `loadFailure` — which is cleared on `did-start-loading` and set on
 * `did-fail-load`, i.e. exactly the lifetime of "an error page is showing".
 *
 * **`viewport` on a hidden pane.** A backgrounded tab lives in a `display:
 * none` subtree (TabsRenderer keeps every tab mounted), so its element rect is
 * 0×0 — and the old shape reported `viewport: {width: 0, height: 0}` next to
 * `isLoading: false`, which reads as "settled, and zero pixels wide" when it
 * means "not laid out, ask again once it's visible". That is structural, not a
 * transient race: it was the answer for *every* backgrounded pane, every time.
 * Rather than report a number no coordinate could safely use, the viewport is
 * omitted and `hidden: true` says why — which also names the remedy, since
 * `activatePane` is what makes it answerable. `checkVisibility()` is the same
 * predicate `screenshot` already gates its reveal on, so the two agree about
 * what "showing" means.
 */
export function handlePaneInfo(
  webview: WebviewTag,
  request: Extract<ControlRequest, { type: 'getPaneInfo' }>
): ControlResponse {
  const rect = webview.getBoundingClientRect()
  const visible = webview.checkVisibility()
  const loadError = getBrowserPane(request.targetPaneId)?.lastLoadError() ?? null
  return {
    ok: true,
    result: {
      paneId: request.targetPaneId,
      url: webview.getURL(),
      title: webview.getTitle(),
      isLoading: webview.isLoading(),
      canGoBack: webview.canGoBack(),
      canGoForward: webview.canGoForward(),
      ...(loadError ? { showingErrorPage: true as const, loadError } : {}),
      // The guest's own viewport, which is the coordinate space every {x,y}
      // input target is expressed in — see handleClick. Absent while hidden,
      // because there is no such space until the pane is laid out.
      ...(visible
        ? { viewport: { width: Math.round(rect.width), height: Math.round(rect.height) } }
        : { hidden: true as const })
    }
  }
}
