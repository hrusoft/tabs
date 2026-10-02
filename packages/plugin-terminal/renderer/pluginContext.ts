import type { RendererPluginContext } from '@tabs/plugin-sdk/renderer/api'
import { createPluginContextHolder } from '@tabs/plugin-sdk/shared/plugin/contextHolder'

/**
 * The pane-window plugin context this package activated with — how modules
 * that run outside activation scope (the renderer's effects, the def's
 * hooks) reach core. Set once, first thing in this package's `activate`.
 */
export const terminalCtx = createPluginContextHolder<RendererPluginContext>('terminal')
