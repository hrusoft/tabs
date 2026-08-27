import { createTypedSettingsAccess } from '../../../renderer/src/plugin/api'
import { type BrowserSettings, DEFAULT_BROWSER_SETTINGS } from '../shared/settings'

/**
 * The browser's typed view of its settings blob — see createTypedSettingsAccess
 * for what the factory holds and why the narrowing cast inside it is sound.
 * Named exports rather than the object itself so `use` keeps a `use*` name and
 * reads as the hook it is at every call site.
 */
const access = createTypedSettingsAccess<BrowserSettings>('browser', DEFAULT_BROWSER_SETTINGS)

export const installBrowserSettingsAccess = access.install
export const getBrowserSettings = access.get
export const useBrowserSetting = access.use
export const updateBrowserSettings = access.update
