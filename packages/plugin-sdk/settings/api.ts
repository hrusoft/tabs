import type { ComponentType } from 'react'
import type { PluginSettingsAccess } from '../renderer/api'

export type { PluginSettingsAccess } from '../renderer/api'
// The presentational rows a settings page is built from — named, not
// `export *`, because rows.tsx also exports RowText, an internal helper the
// rows share. The same four core's old `settingsApi.ts` exposed; the
// boundary ledger sanctions this barrel, not rows.tsx.
export {
  parseNumberInput,
  SettingsCheckboxRow,
  SettingsNumberRow,
  SettingsSelectRow
} from './rows'

/**
 * The Settings-window plugin API — the settings-side sibling of
 * ../renderer/api.ts, and a separate module for the same reason the
 * Settings window has its own entry point: its graph must stay free of
 * everything a pane window carries. A package's settings entry may import
 * this and nothing else of core; its pane entry imports ../renderer/api.ts
 * and never this.
 */

/**
 * A package's Settings page as the package declares it. `contentType` is
 * deliberately not here: the context stamps the package's own type on the
 * registered page, which is what hides it from the sidebar while the type is
 * turned off — a package can neither forget that wiring nor claim another
 * type's. Sidebar `order` is stamped the same way, from the package's census
 * position, so two packages cannot pick colliding literals and the sidebar
 * follows PLUGIN_PACKAGES order like every other package-contributed row.
 */
export interface PluginSettingsPageDef {
  /** Feeds the `settings-tab-${id}` test id; the page component owns its own `settings-page-${id}`. */
  id: string
  label: string
  Icon: ComponentType
  Component: ComponentType
}

/**
 * What core lends a content-type package in the Settings window. Handed to
 * the package's settings `activate` once, before the first render.
 */
export interface SettingsPluginContext {
  /** Registers the package's sidebar page. A duplicate id throws, same as every registry here. */
  registerSettingsPage(page: PluginSettingsPageDef): void
  /**
   * Installed system font families, for font-picker rows (macOS only;
   * resolves empty elsewhere, and callers fall back to free text).
   */
  listFontFamilies(): Promise<string[]>
  settings: PluginSettingsAccess
}
