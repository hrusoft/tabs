import type { MainPluginContext } from '../../../main/plugin/api'
import { createPluginContextHolder } from '../../../shared/plugin/contextHolder'

/**
 * The main-process plugin context this package activated with — how module
 * functions that run outside activation scope (pty creation, the quit hook)
 * reach core. Set once, first thing in this package's `activate`.
 */
export const terminalMainCtx = createPluginContextHolder<MainPluginContext>('terminal (main)')
