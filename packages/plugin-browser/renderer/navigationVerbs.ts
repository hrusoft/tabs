import type { ControlResponse } from '@tabs/plugin-sdk/shared/externalControl'
import { createLeaf } from '@tabs/plugin-sdk/shared/model/factories'
import type { ContentNode } from '@tabs/plugin-sdk/shared/model/types'
import type { WebviewTag } from 'electron'
import type { BrowserControlRequest } from '../shared/externalControl'
import { LOAD_WAIT_MS, MOUNT_WAIT_MS } from '../shared/externalControl'
import { BrowserMethod } from '../shared/ipc'
import { BROWSER_TYPE, manifest as browserManifest } from '../shared/manifest'
import type { BrowserNewPanePlacement } from '../shared/settings'
import { isTrivialUrlChange } from '../shared/urlComparison'
import { getBrowserPane } from './browserControl'
import { mainFrameLoadError } from './browserRegistry'
import { getBrowserSettings } from './browserSettingsAccess'
import { pollUntil } from './pageWait'
import { browserCtx } from './pluginContext'
import { evalInGuest } from './verbSupport'

/**
 * The verbs that load a document into a browser pane — createBrowserPane,
 * navigate, reload, and the history steps — and the page state every one of
 * them reports once the load settles.
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

export async function handleCreateBrowserPane(
  request: Extract<BrowserControlRequest, { type: 'createBrowserPane' }>
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
 * The flag reads `document.title` straight out of the guest at response
 * time, not a flag tracked from `page-title-updated` events: Chromium fires
 * that only when a title *differs* from what was showing, so a reload (or a
 * history step onto a page sharing its predecessor's title) fires none —
 * measured on the real `<webview>` events — and an event-tracked flag reports
 * the *previous* document's explicitness. `document.title` is the DOM's own
 * record (empty when the document set nothing), with no state to go stale.
 * It is *not* what `title` reports: `getTitle()` is Chromium's UI-facing
 * title, which falls back to the URL.
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
  // A guest that can't run script right now (mid-attach, a Chromium internal
  // page) is rare enough, and the flag advisory enough, that assuming
  // explicit (no flag) beats failing the whole verb — the same stance
  // `title`/`url` take by reading whatever the webview last committed.
  const titleRead = await evalInGuest<unknown>(webview, 'document.title')
  const hasExplicitTitle = 'error' in titleRead || titleRead.value !== ''
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

export async function handleNavigate(
  webview: WebviewTag,
  request: Extract<BrowserControlRequest, { type: 'navigate' }>
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

export async function handleReload(
  webview: WebviewTag,
  request: Extract<BrowserControlRequest, { type: 'reload' }>
): Promise<ControlResponse> {
  webview.reload()
  const outcome = await waitForLoadEnd(webview, LOAD_WAIT_MS)
  // url/title but no `redirected`: there is no requested URL to compare
  // against — reload's subject is whatever page the pane already had.
  return { ok: true, result: { ...outcome, ...(await pageState(webview, request.targetPaneId)) } }
}

export async function handleHistoryStep(
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
