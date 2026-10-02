import type { ShortcutActionId } from '@tabs/plugin-sdk/shared/shortcuts'
import type { Api, CaffeinateFlags } from '../api'
import type { LayoutSnapshot } from '../layout'
import type {
  CrossWindowMessageFromMain,
  CrossWindowMessageFromRenderer
} from '../layoutCrossWindow'
import type { Settings } from '../settings'

/** Initial state for a fake-bridge session — what the real app would read from disk. */
export interface TestSeed {
  settings?: Partial<Settings> | undefined
  layout?: LayoutSnapshot | undefined
}

/**
 * The opt-in stub content types a non-Electron tier can register on top of
 * the always-present plain stub (see stubContent.tsx): `second` is another
 * creation-capable type, for tests that need a *row* of creation buttons;
 * `header-chrome` declares HeaderControl/HeaderTitle, for the generic header
 * hooks. Opt-in per test because most specs only care about the plain
 * stub's own button/pane-count assertions and would be perturbed by another
 * type appearing beside it. Deliberately not a `TestSeed` field: the seed is
 * state the real app would read from disk, and this is a registration, which
 * the real app takes from registerBuiltins.
 */
export type ExtraStubType = 'second' | 'header-chrome'

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
  /** Delivers one main-side message of the cross-window drag protocol; what the app sends back lands in `crossWindowSent`. */
  emitCrossWindow(message: CrossWindowMessageFromMain): void
  /** Every message the app sent through layout.sendCrossWindow, oldest first. */
  crossWindowSent(): CrossWindowMessageFromRenderer[]
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
  /**
   * Fires caffeinate.onOpenDialog's subscribers — the same push the native
   * File → Caffeinate… item makes when nothing is running yet (see
   * main/menu.ts).
   */
  fireCaffeinateOpenDialog(): void
  /**
   * Broadcasts a running-state change through caffeinate.onRunningChanged,
   * the same push main's broadcastRunning makes on start/stop/self-exit —
   * also flips what isRunningSync would answer next.
   */
  emitCaffeinateRunningChanged(running: boolean): void
  /** Every flags object the app passed to caffeinate.start, oldest first. */
  caffeinateStarts(): CaffeinateFlags[]
  /** How many times the app called caffeinate.stop. */
  caffeinateStops(): number
}

/**
 * The driver handle as core types it. At runtime the object also carries
 * every content type's own driver methods (merged in by the fake content
 * bridge, src/renderer/src/testing/content/index.ts), but those are typed by
 * each package beside its own handle interface — a type's surface belongs
 * with the type, including the surface that only exists for tests — so core
 * names no content type here.
 */
export type FakeApiHandle = CoreFakeApiHandle

/**
 * `FakeContentHost` now lives in packages/plugin-sdk/renderer/fakeContentHost.ts (the
 * only export of this file any plugin's own testing/fakeApi.ts imports),
 * re-exported here for every existing importer.
 */
export type { FakeContentHost } from '@tabs/plugin-sdk/renderer/fakeContentHost'
