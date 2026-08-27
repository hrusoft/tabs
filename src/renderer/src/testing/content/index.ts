import type { ContentBridgeApi } from '@shared/plugin/bridge'
import { assertPluginTypeName } from '@shared/plugin/bridge'
import { resolvePluginEntries } from '@shared/plugin/entries'
import type { ContentFakeApiHandle } from '@shared/testing/content/api'
import type { FakeContentHost } from '@shared/testing/fakeApiHandle'
import { Emitter } from '../emitter'

/**
 * The fake generic content bridge, and each package's fake main entry
 * installed into it — the test tiers' twin of the real pair (preload's
 * `window.api.content` + each package's main `activate` registering methods).
 * The pieces are discovered the way every other boundary's entries are: a
 * glob over `src/plugins/<name>/testing/fakeApi.ts`, reconciled against each
 * manifest's declared `testing` entry (shared/plugin/entries.ts).
 *
 * One routing table per verb kind, keyed by type name — the same namespace
 * discipline the real channel derivation gives: a package's methods and
 * events cannot collide with another's, and a call against a method nothing
 * registered rejects the way a real `ipcRenderer.invoke` with no handler does
 * — a typo surfaces as a loud failure, not a silent undefined.
 *
 * Each piece receives a host scoped to its own type and returns its driver
 * contribution. The composed handle is cast to `ContentFakeApiHandle` rather
 * than compile-checked complete — the one completeness check discovery cost,
 * traded knowingly: a driver method a package stopped contributing fails the
 * test that calls it, by name, which is the same loudness one step later.
 */
const fakeEntries = import.meta.glob<{
  installFake: (host: FakeContentHost) => Partial<ContentFakeApiHandle>
}>('../../../../plugins/*/testing/fakeApi.ts', { eager: true })

export function createFakeContentBridge(): { api: ContentBridgeApi; handle: ContentFakeApiHandle } {
  const invokeHandlers = new Map<string, (...args: unknown[]) => unknown>()
  const sendListeners = new Map<string, (...args: unknown[]) => void>()
  const emitters = new Map<string, Emitter<unknown[]>>()

  const key = (type: string, name: string): string => `${type} ${name}`
  const emitterFor = (type: string, event: string): Emitter<unknown[]> => {
    const k = key(type, event)
    let emitter = emitters.get(k)
    if (!emitter) {
      emitter = new Emitter<unknown[]>()
      emitters.set(k, emitter)
    }
    return emitter
  }

  const hostFor = (type: string): FakeContentHost => {
    assertPluginTypeName(type)
    return {
      handle: (method, handler) => {
        invokeHandlers.set(key(type, method), handler)
      },
      on: (method, listener) => {
        sendListeners.set(key(type, method), listener)
      },
      emit: (event, ...args) => emitterFor(type, event).emit(args)
    }
  }

  const api: ContentBridgeApi = {
    invoke: async (type, method, ...args) => {
      const handler = invokeHandlers.get(key(type, method))
      if (!handler) {
        throw new Error(`fake content bridge: no handler for "${type}"/"${method}"`)
      }
      return handler(...args)
    },
    // Silent on an unregistered method, like a real ipcMain.on with no listener.
    send: (type, method, ...args) => sendListeners.get(key(type, method))?.(...args),
    on: (type, event, listener) => emitterFor(type, event).subscribe((args) => listener(...args))
  }

  const handle = {} as ContentFakeApiHandle
  for (const [type, entry] of resolvePluginEntries('testing', fakeEntries)) {
    Object.assign(handle, entry.installFake(hostFor(type)))
  }

  return { api, handle }
}
