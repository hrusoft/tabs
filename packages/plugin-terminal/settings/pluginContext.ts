import type { SettingsPluginContext } from '@tabs/plugin-sdk/settings/api'
import { createPluginContextHolder } from '@tabs/plugin-sdk/shared/plugin/contextHolder'

/**
 * The terminal package's Settings-window context, for code that runs outside
 * activation scope (the appearance page's own hooks) — the settings-side twin
 * of renderer/pluginContext.ts.
 */
export const terminalSettingsCtx =
  createPluginContextHolder<SettingsPluginContext>('terminal/settings')
