import type { ControlRequest, ControlResponse } from '@shared/externalControl'
import { PANE_GONE_ERROR } from '@shared/externalControl'
import { createLeaf } from '@shared/model/factories'
import * as tree from '@shared/model/tree'
import type { ContentNode } from '@shared/model/types'
import { compilePattern, patternFilterError } from '@shared/ringLog'
import type { WebviewTag } from 'electron'
import type { RendererPluginContext } from '../../../renderer/src/plugin/api'
import type {
  EditingCommand,
  ElementDescription,
  ElementTarget,
  KeyModifier,
  PageElement,
  SemanticTarget
} from '../shared/externalControl'
import {
  ASSERT_CHECK_BUDGET_MS,
  clampWaitPoll,
  clampWaitTimeout,
  DEFAULT_PAGE_TEXT_MAX,
  EDITING_COMMANDS,
  EXECUTE_OUTPUT_KEY,
  EXECUTE_RESULT_MAX,
  LOAD_WAIT_MS,
  MOUNT_WAIT_MS,
  PAGE_TEXT_HARD_MAX,
  SCREENSHOT_BYTES_KEY,
  WAIT_IDLE_QUIET_MS,
  WAIT_MIN_POLL_MS
} from '../shared/externalControl'
import { BrowserMethod } from '../shared/ipc'
import { BROWSER_TYPE, manifest as browserManifest } from '../shared/manifest'
import type { BrowserNewPanePlacement } from '../shared/settings'
import { isTrivialUrlChange } from '../shared/urlComparison'
import { type BrowserPaneHandle, getBrowserPane } from './browserControl'
import { mainFrameLoadError } from './browserRegistry'
import { getBrowserSettings } from './browserSettingsAccess'
import { findElements } from './findElements'
import { suppressGuestActivation } from './guestActivation'
import {
  describePointScript,
  describeSemanticTarget,
  editingCommandScript,
  elementRectScript,
  executeScript,
  fillFocusedScript,
  focusTargetScript,
  hitTestPointScript,
  PAGE_TEXT_SCRIPT,
  type ReadPageFilter,
  readPageScript,
  refResolverExpression,
  scrollScript,
  semanticResolverExpression
} from './pageScripts'
import { delay, type PageWaitSpec, pollUntil, waitForPageCondition } from './pageWait'
import { browserCtx } from './pluginContext'

/**
 * The browser pane's contribution to the external-control protocol: every verb
 * that drives a `<webview>` guest, its own createBrowserPane, the four core
 * pane-tree verbs whose targets are browser panes by definition (activatePane,
 * closePane, listOwnedPanes, getPaneInfo), and the stubs for the verbs main
 * answers alone.
 *
 * Core owns only the transport and the dispatch registry (see
 * ../externalControl.ts); everything that knows what a browser *is* lives
 * here. The type string itself comes from the shared census
 * (`BROWSER_TYPE`), the same way the content def and the main-process module
 * take theirs — this module never restates it.
 *
 * The page-load and webview-mount waits (LOAD_WAIT_MS / MOUNT_WAIT_MS) live in
 * @shared/externalControl so main's relay budgets are derived from them rather
 * than hand-synced above them.
 */

/**
 * What a navigation settled to. `loaded: false` with no error means the page
 * was still loading when the wait ran out — the caller's to keep polling, not
 * a failure; with `loadError` it means Chromium gave up on the load, and the
 * ERR_* name says why (ERR_CONNECTION_REFUSED against a dev server that
 * isn't up being the case agents actually hit).
 */
interface LoadOutcome {
  loaded: boolean
  loadError?: string
}

/**
 * Waits for the guest to stop loading, capturing any main-frame load failure
 * along the way. Event-driven on `did-stop-loading`, with an `isLoading()`
 * poll as the fallback that resolves the cases that emit no loading events
 * at all — a same-document back/forward, or a load that finished before the
 * listener attached.
 */
function waitForLoadEnd(webview: WebviewTag, timeoutMs: number): Promise<LoadOutcome> {
  return new Promise((resolve) => {
    let loadError: string | undefined
    const settle = (loaded: boolean): void => {
      clearTimeout(timer)
      clearInterval(poll)
      webview.removeEventListener('did-stop-loading', onStop)
      webview.removeEventListener('did-fail-load', onFail)
      resolve(loadError ? { loaded: false, loadError } : { loaded })
    }
    const onStop = (): void => settle(true)
    const onFail = (event: Electron.DidFailLoadEvent): void => {
      loadError = mainFrameLoadError(event) ?? loadError
    }
    webview.addEventListener('did-stop-loading', onStop)
    webview.addEventListener('did-fail-load', onFail)
    const poll = setInterval(() => {
      if (!webview.isLoading()) settle(true)
    }, 250)
    const timer = setTimeout(() => settle(false), timeoutMs)
  })
}

/**
 * Why `targetPaneId` can't be driven as a browser pane, or null if it can.
 *
 * The two cases are reported apart because they mean opposite things to a
 * caller and only this process can tell them apart. Main's ownership check
 * (`ownerOf`, src/main/externalControl.ts) keeps its grant until a `closePane`
 * verb succeeds, so a pane the *user* closed by hand still passes there and
 * arrives here as a live request against an id that no longer resolves — and
 * that, not a type mismatch, is overwhelmingly what fires: main only ever
 * grants ids it saw `createBrowserPane` create, and node ids are uuids, so a
 * granted id cannot later name some other kind of pane.
 *
 * It previously answered both with "target is not a browser pane", which told
 * an agent its pane was the wrong kind when in fact the pane was gone — the
 * one message that describes the case it almost never is.
 */
function browserPaneError(targetPaneId: string): string | null {
  const node = browserCtx.get().layout.findNode(targetPaneId)
  // The same sentence core's main answers for a pane the *caller* closed —
  // shared rather than restated, because an agent shouldn't have to recognise
  // two spellings of "it's gone". See PANE_GONE_ERROR.
  if (!node) return PANE_GONE_ERROR
  if (node.type !== BROWSER_TYPE) return 'target is not a browser pane'
  return null
}

/**
 * Resolves a request's `targetPaneId` to its mounted pane handle, or to the
 * error the caller should return instead. Ownership was already checked in
 * main (see src/main/externalControl.ts) — what's checked here is the two
 * things only this process can know: that the pane still exists as a browser
 * pane, and that a `BrowserRenderer` is currently mounted for it.
 */
function resolveBrowserHandle(
  targetPaneId: string
): { handle: BrowserPaneHandle } | { error: string } {
  const paneError = browserPaneError(targetPaneId)
  if (paneError) return { error: paneError }
  const handle = getBrowserPane(targetPaneId)
  if (!handle) return { error: 'browser pane is not currently mounted' }
  return { handle }
}

/**
 * `resolveBrowserHandle`, then the handle's live `<webview>` — what every
 * read/input verb ultimately acts on. A mounted pane can still briefly lack
 * a guest (mid-attach), which reports the same way as not mounted at all.
 */
function resolveWebview(targetPaneId: string): { webview: WebviewTag } | { error: string } {
  const resolved = resolveBrowserHandle(targetPaneId)
  if ('error' in resolved) return resolved
  const webview = resolved.handle.webview()
  if (!webview) return { error: 'browser pane is not currently mounted' }
  return { webview }
}

/**
 * Wraps a handler in the resolve step every guest verb shares: the request's
 * `targetPaneId` becomes the mounted pane's live `<webview>`, or the caller
 * gets the error instead of the handler running. Cross-cutting concerns wrap
 * handlers at the registration site here — the same idiom as
 * withHostFocusRestored — so no handler body restates the prologue.
 */
function withWebview<R extends { targetPaneId: string }>(
  handle: (webview: WebviewTag, request: R) => ControlResponse | Promise<ControlResponse>
): (request: R) => Promise<ControlResponse> {
  return async (request) => {
    const target = resolveWebview(request.targetPaneId)
    if ('error' in target) return { ok: false, error: target.error }
    return handle(target.webview, request)
  }
}

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
 * Places a `createBrowserPane` verb's new content according to the browser's
 * `controlledPanePlacement` setting (Settings → Browser). `targetId` is the
 * caller's own pane — the "next to me" every placement but `unpinned` is
 * relative to.
 */
function placeControlledPane(
  targetId: string,
  content: ContentNode,
  placement: BrowserNewPanePlacement
): void {
  const layout = browserCtx.get().layout
  switch (placement) {
    case 'split-horizontal':
      layout.placeNewPane(targetId, content, 'horizontal')
      return
    case 'split-vertical':
      layout.placeNewPane(targetId, content, 'vertical')
      return
    case 'unpinned':
      layout.placeNewUnpinnedPane(targetId, content)
      return
    case 'tab':
      layout.placeNewPane(targetId, content)
      return
  }
}

async function handleCreateBrowserPane(
  request: Extract<ControlRequest, { type: 'createBrowserPane' }>
): Promise<ControlResponse> {
  // Refuses rather than unregistering, which is the whole shape of the
  // enable/disable feature (see shared/content/enablement.ts): every other
  // verb keeps working, so an agent can still read and drive panes it
  // created before the user turned the type off. Unregistering the verb
  // instead would also break core's coverage gate, which asserts every name
  // in the protocol resolves to a handler
  // (content/__tests__/externalControlVerbs.test.tsx).
  //
  // The message names where to undo it: this answer becomes the calling
  // agent's context verbatim, and "refused" without a remedy just makes it
  // retry.
  if (!browserCtx.get().isEnabled()) {
    return {
      ok: false,
      error: `the ${browserManifest.displayName} content type is turned off in Settings → General → Content types; re-enable it to create panes of this kind`
    }
  }

  // The caller's own pane may itself be floating, in which case the new
  // browser pane opens inside that window — `withOwner` resolves the
  // destination from the target id, so placement needs no special case. A
  // requested `unpinned` placement is the exception: it spawns its own
  // floating window near the caller's pane rather than docking into
  // anything, so the caller's own docked/floating status doesn't matter
  // there either.
  if (!browserCtx.get().layout.findNode(request.paneId)) {
    return { ok: false, error: 'pane not found' }
  }

  // Tagged so a mount-time auto-focus never yanks the keyboard away from the
  // caller's own terminal (see paneHandles.ts) — the live "controlled by
  // another pane" chrome (robot icon, pulsing border) is driven separately,
  // by main's ownership ledger granting this pane through controlStore.ts.
  const content = { ...createLeaf(BROWSER_TYPE, { url: request.url }), agentCreated: true }
  placeControlledPane(request.paneId, content, getBrowserSettings().controlledPanePlacement)
  // Reported the instant the pane exists, not after the mount/load wait below:
  // the guest starts loading the caller's URL almost immediately, and main's
  // popup-deny / scheme-allowlist guards (did-attach-webview in
  // main/index.ts) only apply to a pane isOwnedPane already knows about. This
  // is what makes that true starting now rather than ~20s from now.
  browserCtx.get().ipc.send(BrowserMethod.paneCreated, content.id, request.paneId)

  // The pane exists in the tree either way from here on — waiting for its
  // webview to mount and its first page to settle only decides what `loaded`
  // says, never whether the paneId comes back.
  const deadline = Date.now() + MOUNT_WAIT_MS
  let handle = getBrowserPane(content.id)
  let webview = handle?.webview() ?? null
  await pollUntil(() => {
    handle = getBrowserPane(content.id)
    webview = handle?.webview() ?? null
    return webview !== null
  }, deadline)
  if (!webview || !handle) return { ok: true, result: { paneId: content.id, loaded: false } }

  // Unlike every other verb here, this one doesn't start the load — the
  // webview is created with its `src` already set, so the guest is loading
  // before this poll can even see it exists. A connection refused to
  // localhost lands within a few milliseconds, i.e. inside the first `delay`
  // above, so a listener attached from here would be far too late. The pane's
  // own instance-lifetime listener caught it (see BrowserInstance.loadFailure);
  // a main-frame failure means that navigation is already over, so there is
  // nothing left to wait for either.
  const failure = handle.lastLoadError()
  if (failure) {
    return {
      ok: true,
      result: {
        paneId: content.id,
        loaded: false,
        loadError: failure,
        ...(await pageState(webview, content.id))
      }
    }
  }
  const outcome = await waitForLoadEnd(webview, LOAD_WAIT_MS)
  const state = await pageState(webview, content.id)
  return {
    ok: true,
    result: {
      paneId: content.id,
      ...outcome,
      ...state,
      // Same contract as navigate's flag: only a first load that finished has
      // "ended up" anywhere worth comparing. The failure paths report
      // loadError instead — a Chromium error page's URL is not a redirect.
      ...(outcome.loaded ? { redirected: !isTrivialUrlChange(request.url, state.url) } : {})
    }
  }
}

/**
 * Where the pane actually is, read at the moment an answer is formed. Every
 * navigation verb reports this alongside `loaded`, because a load "settling"
 * says nothing about *what* it settled on — a server redirect, a client-side
 * router, or a post-load JS redirect all settle happily on some other page,
 * and the old shape (`{loaded: true}` alone) made that invisible until an
 * unrelated later step failed. A caller should trust `url` over the URL it
 * asked for. One residual stays: a JS redirect fired well after the load
 * settles is later than any answer — `getPaneInfo` is the live view.
 *
 * `status`/`statusText` ride along for the same reason: a 404 is a
 * *successful* load of an error document, so `loaded: true` alone can't
 * answer "is this page real". They describe the last committed main-frame
 * document — exactly the document `getURL()`/`getTitle()` describe, which is
 * what keeps the snapshot consistent — and are absent for a non-HTTP one
 * (about:blank, a failed-load error page). Read through the pane handle
 * because only the instance-lifetime listeners can have seen a first load's
 * commit (see BrowserInstance.documentStatus).
 *
 * `titleFromUrl: true` marks a `title` the document never actually set — the
 * URL-derived fallback Chromium reports for a page with no `<title>`, which
 * for an SPA is routinely the state at load-settle, with the real title
 * arriving from script moments later. The verbs deliberately do not wait for
 * it (answer latency is their core promise); the flag tells the caller the
 * title is a stand-in, and `getPaneInfo` reflects the live one.
 *
 * The flag is decided by reading `document.title` straight out of the guest
 * rather than by tracking `page-title-updated` events over a pane's
 * lifetime — a genuine inversion was found and measured on `reload`/
 * `goBack`/`goForward` (never on `navigate`) from exactly that tracking:
 * Chromium only fires `page-title-updated` when a document's title *differs*
 * from what was already showing, so a reload (or a history step landing on a
 * page that happens to share its predecessor's title) commonly fires no
 * title event at all, leaving a `titleExplicit`-style flag stuck at
 * whichever committed-document reset (`did-frame-navigate`, unconditional on
 * every navigation) last ran — reporting the *previous* document's
 * explicitness, not this one's. Measured directly, renderer-side, on the
 * real `<webview>` DOM events: reloading a page whose title does not change
 * fires `did-frame-navigate` but never `page-title-updated`. `document.title`
 * has no such gap — it is the DOM's own record of what the document itself
 * set (empty when nothing did, exact and unconditional otherwise), read at
 * response time rather than accumulated from events, so there is no state to
 * go stale and no separate mechanism per verb. Confirmed identical across
 * navigate/reload/goBack for both an explicit-title page and a title-less
 * one. This is *not* what `getTitle()`/`title` above report: `getTitle()`
 * is Chromium's UI-facing title (falls back to the URL), and callers who
 * want that fallback behavior still get it from `title` — only the flag's
 * source changed.
 */
async function pageState(
  webview: WebviewTag,
  paneId: string
): Promise<{
  url: string
  title: string
  status?: number
  statusText?: string
  titleFromUrl?: true
}> {
  const handle = getBrowserPane(paneId)
  const status = handle?.documentStatus() ?? null
  let hasExplicitTitle = true
  try {
    hasExplicitTitle = (await webview.executeJavaScript('document.title')) !== ''
  } catch {
    // A guest that can't run script right now (mid-attach, a Chromium
    // internal page) is rare enough, and the flag advisory enough, that
    // defaulting to "assume explicit" (no flag) rather than failing the
    // whole verb is the right degrade — the same stance `title`/`url` above
    // already take by reading whatever the webview last committed.
  }
  return {
    url: webview.getURL(),
    title: webview.getTitle(),
    ...(status
      ? { status: status.status, ...(status.statusText ? { statusText: status.statusText } : {}) }
      : {}),
    ...(hasExplicitTitle ? {} : { titleFromUrl: true as const })
  }
}

/**
 * How one issued navigation ended. `loaded` is about the *requested* document
 * (did the loadURL itself finish); `settled` is about the pane (has it
 * stopped loading) — the two disagree exactly when the requested load was
 * superseded and whatever replaced it has finished, which is the state the
 * redirect reporting below exists to name.
 */
interface NavigationAttempt {
  loaded: boolean
  settled: boolean
}

/**
 * Issues one navigation and waits for it to end, one way or another.
 *
 * loadURL's own promise is the cleanest load signal there is: it resolves on
 * did-finish-load and rejects with the Chromium error on did-fail-load.
 */
async function attemptNavigation(
  webview: WebviewTag,
  url: string,
  waitMs: number
): Promise<NavigationAttempt | { error: string }> {
  const startedAt = Date.now()
  const load = webview.loadURL(url)
  const timedOut = Symbol('timedOut')
  let timer: ReturnType<typeof setTimeout> | undefined
  const raced = await Promise.race([
    load.then(
      () => undefined,
      (error: unknown) => error ?? new Error('load failed')
    ),
    new Promise<typeof timedOut>((resolve) => {
      timer = setTimeout(() => resolve(timedOut), waitMs)
    })
  ])
  // Cleared on every outcome, not just the timeout's own: the winning load
  // otherwise leaves a live 15s timer behind per navigate call — harmless
  // individually, a steady leak under an agent driving the pane in a loop.
  // waitForLoadEnd's settle() already does the equivalent for its own pair.
  clearTimeout(timer)
  if (raced === timedOut) return { loaded: false, settled: false }
  if (raced !== undefined) {
    // The rejection arrives wrapped in guest-view plumbing ("Error invoking
    // remote method 'GUEST_VIEW_MANAGER_CALL': ..."); the ERR_* name buried
    // in it is the part a caller can act on, so dig it out.
    const failure = raced as { code?: string; message?: string }
    const raw = failure.code ?? failure.message ?? String(raced)
    const code = /ERR_[A-Z0-9_]+/.exec(raw)?.[0]
    if (code === 'ERR_ABORTED') {
      // This navigation was superseded by another (a JS redirect mid-load, an
      // SPA router swallowing it), mirroring mainFrameLoadError's ERR_ABORTED exemption (browserRegistry.ts) — the
      // pane is fine, it's just not loading the URL asked for. Wait out the
      // superseding load (bounded by what's left of this attempt's budget, and
      // never zero) so the URL reported is where the pane *ended up*, not a
      // mid-flight snapshot of wherever it happened to be at the abort.
      const remaining = Math.max(waitMs - (Date.now() - startedAt), 250)
      const outcome = await waitForLoadEnd(webview, remaining)
      return { loaded: false, settled: outcome.loaded || outcome.loadError !== undefined }
    }
    return { error: `failed to load ${url}: ${code ?? raw}` }
  }
  return { loaded: true, settled: true }
}

/**
 * The result every navigation answer is built from. `redirected` is present
 * only when the pane has settled — an unsettled pane hasn't ended up anywhere
 * yet, and flagging its transient URL would be exactly the string-compare
 * guesswork the flag exists to replace.
 */
async function navigationResult(
  webview: WebviewTag,
  attempt: NavigationAttempt,
  requestedUrl: string,
  paneId: string
): Promise<Record<string, unknown>> {
  const state = await pageState(webview, paneId)
  return {
    loaded: attempt.loaded,
    ...state,
    ...(attempt.settled ? { redirected: !isTrivialUrlChange(requestedUrl, state.url) } : {})
  }
}

async function handleNavigate(
  webview: WebviewTag,
  request: Extract<ControlRequest, { type: 'navigate' }>
): Promise<ControlResponse> {
  const first = await attemptNavigation(webview, request.url, LOAD_WAIT_MS)
  if ('error' in first) return { ok: false, error: first.error }
  const firstUrl = webview.getURL()
  // Retry only a settled miss: the pane demonstrably ended up somewhere other
  // than the requested URL (an auth bounce whose first hit establishes the
  // session), whether the requested load finished there or was superseded on
  // the way. A pane still loading gets no retry — issuing a second load at an
  // unsettled pane is the blind race this verb is being cured of.
  const settledElsewhere = first.settled && !isTrivialUrlChange(request.url, firstUrl)
  if (!request.retryOnRedirect || !settledElsewhere) {
    return {
      ok: true,
      result: await navigationResult(webview, first, request.url, request.targetPaneId)
    }
  }
  const second = await attemptNavigation(webview, request.url, LOAD_WAIT_MS)
  if ('error' in second) {
    return {
      ok: false,
      error: `${second.error} (on the retry — the first attempt landed on ${firstUrl})`
    }
  }
  // The final attempt answers top-level; `firstUrl` keeps the first attempt's
  // landing visible so a caller can see what the bounce was.
  return {
    ok: true,
    result: {
      ...(await navigationResult(webview, second, request.url, request.targetPaneId)),
      retried: true,
      firstUrl
    }
  }
}

async function handleReload(
  webview: WebviewTag,
  request: Extract<ControlRequest, { type: 'reload' }>
): Promise<ControlResponse> {
  webview.reload()
  const outcome = await waitForLoadEnd(webview, LOAD_WAIT_MS)
  // url/title but no `redirected`: there is no requested URL to compare
  // against — reload's subject is whatever page the pane already had.
  return { ok: true, result: { ...outcome, ...(await pageState(webview, request.targetPaneId)) } }
}

async function handleHistoryStep(
  webview: WebviewTag,
  direction: 'back' | 'forward',
  targetPaneId: string
): Promise<ControlResponse> {
  const canStep = direction === 'back' ? webview.canGoBack() : webview.canGoForward()
  if (!canStep) {
    const which = direction === 'back' ? 'earlier' : 'later'
    return { ok: false, error: `cannot go ${direction} — no ${which} page in this pane's history` }
  }
  if (direction === 'back') webview.goBack()
  else webview.goForward()
  const outcome = await waitForLoadEnd(webview, LOAD_WAIT_MS)
  return { ok: true, result: { ...outcome, ...(await pageState(webview, targetPaneId)) } }
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
function handleActivatePane(
  request: Extract<ControlRequest, { type: 'activatePane' }>
): ControlResponse {
  const paneError = browserPaneError(request.targetPaneId)
  if (paneError) return { ok: false, error: paneError }
  browserCtx.get().layout.revealPane(request.targetPaneId)
  return { ok: true }
}

function handleClosePane(request: Extract<ControlRequest, { type: 'closePane' }>): ControlResponse {
  // Unlike the verbs above this doesn't need a mounted renderer — closing a
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
function handleListOwnedPanes(): ControlResponse {
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
function handlePaneInfo(
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

/**
 * How long `screenshot` gives a pane it just revealed to become paintable:
 * React's commit removes the tab panel's `hidden`, then the compositor has to
 * produce a first frame, neither of which is done the instant the store
 * updates. Local to the renderer because main's relay budget for this verb is
 * the read tier's (READ_VERB_BUDGET_MS in main/browserExternalControl.ts) —
 * this must stay far under it so the bounded failure below reaches the caller
 * instead of a relay timeout.
 */
const REVEAL_CAPTURE_WAIT_MS = 3000

/**
 * The ref-or-semantic half of naming an element: the guest expression that
 * finds it, the phrase every error about it uses, and the message for a
 * resolver that answered `null` without saying why.
 *
 * Shared by every verb that names an element rather than restated per verb,
 * because the caller-facing text is the part that drifts. The ref remedy here
 * ("refs are only valid until the page navigates") is an instruction an agent
 * acts on; a second copy phrased differently, or a verb that spells its own
 * `selector "…"` label instead of `describeSemanticTarget`'s, teaches two
 * different recoveries for one state. The `{x,y}` arm of ElementTarget is
 * deliberately not handled — there is nothing to resolve — so callers that
 * accept one branch on it first.
 */
function namedTargetResolver(
  target: { ref: string } | SemanticTarget
): { resolver: string; described: string; notResolved: string } | { error: string } {
  if ('ref' in target) {
    return {
      resolver: refResolverExpression(target.ref),
      described: `ref ${target.ref}`,
      // A semantic resolver always states its own reason; only a ref can miss
      // silently (the registry died with the page), so this fallback is in
      // practice the ref-shaped one.
      notResolved: `no element for ref ${target.ref} — refs are only valid until the page navigates, so call readPage again`
    }
  }
  const invalid = semanticTargetError(target)
  if (invalid) return { error: invalid }
  const described = describeSemanticTarget(target)
  return {
    resolver: semanticResolverExpression(target),
    described,
    notResolved: `no element matches ${described}`
  }
}

/** What `elementRectScript` reports back — see its doc in pageScripts.ts. */
type ElementRectOutcome =
  | { resolved: false; reason?: string }
  | {
      resolved: true
      rect: { x: number; y: number; width: number; height: number }
      element: ElementDescription
    }

/**
 * Resolves `screenshot`'s optional `selector`/`ref` into the rect to clip to,
 * or null when the caller asked for the whole viewport.
 *
 * Two things the guest cannot do for itself happen here. The rect is
 * **clamped to the viewport**, because `capturePage` can only ever return
 * pixels the guest is showing — an element taller than the screen would
 * otherwise request rows that do not exist, which Electron answers with a
 * blank or short image rather than an error. And the rect is **rounded
 * outward** to whole CSS pixels: a fractional rect (a `translateY(0.5px)`, a
 * `zoom`) would otherwise cut a sliver off the element's own edge, which reads
 * as a rendering bug in the page rather than as rounding here.
 */
async function resolveCaptureClip(
  webview: WebviewTag,
  target: { ref: string } | SemanticTarget
): Promise<
  | {
      rect: { x: number; y: number; width: number; height: number }
      element: ElementDescription
    }
  | { error: string }
> {
  const named = namedTargetResolver(target)
  if ('error' in named) return named
  const outcome = (await webview.executeJavaScript(
    elementRectScript(named.resolver)
  )) as ElementRectOutcome
  if (!outcome.resolved) return { error: outcome.reason ?? named.notResolved }

  const described = named.described
  const viewportRect = webview.getBoundingClientRect()
  const left = Math.max(0, Math.floor(outcome.rect.x))
  const top = Math.max(0, Math.floor(outcome.rect.y))
  const right = Math.min(
    Math.round(viewportRect.width),
    Math.ceil(outcome.rect.x + outcome.rect.width)
  )
  const bottom = Math.min(
    Math.round(viewportRect.height),
    Math.ceil(outcome.rect.y + outcome.rect.height)
  )
  if (right <= left || bottom <= top) {
    return {
      error: `${described} is outside the visible viewport, so there is nothing to capture — scroll it into view first`
    }
  }
  return {
    rect: { x: left, y: top, width: right - left, height: bottom - top },
    element: outcome.element
  }
}

/**
 * Captures the guest's visible viewport, or one element's rect within it. The PNG bytes are handed to main
 * under SCREENSHOT_BYTES_KEY rather than returned to the caller — see that
 * constant, and the file-writing half in
 * src/plugins/browser/main/browserExternalControl.ts.
 *
 * A hidden pane is revealed first rather than failed: a backgrounded tab sits
 * in a `hidden` (display: none) subtree — TabsRenderer keeps every tab
 * mounted — and a display-none guest paints nothing, so `capturePage()`
 * against one has been observed to resolve empty, reject (UnknownVizError),
 * or never settle at all. That is why visibility is checked *before* any
 * capture is attempted instead of diagnosed from how the capture failed; the
 * check cannot confuse a hidden pane with a pane mid-close or mid-move,
 * because those never reach this handler at all (withWebview resolves them to
 * the "not currently mounted" error first). The reveal is the same
 * `revealPane` the activatePane verb performs — it never touches
 * setActivePane, so the no-keyboard-steal guarantee is inherited rather than
 * re-implemented — and it is reported as `activated: true` so the caller
 * knows the visible tab changed. `noActivate` opts out for a caller that
 * would rather fail than change what the user sees.
 */
async function handleScreenshot(
  webview: WebviewTag,
  request: Extract<ControlRequest, { type: 'screenshot' }>
): Promise<ControlResponse> {
  // Request-shape checks come first, before anything is revealed: they need
  // nothing from the guest, and refusing after the reveal would change what
  // the user is looking at and spend the whole wait budget to answer a
  // question that was unanswerable from the start.
  const hasSelector = namedString(request.selector)
  const hasRef = namedString(request.ref)
  if (hasSelector && hasRef) {
    return {
      ok: false,
      error: 'pass only one of selector or ref — they are different ways to name one element'
    }
  }
  const clipTarget: { ref: string } | SemanticTarget | null = hasRef
    ? { ref: request.ref as string }
    : hasSelector
      ? { selector: request.selector as string }
      : null

  const deadline = Date.now() + REVEAL_CAPTURE_WAIT_MS
  let activated = false
  if (!webview.checkVisibility()) {
    if (request.noActivate) {
      return {
        ok: false,
        error:
          'the pane is hidden — it is not its tab group’s active tab, so it has no frame to capture; rerun without noActivate, or run activatePane first'
      }
    }
    browserCtx.get().layout.revealPane(request.targetPaneId)
    activated = true
    await pollUntil(() => webview.checkVisibility(), deadline)
  }
  // Resolved after the reveal, never before: an element's rect in a hidden
  // guest is meaningless, and scrollIntoView in one is a no-op.
  const clip = clipTarget ? await resolveCaptureClip(webview, clipTarget) : null
  if (clip && 'error' in clip) return { ok: false, error: clip.error }

  let image: Electron.NativeImage
  try {
    const capture = () => (clip ? webview.capturePage(clip.rect) : webview.capturePage())
    image = await capture()
    // A freshly revealed guest can need a frame or two before a capture sees
    // pixels — retry inside the same budget rather than failing on the first
    // empty image, and give the compositor that frame before the first retry
    // rather than capturing again back-to-back. Only after a reveal: for a
    // pane that was visible all along, an empty capture is not a state that
    // waiting fixes.
    if (activated && image.isEmpty()) {
      await delay(100)
      await pollUntil(
        async () => {
          image = await capture()
          return !image.isEmpty()
        },
        deadline,
        100
      )
    }
  } catch (error) {
    // Kept a clean sentence rather than letting the rejection escape to the
    // dispatch boundary, which would prepend guest-view plumbing the caller
    // can do nothing with.
    return { ok: false, error: `could not capture the pane: ${String(error)}` }
  }
  if (image.isEmpty()) {
    return { ok: false, error: 'the pane produced no frame to capture' }
  }
  // Two different coordinate spaces, reported separately because they are not
  // the same number on a HiDPI display and conflating them silently puts
  // every coordinate-based click off by the scale factor. `getSize()` (and so
  // the encoded PNG) is in *device* pixels — measured at 2392 for a 1196 CSS
  // pixel pane on a 2x screen — while `sendInputEvent` coordinates, element
  // bounding rects, and readPage's rects are all in *CSS* pixels.
  const imageSize = image.getSize()
  const rect = webview.getBoundingClientRect()
  const viewport = { width: Math.round(rect.width), height: Math.round(rect.height) }
  // scaleFactor must describe the *display*, not this particular PNG, because
  // that is what a caller divides an image coordinate by to reach the CSS
  // pixels `click` takes. So it is measured against whatever was actually
  // asked for: the clip's CSS width when clipped, the viewport's when not.
  // Dividing the clipped image by the full viewport width would report a
  // fraction and silently scale every derived coordinate to nothing.
  const capturedCssWidth = clip ? clip.rect.width : viewport.width
  return {
    ok: true,
    result: {
      width: imageSize.width,
      height: imageSize.height,
      viewport,
      scaleFactor: capturedCssWidth > 0 ? imageSize.width / capturedCssWidth : 1,
      // The rect the capture actually used, after clamping — so a caller
      // mapping a point on a clipped image back into page space has the origin
      // it needs rather than having to assume the element's own rect held.
      ...(clip ? { clipped: clip.rect, element: clip.element } : {}),
      // Present only when the reveal actually happened: absence is the
      // promise that the user's visible tabs were not touched.
      ...(activated ? { activated: true } : {}),
      [SCREENSHOT_BYTES_KEY]: image.toPNG()
    }
  }
}

/** The shape every guest read script answers with, beyond its own payload. */
interface ReadDiagnostics {
  readyState?: unknown
  settled?: unknown
  frames?: unknown
  shadowRoots?: unknown
}

/**
 * The readiness-and-shape fields every read verb folds into its result, so a
 * caller can tell "the page doesn't have it" from "the page hasn't finished
 * saying it" or "it's one level down from where this verb can see":
 *
 * - `isLoading` host-side from the webview; `readyState`/`settled` from the
 *   guest script's answer (see READINESS_JS in pageScripts.ts — `settled` is
 *   the persistent tracker's "no mutation for WAIT_IDLE_QUIET_MS", the same
 *   quiet `waitFor --idle` waits for).
 * - `frames`/`shadowRoots` (DOCUMENT_SHAPE_JS) — always-present integers, 0
 *   included, counting content one level below the top document that these
 *   verbs structurally cannot see into (querySelectorAll/innerText don't
 *   descend into a frame or a shadow tree). A nonzero count next to missing
 *   or incomplete content is the cue that it may live there rather than not
 *   exist — see "What this can't do" in SKILL.md for the workaround.
 *
 * The whole guest pair is passed through only when it has the shape our
 * scripts produce — a page that rewrote the answer gets its fields dropped,
 * never fabricated into document state.
 */
function readinessFields(
  webview: WebviewTag,
  guest: ReadDiagnostics | null | undefined
): Record<string, unknown> {
  return {
    isLoading: webview.isLoading(),
    ...(typeof guest?.readyState === 'string' ? { readyState: guest.readyState } : {}),
    ...(typeof guest?.settled === 'boolean' ? { settled: guest.settled } : {}),
    ...(typeof guest?.frames === 'number' ? { frames: guest.frames } : {}),
    ...(typeof guest?.shadowRoots === 'number' ? { shadowRoots: guest.shadowRoots } : {})
  }
}

async function handleGetPageText(
  webview: WebviewTag,
  request: Extract<ControlRequest, { type: 'getPageText' }>
): Promise<ControlResponse> {
  const limit = Math.min(request.maxLength ?? DEFAULT_PAGE_TEXT_MAX, PAGE_TEXT_HARD_MAX)
  const raw = (await webview.executeJavaScript(PAGE_TEXT_SCRIPT)) as
    | ({ text?: unknown } & ReadDiagnostics)
    | null
  const text = typeof raw?.text === 'string' ? raw.text : String(raw?.text ?? '')
  return {
    ok: true,
    result: {
      text: text.slice(0, limit),
      truncated: text.length > limit,
      ...readinessFields(webview, raw)
    }
  }
}

/**
 * Why this readPage request cannot run as it stands, or null if it can.
 * Host-side for the same reason as semanticTargetError: what arrives over the
 * socket is untyped wire input, so the union's optional-but-typed fields are a
 * promise this check keeps rather than one the compiler does. A blank string
 * counts as absent — `role=""` matches nothing and would read as "the page has
 * no controls", the least intended reading there is.
 */
function readPageFilterError(
  request: Extract<ControlRequest, { type: 'readPage' }>
): string | null {
  for (const key of ['selector', 'role'] as const) {
    const value = request[key]
    if (value !== undefined && !namedString(value)) {
      return `${key} must be a non-empty string`
    }
  }
  if (
    request.offset !== undefined &&
    (!Number.isInteger(request.offset) || (request.offset as number) < 0)
  ) {
    return 'offset must be a non-negative integer (it is a 0-based index into the matching elements)'
  }
  return null
}

/**
 * Runs `readPage`'s extraction in the guest and normalizes what comes back.
 * `find` passes no filter, so its candidate set is exactly what it always was.
 */
async function extractPage(
  webview: WebviewTag,
  filter: ReadPageFilter = {}
): Promise<
  | {
      elements: PageElement[]
      truncated: boolean
      total: number
      offset: number
      guest: ReadDiagnostics | null
    }
  | { error: string }
> {
  const raw = (await webview.executeJavaScript(readPageScript(filter))) as
    | ({
        elements?: PageElement[]
        truncated?: boolean
        total?: number
        offset?: number
        error?: string
      } & ReadDiagnostics)
    | null
  // Only the selector branch can report one, and only for a selector the page's
  // own querySelectorAll refused — surfaced rather than degraded to an empty
  // list, which would read as "nothing on this page matches".
  if (typeof raw?.error === 'string') return { error: raw.error }
  const elements = raw?.elements ?? []
  return {
    elements,
    truncated: raw?.truncated === true,
    total: typeof raw?.total === 'number' ? raw.total : elements.length,
    offset: typeof raw?.offset === 'number' ? raw.offset : 0,
    guest: raw
  }
}

async function handleReadPage(
  webview: WebviewTag,
  request: Extract<ControlRequest, { type: 'readPage' }>
): Promise<ControlResponse> {
  const invalid = readPageFilterError(request)
  if (invalid) return { ok: false, error: invalid }
  const extracted = await extractPage(webview, {
    selector: request.selector,
    role: request.role,
    offset: request.offset
  })
  if ('error' in extracted) return { ok: false, error: extracted.error }
  const { elements, truncated, total, offset, guest } = extracted
  return {
    ok: true,
    result: { elements, total, offset, truncated, ...readinessFields(webview, guest) }
  }
}

async function handleFind(
  webview: WebviewTag,
  request: Extract<ControlRequest, { type: 'find' }>
): Promise<ControlResponse> {
  const extracted = await extractPage(webview)
  // Unreachable — find passes no selector, so the guest has nothing to refuse
  // — but narrowing it here keeps the union honest rather than casting it away.
  if ('error' in extracted) return { ok: false, error: extracted.error }
  const { elements, guest } = extracted
  const matches = findElements(elements, request.description, request.maxResults).map(
    ({ element, score }) => ({
      ref: element.ref,
      name: element.name,
      role: element.role,
      tag: element.tag,
      rect: element.rect,
      score
    })
  )
  return { ok: true, result: { matches, ...readinessFields(webview, guest) } }
}

/**
 * Runs an input verb, then puts host focus back where it was — and keeps the
 * pane it drove from becoming the active one.
 *
 * None of the verbs focus the webview themselves, but the *guest* pulls host
 * focus onto the `<webview>` element anyway when a script inside it calls
 * `el.focus()` or a synthesized click lands (same propagation an iframe
 * gets) — measured in the e2e focus test. Left alone, that yanks the
 * keyboard away from the terminal the user is typing in every time an agent
 * drives its pane. Restoring costs the verbs nothing: `sendInputEvent`
 * injects straight into the guest, and the guest's internal activeElement
 * survives the host-side blur, so later verbs still land where they should.
 *
 * Suppressing activation is the same stance one layer up, and is required
 * rather than tidy: since a guest press now activates its pane
 * (src/plugins/browser/main/guestActivation.ts), an agent's `click` would move the
 * active-pane highlight, and core's focus-follows-active would then call the
 * browser handle's `focus()` — landing the keyboard in the webview by the
 * very route the focus restore above exists to prevent.
 *
 * Accepted residual: a *genuine* user click into that same guest during the
 * verb and its 50ms tail is swallowed. It's a ~50ms window against an agent
 * actively driving that pane, and the user's second click lands.
 *
 * Applied at registration below rather than inside each handler, and browser
 * knowledge rather than core's: which verbs can pull host focus is a fact
 * about `<webview>` guests, so the dispatcher must not need to know it.
 */
async function withHostFocusRestored<T>(action: () => Promise<T>): Promise<T> {
  const previous = document.activeElement
  const allowActivationAgain = suppressGuestActivation()
  try {
    return await action()
  } finally {
    // The pull can land a tick after the last injected event.
    await delay(50)
    allowActivationAgain()
    if (
      document.activeElement !== previous &&
      document.activeElement?.tagName === 'WEBVIEW' &&
      previous instanceof HTMLElement &&
      previous.isConnected
    ) {
      previous.focus()
    }
  }
}

/** What `hitTestPointScript` reports back — see its doc in pageScripts.ts. */
type HitTestOutcome =
  | { resolved: false; reason?: string }
  | {
      resolved: true
      x: number
      y: number
      matched: boolean
      intended: ElementDescription
      element: ElementDescription | null
    }

/**
 * How long the host waits before the one hit-test retry. Host-timed rather
 * than an in-guest requestAnimationFrame on purpose: a backgrounded or hidden
 * guest throttles rAF and timers (backgroundThrottling is on for these
 * webviews), and agents routinely drive panes that aren't visible — an
 * in-guest wait could hang the verb until main's relay budget fires, while a
 * host timer is exactly as reliable as the delay(50) polls this module
 * already runs under e2e.
 */
const HIT_TEST_RETRY_DELAY_MS = 100

/** A hit description as prose for the mismatch error, naming what a caller can act on. */
function describeForError(described: ElementDescription | null): string {
  if (!described) return 'no element at all (the point falls outside the document)'
  return described.name
    ? `<${described.tag}> "${described.name}"`
    : `<${described.tag}> (role ${described.role})`
}

/**
 * Why a semantic target can't be resolved as it stands, or null if it can.
 * Shape validation lives host-side, before any guest round trip: what arrives
 * over the socket is untyped wire input, so the union's "at least one
 * criterion" is a promise this check keeps, not one the compiler does. A
 * criterion present but blank (or not a string at all) counts as absent —
 * matching name="" exactly would select every unlabeled control, the least
 * intended reading there is.
 */
function semanticTargetError(target: SemanticTarget): string | null {
  const named = (['role', 'name', 'selector'] as const).some((key) => namedString(target[key]))
  if (!named) {
    return 'a semantic target needs at least one of role, name, selector'
  }
  if (target.nth !== undefined && (!Number.isInteger(target.nth) || target.nth < 0)) {
    return 'nth must be a non-negative integer (it is a 0-based index into the matches)'
  }
  return null
}

/**
 * Turns an `ElementTarget` into the viewport coordinate to dispatch at, plus
 * what sits there. A ref or semantic target is resolved, scrolled into view,
 * and hit-tested in one guest script immediately before dispatch, so a layout
 * shift since readPage moves the click with the element instead of leaving
 * the coordinate pointing at whatever slid into its old spot; a point that no
 * longer holds the element (an overlay, a collapse) gets one retry —
 * transient reflows settle within it — and then a loud failure naming both
 * elements, which beats silently clicking the wrong thing. A raw `{x,y}` is
 * taken as-is and only described, never refused: the caller named the exact
 * point.
 */
async function resolveClickTarget(
  webview: WebviewTag,
  target: ElementTarget
): Promise<{ x: number; y: number; element?: ElementDescription } | { error: string }> {
  if ('x' in target) {
    let element: ElementDescription | undefined
    try {
      const hit = (await webview.executeJavaScript(
        describePointScript(target.x, target.y)
      )) as ElementDescription | null
      element = hit ?? undefined
    } catch {
      // A guest that can't run script (a Chromium error page, the PDF viewer)
      // can still be clicked — the description is reporting, never a gate.
    }
    return { x: target.x, y: target.y, ...(element ? { element } : {}) }
  }

  const named = namedTargetResolver(target)
  if ('error' in named) return named
  const described = named.described

  const script = hitTestPointScript(named.resolver)
  let outcome = (await webview.executeJavaScript(script)) as HitTestOutcome
  if (outcome.resolved && !outcome.matched) {
    await delay(HIT_TEST_RETRY_DELAY_MS)
    outcome = (await webview.executeJavaScript(script)) as HitTestOutcome
  }
  if (!outcome.resolved) return { error: outcome.reason ?? named.notResolved }
  if (!outcome.matched) {
    const remedy =
      'ref' in target
        ? 'call readPage again, or click by coordinate to press what is actually there'
        : 'dismiss what covers it, or click by coordinate to press what is actually there'
    return {
      error: `clicking ${described} (${describeForError(outcome.intended)}) would land on ${describeForError(outcome.element)} instead — the layout shifted or another element covers it; ${remedy}`
    }
  }
  return { x: outcome.x, y: outcome.y, element: outcome.intended }
}

function clickAt(webview: WebviewTag, x: number, y: number): void {
  // A move first, so a page that only reveals a control on hover has seen the
  // pointer arrive before the press lands on it.
  webview.sendInputEvent({ type: 'mouseMove', x, y })
  webview.sendInputEvent({ type: 'mouseDown', x, y, button: 'left', clickCount: 1 })
  webview.sendInputEvent({ type: 'mouseUp', x, y, button: 'left', clickCount: 1 })
}

async function handleClick(
  webview: WebviewTag,
  request: Extract<ControlRequest, { type: 'click' }>
): Promise<ControlResponse> {
  const point = await resolveClickTarget(webview, request.target)
  if ('error' in point) return { ok: false, error: point.error }
  // Deliberately no webview.focus() — sendInputEvent injects straight into
  // the guest's input pipeline; what focus the guest pulls anyway is undone
  // by withHostFocusRestored at the dispatch site.
  //
  // One executeJavaScript→sendInputEvent round trip remains between the
  // hit-test above and the events landing — unclosable without giving up
  // real input events, since dispatch is host-side by design. The window
  // shrank from scroll+round-trip+queue to just the round trip.
  clickAt(webview, point.x, point.y)
  return {
    ok: true,
    result: { x: point.x, y: point.y, ...(point.element ? { element: point.element } : {}) }
  }
}

/**
 * Moves the pointer onto the target and stops there — no press.
 *
 * Resolution is `click`'s, unchanged: the same `resolveClickTarget`, so a ref
 * is scrolled into view and hit-tested, a covered element fails naming both,
 * and a coordinate is taken as given. What differs is only the dispatch, which
 * is why this reads as three lines rather than as a parallel implementation.
 *
 * The hover *persists* — Chromium holds the hovered element until the next
 * pointer event reaches the guest — so the follow-up read that inspects what
 * appeared does not need to re-hover to keep a menu open. A second hover onto
 * the same point is still a real `mousemove`, but produces no fresh
 * `mouseenter`, which is exactly what a real pointer sitting still does.
 */
async function handleHover(
  webview: WebviewTag,
  request: Extract<ControlRequest, { type: 'hover' }>
): Promise<ControlResponse> {
  const point = await resolveClickTarget(webview, request.target)
  if ('error' in point) return { ok: false, error: point.error }
  webview.sendInputEvent({ type: 'mouseMove', x: point.x, y: point.y })
  return {
    ok: true,
    result: { x: point.x, y: point.y, ...(point.element ? { element: point.element } : {}) }
  }
}

/**
 * Puts the guest's focus where typed text should land. A ref or semantic
 * target is focused directly rather than clicked (an overlay could swallow
 * the click) — the semantic form resolves and focuses in the same guest
 * script, so no layout shift fits between match and focus; a coordinate has
 * nothing to focus but the point itself, so that one clicks. Returns a
 * complete error string when the target can't be focused, null on success —
 * the caller decides whether that aborts the verb (type) or just skips the
 * field (formInput).
 */
async function focusTypingTarget(
  webview: WebviewTag,
  target: ElementTarget
): Promise<string | null> {
  if ('ref' in target) {
    const outcome = (await webview.executeJavaScript(
      focusTargetScript(refResolverExpression(target.ref))
    )) as { focused: boolean; reason?: string }
    if (!outcome.focused) {
      return (
        outcome.reason ??
        `could not focus ref ${target.ref} — it may no longer exist, or may not be focusable`
      )
    }
    return null
  }
  if ('x' in target) {
    clickAt(webview, target.x, target.y)
    return null
  }
  const invalid = semanticTargetError(target)
  if (invalid) return invalid
  const outcome = (await webview.executeJavaScript(
    focusTargetScript(semanticResolverExpression(target))
  )) as { focused: boolean; reason?: string }
  if (!outcome.focused) {
    return outcome.reason ?? `could not focus ${describeSemanticTarget(target)}`
  }
  return null
}

/** Sends `text` as real per-character events to whatever the guest has focused. */
function typeChars(webview: WebviewTag, text: string): void {
  for (const character of text) {
    webview.sendInputEvent({ type: 'char', keyCode: character })
  }
}

/**
 * Characters `typeChars` cannot deliver: Chromium's keyboard pipeline drops a
 * `char` event whose character has no key behind it — every C0 control
 * (newline included) and DEL — on the floor, with nothing observable to the
 * sender. `type` therefore refuses such text up front rather than silently
 * sending fewer keystrokes than asked; the error names the exact character
 * and where multiline values should go instead. A charCode walk rather
 * than a regex: biome refuses control characters in regex literals even
 * escaped (noControlCharactersInRegex).
 */
function untypeableCharError(text: string): string | null {
  for (let index = 0; index < text.length; index++) {
    const code = text.charCodeAt(index)
    if (code >= 0x20 && code !== 0x7f) continue
    const described =
      code === 10
        ? 'a newline'
        : code === 13
          ? 'a carriage return'
          : code === 9
            ? 'a tab'
            : `control character 0x${code.toString(16).padStart(2, '0')}`
    return `text contains ${described} at index ${index}, which keystrokes cannot enter — use form-input to set a multiline value verbatim, or key (e.g. --key Enter, --key Tab) to press the key itself`
  }
  return null
}
/**
 * Sends `text` as real character events to whatever the target focuses, then
 * optionally an Enter. Text the char pipeline cannot carry is refused before
 * anything is focused, so a rejected call leaves the page untouched.
 */
async function handleType(
  webview: WebviewTag,
  request: Extract<ControlRequest, { type: 'type' }>
): Promise<ControlResponse> {
  const untypeable = untypeableCharError(request.text)
  if (untypeable) return { ok: false, error: untypeable }

  // focusTypingTarget's errors arrive complete — a semantic failure already
  // names its candidates or its remedy, and a generic suffix appended here
  // would read as noise after them.
  const focusError = await focusTypingTarget(webview, request.target)
  if (focusError) {
    return { ok: false, error: focusError }
  }

  typeChars(webview, request.text)
  if (request.submit) sendKey(webview, 'Enter')
  return { ok: true }
}

/**
 * DOM `KeyboardEvent.key`/`code` spelling → Electron's Accelerator
 * vocabulary, for the one family measured to differ: the arrow keys.
 * `sendInputEvent`'s `keyCode` field must be a valid Accelerator token (its
 * own doc: "Should only use valid Accelerator key codes") — 'Left', not the
 * DOM 'ArrowLeft'. An unrecognized token doesn't fail gracefully or fail only
 * under some modifier: measured directly (a real guest's keydown listener,
 * every modifier crossed with all four arrows), `keyCode: 'ArrowLeft'`
 * produces a completely null `KeyboardEvent` — `key: '', code: '', keyCode:
 * 0` — regardless of which modifier rides along, alt included; `'Left'`
 * produces the correct `key`/`code` (and `altKey`/`shiftKey`/`ctrlKey` set
 * correctly) every time. Scoped to exactly the mismatched family: `'Enter'`,
 * `'Escape'`, `'Tab'` and single letters (the other names this app actually
 * sends) already match Electron's vocabulary and were never observed to
 * break, so they pass through untouched rather than guessing at a wider
 * translation nothing has shown is needed.
 */
const DOM_TO_ACCELERATOR_KEY: Record<string, string> = {
  ArrowLeft: 'Left',
  ArrowRight: 'Right',
  ArrowUp: 'Up',
  ArrowDown: 'Down'
}

function sendKey(webview: WebviewTag, key: string, modifiers: KeyModifier[] = []): void {
  const keyCode = DOM_TO_ACCELERATOR_KEY[key] ?? key
  webview.sendInputEvent({ type: 'keyDown', keyCode, modifiers })
  // A printable key also needs the char event to actually insert anything —
  // keyDown alone fires the handler but leaves the field empty.
  if (keyCode.length === 1) webview.sendInputEvent({ type: 'char', keyCode, modifiers })
  webview.sendInputEvent({ type: 'keyUp', keyCode, modifiers })
}

/**
 * The wire's kebab-case command names → `document.execCommand`'s own spelling.
 * Two vocabularies rather than one because the wire name is a CLI flag value
 * and `selectAll` reads wrong beside `--role`/`--max-length`; the mapping is
 * one line each and keeps `EDITING_COMMANDS` free to be the caller-facing
 * list. See editingCommandScript for why this is execCommand and not the
 * `WebContents` methods of the same names, which are measurably inert on a
 * `<webview>` guest.
 */
const EDITING_COMMAND_NAMES: Record<EditingCommand, string> = {
  'select-all': 'selectAll',
  undo: 'undo',
  redo: 'redo',
  delete: 'delete'
}

/**
 * Letters Chromium claims for its own editing commands under meta/control. A
 * chord naming one is delivered faithfully and still does nothing to the
 * selection or the clipboard, which is the silent-corruption trap this note
 * exists to break: the verb answered `ok: true`, a follow-up Backspace also
 * answered `ok: true`, and between them a field lost one character instead of
 * all of them.
 *
 * The chord is **not refused**. A page's own JS shortcut handlers do fire for
 * it — measured — so refusing would break the legitimate case (an app that
 * binds Cmd+K) to protect the illegitimate one. Reporting alongside the
 * success is what makes the answer honest without taking a capability away.
 */
const EDITING_CHORD_KEYS = new Set(['a', 'c', 'v', 'x', 'z', 'y'])

function editingChordNote(request: Extract<ControlRequest, { type: 'key' }>): string | undefined {
  const modifiers = request.modifiers ?? []
  if (!modifiers.includes('meta') && !modifiers.includes('control')) return undefined
  if (typeof request.key !== 'string' || !EDITING_CHORD_KEYS.has(request.key.toLowerCase())) {
    return undefined
  }
  return "the keystroke was delivered and the page's own handlers saw it, but Chromium's built-in editing commands do not respond to a synthesized chord — the selection and clipboard are unchanged. Use --command (select-all, undo, redo, delete) for those, or form-input to replace a field's value"
}

async function handleKey(
  webview: WebviewTag,
  request: Extract<ControlRequest, { type: 'key' }>
): Promise<ControlResponse> {
  const named = typeof request.key === 'string' && request.key !== ''
  const commanded = request.command !== undefined
  if (named === commanded) {
    return {
      ok: false,
      error: named
        ? 'pass only one of key or command — a keystroke and an editing command are different things'
        : `key needs one of key (a keystroke) or command (${EDITING_COMMANDS.join(', ')})`
    }
  }
  if (commanded) {
    const execName = EDITING_COMMAND_NAMES[request.command as EditingCommand]
    if (!execName) {
      return {
        ok: false,
        error: `unknown command ${JSON.stringify(request.command)} — one of ${EDITING_COMMANDS.join(', ')}`
      }
    }
    // Acts on whatever the guest has focused, exactly as the menu item would.
    const outcome = (await webview.executeJavaScript(editingCommandScript(execName))) as {
      applied: boolean
      element: ElementDescription | null
    }
    if (!outcome.applied) {
      return {
        ok: false,
        error: `the page refused the ${request.command} command${outcome.element ? ` on ${describeForError(outcome.element)}` : ' (nothing is focused)'}`
      }
    }
    return {
      ok: true,
      result: {
        command: request.command,
        ...(outcome.element ? { element: outcome.element } : {})
      }
    }
  }
  sendKey(webview, request.key as string, request.modifiers ?? [])
  const note = editingChordNote(request)
  return { ok: true, ...(note ? { result: { note } } : {}) }
}

/**
 * Scrolls the document and reports where it landed — the *settled* position,
 * not a snapshot taken mid-animation. See scrollScript for both halves of why
 * that used to be wrong (a smooth page's animation, and a zero-sized step on a
 * backgrounded pane); neither needs anything from the host, which is why this
 * handler no longer measures the element.
 */
async function handleScroll(
  webview: WebviewTag,
  request: Extract<ControlRequest, { type: 'scroll' }>
): Promise<ControlResponse> {
  const position = await webview.executeJavaScript(scrollScript(request.direction, request.amount))
  return { ok: true, result: { position } }
}

/**
 * Runs caller-supplied code in the guest page and returns its value.
 *
 * Two failure modes are turned into clean errors rather than letting them
 * escape: the script throwing (a rejected promise from `executeJavaScript`),
 * and it returning something JSON can't represent (a DOM node, a circular
 * object). The latter matters because the value has a long way still to
 * travel — across contextBridge to main, then through `JSON.stringify` onto
 * the socket — and failing at the far end would surface as an unhelpful
 * serialization error instead of "your script returned a DOM node".
 *
 * Note this runs in the page's *own* main world; `<webview>`'s
 * executeJavaScript has no isolated-world option. See pageScripts.ts.
 */
async function handleExecuteJavaScript(
  webview: WebviewTag,
  request: Extract<ControlRequest, { type: 'executeJavaScript' }>
): Promise<ControlResponse> {
  let outcome: { ok: true; value: unknown } | { ok: false; error: string }
  try {
    outcome = await webview.executeJavaScript(executeScript(request.code))
  } catch {
    // Runtime throws are caught inside the guest by executeScript, so the only
    // way to land here is code that isn't a valid expression — and Electron's
    // own message for that says nothing useful, so it isn't repeated.
    return {
      ok: false,
      error:
        'the code is not a valid expression — wrap a sequence of statements in an IIFE, e.g. (() => { ... })()'
    }
  }
  if (!outcome.ok) return { ok: false, error: `script threw: ${outcome.error}` }
  const value = outcome.value

  // File output requested: hand main the *full* serialization instead of
  // applying the cap — the caller asked for a file precisely because the
  // value is large. A plain string goes raw (`text`): the common case is an
  // extracted document, and a JSON-quoted file would force every caller to
  // unquote it. Anything else is pretty-printed JSON (`json`), still valid
  // for a parser; `undefined` keeps its inline-path meaning as JSON null.
  //
  // Answered before the compact serialization below, not after it: this branch
  // never looks at that string, and building it anyway would cost a second
  // full copy of exactly the large values `--out` exists for (a 30MB result
  // measured at ~25ms of wasted renderer main-thread time). The pretty form
  // refuses a cycle or a DOM node identically, so the friendly error below is
  // unchanged — it just arrives from whichever stringify ran.
  let serialized: string | undefined
  try {
    serialized =
      request.outPath !== undefined
        ? typeof value === 'string'
          ? value
          : JSON.stringify(value ?? null, null, 2)
        : JSON.stringify(value)
  } catch {
    return {
      ok: false,
      error: 'the script returned a value that cannot be serialized (a DOM node, or a cycle)'
    }
  }
  if (request.outPath !== undefined) {
    return {
      ok: true,
      result: {
        [EXECUTE_OUTPUT_KEY]: serialized,
        format: typeof value === 'string' ? 'text' : 'json',
        truncated: false
      }
    }
  }
  if (serialized !== undefined && serialized.length > EXECUTE_RESULT_MAX) {
    return {
      ok: true,
      result: { value: serialized.slice(0, EXECUTE_RESULT_MAX), truncated: true }
    }
  }
  // `undefined` (a script ending in a statement, or returning a function)
  // has no JSON form; report it as null rather than dropping the key, so a
  // caller can tell "ran, returned nothing" from "no result field".
  return { ok: true, result: { value: value === undefined ? null : value, truncated: false } }
}

/** What `fillFocusedScript` reports back — see its doc in pageScripts.ts. */
type FillOutcome =
  | { mode: 'none' }
  | { mode: 'unfillable'; element: ElementDescription }
  | { mode: 'select'; matched: boolean; options?: string[]; length?: number }
  | { mode: 'set'; length: number; tag: string }
  | { mode: 'editable'; length: number }
  | { mode: 'error'; error: string }

/**
 * Fills fields in order, replacing whatever each already contains. Sequential
 * rather than parallel because focus is a single shared resource — filling
 * two fields at once would race for it — and a field that fails is reported
 * and skipped rather than aborting the rest of the form.
 *
 * Every value is written in-script by `fillFocusedScript` — nothing here
 * types characters, because the char-event pipeline silently drops `\n` and
 * every other key-less character (see that script's doc; `type` keeps the
 * pipeline because its contract is keystrokes, and it refuses such text).
 *
 * The response reports what each element actually holds after its fill:
 * `fields` carries `{index, length}` per filled field, read back from the
 * element itself, so a caller can check `length` against the value it sent in
 * one glance. An `<input>`/`<textarea>` whose read-back length differs from
 * the requested value's goes to `errors` instead of counting as filled —
 * Chromium sanitizes on write (a single-line `<input>` strips newlines), and
 * "the field doesn't hold what you sent" must never report as success.
 * Contenteditable is exempt from that strict check: its `length` is measured
 * on `innerText`, which normalizes blank lines, so a byte-exact comparison
 * would fail legitimate fills.
 */
async function handleFormInput(
  webview: WebviewTag,
  request: Extract<ControlRequest, { type: 'formInput' }>
): Promise<ControlResponse> {
  let filled = 0
  const fields: { index: number; length: number }[] = []
  const errors: { index: number; error: string }[] = []
  for (const [index, field] of request.fields.entries()) {
    const focusError = await focusTypingTarget(webview, field.target)
    if (focusError) {
      errors.push({ index, error: focusError })
      continue
    }
    let outcome: FillOutcome
    try {
      outcome = (await webview.executeJavaScript(fillFocusedScript(field.value))) as FillOutcome
    } catch {
      // The script catches its own throws; reaching here means the guest
      // couldn't run script at all (navigated away mid-fill, an error page).
      errors.push({ index, error: 'the page could not run the fill — it may have navigated away' })
      continue
    }
    switch (outcome.mode) {
      case 'select':
        if (outcome.matched) {
          filled++
          fields.push({ index, length: outcome.length ?? field.value.length })
        } else {
          const options = outcome.options?.length ? ` (options: ${outcome.options.join(', ')})` : ''
          errors.push({
            index,
            error: `no option matching ${JSON.stringify(field.value)}${options}`
          })
        }
        break
      case 'set':
        if (outcome.length === field.value.length) {
          filled++
          fields.push({ index, length: outcome.length })
        } else {
          const why =
            outcome.tag === 'input' && /[\r\n]/.test(field.value)
              ? 'a single-line <input> cannot hold newlines; target a <textarea> instead'
              : 'the element rewrote or refused part of the value'
          errors.push({
            index,
            error: `the field holds ${outcome.length} of the ${field.value.length} characters sent — ${why}`
          })
        }
        break
      case 'editable':
        filled++
        fields.push({ index, length: outcome.length })
        break
      case 'unfillable':
        errors.push({
          index,
          error: `${describeForError(outcome.element)} is not a fillable field — use click for buttons, checkboxes and radios`
        })
        break
      case 'error':
        errors.push({ index, error: `could not set the value: ${outcome.error}` })
        break
      default:
        errors.push({
          index,
          error: 'the target did not leave a field focused, so there is nothing to fill'
        })
    }
  }
  return {
    ok: true,
    result: {
      filled,
      ...(fields.length > 0 ? { fields } : {}),
      ...(errors.length > 0 ? { errors } : {})
    }
  }
}

/**
 * Console output captured for the pane's current page. Resolves the pane
 * handle itself (the one verb that doesn't go through `withWebview`) because
 * it reads the handle rather than driving the guest: the buffer is filled by
 * the `<webview>` element's own `console-message` events as they happen — a
 * page's console history isn't something the page can be asked for after the
 * fact.
 */
function handleReadConsoleMessages(
  request: Extract<ControlRequest, { type: 'readConsoleMessages' }>
): ControlResponse {
  const resolved = resolveBrowserHandle(request.targetPaneId)
  if ('error' in resolved) return { ok: false, error: resolved.error }
  // Refused rather than silently falling back to a substring search — see
  // patternFilterError's comment; read-network's identical --pattern check
  // shares this same function.
  const patternError = patternFilterError(request.pattern)
  if (patternError !== undefined) return { ok: false, error: patternError }
  const matches = compilePattern(request.pattern)
  const messages = resolved.handle
    .consoleMessages(request.sinceSeq)
    .filter((entry) => matches(entry.text))
  return { ok: true, result: { messages } }
}

type WaitForRequest = Extract<ControlRequest, { type: 'waitFor' }>

/** A wire string that names something: present, a string, and not blank. */
function namedString(value: unknown): value is string {
  return typeof value === 'string' && value.trim() !== ''
}

/**
 * The one wait/assert message that names neither verb — hoisted because the
 * two validators are deliberately separate per-verb (their other messages
 * name their own verb), and a shared string is the only part that may not
 * fork.
 */
const GONE_NEEDS_TARGET = 'gone inverts text or selector — it needs one of them to invert'

/**
 * Why this waitFor request cannot run as it stands, or null if it can.
 * Host-side for the same reason as semanticTargetError: what arrives over the
 * socket is untyped wire input, so "exactly one condition" is a promise this
 * check keeps, not one the compiler does. Exactly one is a decision, not a
 * limitation — AND-ed conditions read plausibly but hide which half never
 * held when the wait times out, and a sequence of waits (or a batch) states
 * the same thing legibly.
 */
function waitSpecError(request: WaitForRequest): string | null {
  const conditions = [
    namedString(request.text),
    namedString(request.selector),
    namedString(request.urlContains),
    request.idle === true
  ].filter(Boolean).length
  if (conditions === 0) {
    return 'waitFor needs a condition: one of text, selector, urlContains, idle'
  }
  if (conditions > 1) {
    return 'waitFor takes exactly one condition per call — run several waits (or a batch of them) to combine conditions'
  }
  if (request.gone === true && !namedString(request.text) && !namedString(request.selector)) {
    return GONE_NEEDS_TARGET
  }
  return null
}

/**
 * The wait spec, rebuilt from the validated fields rather than spread from the
 * wire, so a blank-but-present string can't reach the guest as a condition.
 *
 * Shared by `waitFor` and `assert` — unlike their validators and their prose,
 * which are deliberately per-verb (each message must name its own verb), this
 * holds no wording at all, so a condition added to one and not the other would
 * be a condition the validator accepts and the spec silently drops. `idle` is
 * absent from assert's vocabulary and simply never set for it.
 */
function buildPageWaitSpec(request: {
  text?: string
  selector?: string
  urlContains?: string
  gone?: boolean
  idle?: boolean
}): PageWaitSpec {
  if (namedString(request.urlContains)) return { urlContains: request.urlContains }
  if (request.idle === true) return { idle: true }
  return {
    ...(namedString(request.text) ? { text: request.text } : {}),
    ...(namedString(request.selector) ? { selector: request.selector } : {}),
    ...(request.gone === true ? { gone: true } : {})
  }
}

/** The condition as prose, for the timeout error naming what never held. */
function describeWaitCondition(request: WaitForRequest): string {
  if (request.idle === true) {
    return `the DOM to go idle (no mutations for ${WAIT_IDLE_QUIET_MS}ms)`
  }
  if (namedString(request.urlContains)) {
    return `the URL to contain ${JSON.stringify(request.urlContains)}`
  }
  if (namedString(request.selector)) {
    return `selector ${JSON.stringify(request.selector)} to ${request.gone ? 'stop matching' : 'match a visible element'}`
  }
  return `text ${JSON.stringify(request.text)} to ${request.gone ? 'disappear' : 'appear'}`
}

/**
 * One call in place of a caller's sleep-and-poll loop — the mechanics live in
 * pageWait.ts (the navigation-surviving supervisor) and waitScripts.ts (the
 * in-guest watchers); this handler only validates the wire shape, clamps the
 * bounds with the same shared arithmetic main prices the relay from, and
 * turns the outcome into a ControlResponse. On success the elapsed time tells
 * the caller what the page actually took; on timeout the error names the
 * condition that never held, which is the difference between a diagnosis and
 * a shrug.
 */
async function handleWaitFor(
  webview: WebviewTag,
  request: WaitForRequest
): Promise<ControlResponse> {
  const invalid = waitSpecError(request)
  if (invalid) return { ok: false, error: invalid }
  const timeoutMs = clampWaitTimeout(request.timeoutMs)
  const pollMs = clampWaitPoll(request.pollMs)
  const outcome = await waitForPageCondition(webview, buildPageWaitSpec(request), {
    timeoutMs,
    pollMs,
    // Only the pane's existence — never its mount state, which is transient
    // while a drag reparents the pane and exactly what re-arming survives.
    invalidReason: () => browserPaneError(request.targetPaneId)
  })
  if ('error' in outcome) return { ok: false, error: outcome.error }
  if (!outcome.settled) {
    return {
      ok: false,
      error: `timed out after ${timeoutMs}ms waiting for ${describeWaitCondition(request)}`
    }
  }
  const { settled: _settled, elapsedMs, ...extras } = outcome
  return { ok: true, result: { elapsedMs, ...extras } }
}

type AssertRequest = Extract<ControlRequest, { type: 'assert' }>

/**
 * waitSpecError's twin, kept separate rather than parameterized: the
 * vocabularies differ (no idle here), and each message should name its own
 * verb — a validation error is the one part of a verb an agent quotes back.
 */
function assertSpecError(request: AssertRequest): string | null {
  const conditions = [
    namedString(request.text),
    namedString(request.selector),
    namedString(request.urlContains)
  ].filter(Boolean).length
  if (conditions === 0) {
    return 'assert needs a condition: one of text, selector, urlContains'
  }
  if (conditions > 1) {
    return 'assert takes exactly one condition per call — batch several asserts to combine them'
  }
  if (request.gone === true && !namedString(request.text) && !namedString(request.selector)) {
    return GONE_NEEDS_TARGET
  }
  return null
}

/** The failed premise as prose — the transcript line that says what broke. */
function describeAssertFailure(request: AssertRequest): string {
  if (namedString(request.urlContains)) {
    return `the URL does not contain ${JSON.stringify(request.urlContains)}`
  }
  if (namedString(request.selector)) {
    return request.gone === true
      ? `selector ${JSON.stringify(request.selector)} still matches a visible element`
      : `selector ${JSON.stringify(request.selector)} does not match a visible element`
  }
  return request.gone === true
    ? `page text still contains ${JSON.stringify(request.text)}`
    : `page text does not contain ${JSON.stringify(request.text)}`
}

/**
 * `waitFor`'s single-shot twin: the same conditions, evaluated once, with a
 * failure that *fails the verb* — which is what lets a failing premise stop a
 * batch and be named in its transcript, instead of coming back as data the
 * caller must inspect.
 *
 * Runs through the same supervisor as waitFor on the fixed
 * ASSERT_CHECK_BUDGET_MS rather than injecting a bare one-shot check — the
 * supervisor is what survives an injection refused by a mid-load document and
 * a navigation racing the check, and the in-guest script checks synchronously
 * on arrival, so a condition that holds settles on the first look regardless.
 * See the constant's doc for the tolerance this knowingly grants a condition
 * that arrives late. `elapsedMs` is deliberately not reported: for a bounded
 * check it is machinery noise, where for a wait it is the answer.
 */
async function handleAssert(webview: WebviewTag, request: AssertRequest): Promise<ControlResponse> {
  const invalid = assertSpecError(request)
  if (invalid) return { ok: false, error: invalid }
  const outcome = await waitForPageCondition(webview, buildPageWaitSpec(request), {
    timeoutMs: ASSERT_CHECK_BUDGET_MS,
    pollMs: WAIT_MIN_POLL_MS,
    invalidReason: () => browserPaneError(request.targetPaneId)
  })
  if ('error' in outcome) return { ok: false, error: outcome.error }
  if (!outcome.settled) {
    return { ok: false, error: `assertion failed: ${describeAssertFailure(request)}` }
  }
  const { settled: _settled, elapsedMs: _elapsedMs, ...extras } = outcome
  return { ok: true, result: { ...extras } }
}

/**
 * A verb main answers in full and never relays, so this window has nothing to
 * do but exist for it.
 *
 * The stub is still this type's to supply rather than core's: the coverage
 * gate is over every verb in the protocol (see `unhandledControlVerbs`), so an
 * unclaimed name would have to be stubbed in core's own module under this
 * type's name — exactly the coupling the registry split removed. Reaching one
 * of these means a request was relayed that shouldn't have been, which is a
 * wiring bug in main's verb table, hence the flat error rather than a silent
 * success.
 *
 * One helper rather than three literals for the same reason `relayed` above is
 * one: the three that need it (readNetworkRequests, captureNetworkBodies,
 * saveResource) differ only in the verb name, and each carried its own copy of
 * this paragraph with a noun swapped. Core's `batch` stub reads the same but
 * stays its own: it lives on the other side of the plugin boundary, and its
 * reason differs — batch is *decomposed* in main into sub-requests that are
 * each relayed here individually, not answered there.
 */
function answeredInMain(verb: string): () => ControlResponse {
  return () => ({ ok: false, error: `${verb} is handled in the main process` })
}

/**
 * Claims every verb this content type answers. Called once from this
 * package's `activate`, i.e. only when the browser type is actually
 * registered — a build without it answers these verbs with core's
 * "no handler" error rather than silently doing nothing.
 */
export function registerBrowserControlVerbs(ctx: RendererPluginContext): void {
  const { registerControlVerb } = ctx
  registerControlVerb('createBrowserPane', handleCreateBrowserPane)
  registerControlVerb('navigate', withWebview(handleNavigate))
  registerControlVerb('reload', withWebview(handleReload))
  registerControlVerb(
    'goBack',
    withWebview((webview, request) => handleHistoryStep(webview, 'back', request.targetPaneId))
  )
  registerControlVerb(
    'goForward',
    withWebview((webview, request) => handleHistoryStep(webview, 'forward', request.targetPaneId))
  )
  registerControlVerb('activatePane', handleActivatePane)
  registerControlVerb('closePane', handleClosePane)
  registerControlVerb('listOwnedPanes', handleListOwnedPanes)
  registerControlVerb('getPaneInfo', withWebview(handlePaneInfo))
  registerControlVerb('screenshot', withWebview(handleScreenshot))
  registerControlVerb('getPageText', withWebview(handleGetPageText))
  registerControlVerb('readPage', withWebview(handleReadPage))
  registerControlVerb('find', withWebview(handleFind))
  // The input verbs run under the focus guard — the guest side of a click or
  // focus() pulls host focus onto the webview element (see
  // withHostFocusRestored), and these are the verbs that trigger it.
  const click = withWebview(handleClick)
  const type = withWebview(handleType)
  const key = withWebview(handleKey)
  const formInput = withWebview(handleFormInput)
  // hover takes the full guard even though only half of it can fire, and that
  // is deliberate rather than copied. The *activation* half is inert by
  // construction: main's guest-activation listener bails on anything that
  // isn't a `mouseDown` (see main/guestActivation.ts and the measured
  // event-type table in CLAUDE.md), and hover sends only `mouseMove`. The
  // *focus* half is not — a page's own mouseenter handler is free to call
  // el.focus(), which pulls host focus onto the <webview> exactly as a click's
  // does, and that is the whole reason this wrapper exists. Taking the pair is
  // cheaper than a hover-only variant that would have to be re-audited every
  // time either half changes.
  const hover = withWebview(handleHover)
  registerControlVerb('click', (request) => withHostFocusRestored(() => click(request)))
  registerControlVerb('hover', (request) => withHostFocusRestored(() => hover(request)))
  registerControlVerb('type', (request) => withHostFocusRestored(() => type(request)))
  registerControlVerb('key', (request) => withHostFocusRestored(() => key(request)))
  registerControlVerb('scroll', withWebview(handleScroll))
  registerControlVerb('readConsoleMessages', handleReadConsoleMessages)
  registerControlVerb('executeJavaScript', withWebview(handleExecuteJavaScript))
  // No focus guard: waitFor injects no input and focuses nothing — it only
  // watches. withWebview alone, like the read verbs above. assert is its
  // single-shot twin and shares the reasoning.
  registerControlVerb('waitFor', withWebview(handleWaitFor))
  registerControlVerb('assert', withWebview(handleAssert))
  registerControlVerb('formInput', (request) => withHostFocusRestored(() => formInput(request)))
  // The three main answers alone, each because it owns the machinery: the
  // webRequest capture (readNetworkRequests), the CDP body session
  // (captureNetworkBodies, see main/networkBodyCapture.ts), and the fetch
  // routes plus the file sink (saveResource). See `answeredInMain`.
  registerControlVerb('readNetworkRequests', answeredInMain('readNetworkRequests'))
  registerControlVerb('captureNetworkBodies', answeredInMain('captureNetworkBodies'))
  registerControlVerb('saveResource', answeredInMain('saveResource'))
}
