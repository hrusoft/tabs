import type { Api, CoreApi } from '@shared/api'
import type { LayoutSnapshot } from '@shared/layout'
import { DEFAULT_SETTINGS, type Settings } from '@shared/settings'
import type { ShortcutActionId } from '@shared/shortcuts'
import type { FakeApiHandle, TestSeed } from '@shared/testing/fakeApiHandle'
import { createFakeContentBridge } from './content'
import { Emitter } from './emitter'

declare global {
  interface Window {
    /** The fake bridge's driver handle — installed by the test setups alongside `window.api`. */
    __fakeApi?: FakeApiHandle
    /** Seed the browser-tier harness reads before mounting (set via page.addInitScript). */
    __tabsTestSeed?: TestSeed
    /**
     * Ask the browser-tier harness to register a *second* creation-capable
     * content type (set via page.addInitScript — see mountTestApp.tsx for why
     * it is opt-in rather than always on). Deliberately not a `TestSeed`
     * field: the seed is state the real app would read from disk, and this is
     * a registration, which the real app takes from registerBuiltins.
     */
    __tabsTestExtraContent?: boolean
  }
}

/**
 * An in-memory implementation of the whole `window.api` bridge, so the real
 * renderer can mount with no Electron behind it (jsdom component tests, and
 * the Playwright browser tier via harnessMain.ts). Typed against `Api`, so a
 * preload surface change is a compile error here, not silent drift. The
 * returned handle scripts the parts a test needs to drive: firing the event
 * subscriptions the app installed, and reading back what it persisted.
 *
 * Core's namespaces are built here, annotated `Api` so a missing one fails
 * to compile. The generic content bridge and each package's fake main entry
 * come from ./content/index.ts; its driver half spreads into the returned
 * handle, which the `FakeApiHandle` annotation keeps honest the same way.
 */
export function createFakeApi(seed: TestSeed = {}): FakeApiHandle {
  let settings: Settings = { ...DEFAULT_SETTINGS, ...seed.settings }
  let layout = seed.layout
  let fullScreen = false
  let captureMode = false
  const layoutSets: LayoutSnapshot[] = []
  const settingsSets: Partial<Settings>[] = []
  const openedExternalUrls: string[] = []
  const copiedText: string[] = []
  const settingsChange = new Emitter<Partial<Settings>>()
  const fullScreenChange = new Emitter<boolean>()
  const ownershipChange = new Emitter<{ paneId: string; owned: boolean }>()
  // One emitter for every shortcut, carrying the id — the same shape the real
  // bridge uses, so subscribers filter rather than the channel doing it.
  const shortcut = new Emitter<ShortcutActionId>()
  const content = createFakeContentBridge()

  const core: CoreApi = {
    pane: { confirmClose: async () => handle.confirmCloseResponse },
    appWindow: {
      isFullScreen: async () => fullScreen,
      onFullScreenChange: (callback) => fullScreenChange.subscribe(callback),
      openSettings: () => {},
      // Recorded rather than ignored: "the OS opened it" is unobservable in
      // every tier, so what a test can assert is that the right URL left the
      // app — see FakeApiHandle.openedExternalUrls.
      openExternal: (url) => {
        openedExternalUrls.push(url)
      },
      // A fixed, obviously-fake identity. The real answer comes from
      // app.getVersion()/process.versions, neither of which exists here, and
      // pinning a literal is what lets a jsdom test assert the About window
      // renders what it was given rather than whatever it happens to run on.
      getAppInfoSync: () => ({
        version: '0.0.0-test',
        electron: '0.0.0',
        chrome: '0.0.0',
        node: '0.0.0'
      }),
      // 0, like the real answer on non-macOS: neither tier this bridge serves
      // (jsdom, plain Chromium) runs behind a real OS-rounded window frame.
      getCornerRadiusSync: () => 0,
      copyText: (text) => {
        copiedText.push(text)
      }
    },
    settings: {
      // Synchronous, like preload's sendSync — the store reads it at module init.
      getSync: () => ({ ...settings }),
      // Recording is the whole contract for both set()s: writes are appended
      // for the handle's settingsSets()/layoutSets() assertions and getSync
      // deliberately keeps answering from the seed, unlike the real bridge,
      // where main persists a write and a later getSync reflects it. The
      // tiers re-seed per test (reset/fresh page), so nothing observes the
      // difference — a test that needs post-write reads should reset with the
      // written value as its seed instead.
      set: (partial) => {
        settingsSets.push(partial)
      },
      onChange: (callback) => settingsChange.subscribe(callback)
    },
    layout: {
      // Undefined is the first-run path: layoutStore's `!snapshot?.root` guard
      // falls back to a single empty pane, same as a missing layout.json.
      getSync: () => layout as LayoutSnapshot,
      // See settings.set above — write-only by design.
      set: (snapshot) => {
        layoutSets.push(snapshot)
      }
    },
    shortcuts: {
      onShortcut: (id, callback) =>
        shortcut.subscribe((fired) => {
          if (fired === id) callback()
        }),
      setCaptureMode: (active) => {
        captureMode = active
      }
    },
    bell: { ring: () => {} },
    fonts: { listFamilies: async () => [] },
    externalControl: {
      onRequest: () => () => {},
      respond: () => {},
      // No ownership at boot in tests — nothing here creates a pane via
      // tabs-ctl before the app mounts, so an empty snapshot always matches a
      // fresh launch. A test exercises the indicator through
      // emitOwnershipChanged, the live path, same as the real ledger's push.
      getOwnedPanesSync: () => [],
      onOwnershipChanged: (callback) =>
        ownershipChange.subscribe(({ paneId, owned }) => callback(paneId, owned))
    },
    skills: {
      status: async () => [],
      install: async () => ({ ok: true }),
      uninstall: async () => ({ ok: true })
    },
    content: content.api
  }

  const api: Api = core

  const handle: FakeApiHandle = {
    api,
    confirmCloseResponse: true,
    reset(next = {}) {
      settings = { ...DEFAULT_SETTINGS, ...next.settings }
      layout = next.layout
      fullScreen = false
      captureMode = false
      layoutSets.length = 0
      settingsSets.length = 0
      openedExternalUrls.length = 0
      copiedText.length = 0
      handle.confirmCloseResponse = true
      // Emitter subscriber sets deliberately survive — see FakeApiHandle.reset.
    },
    fireShortcut: (id) => shortcut.emit(id),
    emitSettingsChange: (partial) => settingsChange.emit(partial),
    emitFullScreenChange: (value) => {
      fullScreen = value
      fullScreenChange.emit(value)
    },
    emitOwnershipChanged: (paneId, owned) => {
      ownershipChange.emit({ paneId, owned })
    },
    layoutSets: () => [...layoutSets],
    settingsSets: () => [...settingsSets],
    openedExternalUrls: () => [...openedExternalUrls],
    copiedText: () => [...copiedText],
    captureMode: () => captureMode,
    ...content.handle
  }
  return handle
}
