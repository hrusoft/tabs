import { CONTENT_TYPE_MANIFESTS, type ContentTypeId } from '@shared/content/registry'
import { registerSettingsPage } from '../settings/settingsPageRegistry'
import { createPluginSettingsAccess } from './settingsAccess'
import type { SettingsPluginContext } from './settingsApi'

/**
 * Core's side of the Settings-window plugin API — the settings-side sibling
 * of plugin/context.ts, kept in its own module so the Settings window's entry
 * graph pulls in the page registry and the settings store, and none of what a
 * pane window carries (layout store, placement, pane handles).
 */
export function createSettingsPluginContext(type: ContentTypeId): SettingsPluginContext {
  // Sidebar position is the package's census position (PLUGIN_PACKAGES
  // order), stamped here like `contentType` — not a number the page picks.
  // Two packages once picked the same literal, which left the order to the
  // registry's label tiebreak: correct-looking by accident, and a rename
  // away from reshuffling the sidebar. Core's own pages pin the ends
  // (General 0, Skills 100); the 10+ band sits between them.
  const order = 10 + CONTENT_TYPE_MANIFESTS.findIndex((manifest) => manifest.type === type)
  return {
    registerSettingsPage: (page) => registerSettingsPage({ ...page, order, contentType: type }),
    listFontFamilies: () => window.api.fonts.listFamilies(),
    settings: createPluginSettingsAccess(type)
  }
}
