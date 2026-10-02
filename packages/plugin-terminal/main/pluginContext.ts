import type { MainPluginContext } from '@tabs/plugin-sdk/main/api'
import { createPluginContextHolder } from '@tabs/plugin-sdk/shared/plugin/contextHolder'

/**
 * The main-process plugin context this package activated with — how module
 * functions that run outside activation scope (pty creation, the quit hook)
 * reach core. Set once, first thing in this package's `activate`.
 */
export const terminalMainCtx = createPluginContextHolder<MainPluginContext>('terminal (main)')
