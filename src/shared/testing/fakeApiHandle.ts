import type { Api } from '../api'
import type { LayoutSnapshot } from '../layout'
import type { Settings } from '../settings'
import type { ShortcutActionId } from '../shortcuts'
import type { ContentFakeApiHandle } from './content/api'

/** Initial state for a fake-bridge session — what the real app would read from disk. */
export interface TestSeed {
  settings?: Partial<Settings> | undefined
  layout?: LayoutSnapshot | undefined
}

/**
 * Core's half of the driver surface both non-Electron test tiers use to script
 * the fake `window.api` (implemented in src/renderer/src/testing/fakeApi.ts):
 * jsdom component tests import the handle directly; Playwright browser-mode
 * tests reach the same handle through `window.__fakeApi` via `page.evaluate`.
 * Pure types only — no `declare global` here, so src/shared stays free of DOM
 * types (the Window augmentation lives next to each use instead).
 */
interface CoreFakeApiHandle {
  api: Api
  /**
   * Clears recorded calls and re-seeds settings/layout state. Subscriber sets
   * survive deliberately: module-level app wiring (settingsStore's onChange,
   * the shortcut installers) subscribes once per process, exactly like a real
   * renderer's lifetime.
   */
  reset(seed?: TestSeed): void
  /**
   * Fires one action's shortcuts.onShortcut callbacks — the exact contract its
   * File/Edit menu item drives (see buildMenu in src/main/menu.ts). Takes the
   * id rather than offering a `fireNewTab`-style method per action, for the
   * same reason the bridge itself does.
   */
  fireShortcut(id: ShortcutActionId): void
  /** Broadcasts a settings change through settings.onChange — the same path a real cross-window edit takes. */
  emitSettingsChange(partial: Partial<Settings>): void
  /** Flips the fullscreen state and fires appWindow.onFullScreenChange. */
  emitFullScreenChange(isFullScreen: boolean): void
  /**
   * Broadcasts an ownership grant/release through
   * externalControl.onOwnershipChanged — the same push a real ledger
   * mutation sends (see grantOwnership/releaseOwnership in
   * src/main/externalControl.ts). Drives controlStore.ts in tests, since
   * that store has no imperative writer of its own to call directly.
   */
  emitOwnershipChanged(paneId: string, owned: boolean): void
  /** Every snapshot the app persisted through layout.set, oldest first. */
  layoutSets(): LayoutSnapshot[]
  /** Every partial the app persisted through settings.set, oldest first. */
  settingsSets(): Partial<Settings>[]
  /**
   * Every URL the app handed to appWindow.openExternal, oldest first. The
   * real bridge's answer is "the OS opened it", which no tier can observe —
   * so what a test can hold honest is that the right URL left the app (the
   * About window's donation tiers, a terminal's cmd-clicked link).
   */
  openedExternalUrls(): string[]
  /** Every string the app put on the clipboard through appWindow.copyText, oldest first. */
  copiedText(): string[]
  /** Whether shortcut capture is currently armed — what main would be suspending accelerators for. */
  captureMode(): boolean
  /** What pane.confirmClose resolves with (default true — nothing blocks the close). */
  confirmCloseResponse: boolean
}

/**
 * The whole driver handle: core plus whatever the registered content types
 * contribute (see ./content/api.ts). Same shape of decomposition as `Api`
 * itself, and for the same reason — a type's surface belongs with the type,
 * including the surface that only exists for tests.
 */
export type FakeApiHandle = CoreFakeApiHandle & ContentFakeApiHandle

/**
 * What the fake content bridge lends a package's testing piece — a fake main
 * entry, deliberately mirroring MainPluginIpc plus the emit the real main
 * performs through `ipc.emit`: the piece registers the same method names its
 * real main entry does and fires the same events, so the package's renderer
 * client (over `ctx.ipc`) cannot tell the tiers apart. Scoped to the piece's
 * own type by the host that hands it over (see
 * renderer/src/testing/content/index.ts).
 */
export interface FakeContentHost {
  /** Registers a request/response method; the fake `invoke` resolves with its return. */
  handle(method: string, handler: (...args: unknown[]) => unknown): void
  /** Registers a fire-and-forget method for the fake `send`. */
  on(method: string, listener: (...args: unknown[]) => void): void
  /** Emits an event to every `ctx.ipc.on` subscriber (names may embed ids). */
  emit(event: string, ...args: unknown[]): void
}
