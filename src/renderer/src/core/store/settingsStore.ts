import { DEFAULT_SETTINGS, type Settings } from '@shared/settings'
import { create } from 'zustand'

export interface SettingsState extends Settings {
  /** Updates one core (flat) setting locally and persists it through the main process. */
  setSetting: <K extends Exclude<keyof Settings, 'contentTypes'>>(
    key: K,
    value: Settings[K]
  ) => void
  /**
   * Replaces `type`'s settings blob wholesale and persists it. Always pass a
   * COMPLETE blob — that's the write contract (see Settings.contentTypes):
   * main and the onChange mirror below merge at the contentTypes-record
   * level only, so sibling types survive but the named type's blob is
   * replaced, not patched.
   */
  setContentTypeSettings: (type: string, settings: unknown) => void
}

/**
 * Persisted app settings, mirrored from the main process's settings.json
 * (see src/main/settings.ts). Read synchronously at module init — the same
 * pattern as layoutStore's snapshot — so the first render already reflects
 * them and an early toggle can never be overwritten by a late async
 * hydration response. The defaults spread underneath is belt-and-braces for
 * the sync read somehow coming back empty; the main process registers the
 * handler before any window loads.
 */
export const useSettingsStore = create<SettingsState>()((set, get) => ({
  ...DEFAULT_SETTINGS,
  ...window.api.settings.getSync(),
  setSetting: (key, value) => {
    const patch = { [key]: value } as Partial<Settings>
    set(patch)
    window.api.settings.set(patch)
  },
  setContentTypeSettings: (type, settings) => {
    set({ contentTypes: { ...get().contentTypes, [type]: settings } })
    window.api.settings.set({ contentTypes: { [type]: settings } })
  }
}))

// Mirrors a change made in another window (e.g. editing a color in the
// Settings window while the main window is open) into this store, so an
// already-mounted renderer never needs a reload to see it. Only ever calls
// setState — never setSetting/api.settings.set — so it can't loop back
// through settings:changed. contentTypes gets the same one-level merge as
// main's settings:set handler, so a broadcast carrying one type's blob can't
// clobber a sibling type's in this window. One store instance per renderer
// for the process's lifetime, so no unsubscribe is needed.
window.api.settings.onChange((partial) => {
  useSettingsStore.setState((state) =>
    partial.contentTypes
      ? { ...partial, contentTypes: { ...state.contentTypes, ...partial.contentTypes } }
      : partial
  )
})
