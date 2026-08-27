import type {
  BrowserWindow,
  IpcMainEvent,
  IpcMainInvokeEvent,
  WebContents,
  WebPreferences
} from 'electron'
import type { ControlRequest } from '../../shared/externalControl'
import type { Settings } from '../../shared/settings'
import type { CloseBlockerProvider } from '../closeBlockers'
import type { MainControlVerbTable } from '../controlVerbs'
import type { LeafConfigPatch } from '../layout'

/**
 * The main-process plugin API — the one core module a content-type package
 * may import in main, and the complete statement of what a package may do
 * there.
 *
 * A package's main entry is `activate(ctx): MainPluginModule`: core builds
 * the context (plugin/context.ts), the package registers its IPC and its
 * external-control verbs inside `activate`, and hands back the record of
 * lifecycle hooks core will drive (contentTypes.ts iterates them at each
 * moment). Everything stateful arrives on the context; this module exports
 * types plus a handful of pure environment facts and OS probes, so a plugin
 * file's imports from core stay type-only or stateless — the same auditable
 * split as the renderer's plugin/api.ts.
 *
 * Deliberately unversioned: the built-in packages update with core in the
 * same commit.
 */

export type { CloseBlocker, CloseBlockerProvider } from '../closeBlockers'
export type { MainControlContext, MainControlVerb, MainControlVerbTable } from '../controlVerbs'
// Pure environment facts and OS probes — constants and stateless helpers a
// package may import directly. RELAY_HEADROOM_MS in particular must be
// importable rather than context-borne: verb tables are module-scope consts
// whose timeout arithmetic runs at import time, before any context exists.
export { e2eHidden } from '../e2eHidden'
export { RELAY_HEADROOM_MS } from '../externalControl'
export { platform } from '../platform'
export {
  type ForegroundProcess,
  getForegroundProcess,
  getForegroundProcessSync,
  getProcessCwd,
  getProcessCwdSync
} from '../processProbe'

/**
 * What a content-type package's main `activate` returns — the lifecycle hooks
 * core drives on its behalf. Every field is optional: a package that only
 * answers IPC returns an empty record. The package's type name appears
 * nowhere on it — contentTypes.ts keys the activation list by it and the
 * compiler holds that key to the census, so a field here would be a second
 * copy nothing checks.
 *
 * That name is deliberately not what enable/disable keys off either: turning
 * a type off is a creation gate in the renderer, and every main package still
 * activates and still answers IPC so an already-open pane of a disabled type
 * keeps running (see src/shared/content/enablement.ts).
 */
export interface MainPluginModule {
  /**
   * `webPreferences` this type needs at window *construction* time, merged
   * into every pane-tree window's (see createWindow). The browser's
   * `webviewTag` is the case that exists: a flag Electron only honours in the
   * constructor, so `wireWindow` below is structurally too late for it.
   *
   * Core merges these *under* its own preload/sandbox settings, so a package
   * can add a capability but never redefine how the window loads its
   * renderer. A capability granted here comes with whatever hardening it
   * needs, from the same package — which is what makes "a build without this
   * type" mean the capability is simply absent, rather than present and
   * unguarded.
   */
  windowPreferences?: WebPreferences
  /**
   * Wires the pane-tree window — the main window only, never the Settings
   * window, which hosts no panes and so gets none of the preferences above.
   * Called from createWindow, so it runs again for the window macOS builds on
   * 'activate' after every window has been closed.
   */
  wireWindow?(window: BrowserWindow): void
  /**
   * Work this type must do as the app quits: flushing state worth persisting,
   * then tearing down OS resources it owns.
   *
   * MUST BE SYNCHRONOUS AND MUST NOT THROW, and neither is a style
   * preference: async work here hangs shutdown (and the next launch), and an
   * escaping throw can abort the process outright — CLAUDE.md's before-quit
   * gotcha is four separate incidents long and carries the whole story.
   *
   * Core defends itself regardless — it catches per package (see
   * runContentModuleQuitHooks), so one type's failure cannot skip another's
   * teardown — but that is a backstop, not permission. Note TypeScript cannot
   * enforce the synchronous half: an `async` function is assignable to a
   * `void`-returning signature, so the guard against that is a runtime one.
   */
  onQuitSync?(): void
  /**
   * e2e only: returns this type's mutable main-process state to what a freshly
   * launched app would have. Anything keyed by a pane id belongs here, or it
   * silently leaks into the next test in the spec file (see main/e2e.ts).
   */
  resetForTests?(): void
}

/**
 * The main half of the generic content bridge, scoped to the package's own
 * type: every registration and emission lands on a `plugin:<own type>:`
 * channel derived by shared/plugin/bridge.ts — the same builders preload's
 * `window.api.content` uses — so a package's renderer client and its main
 * entry agree on channels without either naming one. The Electron event is
 * passed through to handlers (main plugin code is full-trust process code and
 * legitimately reads `event.sender`).
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
 * What core lends a content-type package in the main process. Handed to the
 * package's `activate` once, from whenReady — after registerSettingsIpc (so
 * settings are readable) and before the external-control socket accepts its
 * first connection (so every verb is claimed first; index.ts's whenReady holds the
 * ordering, and contentTypes.ts documents it).
 */
export interface MainPluginContext {
  ipc: MainPluginIpc
  /**
   * Claims every verb in `table` for this process. Annotate the table with
   * the package's own request union (`MainControlVerbTable<FooRequest>`) and
   * the compiler enforces it covers exactly that union's verbs — the
   * compile-time half of the coverage guarantee; the e2e gate over
   * unhandledMainControlVerbs is the runtime half.
   */
  registerControlVerbs<R extends { type: ControlRequest['type'] }>(
    table: MainControlVerbTable<R>
  ): void
  /**
   * Whether an external-control caller owns this pane — i.e. the pane was
   * created through `createBrowserPane` and not yet closed through the
   * protocol. The ledger itself stays core's; this is the read side a
   * package's own policy checks build on (agent-owned popups, navigation
   * constraints).
   */
  isOwnedPane(paneId: string): boolean
  /**
   * The write side of the same ledger `isOwnedPane` reads, callable outside a
   * verb handler's own `MainControlContext` — for reporting ownership the
   * instant a package's renderer knows a pane's id, rather than waiting for
   * that verb's full relay response. `createBrowserPane`'s renderer-side
   * handler is the reason this exists: its relay doesn't resolve until the
   * new webview has mounted and its first load has settled, which left an
   * agent-owned pane's popup-deny and scheme-allowlist guards reading
   * `isOwnedPane` as false for that whole window. Call it only once the pane
   * genuinely exists (same contract as `MainControlContext.grantOwnership`).
   */
  grantOwnership(paneId: string, ownerPaneId: string): void
  /**
   * Records which WebContents currently hosts `paneId`, so core (and the
   * relay) can reach the window that renders it; returns the unregister
   * function. Same reattach-tolerant idiom as the renderer's pane handles.
   */
  registerPaneHost(paneId: string, webContents: WebContents): () => void
  /** Registers this type's "would closing destroy live work?" provider; returns its unregister. */
  registerCloseBlockerProvider(provider: CloseBlockerProvider): () => void
  /**
   * Best-effort refresh of the persisted config of every pane the package
   * names, to whatever its live state is, then saves — the quit-time hook
   * behind "a restored session reopens each pane as it actually was". Fully
   * synchronous; gated on persistLayoutOnExit inside core.
   */
  refreshLeafConfigs(
    listPaneIds: () => readonly string[],
    getLivePatch: (id: string) => LeafConfigPatch | undefined
  ): void
  /** Opens a URL in the OS browser, under core's own scheme policy — never throws. */
  openExternalUrl(url: string): void
  /** This boot's external-control socket path — what a package injects into child environments. */
  controlSocketPath(): string
  /** An absolute path under the app's userData dir for `fileName` — where per-app artifacts belong. */
  userDataPath(fileName: string): string
  /**
   * Read-only view of the loaded settings. Whole rather than blob-scoped,
   * unlike the renderer context's: main packages legitimately consult core
   * settings (the browser matches nav chords against `shortcuts`), and main
   * plugin code is full-trust process code either way. Writes stay with the
   * windows.
   */
  settings: {
    get(): Settings
    /** Fires after core applies a change; returns the unsubscribe function. */
    subscribe(listener: (partial: Partial<Settings>) => void): () => void
  }
}
