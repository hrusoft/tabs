import { createPluginContextHolder } from '@shared/plugin/contextHolder'
import type { SettingsPluginContext } from '../../../renderer/src/plugin/settingsApi'

/**
 * The terminal package's Settings-window context, for code that runs outside
 * activation scope (the appearance page's own hooks) — the settings-side twin
 * of renderer/pluginContext.ts.
 */
export const terminalSettingsCtx =
  createPluginContextHolder<SettingsPluginContext>('terminal/settings')
