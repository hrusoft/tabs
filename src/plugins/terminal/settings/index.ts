import type { SettingsPluginContext } from '../../../renderer/src/plugin/settingsApi'
import { installTerminalSettingsAccess } from '../renderer/terminalSettingsAccess'
import { terminalSettingsCtx } from './pluginContext'
import { terminalSettingsPageDef } from './TerminalSettingsPage'

/**
 * Everything the terminal package contributes to the Settings window — the
 * settings-side twin of the renderer entry (../renderer/index.ts), and a separate entry on purpose:
 * this graph must reach the appearance page and the shared settings accessor
 * without ever touching TerminalRenderer, whose import would drag xterm and
 * its CSS into a window that only draws a sidebar and a form.
 */
export function activate(ctx: SettingsPluginContext): void {
  terminalSettingsCtx.set(ctx)
  installTerminalSettingsAccess(ctx.settings)
  ctx.registerSettingsPage(terminalSettingsPageDef)
}
