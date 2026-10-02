import type {
  ContentRendererDef,
  ContentRendererProps,
  RendererPluginContext
} from '@tabs/plugin-sdk/renderer/api'
import { createLeaf } from '@tabs/plugin-sdk/shared/model/factories'
import type { LeafContent } from '@tabs/plugin-sdk/shared/model/types'
import type { WebviewTag } from 'electron'
import { createElement, useEffect } from 'react'
import { BrowserHeaderTitle } from '../renderer/BrowserHeaderTitle'
import { BrowserIcon } from '../renderer/browserIcons'
import {
  acquireBrowser,
  type BrowserInstance,
  createConsoleLog,
  releaseBrowser
} from '../renderer/browserRegistry'
import { BROWSER_TYPE, manifest } from '../shared/manifest'

/**
 * The browser as the native-vs-Electron visual comparison renders it
 * (native/Visual/capture-electron.mjs, through the Chromium harness). Never
 * part of the app: reached only from the harness's registerTestContent.ts.
 *
 * A `<webview>` doesn't render in the harness (it is an Electron-only tag), so
 * this is the real chrome around a stand-in page. The header is the package's
 * own `BrowserHeaderTitle` as the pane's `HeaderTitle`, reading its state from
 * a fake `BrowserInstance` acquired through the real `acquireBrowser` (which
 * is how `BrowserRenderer` publishes the live one), so Back and Forward can be
 * enabled per scenario. The body is `.browser-content` holding a solid-color
 * box with the webview's own class, `.browser-webview`, where the page goes: the
 * comparison decided that the chrome is exact and page text isn't compared.
 */

/** One browser pane's state as a scenario seeds it (the README's `browser.<leaf id>`, minus `focusAddress`). */
export interface BrowserVisualSeed {
  canGoBack?: boolean
  canGoForward?: boolean
  /** The stand-in page's background, a CSS color. */
  page: string
}

/**
 * A `webview` as far as the header and the registry read one: the history
 * flags the scenario seeds, the URL the layout holds, and listeners that never
 * fire (nothing navigates).
 */
function fakeWebview(url: string, seed: BrowserVisualSeed): WebviewTag {
  const fake = {
    src: url,
    getURL: () => url,
    canGoBack: () => seed.canGoBack === true,
    canGoForward: () => seed.canGoForward === true,
    addEventListener: () => {},
    removeEventListener: () => {},
    loadURL: () => Promise.resolve(),
    goBack: () => {},
    goForward: () => {},
    reload: () => {}
  }
  return fake as unknown as WebviewTag
}

function fakeInstance(url: string, seed: BrowserVisualSeed): BrowserInstance {
  return {
    webview: fakeWebview(url, seed),
    console: createConsoleLog(),
    loadFailure: { current: null },
    documentStatus: { current: null },
    onGuestAttached: { current: null },
    unsubscribe: () => {}
  }
}

/**
 * The stand-in for `BrowserRenderer`: the same lifecycle (acquire the instance
 * from an effect, after the header has mounted without one, release it on
 * unmount) around a solid-color box.
 */
function standInRenderer(seeds: Record<string, BrowserVisualSeed>) {
  return function BrowserStandIn({ node }: ContentRendererProps<LeafContent>) {
    const seed = seeds[node.id]
    if (!seed) throw new Error(`browser visual capture: no seed for pane ${node.id}`)
    useEffect(() => {
      const url = (node.config.url as string | undefined) ?? 'about:blank'
      acquireBrowser(node.id, () => fakeInstance(url, seed))
      return () => releaseBrowser(node.id, () => {})
    }, [node.id, node.config.url, seed])
    return createElement(
      'div',
      { className: 'browser-content' },
      createElement('div', { className: 'browser-webview', style: { background: seed.page } })
    )
  }
}

/** What a scenario asks of the browser: its panes' pages, and whether empty panes offer "New browser" (the README's `creationActions`). */
export interface BrowserVisualCapture {
  panes: Record<string, BrowserVisualSeed>
  createAction: boolean
}

/**
 * The capture's stand-in for this package's `activate`: the same context and
 * type identity, with the body swapped for the stand-in page. The creation
 * action is left out unless the scenario asks for it, so that an empty pane
 * shows the same toolbar as in every other scenario.
 */
export function activateVisualCapture(
  ctx: RendererPluginContext,
  capture: BrowserVisualCapture
): void {
  const def: ContentRendererDef<LeafContent> = {
    type: manifest.type,
    displayName: manifest.displayName,
    Component: standInRenderer(capture.panes),
    HeaderTitle: BrowserHeaderTitle,
    ...(capture.createAction
      ? {
          createAction: {
            testId: 'pane-new-browser-button',
            label: 'New browser',
            Icon: BrowserIcon,
            createContent: () => createLeaf(BROWSER_TYPE, { url: 'about:blank' })
          }
        }
      : {})
  }
  ctx.registerContent(def)
}
