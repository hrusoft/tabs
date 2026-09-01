import { contextBridge, ipcRenderer } from 'electron'
import type {
  Api,
  AppInfo,
  AppWindowApi,
  BellApi,
  CoreApi,
  ExternalControlApi,
  FontsApi,
  LayoutApi,
  PaneApi,
  SettingsApi,
  ShortcutsApi,
  SkillInstallTarget,
  SkillResult,
  SkillsApi
} from '../shared/api'
import type {
  ControlRequest,
  ControlResponse,
  RelayedControlRequest,
  RelayedControlResponse
} from '../shared/externalControl'
import { IpcChannel } from '../shared/ipc'
import type { LayoutSnapshot } from '../shared/layout'
import type { ContentBridgeApi } from '../shared/plugin/bridge'
import { pluginEventChannel, pluginMethodChannel } from '../shared/plugin/bridge'
import type { Settings } from '../shared/settings'
import type { ShortcutActionId } from '../shared/shortcuts'
import { on } from './ipcOn'

/**
 * The whole `window.api` bridge — core namespaces plus the generic content
 * bridge every content-type package speaks IPC through. Packages ship no
 * preload code: their typed clients live renderer-side over `content`, whose
 * channel derivation (shared/plugin/bridge.ts) is the entire contract.
 */

/**
 * Content-neutral pane operations. `confirmClose` is the warn-before-closing
 * check: the main process asks its registered close-blocker providers (see
 * src/main/closeBlockers.ts) whether anything under the panes being closed is
 * still doing work.
 */
const pane: PaneApi = {
  confirmClose: (ids: string[]): Promise<boolean> =>
    ipcRenderer.invoke(IpcChannel.paneConfirmClose, ids)
}

/**
 * Bridges the main process's native fullscreen state — not observable from
 * CSS or the DOM Fullscreen API, since traffic-light-triggered fullscreen
 * on macOS is a BrowserWindow-level event, not an HTML one — plus the two
 * things only the main process can do to a window: open Settings, and hand a
 * URL to the OS. `openExternal` is fire-and-forget; main validates the
 * protocol before it reaches the shell (see openExternalUrl in main/openExternal.ts).
 *
 * `getAppInfoSync` and `copyText` serve the About window: the first is a
 * synchronous read for the same reason layout/settings are (it feeds the
 * first painted frame), the second reaches the clipboard through main rather
 * than `navigator.clipboard`, which needs a focused document — see the note
 * on AppWindowApi.copyText in src/shared/api.ts.
 */
const appWindow: AppWindowApi = {
  isFullScreen: (): Promise<boolean> => ipcRenderer.invoke(IpcChannel.windowIsFullScreen),
  onFullScreenChange: (callback: (isFullScreen: boolean) => void): (() => void) =>
    on(IpcChannel.windowFullScreenChanged, callback),
  openSettings: (): void => {
    ipcRenderer.send(IpcChannel.windowOpenSettings)
  },
  openExternal: (url: string): void => {
    ipcRenderer.send(IpcChannel.windowOpenExternal, url)
  },
  getAppInfoSync: (): AppInfo => ipcRenderer.sendSync(IpcChannel.windowGetAppInfoSync),
  getCornerRadiusSync: (): number => ipcRenderer.sendSync(IpcChannel.windowGetCornerRadiusSync),
  copyText: (text: string): void => {
    ipcRenderer.send(IpcChannel.windowCopyText, text)
  }
}

/**
 * Menu-driven shortcuts (New Tab, New Horizontal Split, New Vertical Split,
 * New Unpinned Pane, Close Pane, Clear Buffer) — see src/main/menu.ts's
 * buildMenu for why these come from a native menu accelerator instead of a
 * renderer-side keydown listener, and src/shared/shortcuts.ts for the
 * bindings they carry, which the user can rebind. `setCaptureMode` is the
 * Settings window arming its recorder.
 *
 * Every action arrives on one channel carrying its id, so the filtering
 * happens here rather than in the channel name — which is what lets a new
 * shortcut be an entry in the shared action registry instead of an edit in
 * this file too.
 */
const shortcuts: ShortcutsApi = {
  onShortcut: (id: ShortcutActionId, callback: () => void): (() => void) =>
    on(IpcChannel.shortcutAction, (fired: ShortcutActionId) => {
      if (fired === id) callback()
    }),
  setCaptureMode: (active: boolean): void => {
    ipcRenderer.send(IpcChannel.shortcutsSetCapture, active)
  }
}

/**
 * Persisted app settings, backed by a JSON file in the main process (see
 * src/main/settings.ts). `getSync` is synchronous like `layout.getSync` —
 * settingsStore reads it at module init, before the first render. `set` is
 * fire-and-forget since the renderer keeps its own optimistic copy in sync
 * (see settingsStore.ts).
 */
const settings: SettingsApi = {
  getSync: (): Settings => ipcRenderer.sendSync(IpcChannel.settingsGetSync),
  set: (partial: Partial<Settings>): void => {
    ipcRenderer.send(IpcChannel.settingsSet, partial)
  },
  onChange: (callback: (partial: Partial<Settings>) => void): (() => void) =>
    on(IpcChannel.settingsChanged, callback)
}

/**
 * Persisted pane layout, backed by a JSON file in the main process (see
 * src/main/layout.ts). `getSync` is synchronous — it runs at layoutStore's
 * module init, before the first render, so the real layout is there from the
 * start instead of popping in after an empty-pane flash.
 */
const layout: LayoutApi = {
  getSync: (): LayoutSnapshot => ipcRenderer.sendSync(IpcChannel.layoutGetSync),
  set: (snapshot: LayoutSnapshot): void => {
    ipcRenderer.send(IpcChannel.layoutSet, snapshot)
  }
}

/**
 * One-way signal that a terminal just rang its bell (xterm's onBell — see
 * TerminalRenderer.tsx). Fire-and-forget: the main process alone decides
 * whether to bounce the Dock icon, since only it knows whether the app
 * window currently has OS focus.
 */
const bell: BellApi = {
  ring: (): void => {
    ipcRenderer.send(IpcChannel.bellRing)
  }
}

/**
 * Installed system font families, for the terminal settings' font-family
 * dropdown (see src/main/fonts.ts). Resolves to an empty array on any
 * platform other than macOS.
 */
const fonts: FontsApi = {
  listFamilies: (): Promise<string[]> => ipcRenderer.invoke(IpcChannel.fontsListFamilies)
}

/**
 * Renderer side of the external control socket (see
 * src/main/externalControl.ts): main relays a pane-tree request here since it
 * has no live tree of its own, tagged with a requestId `respond` must echo
 * back so main can match the reply to the caller waiting on the socket.
 */
const externalControl: ExternalControlApi = {
  onRequest: (callback: (requestId: string, request: ControlRequest) => void): (() => void) =>
    on<[RelayedControlRequest]>(IpcChannel.externalControlRequest, (payload) =>
      callback(payload.requestId, payload.request)
    ),
  respond: (requestId: string, response: ControlResponse): void => {
    const payload: RelayedControlResponse = { requestId, response }
    ipcRenderer.send(IpcChannel.externalControlResponse, payload)
  },
  getOwnedPanesSync: (): string[] =>
    ipcRenderer.sendSync(IpcChannel.externalControlOwnershipGetSync),
  onOwnershipChanged: (callback: (paneId: string, owned: boolean) => void): (() => void) =>
    on<[{ paneId: string; owned: boolean }]>(
      IpcChannel.externalControlOwnershipChanged,
      (payload) => callback(payload.paneId, payload.owned)
    )
}

/**
 * Installs (or reports the status of) the bundled "control Tabs" skill into
 * an agent's personal skill directory (see src/main/skills.ts), driven by the
 * Settings window's AI tab.
 */
const skills: SkillsApi = {
  status: (): Promise<SkillInstallTarget[]> => ipcRenderer.invoke(IpcChannel.skillsStatus),
  install: (targetId: string): Promise<SkillResult> =>
    ipcRenderer.invoke(IpcChannel.skillsInstall, targetId),
  uninstall: (targetId: string): Promise<SkillResult> =>
    ipcRenderer.invoke(IpcChannel.skillsUninstall, targetId)
}

/**
 * The generic content bridge. A thin, forever-stable passthrough: the channel
 * builders scope every call under `plugin:<type>:` (so this surface cannot
 * reach a core channel) and validate the type name; which methods and events
 * exist is between a package's renderer client and its main entry, both of
 * which derive the same channel names from the same builders.
 */
const content: ContentBridgeApi = {
  invoke: (type: string, method: string, ...args: unknown[]): Promise<unknown> =>
    ipcRenderer.invoke(pluginMethodChannel(type, method), ...args),
  send: (type: string, method: string, ...args: unknown[]): void => {
    ipcRenderer.send(pluginMethodChannel(type, method), ...args)
  },
  on: (type: string, event: string, listener: (...args: unknown[]) => void): (() => void) =>
    on(pluginEventChannel(type, event), listener)
}

const core: CoreApi = {
  pane,
  appWindow,
  settings,
  layout,
  shortcuts,
  bell,
  fonts,
  externalControl,
  skills,
  content
}

// The app's whole main-world surface. Context isolation is always on (the
// BrowserWindow never disables it), so this is unconditional — and
// exposeInMainWorld throwing on a misconfigured window is the right failure.
//
// The `Api` annotation is what keeps this complete: a missing namespace is a
// compile error here, not an `undefined` the renderer trips over at runtime.
const api: Api = core

contextBridge.exposeInMainWorld('api', api)
