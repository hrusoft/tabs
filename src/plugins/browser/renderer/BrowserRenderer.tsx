import './browser.css'
import type { LeafContent } from '@shared/model/types'
import type { RingLog } from '@shared/ringLog'
import type { WebviewTag } from 'electron'
import { useCallback, useEffect, useRef } from 'react'
import { type ContentRendererProps, focusIsInPaneChrome } from '../../../renderer/src/plugin/api'
import { BrowserGuestMethod } from '../shared/ipc'
import {
  acquireBrowser,
  type ConsoleEntry,
  consoleLevelName,
  createConsoleLog,
  type DocumentStatus,
  mainFrameLoadError,
  releaseBrowser
} from './browserRegistry'
import { createGuestReporter } from './guestReport'
import { browserCtx } from './pluginContext'

/**
 * Renders the live `<webview>` behind a browser pane (`src/main/windows.ts`
 * merges in the `webviewTag` preference this needs; `src/plugins/browser/
 * main/index.ts` is what hardens what an attached guest may then do —
 * popups, navigation). The nav chrome (back/forward/refresh + address bar)
 * is not here — it's BrowserHeaderTitle, this type's `ContentRendererDef.
 * HeaderTitle`, in the pane's own header. `node.config.url` seeds the
 * webview's starting page and is kept in sync on every navigation via
 * `setLeafConfig`, so a remount, a duplicated pane, or an app restart all
 * resume at the current page rather than the original seed URL.
 */
export function BrowserRenderer({ node }: ContentRendererProps<LeafContent>) {
  const containerRef = useRef<HTMLDivElement>(null)
  const webviewRef = useRef<WebviewTag | null>(null)
  const consoleRef = useRef<RingLog<ConsoleEntry> | null>(null)
  const loadFailureRef = useRef<{ current: string | null } | null>(null)
  const documentStatusRef = useRef<{ current: DocumentStatus | null } | null>(null)
  // A focus this pane owes its guest, deferred because the guest didn't exist
  // when it was asked for — see focusGuest.
  const pendingFocusRef = useRef(false)

  /**
   * Hands the keyboard to the guest, or arranges to once there is one.
   *
   * `<webview>.focus()` is not the element's own — Electron overrides it to
   * forward into the guest `WebContents`, so calling it while no guest is
   * attached throws out of Electron's element code (`Cannot read properties
   * of null (reading 'focus')`), and there is no public way to ask whether
   * one is: `getWebContentsId()` throws the same way, which is why the
   * `getURL()`/`canGoBack()` reads in the effect below are already wrapped.
   *
   * The gap this closes is not exotic. A structural reparent — a pane drag,
   * a tab group collapsing — destroys the guest and builds a new one under
   * the same element (see browserRegistry.ts), and React remounts the pane
   * in that same commit, so core's focus-follows-active asks the fresh mount
   * to take focus while the element is momentarily guestless. That throw used
   * to take the whole app down — it escapes a layout effect, React unmounts
   * the tree, the window goes blank, and because layout persistence is
   * debounced (see persistLayout) the drop that caused it never reaches disk,
   * so the next launch restores the pre-drag tree and it reads as a crash
   * rather than as a focus bug. Core now isolates that for every content type
   * (see `dispatchFocus` in paneHandles.ts), so what is left here is not the
   * crash but the focus itself.
   *
   * Deferring rather than merely swallowing is what actually delivers it:
   * the pane really is the active one, and the guest attaching is the
   * first moment it can have the keyboard. `PaneFocusFollower` will not ask
   * again — it fires on `activePaneId` *changing*, and a move keeps the pane
   * active throughout. Measured, a second `registerHandle` does land during
   * the drop (the pane mounts twice) and its focus succeeds because the
   * attach has already happened by then — but that is an incidental extra
   * commit, not a guarantee: with the deferral removed the focus still
   * arrives today, and would silently stop arriving the day those two
   * commits collapse into one.
   *
   * Stable across renders (it closes over refs and `node.id`, which doesn't
   * change for a mounted pane) so the handle effect below can name it as a
   * dependency honestly: re-registering the handle re-runs
   * `registerPaneHandle`, which focuses an already-active pane, so a fresh
   * identity per render would refocus this guest on every keystroke in the
   * address bar.
   */
  const focusGuest = useCallback((): void => {
    const webview = webviewRef.current
    if (!webview) return
    // A click on this pane's own header chrome (the address bar, a nav
    // button) activates the pane too — the guest must not yank focus off
    // whatever the user just chose there. Checked on the deferred path as
    // well, since the user can reach the header during the attach.
    if (focusIsInPaneChrome(node.id)) return
    try {
      webview.focus()
      pendingFocusRef.current = false
    } catch {
      pendingFocusRef.current = true
    }
  }, [node.id])

  // node.config.url is read directly (not through a dependency) each time
  // this effect runs, rather than reacting to it changing: it's only ever
  // used to seed a brand-new instance or to refresh `src` before a reparent
  // (see below), never to react to a navigation this same renderer just
  // caused by writing back through setLeafConfig — that would re-run the
  // effect on every navigation for no reason.
  // biome-ignore lint/correctness/useExhaustiveDependencies: see above
  useEffect(() => {
    const container = containerRef.current
    if (!container) return

    const instance = acquireBrowser(node.id, () => {
      const webview = document.createElement('webview')
      webview.className = 'browser-webview'
      webview.src = (node.config.url as string | undefined) ?? 'about:blank'
      const consoleLog = createConsoleLog()
      const loadFailure: { current: string | null } = { current: null }
      const documentStatus: { current: DocumentStatus | null } = { current: null }

      // These listeners live as long as the instance, across remounts —
      // anything mount-scoped must be reached through
      // `onGuestAttached.current`, never captured here, or a structural
      // remount leaves them calling a dead mount's closure (see
      // BrowserInstance.onGuestAttached). The header's own address-bar and
      // nav-state sync is not here at all: BrowserHeaderTitle listens on the
      // webview itself, per mount.
      const onGuestAttached: { current: (() => void) | null } = { current: null }

      // A pane opened with no URL starts on about:blank (browserContentDef),
      // and Chromium counts that commit as an ordinary history entry: the
      // first real navigation would leave Back pointing at a blank page the
      // user never asked to visit. Dropping the entry on the way out of it
      // keeps Back meaning "where I came from". Deliberately scoped to the
      // *initial* blank — a later, deliberate about:blank is somewhere the
      // user chose to be, and its history is left alone.
      //
      // Worth knowing: whether that entry existed at all used to depend on
      // timing, since a navigation issued before the blank commits replaces
      // it instead of stacking on it. e2e/browser.spec.ts's history test
      // only passed by winning that race (see the settle wait it now does
      // first, which fails 3/3 against this file without the clear below).
      let atInitialBlank = webview.src === 'about:blank'

      const onDidNavigate = (event: Electron.DidNavigateEvent): void => {
        if (atInitialBlank && event.url !== 'about:blank') {
          atInitialBlank = false
          webview.clearHistory()
        }
        // A new document means a new console. Safe to clear on commit: the
        // new page's own scripts don't run until after this fires, so nothing
        // belonging to it has been captured yet. Deliberately not done for
        // did-navigate-in-page below, which is the same document.
        consoleLog.clear()
        browserCtx.get().layout.setLeafConfig(node.id, { url: event.url })
      }
      const onConsoleMessage = (event: Electron.ConsoleMessageEvent): void => {
        consoleLog.add({
          level: consoleLevelName(event.level),
          text: event.message,
          timestamp: Date.now(),
          sourceURL: event.sourceId,
          line: event.line
        })
      }
      const onDidNavigateInPage = (event: Electron.DidNavigateInPageEvent): void => {
        browserCtx.get().layout.setLeafConfig(node.id, { url: event.url })
      }
      // The HTTP status lives only on the commit event, and only on the
      // frame-level one — the element's `did-navigate` carries just the URL —
      // so it's recorded on these instance-lifetime listeners for the same
      // first-load reason as loadFailure below. Chromium reports -1 for
      // non-HTTP documents (about:blank, its own error pages), which records
      // as "no status" rather than a number nobody sent. In-page navigations
      // fire did-navigate-in-page instead, never this, so the current
      // document's status survives them untouched.
      const onDidFrameNavigate = (event: Electron.DidFrameNavigateEvent): void => {
        if (!event.isMainFrame) return
        documentStatus.current =
          event.httpResponseCode >= 100
            ? { status: event.httpResponseCode, statusText: event.httpStatusText }
            : null
      }
      const onTitleUpdated = (event: Electron.PageTitleUpdatedEvent): void => {
        browserCtx.get().layout.setLiveTitle(node.id, event.title)
      }
      // Which guest currently backs this pane, told to main. Re-reported on
      // every attach rather than seeded once: a structural reparent destroys
      // the guest WebContents and builds a new one with a new id under this
      // same element (see browserRegistry.ts).
      //
      // Called from three points because `did-attach` alone is too early to
      // read the id — the reason, and the measurements behind it, live on
      // createGuestReporter, which also makes the rule testable without a
      // <webview>. Every call is idempotent, so the redundancy is free.
      const reportGuest = createGuestReporter(
        node.id,
        () => webview.getWebContentsId(),
        (paneId, guestId) => browserCtx.get().ipc.send(BrowserGuestMethod.attached, paneId, guestId)
      )
      const onDidAttach = (): void => {
        reportGuest()
        // The next macrotask, not a microtask: measured, the id is unreadable
        // in both `did-attach` and the microtask after it, and first readable
        // here.
        setTimeout(reportGuest, 0)
        onGuestAttached.current?.()
      }
      // A load failure has to be recorded here, not just wherever someone is
      // awaiting a load: the guest starts loading the moment it attaches, and
      // a connection refused can be over before external control has even
      // seen the webview exist (see BrowserInstance.loadFailure).
      const onDidStartLoading = (): void => {
        loadFailure.current = null
      }
      const onDidFailLoad = (event: Electron.DidFailLoadEvent): void => {
        const error = mainFrameLoadError(event)
        if (error) loadFailure.current = error
      }

      webview.addEventListener('did-navigate', onDidNavigate)
      webview.addEventListener('did-frame-navigate', onDidFrameNavigate)
      webview.addEventListener('did-navigate-in-page', onDidNavigateInPage)
      webview.addEventListener('page-title-updated', onTitleUpdated)
      webview.addEventListener('did-attach', onDidAttach)
      webview.addEventListener('dom-ready', reportGuest)
      webview.addEventListener('console-message', onConsoleMessage)
      webview.addEventListener('did-start-loading', onDidStartLoading)
      webview.addEventListener('did-fail-load', onDidFailLoad)

      return {
        webview,
        console: consoleLog,
        loadFailure,
        documentStatus,
        onGuestAttached,
        unsubscribe: () => {
          webview.removeEventListener('did-navigate', onDidNavigate)
          webview.removeEventListener('did-frame-navigate', onDidFrameNavigate)
          webview.removeEventListener('did-navigate-in-page', onDidNavigateInPage)
          webview.removeEventListener('page-title-updated', onTitleUpdated)
          webview.removeEventListener('did-attach', onDidAttach)
          webview.removeEventListener('dom-ready', reportGuest)
          webview.removeEventListener('console-message', onConsoleMessage)
          webview.removeEventListener('did-start-loading', onDidStartLoading)
          webview.removeEventListener('did-fail-load', onDidFailLoad)
          browserCtx.get().ipc.send(BrowserGuestMethod.detached, node.id)
        }
      }
    })

    // No-op if already the container's child; re-parents on a remount. A
    // genuine reparent reloads the guest page (see browserRegistry.ts) —
    // guarded here so a no-op React re-run (e.g. StrictMode's dev double
    // effect) can't trigger that reload for nothing. When a reparent is
    // real, refresh `src` from the latest known URL first so the reload
    // Electron is about to do anyway lands on the current page rather than
    // whatever URL this instance was first created with.
    if (instance.webview.parentElement !== container) {
      const latestUrl = (node.config.url as string | undefined) ?? instance.webview.src
      if (latestUrl !== instance.webview.src) instance.webview.src = latestUrl
      container.appendChild(instance.webview)
    }
    webviewRef.current = instance.webview
    consoleRef.current = instance.console
    loadFailureRef.current = instance.loadFailure
    documentStatusRef.current = instance.documentStatus
    // This mount's own attach hook.
    instance.onGuestAttached.current = () => {
      if (pendingFocusRef.current) focusGuest()
    }

    return () => {
      instance.onGuestAttached.current = null
      releaseBrowser(node.id, (dying) => dying.unsubscribe())
    }
  }, [node.id])

  // This pane's core handle (see core/registry/paneHandles.ts): how core's
  // focus-follows-active reaches the guest, and how external-control
  // requests (see ../externalControl.ts) reach this pane's live webview.
  // BrowserHeaderTitle reaches the same webview a different way — through
  // useBrowserInstance (browserRegistry.ts), not this handle — since it
  // already knows this pane is a browser and has no need for core's
  // type-agnostic capability lookup. Registered separately from the
  // acquire/release effect above so it doesn't participate in that effect's
  // reattach/no-op-guard logic, and lazily (getters, not the element) so it
  // keeps resolving correctly as the pane reattaches.
  useEffect(
    () =>
      browserCtx.get().panes.registerHandle(node.id, {
        focus: focusGuest,
        // Only release focus the guest still holds — by the time a
        // deactivation runs, focus may already belong to the next pane. That
        // check also covers the guestless window focusGuest documents: an
        // element with no guest is never `document.activeElement`, so the
        // `blur()` that would throw the same way is never reached.
        blur: () => {
          const webview = webviewRef.current
          if (webview && document.activeElement === webview) webview.blur()
          pendingFocusRef.current = false
        },
        extension: {
          webview: () => webviewRef.current,
          consoleMessages: (sinceSeq: number | undefined) =>
            consoleRef.current?.list(sinceSeq) ?? [],
          lastLoadError: () => loadFailureRef.current?.current ?? null,
          documentStatus: () => documentStatusRef.current?.current ?? null
        }
      }),
    [node.id, focusGuest]
  )

  return <div className="browser-content" data-testid="browser" ref={containerRef} />
}
