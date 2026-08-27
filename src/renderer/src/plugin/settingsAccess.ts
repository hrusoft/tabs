import { useSettingsStore } from '../core/store/settingsStore'
import type { PluginSettingsAccess } from './api'

/**
 * The one implementation of a package's scoped settings surface, shared by
 * both context factories: the pane window's (plugin/context.ts) and the
 * Settings window's (plugin/settingsContext.ts). The two windows activate a
 * package separately, but "your own blob and nothing else" must mean the same
 * thing in both — one implementation is what keeps that true.
 */
export function createPluginSettingsAccess(type: string): PluginSettingsAccess {
  return {
    get: () => useSettingsStore.getState().contentTypes[type],
    use: (select) => useSettingsStore((state) => select(state.contentTypes[type])),
    update: (blob) => useSettingsStore.getState().setContentTypeSettings(type, blob)
  }
}
