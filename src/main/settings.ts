import { readFileSync } from 'node:fs'
import { IpcChannel } from '../shared/ipc'
import {
  CONTENT_TYPE_SETTINGS,
  DEFAULT_SETTINGS,
  migrateSettings,
  type Settings
} from '../shared/settings'
import { e2eHidden } from './e2eHidden'
import { onRendererMessage, registerSyncGetter } from './ipcListeners'
import { forEachLiveWindow } from './liveWindows'
import type { JsonReadDeps, JsonWriteDeps } from './persist'
import { removeQuietly, saveJsonQuietly, userDataPath } from './persist'

function settingsPath(): string {
  return userDataPath('settings.json')
}

/**
 * Reads settings from disk and runs them through migrateSettings (see
 * shared/settings.ts), which fills defaults for missing keys, hoists the
 * pre-contentTypes flat shape, and deep-merges each content type's blob.
 *
 * The try scope is deliberately only the read + parse: those are the two
 * failures that genuinely mean "no usable file" (first run, corrupt JSON)
 * and may fall back to the defaults outright. Everything after is total by
 * contract — a throw landing in this catch would silently reset a
 * hand-tuned palette to the defaults, and the next debounced save would
 * persist the wipe.
 */
export function loadSettings({
  path = settingsPath(),
  readFile = (p) => readFileSync(p, 'utf-8')
}: JsonReadDeps = {}): Settings {
  let parsed: unknown
  try {
    parsed = JSON.parse(readFile(path))
  } catch {
    return DEFAULT_SETTINGS
  }
  return migrateSettings(parsed)
}

/**
 * Persists the settings, best-effort — same contract as `saveLayout`: nothing
 * throws out of here whatever writer is in play, and the default writer
 * recreates a missing userData directory. This one runs from the debounce
 * timer below, where an uncaught throw is just as fatal as one out of an
 * `ipcMain.on` listener. See persist.ts.
 */
export function saveSettings(settings: Settings, deps: JsonWriteDeps = {}): void {
  saveJsonQuietly('settings', deps.path ?? settingsPath(), settings, deps.writeFile)
}

let current: Settings

/**
 * How long a burst of settings:set calls may coalesce before hitting disk.
 * A continuous control (a color-picker or slider drag in the Settings
 * window) fires per input tick, and writing synchronously per tick blocked
 * the main process tens of times a second for no benefit — `current` and
 * the cross-window broadcast (the live preview) still update on every tick;
 * only the disk write is deferred. Anything that ends the process flushes
 * first (see flushSettingsWrite, called from main/index.ts's before-quit).
 */
const SAVE_DEBOUNCE_MS = 300

let saveTimer: NodeJS.Timeout | null = null

function scheduleSave(): void {
  if (saveTimer !== null) clearTimeout(saveTimer)
  saveTimer = setTimeout(() => {
    saveTimer = null
    saveSettings(current)
  }, SAVE_DEBOUNCE_MS)
}

/**
 * Main-process listeners for a settings change, fired after `current` has been
 * updated so a listener reading `getSettings()` sees the new value. Today:
 * index.ts rebuilding the application menu when a shortcut is rebound, and
 * theme.ts pushing a new colorTheme into the native layer. An explicit hook
 * rather than a second `ipcMain.on` for the same channel, which would work
 * only by relying on EventEmitter listener ordering to run after the handler
 * below.
 */
const changeListeners = new Set<(partial: Partial<Settings>) => void>()

export function subscribeSettings(listener: (partial: Partial<Settings>) => void): () => void {
  changeListeners.add(listener)
  return () => {
    changeListeners.delete(listener)
  }
}

/** Writes a pending debounced settings save out immediately (the quit path). */
export function flushSettingsWrite(): void {
  if (saveTimer === null) return
  clearTimeout(saveTimer)
  saveTimer = null
  saveSettings(current)
}

/**
 * e2e only: overlays each content type's `testBaseline` onto the settings a
 * test starts from, for shipping defaults the suite structurally cannot work
 * against (the terminal's WebGL renderer is the one today — see
 * terminalSettingsDescriptor).
 *
 * Names no content type: which keys those are is the type's own business, and
 * this module is the one place that has to stay blob-agnostic. Applied to the
 * baseline only, never to a write, so an explicit settings:set from a test
 * still wins. Returns a fresh object rather than mutating — `current` may alias
 * the DEFAULT_SETTINGS singleton (see the settingsSet handler).
 */
function e2eSettingsBaseline(settings: Settings): Settings {
  if (!e2eHidden) return settings
  const contentTypes = { ...settings.contentTypes }
  for (const descriptor of CONTENT_TYPE_SETTINGS) {
    if (!descriptor.testBaseline) continue
    contentTypes[descriptor.type] = {
      ...(contentTypes[descriptor.type] as Record<string, unknown>),
      ...descriptor.testBaseline
    }
  }
  return { ...settings, contentTypes }
}

/** Loads the persisted settings once and wires up the get/set IPC channels. */
export function registerSettingsIpc(): void {
  current = e2eSettingsBaseline(loadSettings())
  registerSyncGetter(IpcChannel.settingsGetSync, () => current)
  onRendererMessage(IpcChannel.settingsSet, (event, partial: Partial<Settings>) => {
    // contentTypes merges one level deep — a write carrying one type's blob
    // must not clobber sibling types'. Exactly one level: the write contract
    // (see shared/settings.ts) is that a per-type blob is always sent WHOLE,
    // so each named type's blob is replaced wholesale. Always build fresh
    // objects here — after resetSettingsForTests, `current` aliases the
    // shared DEFAULT_SETTINGS singleton, so in-place mutation would corrupt
    // the defaults for the rest of the process.
    const { contentTypes, ...flat } = partial
    current = {
      ...current,
      ...flat,
      contentTypes: contentTypes
        ? { ...current.contentTypes, ...contentTypes }
        : current.contentTypes
    }
    scheduleSave()
    // Mirrors the change into every other open window (e.g. the Settings
    // window editing a color while the main window is open) so an
    // already-mounted settingsStore doesn't need a reload to see it. The
    // sender is excluded since it already applied the change optimistically
    // (see settingsStore.ts's setSetting).
    forEachLiveWindow((win) => {
      if (win.webContents.id !== event.sender.id) {
        win.webContents.send(IpcChannel.settingsChanged, partial)
      }
    })
    // Guarded per listener, on top of onRendererMessage's own guard, so one
    // module's failing listener (a full menu rebuild, a native theme push)
    // doesn't starve the others of the change.
    for (const listener of changeListeners) {
      try {
        listener(partial)
      } catch (error) {
        console.error('[tabs] settings change listener failed:', error)
      }
    }
  })
}

/**
 * e2e only: drops settings back to the defaults and clears the persisted
 * copy, so a reused app starts the next test where a freshly launched one
 * would. A save still pending from the debounce above is cancelled, not
 * flushed — it would re-create the file this just deleted. See main/e2e.ts
 * for the whole reset sequence.
 */
export function resetSettingsForTests(): void {
  if (saveTimer !== null) {
    clearTimeout(saveTimer)
    saveTimer = null
  }
  current = e2eSettingsBaseline(DEFAULT_SETTINGS)
  removeQuietly(settingsPath())
}

/**
 * The live in-memory settings, for other main-process modules that need to
 * read a current value rather than round-trip the renderer's async IPC (see
 * layout.ts gating persistence on `persistLayoutOnExit`). Only valid after
 * `registerSettingsIpc` has run — index.ts calls it before any module that
 * depends on this.
 */
export function getSettings(): Settings {
  // Enforced rather than trusted: `current` is assigned by registerSettingsIpc,
  // and a read before then would otherwise surface as a TypeError in whichever
  // unrelated module read a key first, with nothing pointing here.
  // biome-ignore lint/suspicious/noUnnecessaryConditions: the type says always-assigned; this guard exists for when the whenReady ordering breaks that promise
  if (current === undefined) {
    throw new Error(
      'getSettings() called before registerSettingsIpc() — check whenReady ordering in index.ts'
    )
  }
  return current
}
