import type { Api, CaffeinateFlags } from '@shared/api'
import type { OwnershipChange } from '@shared/externalControl'
import type { LayoutSnapshot } from '@shared/layout'
import type {
  CrossWindowMessageFromMain,
  CrossWindowMessageFromRenderer
} from '@shared/layoutCrossWindow'
import { DEFAULT_SETTINGS, type Settings } from '@shared/settings'
import type { ShortcutActionId } from '@shared/shortcuts'
import type { ExtraStubType, FakeApiHandle, TestSeed } from '@shared/testing/fakeApiHandle'
import { createFakeContentBridge } from './content'
import { Emitter } from './emitter'

declare global {
  interface Window {
    /** The fake bridge's driver handle — installed by the test setups alongside `window.api`. */
    __fakeApi?: FakeApiHandle
    /** Seed the browser-tier harness reads before mounting (set via page.addInitScript). */
    __tabsTestSeed?: TestSeed
    /** Extra stub content types the browser-tier harness registers before mounting (set via page.addInitScript) — see ExtraStubType. */
    __tabsTestExtraContent?: ExtraStubType[]
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
  const ownershipChange = new Emitter<OwnershipChange>()
  const crossWindowFromMain = new Emitter<CrossWindowMessageFromMain>()
  const crossWindowSent: CrossWindowMessageFromRenderer[] = []
  // One emitter for every shortcut, carrying the id — the same shape the real
  // bridge uses, so subscribers filter rather than the channel doing it.
  const shortcut = new Emitter<ShortcutActionId>()
  const content = createFakeContentBridge()
  let caffeinateRunning = false
  const caffeinateStarts: CaffeinateFlags[] = []
  let caffeinateStops = 0
  const caffeinateRunningChange = new Emitter<boolean>()
  const caffeinateOpenDialog = new Emitter<void>()

  const api: Api = {
    pane: { confirmClose: async () => true },
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
      },
      // Cross-window drag needs a real second window, so main's side is
      // whatever a test emits (FakeApiHandle.emitCrossWindow) and the
      // renderer's side is recorded. One message is answered: `release`,
      // which every targetless in-window drop waits on before flying the
      // ghost home — with no second window the answer is always "no",
      // deferred a tick like a real round trip.
      sendCrossWindow: (message) => {
        crossWindowSent.push(message)
        if (message.type === 'release') {
          queueMicrotask(() =>
            crossWindowFromMain.emit({ type: 'release-result', committed: false })
          )
        }
      },
      onCrossWindow: (listener) => crossWindowFromMain.subscribe(listener)
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
    caffeinate: {
      isRunningSync: () => caffeinateRunning,
      // Synchronous, self-contained flips rather than a round trip a test
      // would have to separately emit back: a real click on Start/Decaf
      // should be immediately visible in what the button/menu-forwarding
      // wiring reads next, the same way the real bridge's own state changes
      // once main's broadcastRunning lands.
      start: (flags) => {
        caffeinateStarts.push(flags)
        caffeinateRunning = true
        caffeinateRunningChange.emit(true)
      },
      stop: () => {
        caffeinateStops += 1
        caffeinateRunning = false
        caffeinateRunningChange.emit(false)
      },
      onRunningChanged: (callback) => caffeinateRunningChange.subscribe(callback),
      onOpenDialog: (callback) => caffeinateOpenDialog.subscribe(() => callback())
    },
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

  const handle: FakeApiHandle = {
    api,
    reset(next = {}) {
      settings = { ...DEFAULT_SETTINGS, ...next.settings }
      layout = next.layout
      fullScreen = false
      captureMode = false
      layoutSets.length = 0
      settingsSets.length = 0
      openedExternalUrls.length = 0
      copiedText.length = 0
      caffeinateRunning = false
      caffeinateStarts.length = 0
      caffeinateStops = 0
      crossWindowSent.length = 0
      // Emitter subscriber sets deliberately survive — see FakeApiHandle.reset.
    },
    fireShortcut: (id) => shortcut.emit(id),
    emitSettingsChange: (partial) => settingsChange.emit(partial),
    emitFullScreenChange: (value) => {
      fullScreen = value
      fullScreenChange.emit(value)
    },
    fireCaffeinateOpenDialog: () => caffeinateOpenDialog.emit(),
    emitCaffeinateRunningChanged: (running) => {
      caffeinateRunning = running
      caffeinateRunningChange.emit(running)
    },
    caffeinateStarts: () => [...caffeinateStarts],
    caffeinateStops: () => caffeinateStops,
    emitOwnershipChanged: (paneId, owned) => {
      ownershipChange.emit({ paneId, owned })
    },
    emitCrossWindow: (message) => crossWindowFromMain.emit(message),
    crossWindowSent: () => [...crossWindowSent],
    layoutSets: () => [...layoutSets],
    settingsSets: () => [...settingsSets],
    openedExternalUrls: () => [...openedExternalUrls],
    copiedText: () => [...copiedText],
    captureMode: () => captureMode,
    ...content.handle
  }
  return handle
}
