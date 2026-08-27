import type { SettingsPluginContext } from '../../../renderer/src/plugin/settingsApi'
import { installGitTreeSettingsAccess } from '../renderer/gitTreeSettingsAccess'
import { gitTreeSettingsPageDef } from './GitTreeSettingsPage'

/**
 * Everything the git tree package contributes to the Settings window — the
 * settings-side twin of renderer/index.ts, and a separate entry on purpose:
 * the Settings window's own entry point never runs registerBuiltins, so
 * globbing the pane-window renderer entry from there would pull
 * GitTreeRenderer (and its CSS) into a window that only draws a sidebar and a
 * form.
 */
export function activate(ctx: SettingsPluginContext): void {
  installGitTreeSettingsAccess(ctx.settings)
  ctx.registerSettingsPage(gitTreeSettingsPageDef)
}
