import { ipcMain } from 'electron'
import { pluginEventChannel, pluginMethodChannel } from '../../shared/plugin/bridge'
import { registerCloseBlockerProvider } from '../closeBlockers'
import { controlSocketPath } from '../controlSocket'
import { registerMainControlVerbs } from '../controlVerbs'
import { grantOwnership, isOwnedPane } from '../externalControl'
import { onRendererMessage } from '../ipcListeners'
import { refreshLeafConfigs } from '../layout'
import { openExternalUrl } from '../openExternal'
import { registerPaneHost } from '../paneHostRegistry'
import { userDataPath } from '../persist'
import { getSettings, subscribeSettings } from '../settings'
import type { MainPluginContext } from './api'

/**
 * Core's side of the main-process plugin API: builds the context a
 * content-type package's `activate` receives. The only importer is the
 * activation site (contentTypes.ts), so this file is where "what a plugin may
 * do in main" is wired to what core actually does.
 *
 * Everything delegates; nothing holds state. Bound to the package's type,
 * which is what scopes `ipc` — every channel it registers or emits on is
 * derived under `plugin:<type>:` by the same builders preload uses, so
 * cross-package collisions are impossible by construction rather than by
 * review.
 */
export function createMainPluginContext(type: string): MainPluginContext {
  return {
    ipc: {
      handle: (method, handler) => ipcMain.handle(pluginMethodChannel(type, method), handler),
      on: (method, listener) => onRendererMessage(pluginMethodChannel(type, method), listener),
      emit: (target, event, ...args) => {
        target.send(pluginEventChannel(type, event), ...args)
      }
    },
    registerControlVerbs: registerMainControlVerbs,
    isOwnedPane,
    grantOwnership,
    registerPaneHost,
    registerCloseBlockerProvider,
    refreshLeafConfigs,
    openExternalUrl,
    controlSocketPath,
    userDataPath,
    settings: {
      get: getSettings,
      subscribe: subscribeSettings
    }
  }
}
