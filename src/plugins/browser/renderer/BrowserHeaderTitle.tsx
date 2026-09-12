import './browser.css'
import type { LeafContent } from '@shared/model/types'
import { useEffect, useRef, useState } from 'react'
import { HeaderButton } from '../../../renderer/src/plugin/api'
import { resolveAddressInput } from './addressInput'
import { BackIcon, ForwardIcon, RefreshIcon } from './browserIcons'
import { useBrowserInstance } from './browserRegistry'

/**
 * The browser's `ContentRendererDef.HeaderTitle` — back/forward/refresh + an
 * address bar, replacing the pane header's whole title slot. Used to be the
 * pane body's own separate `.browser-toolbar`; now the header *is* the nav
 * chrome, and `BrowserRenderer`'s body holds nothing but the `<webview>`.
 *
 * Reads the pane's live `BrowserInstance` reactively via `useBrowserInstance`
 * (a subscription, because `Pane` mounts this component before the body that
 * creates the instance — see createPaneValueStore). `BrowserRenderer`, which
 * alone owns the webview's DOM container, stays the sole owner of that
 * instance's create/dispose lifecycle; this only listens on its webview, per
 * mount, so a structural remount re-wires the listeners to the new mount's
 * own state rather than leaving the instance calling a dead mount's setters.
 */
export function BrowserHeaderTitle({ leaf }: { leaf: LeafContent }) {
  const addressInputRef = useRef<HTMLInputElement>(null)
  const [addressValue, setAddressValue] = useState(
    () => (leaf.config.url as string | undefined) ?? 'about:blank'
  )
  const [canGoBack, setCanGoBack] = useState(false)
  const [canGoForward, setCanGoForward] = useState(false)
  const instance = useBrowserInstance(leaf.id)

  useEffect(() => {
    if (!instance) return
    const { webview } = instance
    const sync = (): void => {
      try {
        // A background navigation (the user clicked a link on the page)
        // shouldn't stomp on address-bar text the user is mid-typing.
        if (document.activeElement !== addressInputRef.current) {
          setAddressValue(webview.getURL() || webview.src)
        }
        setCanGoBack(webview.canGoBack())
        setCanGoForward(webview.canGoForward())
      } catch {
        // Throws if the guest hasn't finished attaching yet (a brand-new
        // instance) — the useState defaults already seeded from
        // leaf.config.url cover that case, and did-navigate fills in the
        // real values once it fires.
      }
    }
    sync()
    webview.addEventListener('did-navigate', sync)
    webview.addEventListener('did-navigate-in-page', sync)
    return () => {
      webview.removeEventListener('did-navigate', sync)
      webview.removeEventListener('did-navigate-in-page', sync)
    }
  }, [instance])

  const navigateTo = (value: string): void => {
    const url = resolveAddressInput(value)
    if (url) instance?.webview.loadURL(url)
  }

  return (
    <>
      <HeaderButton
        testId="browser-back-button"
        label="Back"
        disabled={!canGoBack}
        onPress={() => instance?.webview.goBack()}
      >
        <BackIcon />
      </HeaderButton>
      <HeaderButton
        testId="browser-forward-button"
        label="Forward"
        disabled={!canGoForward}
        onPress={() => instance?.webview.goForward()}
      >
        <ForwardIcon />
      </HeaderButton>
      <HeaderButton
        testId="browser-refresh-button"
        label="Refresh"
        onPress={() => instance?.webview.reload()}
      >
        <RefreshIcon />
      </HeaderButton>
      <div className="browser-address-bar" data-testid="browser-address-bar">
        {leaf.title && (
          <div
            className="browser-title-segment"
            title={leaf.title}
            data-testid="browser-title-segment"
          >
            {leaf.title}
          </div>
        )}
        <input
          ref={addressInputRef}
          type="text"
          className="browser-address-input"
          data-testid="browser-address-input"
          aria-label="Address"
          value={addressValue}
          onChange={(event) => setAddressValue(event.target.value)}
          onKeyDown={(event) => {
            if (event.key !== 'Enter') return
            navigateTo(addressValue)
            addressInputRef.current?.blur()
          }}
        />
      </div>
    </>
  )
}
