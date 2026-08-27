import { mkdtempSync, readFileSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { describe, expect, it, vi } from 'vitest'
import { DEFAULT_BROWSER_SETTINGS } from '../../plugins/browser/shared/settings'
import { DEFAULT_GIT_TREE_SETTINGS } from '../../plugins/gitTree/shared/settings'
import {
  DEFAULT_TERMINAL_APPEARANCE,
  DEFAULT_TERMINAL_SETTINGS,
  type TerminalSettings
} from '../../plugins/terminal/shared/settings'
import { DEFAULT_SETTINGS, type Settings } from '../../shared/settings'
import { loadSettings, saveSettings } from '../settings'

/** The terminal blob out of a loaded Settings — the cast core itself never makes. */
function terminalOf(settings: Settings): TerminalSettings {
  return settings.contentTypes.terminal as TerminalSettings
}

describe('loadSettings', () => {
  it('falls back to the defaults when the file is missing', () => {
    const settings = loadSettings({
      path: '/nonexistent/settings.json',
      readFile: () => {
        throw new Error('ENOENT')
      }
    })
    expect(settings).toEqual(DEFAULT_SETTINGS)
  })

  it('falls back to the defaults when the file has corrupt JSON', () => {
    const settings = loadSettings({ path: '/fake/settings.json', readFile: () => 'not json' })
    expect(settings).toEqual(DEFAULT_SETTINGS)
  })

  it('merges the parsed file over the defaults', () => {
    const settings = loadSettings({
      path: '/fake/settings.json',
      readFile: () => JSON.stringify({ showNavFlash: false })
    })
    expect(settings).toEqual({ ...DEFAULT_SETTINGS, showNavFlash: false })
  })

  it('defaults keys the saved file is missing, for forward compatibility', () => {
    const settings = loadSettings({
      path: '/fake/settings.json',
      readFile: () => JSON.stringify({})
    })
    expect(settings).toEqual(DEFAULT_SETTINGS)
  })

  it('merges terminal appearance one level deeper, so a file missing a newer field still defaults it', () => {
    const settings = loadSettings({
      path: '/fake/settings.json',
      readFile: () =>
        JSON.stringify({
          contentTypes: { terminal: { appearance: { fontSize: 20, ansi: { red: '#ff0000' } } } }
        })
    })
    expect(terminalOf(settings)).toEqual({
      ...DEFAULT_TERMINAL_SETTINGS,
      appearance: {
        ...DEFAULT_TERMINAL_APPEARANCE,
        fontSize: 20,
        ansi: { ...DEFAULT_TERMINAL_APPEARANCE.ansi, red: '#ff0000' }
      }
    })
  })
})

describe('migration from the flat pre-contentTypes shape', () => {
  const oldShape = {
    showNavFlash: false,
    inheritCwdOnNewPane: false,
    enableWebglRendering: true,
    terminal: { fontSize: 19, ansi: { red: '#123456' } }
  }

  it('hoists the flat terminal keys into contentTypes.terminal', () => {
    const settings = loadSettings({
      path: '/fake/settings.json',
      readFile: () => JSON.stringify(oldShape)
    })
    expect(settings.showNavFlash).toBe(false)
    expect(terminalOf(settings)).toEqual({
      inheritCwdOnNewPane: false,
      enableWebglRendering: true,
      scrollback: DEFAULT_TERMINAL_SETTINGS.scrollback,
      appearance: {
        ...DEFAULT_TERMINAL_APPEARANCE,
        fontSize: 19,
        ansi: { ...DEFAULT_TERMINAL_APPEARANCE.ansi, red: '#123456' }
      }
    })
    expect(settings).not.toHaveProperty('terminal')
    expect(settings).not.toHaveProperty('inheritCwdOnNewPane')
    expect(settings).not.toHaveProperty('enableWebglRendering')
  })

  it('is idempotent through a save: old shape → save → load is a fixpoint', () => {
    const migrated = loadSettings({
      path: '/fake/settings.json',
      readFile: () => JSON.stringify(oldShape)
    })
    let stored = ''
    saveSettings(migrated, {
      path: '/fake/settings.json',
      writeFile: (_path, data) => (stored = data)
    })
    const reloaded = loadSettings({ path: '/fake/settings.json', readFile: () => stored })
    expect(reloaded).toEqual(migrated)
  })

  it('prefers the namespaced blob when legacy flat keys reappear beside it (downgrade round-trip)', () => {
    const settings = loadSettings({
      path: '/fake/settings.json',
      readFile: () =>
        JSON.stringify({
          inheritCwdOnNewPane: true,
          terminal: { ansi: { red: '#aaaaaa' } },
          contentTypes: {
            terminal: { inheritCwdOnNewPane: false, appearance: { ansi: { red: '#123456' } } }
          }
        })
    })
    expect(terminalOf(settings).inheritCwdOnNewPane).toBe(false)
    expect(terminalOf(settings).appearance.ansi.red).toBe('#123456')
  })

  it('never throws on hostile shapes, and always yields complete settings', () => {
    const hostile = [
      '[]',
      '"x"',
      '42',
      'null',
      JSON.stringify({ terminal: null }),
      JSON.stringify({ terminal: 'nope' }),
      JSON.stringify({ contentTypes: 7 }),
      JSON.stringify({ contentTypes: { terminal: 'nope' } }),
      JSON.stringify({ contentTypes: { terminal: { appearance: { ansi: 3 } } } }),
      JSON.stringify({ shortcuts: 7 }),
      JSON.stringify({ shortcuts: 'CmdOrCtrl+T' }),
      JSON.stringify({ shortcuts: { 'new-tab': { code: 42 } } }),
      JSON.stringify({ disabledContentTypes: 7 }),
      JSON.stringify({ disabledContentTypes: 'browser' }),
      JSON.stringify({ disabledContentTypes: { browser: true } }),
      JSON.stringify({ disabledContentTypes: [null, 42] })
    ]
    for (const raw of hostile) {
      const settings = loadSettings({ path: '/fake/settings.json', readFile: () => raw })
      expect(terminalOf(settings).appearance.ansi).toEqual(DEFAULT_TERMINAL_APPEARANCE.ansi)
      expect(settings.shortcuts).toEqual({})
      expect(settings.disabledContentTypes).toEqual([])
    }
  })

  it('keeps disabled content types through a save round-trip', () => {
    const raw = JSON.stringify({ disabledContentTypes: ['browser'] })
    const settings = loadSettings({ path: '/fake/settings.json', readFile: () => raw })
    expect(settings.disabledContentTypes).toEqual(['browser'])

    let stored = ''
    saveSettings(settings, {
      path: '/fake/settings.json',
      writeFile: (_path, data) => (stored = data)
    })
    expect(
      loadSettings({ path: '/fake/settings.json', readFile: () => stored }).disabledContentTypes
    ).toEqual(['browser'])
  })

  // A type disabled while its plugin was uninstalled keeps its entry, so
  // reinstalling doesn't silently turn it back on. Deliberately not filtered
  // against the census — see shared/content/enablement.ts.
  it('keeps a disabled entry naming a type this build has never heard of', () => {
    const settings = loadSettings({
      path: '/fake/settings.json',
      readFile: () => JSON.stringify({ disabledContentTypes: ['browser', 'some-future-type'] })
    })
    expect(settings.disabledContentTypes).toEqual(['browser', 'some-future-type'])
  })

  it('keeps shortcut overrides, including a deliberate unbinding, through a save round-trip', () => {
    const raw = JSON.stringify({
      shortcuts: {
        'new-tab': { mod: true, alt: true, code: 'KeyN' },
        'clear-buffer': null,
        'future-action': { mod: true, code: 'KeyZ' }
      }
    })
    const settings = loadSettings({ path: '/fake/settings.json', readFile: () => raw })
    expect(settings.shortcuts).toEqual({
      'new-tab': { mod: true, alt: true, code: 'KeyN' },
      'clear-buffer': null,
      'future-action': { mod: true, code: 'KeyZ' }
    })

    let stored = ''
    saveSettings(settings, {
      path: '/fake/settings.json',
      writeFile: (_path, data) => (stored = data)
    })
    expect(loadSettings({ path: '/fake/settings.json', readFile: () => stored }).shortcuts).toEqual(
      settings.shortcuts
    )
  })

  // A file written before shortcuts existed must come through with every
  // action at its default, not with the key missing from Settings entirely.
  it('gives a settings file with no shortcuts key an empty override record', () => {
    const settings = loadSettings({
      path: '/fake/settings.json',
      readFile: () => JSON.stringify({ showNavFlash: false })
    })
    expect(settings.shortcuts).toEqual({})
  })

  it('preserves unknown keys at both levels, including through a save round-trip', () => {
    const raw = JSON.stringify({
      someFutureKey: 1,
      // A content type this app doesn't (yet) register a descriptor for —
      // unlike 'browser'/'terminal'/'gitTree', migrateSettings has nothing to
      // merge this against, so it must pass through untouched.
      contentTypes: { someFutureContentType: { zoom: 2 } }
    })
    const settings = loadSettings({ path: '/fake/settings.json', readFile: () => raw })
    expect(settings).toHaveProperty('someFutureKey', 1)
    expect(settings.contentTypes.someFutureContentType).toEqual({ zoom: 2 })

    let stored = ''
    saveSettings(settings, {
      path: '/fake/settings.json',
      writeFile: (_path, data) => (stored = data)
    })
    const reloaded = loadSettings({ path: '/fake/settings.json', readFile: () => stored })
    expect(reloaded).toHaveProperty('someFutureKey', 1)
    expect(reloaded.contentTypes.someFutureContentType).toEqual({ zoom: 2 })
  })
})

describe('saveSettings', () => {
  it('writes the settings as JSON to the given path', () => {
    let written: { path: string; data: string } | undefined
    saveSettings(
      {
        colorTheme: 'light',
        showNavFlash: false,
        persistLayoutOnExit: true,
        dimInactivePanes: false,
        dimInactivePanesIntensity: 0.5,
        enableBellIndicator: true,
        enableControlIndicator: true,
        snapResizeSeparators: false,
        newUnpinnedPanePosition: 'bottom-left',
        shortcuts: {},
        disabledContentTypes: [],
        contentTypes: { terminal: DEFAULT_TERMINAL_SETTINGS }
      },
      {
        path: '/fake/settings.json',
        writeFile: (path, data) => {
          written = { path, data }
        }
      }
    )
    expect(written).not.toBeNull()
    expect(written?.path).toBe('/fake/settings.json')
    expect(JSON.parse(written?.data ?? '')).toEqual({
      colorTheme: 'light',
      showNavFlash: false,
      persistLayoutOnExit: true,
      dimInactivePanes: false,
      dimInactivePanesIntensity: 0.5,
      enableBellIndicator: true,
      enableControlIndicator: true,
      snapResizeSeparators: false,
      newUnpinnedPanePosition: 'bottom-left',
      shortcuts: {},
      disabledContentTypes: [],
      contentTypes: { terminal: DEFAULT_TERMINAL_SETTINGS }
    })
  })

  it('round-trips through loadSettings', () => {
    const toSave: Settings = {
      colorTheme: 'system',
      showNavFlash: false,
      persistLayoutOnExit: false,
      dimInactivePanes: true,
      dimInactivePanesIntensity: 0.8,
      enableBellIndicator: false,
      enableControlIndicator: false,
      snapResizeSeparators: true,
      newUnpinnedPanePosition: 'middle-center',
      shortcuts: { 'new-tab': { mod: true, code: 'KeyN' } },
      disabledContentTypes: ['browser'],
      contentTypes: {
        terminal: {
          inheritCwdOnNewPane: false,
          enableWebglRendering: true,
          scrollback: DEFAULT_TERMINAL_SETTINGS.scrollback,
          appearance: DEFAULT_TERMINAL_APPEARANCE
        } satisfies TerminalSettings,
        // Every registered descriptor gets merged in on load, even one absent
        // from what was saved (migrateSettings runs every CONTENT_TYPE_SETTINGS
        // entry unconditionally) — so the round-tripped value carries gitTree's
        // and browser's defaults too, and the expectation has to state that
        // rather than omit it.
        gitTree: DEFAULT_GIT_TREE_SETTINGS,
        browser: DEFAULT_BROWSER_SETTINGS
      }
    }
    let stored = ''
    saveSettings(toSave, {
      path: '/fake/settings.json',
      writeFile: (_path, data) => (stored = data)
    })
    const settings = loadSettings({ path: '/fake/settings.json', readFile: () => stored })
    expect(settings).toEqual(toSave)
  })

  // saveSettings runs from the debounce timer, where an uncaught throw kills
  // the main process just as an ipcMain.on listener would — see persist.ts.
  it('reports a failed write instead of throwing out of the save', () => {
    const logged = vi.spyOn(console, 'error').mockImplementation(() => {})
    expect(() =>
      saveSettings(DEFAULT_SETTINGS, {
        path: '/fake/settings.json',
        writeFile: () => {
          throw new Error('EACCES: permission denied')
        }
      })
    ).not.toThrow()
    expect(logged).toHaveBeenCalled()
    logged.mockRestore()
  })

  it('creates a missing parent directory rather than failing the write', () => {
    const dir = mkdtempSync(join(tmpdir(), 'tabs-settings-test-'))
    const target = join(dir, 'vanished', 'settings.json')
    // The real default writer, as used when userData has gone missing.
    saveSettings(DEFAULT_SETTINGS, { path: target })
    expect(JSON.parse(readFileSync(target, 'utf-8'))).toEqual(DEFAULT_SETTINGS)
    rmSync(dir, { recursive: true, force: true })
  })
})
