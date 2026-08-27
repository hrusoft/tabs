import type { ControlRequest, ControlResponse } from './externalControl'
import type { LayoutSnapshot } from './layout'
import type { ContentBridgeApi } from './plugin/bridge'
import type { Settings } from './settings'
import type { ShortcutActionId } from './shortcuts'

/**
 * The renderer-facing `window.api` surface, declared once here so the two
 * sides of the preload boundary can't drift: preload's implementation
 * (src/preload/index.ts) is annotated with these types — a signature change
 * there that this file doesn't reflect is a compile error, not a stale
 * declaration — and the renderer's `window.api` global (src/preload/index.d.ts)
 * is declared from the same `Api`.
 *
 * Everything below is *core* surface — including `content`, the generic
 * bridge every content-type package speaks IPC through (see
 * ./plugin/bridge.ts). Packages contribute no namespaces of their
 * own: a package's typed client lives in the package, over the type-scoped
 * `ipc` its activation context carries, so this file never changes when a
 * type is added.
 */

export interface PaneApi {
  /**
   * Asks the main process whether closing the panes holding `ids` would
   * destroy live work (e.g. a terminal's foreground process — see
   * src/main/closeBlockers.ts), and if so shows a single confirmation dialog
   * listing all of it. Resolves true immediately (no dialog) when nothing
   * blocks, or with the user's Cancel/Close Anyway choice otherwise.
   */
  confirmClose: (ids: string[]) => Promise<boolean>
}

/**
 * What the About window puts in its identity block: the app's own version,
 * plus the three runtimes it credits (see shared/attributions.ts).
 *
 * All four are read from the live process rather than restated as literals
 * anywhere — `app.getVersion()` and `process.versions` — so a release bump
 * or an Electron upgrade can never leave a stale number on screen, and the
 * release flow gains nothing new to remember.
 */
export interface AppInfo {
  /** The app's version, i.e. package.json's `version` field. */
  version: string
  /** `process.versions.electron`. */
  electron: string
  /** `process.versions.chrome`. */
  chrome: string
  /** `process.versions.node`. */
  node: string
}

export interface AppWindowApi {
  /** The main process's current native-fullscreen state. */
  isFullScreen: () => Promise<boolean>
  /** Subscribes to native fullscreen enter/leave; returns an unsubscribe function. */
  onFullScreenChange: (callback: (isFullScreen: boolean) => void) => () => void
  /** Opens the Settings window, creating it if needed, or focusing it if already open. */
  openSettings: () => void
  /** Opens `url` in the OS's default browser. Silently ignored unless it's an http(s)/mailto URL. */
  openExternal: (url: string) => void
  /**
   * The app's version and the runtimes under it, read synchronously so the
   * About window's first frame already has them — same contract as
   * layout.getSync/settings.getSync.
   */
  getAppInfoSync: () => AppInfo
  /**
   * Puts `text` on the user's system clipboard. Main-side on purpose:
   * `navigator.clipboard.writeText` throws on an unfocused document, which
   * every e2e window structurally is (see src/main/e2eHidden.ts), so the
   * renderer route would be untestable in the tier that matters.
   *
   * Deliberately *not* reachable from external control — an agent driving a
   * pane must not silently overwrite the user's clipboard, which is why the
   * browser package excludes the copy/cut/paste commands (see
   * src/plugins/browser/shared/externalControl.ts). This is the app's own UI
   * acting on the user's own click.
   */
  copyText: (text: string) => void
}

export interface SettingsApi {
  /** The persisted settings, read synchronously so they're ready before first render. */
  getSync: () => Settings
  /**
   * Merges `partial` into the persisted settings and saves it to disk.
   * `contentTypes`, when present, maps type → *complete* blob: main merges at
   * the record level only and replaces each named type's blob wholesale, so
   * senders must never send a partial blob (see Settings.contentTypes).
   */
  set: (partial: Partial<Settings>) => void
  /** Subscribes to a settings change made in another window; returns an unsubscribe function. */
  onChange: (callback: (partial: Partial<Settings>) => void) => () => void
}

export interface LayoutApi {
  /** The persisted layout, read synchronously so it's ready before first render. */
  getSync: () => LayoutSnapshot
  /** Replaces the persisted layout wholesale and saves it to disk. */
  set: (snapshot: LayoutSnapshot) => void
}

export interface ShortcutsApi {
  /**
   * Subscribes to one menu-forwarded shortcut action, by the id it carries in
   * the shared registry (`SHORTCUT_ACTIONS` in src/shared/shortcuts.ts);
   * returns an unsubscribe function.
   *
   * Taking the id as an argument rather than offering an `onNewTab`-style
   * method per action is what keeps a new shortcut from costing an edit in
   * every layer: the id already exists in the registry, so the bridge, the
   * channel and the fake all carry it instead of restating it. Only actions
   * main forwards to a renderer appear here — `open-settings` is handled in
   * main, and the four nav actions are enforced by keydown listeners rather
   * than the menu (see the `layer` field on each action).
   */
  onShortcut: (id: ShortcutActionId, callback: () => void) => () => void
  /**
   * Arms/disarms shortcut capture, which strips the accelerators off the
   * customizable menu items for as long as it's on.
   *
   * The Settings window's "press a new combination" control cannot work
   * without it: macOS matches a menu key equivalent *before* the keystroke
   * reaches any renderer, so with the menu intact a capture listener can never
   * observe a combination that some action already holds — i.e. exactly the
   * ones a user most wants to reassign. Fire-and-forget; main auto-disarms if
   * the window that armed it goes away (see src/main/shortcuts.ts).
   */
  setCaptureMode: (active: boolean) => void
}

/**
 * Core, not the terminal's, by decision rather than omission: `bellStore` is
 * keyed by pane id and content-agnostic, so any content type can raise the same
 * signal — the terminal simply happens to be the only one that does today.
 */
export interface BellApi {
  /** Signals a terminal just rang its bell; main bounces the Dock icon if the window isn't focused and the setting is on. */
  ring: () => void
}

/**
 * Also core by decision: a font list is an OS capability, not a terminal one,
 * even though the terminal's settings page is currently its only caller.
 */
export interface FontsApi {
  /** Installed system font family names — empty on any platform other than macOS. */
  listFamilies: () => Promise<string[]>
}

/**
 * The renderer side of the external control socket (see
 * src/main/externalControl.ts): the pane tree only exists in this process, so
 * a request that needs it mutated/read is relayed here, tagged with a
 * `requestId` the reply must echo back.
 */
export interface ExternalControlApi {
  /** Subscribes to a relayed request; returns an unsubscribe function. */
  onRequest: (callback: (requestId: string, request: ControlRequest) => void) => () => void
  /** Answers a relayed request by its `requestId`. */
  respond: (requestId: string, response: ControlResponse) => void
  /**
   * Snapshot of every pane id currently owned by another pane through the
   * ownership ledger (see main/externalControl.ts's `ownerOf`), read
   * synchronously so it's ready before first render — same contract as
   * layout.getSync/settings.getSync. Drives controlStore.ts's initial state.
   */
  getOwnedPanesSync: () => string[]
  /**
   * Subscribes to a live ownership grant/release (grantOwnership /
   * releaseOwnership in main/externalControl.ts); returns an unsubscribe
   * function. The push half of controlStore.ts's pane-controlled indicator.
   */
  onOwnershipChanged: (callback: (paneId: string, owned: boolean) => void) => () => void
}

export interface SkillInstallTarget {
  id: string
  label: string
  installed: boolean
}

/** The outcome shape every skills mutation answers with — spelled once for main, preload and the Settings page alike. */
export type SkillResult = { ok: true } | { ok: false; error: string }

export interface SkillsApi {
  /** Per-target install status for the bundled "control Tabs" skill. */
  status: () => Promise<SkillInstallTarget[]>
  /** Symlinks the bundled skill into `targetId`'s personal skill directory. */
  install: (targetId: string) => Promise<SkillResult>
  /** Removes the symlink `install` created for `targetId`, if any. A no-op if nothing is installed. */
  uninstall: (targetId: string) => Promise<SkillResult>
}

/**
 * The namespaces that exist whatever content types are registered — everything
 * about panes, windows, settings, layout, shortcuts and the control socket.
 */
export interface CoreApi {
  pane: PaneApi
  appWindow: AppWindowApi
  settings: SettingsApi
  layout: LayoutApi
  shortcuts: ShortcutsApi
  bell: BellApi
  fonts: FontsApi
  externalControl: ExternalControlApi
  skills: SkillsApi
  content: ContentBridgeApi
}

/**
 * The whole bridge — entirely core surface: an
 * object literal annotated `Api` must supply every namespace and may supply
 * no extras, so preload and the fake bridge both stay compile-checked for
 * completeness.
 */
export type Api = CoreApi
