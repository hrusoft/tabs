import { isContentTypeEnabled } from '@shared/content/enablement'
import { useState, useSyncExternalStore } from 'react'
import { useSettingsStore } from '../core/store/settingsStore'
import {
  getSettingsPagesVersion,
  listSettingsPages,
  subscribeSettingsPages
} from './settingsPageRegistry'

/**
 * The Settings window's whole tree: a macOS System Settings-style sidebar of
 * categories on the left, and the active category's controls on the right.
 * The sidebar comes from the settings-page registry (core pages plus each
 * content type's contribution — see registerBuiltinPages.ts), not a
 * hardcoded list. Active tab is plain component state — a single,
 * non-persisted UI concern scoped to one window, unlike the persisted
 * settings themselves (see settingsStore.ts).
 *
 * The title bar above it is the app's own chrome, not the OS's: this window
 * hides its native title bar the same way the main one does (see
 * createSettingsWindow in src/main/windows.ts), so it has to draw and provide
 * its own drag region — .settings-titlebar, sized and positioned to match
 * the main window's own root tab bar (.tab-bar-root in
 * content/tabs/TabBar.tsx), so the two read as one app's chrome even though
 * they're two different mechanisms (this window has no tab group of its own
 * to grow a bar out of).
 *
 * A disabled content type's page is filtered out here rather than at
 * registration: the registry is a plain map with no business reading settings,
 * and re-registering on every settings change would churn the very store this
 * sidebar subscribes to. Which pages that applies to is declared, not inferred
 * — a page names the type it configures via `contentType` (see
 * terminalSettingsPageDef), and core's own pages leave it absent, so they are
 * never touched.
 */
export function SettingsWindow() {
  // Subscribed so a page registered after mount (a future plugin) appears
  // without a reload — the same pattern as ContentView on contentRegistry.
  useSyncExternalStore(subscribeSettingsPages, getSettingsPagesVersion)
  const disabledContentTypes = useSettingsStore((state) => state.disabledContentTypes)
  const pages = listSettingsPages().filter(
    (page) =>
      page.contentType === undefined || isContentTypeEnabled(disabledContentTypes, page.contentType)
  )
  const [activeTab, setActiveTab] = useState('general')
  // Derived rather than written back into `activeTab`: disabling a type while
  // its page is on screen must not leave a blank pane with nothing selected,
  // and keeping the state untouched means re-enabling returns the user to the
  // page they were reading. Reachable from another window's edit, since
  // settingsStore mirrors settings:changed.
  const visibleTab = pages.some((page) => page.id === activeTab) ? activeTab : pages[0]?.id
  const ActivePage = pages.find((page) => page.id === visibleTab)?.Component
  return (
    <div className="settings-shell">
      <header className="settings-titlebar" data-testid="settings-titlebar">
        Settings
      </header>
      <div className="settings-window" data-testid="settings-window">
        <nav className="settings-sidebar" aria-label="Settings categories">
          {pages.map(({ id, label, Icon }) => (
            <button
              key={id}
              type="button"
              className="settings-sidebar-item"
              data-active={visibleTab === id || undefined}
              data-testid={`settings-tab-${id}`}
              onClick={() => setActiveTab(id)}
            >
              <Icon />
              <span>{label}</span>
            </button>
          ))}
        </nav>
        <div className="settings-content">{ActivePage && <ActivePage />}</div>
      </div>
    </div>
  )
}
