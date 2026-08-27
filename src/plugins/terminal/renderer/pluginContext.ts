import { createPluginContextHolder } from '@shared/plugin/contextHolder'
import type { RendererPluginContext } from '../../../renderer/src/plugin/api'

/**
 * The pane-window plugin context this package activated with — how modules
 * that run outside activation scope (the renderer's effects, the def's
 * hooks) reach core. Set once, first thing in this package's `activate`.
 */
export const terminalCtx = createPluginContextHolder<RendererPluginContext>('terminal')
