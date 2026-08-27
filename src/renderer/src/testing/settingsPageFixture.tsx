import { DEFAULT_SETTINGS, type Settings } from '@shared/settings'
import { render } from '@testing-library/react'
import type { ComponentType } from 'react'
import { useSettingsStore } from '../core/store/settingsStore'

/**
 * Mounting a Settings-window page over a stated settings snapshot, and reading
 * back what it persisted.
 *
 * The Settings window is its own entry point (settings-main.tsx), so its pages
 * are mounted directly — there is no `renderApp` equivalent to go through, and
 * every page test was writing the same three lines out for itself.
 *
 * Their order is the contract rather than a style: the fake bridge is seeded
 * *before* the store, because `settingsStore` reads
 * `window.api.settings.getSync()` at module-eval time and the write read back
 * below goes through that same bridge.
 */
export function mountSettingsPage(Page: ComponentType, partial: Partial<Settings> = {}): void {
  const settings: Settings = { ...DEFAULT_SETTINGS, ...partial }
  window.__fakeApi?.reset({ settings })
  useSettingsStore.setState(settings)
  render(<Page />)
}

/** The last value a page persisted for `key`, or undefined if it never wrote that key. */
export function lastSettingsWrite<K extends keyof Settings>(key: K): Settings[K] | undefined {
  const writes = window.__fakeApi?.settingsSets() ?? []
  return writes.at(-1)?.[key]
}
