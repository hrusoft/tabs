import type { SettingsPluginContext } from '../../../renderer/src/plugin/settingsApi'
import { installBrowserSettingsAccess } from '../renderer/browserSettingsAccess'
import { browserSettingsPageDef } from './BrowserSettingsPage'

/**
 * Everything the browser package contributes to the Settings window — the
 * settings-side twin of renderer/index.ts, and a separate entry on purpose:
 * this graph must reach the settings page without ever touching
 * BrowserRenderer, whose import would drag `<webview>` into a window that
 * only draws a sidebar and a form.
 */
export function activate(ctx: SettingsPluginContext): void {
  installBrowserSettingsAccess(ctx.settings)
  ctx.registerSettingsPage(browserSettingsPageDef)
}
