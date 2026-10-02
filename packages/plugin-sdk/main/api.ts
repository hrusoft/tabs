import type {
  BrowserWindow,
  IpcMainEvent,
  IpcMainInvokeEvent,
  WebContents,
  WebPreferences
} from 'electron'
import type { ShortcutSettingsLike } from '../shared/shortcuts'
import type { CloseBlockerProvider } from './closeBlockers'
import type { MainControlVerbTable } from './controlVerbTable'

// What a package reaches in main beyond the context types below — named, not
// `export *`, so a sibling's test-only or internal exports (processProbe's
// parsers, PROBE_TIMEOUT_MS) stay off the plugin surface. These are exactly
// the names core's old `src/main/plugin/api.ts` exposed; the boundary ledger
// sanctions this barrel, not its siblings.
export type { CloseBlocker, CloseBlockerProvider } from './closeBlockers'
export type {
  MainControlContext,
  MainControlVerb,
  MainControlVerbTable
} from './controlVerbTable'
export { e2eHidden } from './e2eHidden'
export { platform } from './platform'
export {
  type ForegroundProcess,
  getForegroundProcess,
  getForegroundProcessSync,
  getProcessCwd,
  getProcessCwdSync
} from './processProbe'
export { RELAY_HEADROOM_MS } from './relayHeadroom'

/**
 * The main-process plugin API — the one core module a content-type package
 * may import in main, and the complete statement of what a package may do
 * there.
 *
 * A package's main entry is `activate(ctx): MainPluginModule`: core builds
 * the context, the package registers its IPC and its external-control
 * verbs inside `activate`, and hands back the record of lifecycle hooks
 * core will drive. Everything stateful arrives on the context; this module
 * exports types plus a handful of pure environment facts and OS probes
 * (e2eHidden.ts, platform.ts, processProbe.ts, relayHeadroom.ts, all
 * siblings here), so a plugin file's imports from core stay type-only or
 * stateless — the same auditable split as the renderer's own api.ts.
 */

/**
 * What a content-type package's main `activate` returns — the lifecycle
 * hooks core drives on its behalf. Every field is optional: a package that
 * only answers IPC returns an empty record.
 */
export interface MainPluginModule {
  /**
   * `webPreferences` this type needs at window *construction* time, merged
   * into every pane-tree window's. The browser's `webviewTag` is the case
   * that exists: a flag Electron only honours in the constructor.
   *
   * Core merges these *under* its own preload/sandbox settings, so a
   * package can add a capability but never redefine how the window loads
   * its renderer.
   */
  windowPreferences?: WebPreferences
  /**
   * Wires a pane-tree window — every one of them, never the Settings or
   * About window, which host no panes and so get none of the preferences
   * above. Called from createWindow, so it runs for each window as it is
   * created: at boot, for New Window, and for one a macOS reactivate or
   * restore brings back.
   */
  wireWindow?(window: BrowserWindow): void
  /**
   * Work this type must do as the app quits: flushing state worth
   * persisting, then tearing down OS resources it owns.
   *
   * MUST BE SYNCHRONOUS AND MUST NOT THROW, and neither is a style
   * preference: async work here hangs shutdown (and the next launch), and
   * an escaping throw can abort the process outright.
   */
  onQuitSync?(): void
  /**
   * A pane-tree window closed, and every pane it held is gone for good.
   * Its renderer is already destroyed and nothing will remount those
   * panes, so release whatever this type still holds for panes whose host
   * WebContents is destroyed.
   *
   * Not called while quitting: `onQuitSync` covers that.
   */
  onWindowDiscarded?(): void
  /**
   * e2e only: returns this type's mutable main-process state to what a
   * freshly launched app would have.
   */
  resetForTests?(): void
}

/**
 * The main half of the generic content bridge, scoped to the package's own
 * type: every registration and emission lands on a `plugin:<own type>:`
 * channel — the same builders preload's `window.api.content` uses — so a
 * package's renderer client and its main entry agree on channels without
 * either naming one. The Electron event is passed through to handlers
 * (main plugin code is full-trust process code and legitimately reads
 * `event.sender`).
 */
export interface MainPluginIpc {
  /** Registers a request/response method (`ipcMain.handle` semantics). */
  handle(method: string, handler: (event: IpcMainInvokeEvent, ...args: unknown[]) => unknown): void
  /** Registers a fire-and-forget method (`ipcMain.on` semantics). */
  on(method: string, listener: (event: IpcMainEvent, ...args: unknown[]) => void): void
  /** Emits an event to one renderer (names may embed ids, e.g. `data:<paneId>`). */
  emit(target: WebContents, event: string, ...args: unknown[]): void
}

/**
 * What core lends a content-type package in the main process. Handed to
 * the package's `activate` once, from whenReady.
 */
export interface MainPluginContext {
  ipc: MainPluginIpc
  /**
   * Claims every verb in `table` for this process. Annotate the table with
   * the package's own request union (`MainControlVerbTable<FooRequest>`)
   * and the compiler enforces it covers exactly that union's verbs.
   */
  registerControlVerbs<R extends { type: string }>(table: MainControlVerbTable<R>): void
  /**
   * Whether an external-control caller owns this pane — i.e. the pane was
   * created through `createBrowserPane` and not yet closed through the
   * protocol. The ledger itself stays core's; this is the read side a
   * package's own policy checks build on.
   */
  isOwnedPane(paneId: string): boolean
  /**
   * The write side of the same ledger `isOwnedPane` reads, callable outside
   * a verb handler's own context — for reporting ownership the instant a
   * package's renderer knows a pane's id.
   */
  grantOwnership(paneId: string, ownerPaneId: string): void
  /**
   * Records which WebContents currently hosts `paneId`, so core (and the
   * relay) can reach the window that renders it; returns the unregister
   * function.
   */
  registerPaneHost(paneId: string, webContents: WebContents): () => void
  /** Registers this type's "would closing destroy live work?" provider; returns its unregister. */
  registerCloseBlockerProvider(provider: CloseBlockerProvider): () => void
  /**
   * Best-effort refresh of the persisted config of every pane the package
   * names, to whatever its live state is, then saves. Fully synchronous;
   * gated on persistLayoutOnExit inside core.
   */
  refreshLeafConfigs(
    listPaneIds: () => readonly string[],
    getLivePatch: (id: string) => Readonly<Record<string, unknown>> | undefined
  ): void
  /** Opens a URL in the OS browser, under core's own scheme policy — never throws. */
  openExternalUrl(url: string): void
  /** This boot's external-control socket path — what a package injects into child environments. */
  controlSocketPath(): string
  /** An absolute path under the app's userData dir for `fileName` — where per-app artifacts belong. */
  userDataPath(fileName: string): string
  /**
   * Read-only view of the loaded settings — narrowed to the one slice a
   * plugin has ever actually read (the browser matches nav chords against
   * `shortcuts`), rather than core's own full `Settings` type: core's
   * concrete implementation returns the real `Settings` object, which
   * satisfies this narrower shape structurally, so nothing at the one real
   * call site (guestNavKeys.ts's `navDirectionForChord`, itself already
   * typed against this same `ShortcutSettingsLike`) needs a cast. Writes
   * stay with the windows.
   */
  settings: {
    get(): ShortcutSettingsLike
  }
}
