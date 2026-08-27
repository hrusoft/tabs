import { isContentTypeEnabled } from '@shared/content/enablement'
import { exposedCwdOf } from '../content/exposedCwd'
import { registerControlVerb } from '../content/externalControl'
import { placeNewPane, placeNewUnpinnedPane, revealPane } from '../content/placement'
import { dispatchNavChord } from '../content/spatialNav'
import { getPaneHandle, registerPaneHandle } from '../core/registry/paneHandles'
import { contentRegistry } from '../core/registry/registry'
import { useBellStore } from '../core/store/bellStore'
import { allRoots, findNodeAnywhere, useLayoutStore } from '../core/store/layoutStore'
import { useSettingsStore } from '../core/store/settingsStore'
import type { RendererPluginContext } from './api'
import { createPluginSettingsAccess } from './settingsAccess'

/**
 * Core's side of the renderer plugin API: builds the context a content-type
 * package activates against. The only importer is the activation site
 * (content/registerBuiltins.ts, plus the test tiers' registerTestContent.ts),
 * so this file is where "what a plugin may do" is wired to what core actually
 * does — the one place the two can drift, and therefore the one place to look
 * when a context capability misbehaves.
 *
 * Each context is bound to a single content type at creation. That binding is
 * load-bearing, not bookkeeping: it is what scopes `settings` to the package's
 * own blob and lets `registerContent` reject a def whose `type` claims some
 * other package's name — the closest a statically-linked package system gets
 * to the loader-era reconciliation of "you registered what you declared".
 *
 * Everything here delegates; nothing holds state. The layout surface reads
 * `useLayoutStore.getState()` per call rather than capturing a snapshot, so a
 * context created at boot stays correct for the window's lifetime.
 */
export function createRendererPluginContext(type: string): RendererPluginContext {
  return {
    registerContent: (def) => {
      if (def.type !== type) {
        throw new Error(
          `content-type package "${type}" tried to register a renderer for "${def.type}"`
        )
      }
      contentRegistry.register(def)
    },
    registerControlVerb,
    exposedCwdOf,
    dispatchNavChord,
    openExternal: (url) => window.api.appWindow.openExternal(url),
    isEnabled: () => isContentTypeEnabled(useSettingsStore.getState().disabledContentTypes, type),
    panes: {
      registerHandle: registerPaneHandle,
      getHandle: getPaneHandle
    },
    layout: {
      setLeafConfig: (nodeId, config) => useLayoutStore.getState().setLeafConfig(nodeId, config),
      setLiveTitle: (nodeId, title) => useLayoutStore.getState().setLiveTitle(nodeId, title),
      setActivePane: (id) => useLayoutStore.getState().setActivePane(id),
      closePane: (nodeId) => useLayoutStore.getState().closePane(nodeId),
      findNode: (id) => findNodeAnywhere(useLayoutStore.getState(), id),
      allRoots: () => allRoots(useLayoutStore.getState()),
      placeNewPane,
      placeNewUnpinnedPane,
      revealPane
    },
    ipc: {
      invoke: (method, ...args) => window.api.content.invoke(type, method, ...args),
      send: (method, ...args) => window.api.content.send(type, method, ...args),
      on: (event, listener) => window.api.content.on(type, event, listener)
    },
    bell: {
      ring: (id) => {
        // One "this pane rang" report, two core-owned surfacings: the in-app
        // indicator (attention-gated inside bellStore.ring) and the Dock
        // bounce (focus-gated in main). The enablement gate covers both, as
        // it always has — it used to live in the terminal's onBell, moved
        // here so the ringer states the event and core decides what the user
        // sees.
        if (!useSettingsStore.getState().enableBellIndicator) return
        useBellStore.getState().ring(id)
        window.api.bell.ring()
      },
      clear: (id) => useBellStore.getState().clear(id)
    },
    settings: createPluginSettingsAccess(type)
  }
}
