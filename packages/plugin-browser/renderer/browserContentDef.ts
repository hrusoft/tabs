import type { ContentRendererDef } from '@tabs/plugin-sdk/renderer/api'
import { createLeaf } from '@tabs/plugin-sdk/shared/model/factories'
import type { LeafContent } from '@tabs/plugin-sdk/shared/model/types'
import { PANE_NOT_MOUNTED_ERROR } from '../shared/externalControl'
import { BROWSER_TYPE, manifest as browserManifest } from '../shared/manifest'
import { BrowserHeaderTitle } from './BrowserHeaderTitle'
import { BrowserRenderer } from './BrowserRenderer'
import { narrowBrowserHandle } from './browserControl'
import { BrowserIcon } from './browserIcons'
import { guestViewport } from './verbSupport'

/**
 * Mints `pane-info`'s `pageInstance` — an opaque value that changes exactly
 * when the page behind a pane is re-created, i.e. reloaded from scratch with
 * its history, in-page state, console and refs gone.
 *
 * The guest `WebContents` id is the right thing to watch: a structural
 * reparent destroys the guest and builds a new one with a new id (see
 * browserRegistry.ts), and a cross-window move lands the pane on a new guest
 * in another renderer. Ids restart with the process, though, so a bare id
 * could repeat across a restart and read as "nothing happened"; prefixing a
 * token minted once per renderer process makes a restart (or a renderer
 * reload, which re-creates every guest anyway) change it too.
 */
const RENDERER_TOKEN = crypto.randomUUID().slice(0, 8)

/**
 * `pageInstance` for `webview`, or undefined in the instant a re-created
 * page has no guest yet (`getWebContentsId()` throws then — see
 * BrowserRenderer's focusGuest).
 */
function pageInstanceOf(webview: { getWebContentsId(): number }): string | undefined {
  try {
    return `${RENDERER_TOKEN}-${webview.getWebContentsId()}`
  } catch {
    return undefined
  }
}

/**
 * The browser's content-registry contribution — registered by
 * registerBuiltins. New browser panes start blank; splitting or tabbing from
 * one copies its config as-is (no deriveConfig).
 *
 * Identity comes from the shared census, not from literals here — see
 * shared/content/registry.ts.
 */
export const browserContentDef: ContentRendererDef<LeafContent> = {
  type: browserManifest.type,
  displayName: browserManifest.displayName,
  Component: BrowserRenderer,
  createAction: {
    testId: 'pane-new-browser-button',
    label: 'New browser',
    Icon: BrowserIcon,
    createContent: () => createLeaf(BROWSER_TYPE, { url: 'about:blank' })
  },
  HeaderTitle: BrowserHeaderTitle,
  // `listOwnedPanes`'s per-pane summary — config-only, works whether or not
  // the pane is currently mounted, matching what this verb has always read.
  listSummaryForControl: (leaf) => ({ url: (leaf.config.url as string | undefined) ?? '' }),
  // `getPaneInfo`'s full, live read — moved here verbatim from the old
  // browser-only `handlePaneInfo` (see CLAUDE.md's external-control entry for
  // why `hidden`/`viewport` are a conditional pair rather than a `visible`
  // boolean, and why `showingErrorPage`/`loadError` are conditional too).
  describeForControl: async (_leaf, handle) => {
    const browserHandle = narrowBrowserHandle(handle?.extension)
    const webview = browserHandle?.webview()
    if (!browserHandle || !webview) return { error: PANE_NOT_MOUNTED_ERROR }
    const visible = webview.checkVisibility()
    // The same page-read viewport screenshot reports (see guestViewport), so
    // the two can never disagree about the space a coordinate click is in.
    const viewport = visible ? await guestViewport(webview) : null
    const loadError = browserHandle.lastLoadError() ?? null
    const pageInstance = pageInstanceOf(webview)
    return {
      fields: {
        ...(pageInstance ? { pageInstance } : {}),
        url: webview.getURL(),
        title: webview.getTitle(),
        isLoading: webview.isLoading(),
        canGoBack: webview.canGoBack(),
        canGoForward: webview.canGoForward(),
        ...(loadError ? { showingErrorPage: true as const, loadError } : {}),
        ...(viewport
          ? { viewport: { width: viewport.width, height: viewport.height } }
          : { hidden: true as const })
      }
    }
  }
}
