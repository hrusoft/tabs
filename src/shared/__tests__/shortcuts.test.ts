import { describe, expect, it } from 'vitest'
import { DEFAULT_SETTINGS } from '../settings'
import {
  bindingKey,
  bindingsEqual,
  findConflict,
  formatBinding,
  formatChordAsQuery,
  hasRequiredModifier,
  isBareCtrlLetterChord,
  isOverridden,
  isReservedBinding,
  type KeyBinding,
  type KeyChord,
  matchesBinding,
  parseSearchChord,
  resolveBinding,
  SHORTCUT_ACTIONS,
  sanitizeShortcutOverrides,
  toAccelerator
} from '../shortcuts'

function chord(code: string, held: Partial<Omit<KeyChord, 'code'>> = {}): KeyChord {
  return { code, meta: false, ctrl: false, alt: false, shift: false, ...held }
}

function withShortcuts(shortcuts: Record<string, KeyBinding | null>) {
  return { ...DEFAULT_SETTINGS, shortcuts }
}

describe('resolveBinding', () => {
  it('falls back to the action default when there is no override', () => {
    expect(resolveBinding(withShortcuts({}), 'new-tab')).toEqual({ mod: true, code: 'KeyT' })
  })

  it('prefers an override over the default', () => {
    const settings = withShortcuts({ 'new-tab': { mod: true, alt: true, code: 'KeyN' } })
    expect(resolveBinding(settings, 'new-tab')).toEqual({ mod: true, alt: true, code: 'KeyN' })
  })

  // The distinction the sparse record exists for: an absent key means "use the
  // default", an explicit null means the user deliberately unbound it. Storing
  // a complete record would make these two indistinguishable.
  it('treats an explicit null as deliberately unbound, not as missing', () => {
    expect(resolveBinding(withShortcuts({ 'new-tab': null }), 'new-tab')).toBeNull()
    expect(isOverridden(withShortcuts({ 'new-tab': null }), 'new-tab')).toBe(true)
    expect(isOverridden(withShortcuts({}), 'new-tab')).toBe(false)
  })
})

describe('toAccelerator', () => {
  it('spells the platform modifier as CommandOrControl, so one binding serves both platforms', () => {
    expect(toAccelerator({ mod: true, code: 'KeyT' }, 'darwin')).toBe('CommandOrControl+T')
    expect(toAccelerator({ mod: true, code: 'KeyT' }, 'other')).toBe('CommandOrControl+T')
  })

  it('reproduces every shipped default as the accelerator it replaces', () => {
    const accelerators = Object.fromEntries(
      SHORTCUT_ACTIONS.map((action) => [action.id, toAccelerator(action.defaultBinding, 'darwin')])
    )
    expect(accelerators).toEqual({
      'open-settings': 'CommandOrControl+,',
      'command-palette': 'CommandOrControl+P',
      'new-tab': 'CommandOrControl+T',
      'split-horizontal': 'CommandOrControl+Shift+T',
      'split-vertical': 'CommandOrControl+Alt+T',
      'new-unpinned-pane': 'CommandOrControl+Alt+Shift+T',
      'close-pane': 'CommandOrControl+W',
      'clear-buffer': 'CommandOrControl+K',
      'refresh-pane': 'CommandOrControl+R',
      'nav-left': 'CommandOrControl+Left',
      'nav-right': 'CommandOrControl+Right',
      'nav-up': 'CommandOrControl+Up',
      'nav-down': 'CommandOrControl+Down'
    })
  })

  it('names the remaining modifiers and translates codes to accelerator tokens', () => {
    expect(toAccelerator({ mod: true, ctrl: true, code: 'KeyF' }, 'darwin')).toBe(
      'CommandOrControl+Control+F'
    )
    expect(toAccelerator({ alt: true, shift: true, code: 'Digit3' }, 'darwin')).toBe('Alt+Shift+3')
    expect(toAccelerator({ mod: true, code: 'Slash' }, 'darwin')).toBe('CommandOrControl+/')
    expect(toAccelerator({ mod: true, code: 'Enter' }, 'darwin')).toBe('CommandOrControl+Return')
    expect(toAccelerator({ alt: true, code: 'F7' }, 'darwin')).toBe('Alt+F7')
  })

  // Off macOS, Control already *is* CommandOrControl; emitting both would
  // produce an accelerator no keypress can ever satisfy.
  it('does not emit Control twice off macOS', () => {
    expect(toAccelerator({ mod: true, ctrl: true, code: 'KeyF' }, 'other')).toBe(
      'CommandOrControl+F'
    )
  })

  it('returns null for a key with no accelerator spelling, rather than an unfireable string', () => {
    expect(toAccelerator({ mod: true, code: 'NumpadDivide' }, 'darwin')).toBeNull()
    expect(toAccelerator({ mod: true, code: 'MediaPlayPause' }, 'darwin')).toBeNull()
  })
})

describe('formatBinding', () => {
  it('uses macOS glyphs in the order macOS itself shows them', () => {
    expect(formatBinding({ mod: true, code: 'KeyT' }, 'darwin')).toBe('⌘T')
    expect(
      formatBinding({ mod: true, ctrl: true, alt: true, shift: true, code: 'KeyT' }, 'darwin')
    ).toBe('⌃⌥⇧⌘T')
    expect(formatBinding({ mod: true, code: 'ArrowLeft' }, 'darwin')).toBe('⌘←')
  })

  it('spells the modifiers out off macOS', () => {
    expect(formatBinding({ mod: true, shift: true, code: 'KeyT' }, 'other')).toBe('Ctrl+Shift+T')
  })

  it('labels an unbound action', () => {
    expect(formatBinding(null, 'darwin')).toBe('Not set')
  })
})

describe('matchesBinding', () => {
  it('matches the exact combination', () => {
    const binding: KeyBinding = { mod: true, code: 'ArrowLeft' }
    expect(matchesBinding(binding, chord('ArrowLeft', { meta: true }), 'darwin')).toBe(true)
    expect(matchesBinding(binding, chord('ArrowLeft', { ctrl: true }), 'other')).toBe(true)
  })

  // The exactness that preserves the behaviour of the hardcoded checks this
  // replaced: extra modifiers must fall through to whatever else wants them,
  // not be treated as a loose "cmd+arrow was pressed".
  it('rejects a chord carrying extra modifiers', () => {
    const binding: KeyBinding = { mod: true, code: 'ArrowLeft' }
    expect(matchesBinding(binding, chord('ArrowLeft', { meta: true, ctrl: true }), 'darwin')).toBe(
      false
    )
    expect(matchesBinding(binding, chord('ArrowLeft', { meta: true, shift: true }), 'darwin')).toBe(
      false
    )
    expect(matchesBinding(binding, chord('ArrowLeft', { meta: true, alt: true }), 'darwin')).toBe(
      false
    )
  })

  it("rejects the other platform's modifier", () => {
    const binding: KeyBinding = { mod: true, code: 'ArrowLeft' }
    expect(matchesBinding(binding, chord('ArrowLeft', { ctrl: true }), 'darwin')).toBe(false)
    expect(matchesBinding(binding, chord('ArrowLeft', { meta: true }), 'other')).toBe(false)
  })

  it('distinguishes macOS Control from Command', () => {
    const binding: KeyBinding = { ctrl: true, code: 'KeyB' }
    expect(matchesBinding(binding, chord('KeyB', { ctrl: true }), 'darwin')).toBe(true)
    expect(matchesBinding(binding, chord('KeyB', { meta: true }), 'darwin')).toBe(false)
  })

  it('never matches an unbound action', () => {
    expect(matchesBinding(null, chord('KeyT', { meta: true }), 'darwin')).toBe(false)
  })
})

describe('validation helpers', () => {
  it('requires a real modifier, so a bare key can never be taken from a terminal pane', () => {
    expect(hasRequiredModifier({ code: 'KeyT' })).toBe(false)
    expect(hasRequiredModifier({ shift: true, code: 'KeyT' })).toBe(false)
    expect(hasRequiredModifier({ mod: true, code: 'KeyT' })).toBe(true)
    expect(hasRequiredModifier({ alt: true, code: 'KeyT' })).toBe(true)
    expect(hasRequiredModifier({ ctrl: true, code: 'KeyT' })).toBe(true)
  })

  it('reserves the combinations the stock role menus own', () => {
    expect(isReservedBinding({ mod: true, code: 'KeyC' })).toBe(true)
    expect(isReservedBinding({ mod: true, code: 'KeyQ' })).toBe(true)
    expect(isReservedBinding({ mod: true, ctrl: true, code: 'KeyF' })).toBe(true)
    // Close Pane replaces the stock `close` role outright, so W is ours.
    expect(isReservedBinding({ mod: true, code: 'KeyW' })).toBe(false)
    expect(isReservedBinding({ mod: true, alt: true, code: 'KeyC' })).toBe(false)
    // Refresh replaces the stock Reload/Force Reload role items outright
    // (buildMenu's View submenu drops them), so R is ours too.
    expect(isReservedBinding({ mod: true, code: 'KeyR' })).toBe(false)
    expect(isReservedBinding({ mod: true, shift: true, code: 'KeyR' })).toBe(false)
  })

  it('recognises a bare ⌃+letter chord on macOS', () => {
    expect(isBareCtrlLetterChord({ ctrl: true, code: 'KeyC' }, 'darwin')).toBe(true)
    expect(isBareCtrlLetterChord({ ctrl: true, mod: true, code: 'KeyC' }, 'darwin')).toBe(false)
    expect(isBareCtrlLetterChord({ ctrl: true, code: 'ArrowLeft' }, 'darwin')).toBe(false)
    // Off macOS Control is the ordinary app modifier, so the shape isn't bare.
    expect(isBareCtrlLetterChord({ ctrl: true, code: 'KeyC' }, 'other')).toBe(false)
  })
})

describe('findConflict', () => {
  it('finds the action already holding a combination', () => {
    expect(findConflict(withShortcuts({}), { mod: true, code: 'KeyW' }, 'new-tab')?.id).toBe(
      'close-pane'
    )
  })

  it('ignores the action being rebound and genuinely free combinations', () => {
    expect(findConflict(withShortcuts({}), { mod: true, code: 'KeyT' }, 'new-tab')).toBeNull()
    expect(findConflict(withShortcuts({}), { mod: true, alt: true, code: 'KeyJ' }, 'new-tab')).toBe(
      null
    )
  })

  it('sees the combination an override moved, not the default it left behind', () => {
    const settings = withShortcuts({ 'clear-buffer': { mod: true, alt: true, code: 'KeyJ' } })
    expect(findConflict(settings, { mod: true, alt: true, code: 'KeyJ' }, 'new-tab')?.id).toBe(
      'clear-buffer'
    )
    expect(findConflict(settings, { mod: true, code: 'KeyK' }, 'new-tab')).toBeNull()
  })

  it('does not collide with an unbound action', () => {
    const settings = withShortcuts({ 'clear-buffer': null })
    expect(findConflict(settings, { mod: true, code: 'KeyK' }, 'new-tab')).toBeNull()
  })
})

describe('bindingKey / bindingsEqual', () => {
  it('ignores property order and absent-vs-false modifiers', () => {
    expect(bindingKey({ code: 'KeyT', mod: true })).toBe(bindingKey({ mod: true, code: 'KeyT' }))
    expect(
      bindingsEqual({ mod: true, code: 'KeyT' }, { mod: true, shift: false, code: 'KeyT' })
    ).toBe(true)
    expect(
      bindingsEqual({ mod: true, code: 'KeyT' }, { mod: true, shift: true, code: 'KeyT' })
    ).toBe(false)
    expect(bindingsEqual(null, null)).toBe(true)
    expect(bindingsEqual(null, { mod: true, code: 'KeyT' })).toBe(false)
  })
})

describe('sanitizeShortcutOverrides', () => {
  it('keeps well-formed bindings and explicit unbindings', () => {
    expect(
      sanitizeShortcutOverrides({
        'new-tab': { mod: true, code: 'KeyN' },
        'close-pane': null
      })
    ).toEqual({ 'new-tab': { mod: true, code: 'KeyN' }, 'close-pane': null })
  })

  // Total by contract: migrateSettings must never throw, since loadSettings'
  // catch would reset the entire file to defaults and the next save persists it.
  it('drops malformed entries instead of throwing', () => {
    expect(
      sanitizeShortcutOverrides({
        'new-tab': { code: 42 },
        'close-pane': 'CmdOrCtrl+W',
        'clear-buffer': {},
        'nav-up': { mod: true, code: '' },
        'nav-down': { mod: true, code: 'ArrowDown' }
      })
    ).toEqual({ 'nav-down': { mod: true, code: 'ArrowDown' } })
  })

  it('normalizes non-boolean modifier values away rather than trusting them', () => {
    expect(sanitizeShortcutOverrides({ 'new-tab': { code: 'KeyN', mod: 'yes', alt: 1 } })).toEqual({
      'new-tab': { code: 'KeyN' }
    })
  })

  it('returns an empty record for a non-object', () => {
    expect(sanitizeShortcutOverrides(undefined)).toEqual({})
    expect(sanitizeShortcutOverrides(null)).toEqual({})
    expect(sanitizeShortcutOverrides('nope')).toEqual({})
    expect(sanitizeShortcutOverrides([1, 2])).toEqual({})
  })

  // Same forward-compat spirit as contentTypes: an id from a newer version
  // must survive a round-trip through an older one.
  it('lets an unknown action id ride through', () => {
    expect(sanitizeShortcutOverrides({ 'future-action': { mod: true, code: 'KeyZ' } })).toEqual({
      'future-action': { mod: true, code: 'KeyZ' }
    })
  })
})

// The Keyboard settings page's search box only — see KeyboardSettings.tsx.
describe('parseSearchChord', () => {
  it('parses a modifier word plus a single letter, case-insensitively', () => {
    expect(parseSearchChord('cmd+t', 'darwin')).toEqual({ mod: true, code: 'KeyT' })
    expect(parseSearchChord('CMD+T', 'darwin')).toEqual({ mod: true, code: 'KeyT' })
    expect(parseSearchChord('command+t', 'darwin')).toEqual({ mod: true, code: 'KeyT' })
  })

  it('does not care about token order', () => {
    expect(parseSearchChord('shift+cmd+n', 'darwin')).toEqual({
      mod: true,
      shift: true,
      code: 'KeyN'
    })
    expect(parseSearchChord('cmd+shift+n', 'darwin')).toEqual({
      mod: true,
      shift: true,
      code: 'KeyN'
    })
  })

  it('folds multiple modifier words together', () => {
    expect(parseSearchChord('cmd+alt+t', 'darwin')).toEqual({ mod: true, alt: true, code: 'KeyT' })
    expect(parseSearchChord('cmd+option+t', 'darwin')).toEqual({
      mod: true,
      alt: true,
      code: 'KeyT'
    })
  })

  // Off macOS, physical Control already is the platform modifier (see
  // bindingFromEvent in KeyboardSettings.tsx) — a typed "ctrl" means `mod`
  // there, not the separate `ctrl` field mac uses for literal Control.
  it('is platform-aware about ctrl/control', () => {
    expect(parseSearchChord('ctrl+t', 'darwin')).toEqual({ ctrl: true, code: 'KeyT' })
    expect(parseSearchChord('ctrl+t', 'other')).toEqual({ mod: true, code: 'KeyT' })
    expect(parseSearchChord('control+t', 'darwin')).toEqual({ ctrl: true, code: 'KeyT' })
  })

  it('parses digits, F-keys, and named keys', () => {
    expect(parseSearchChord('cmd+1', 'darwin')).toEqual({ mod: true, code: 'Digit1' })
    expect(parseSearchChord('cmd+f5', 'darwin')).toEqual({ mod: true, code: 'F5' })
    expect(parseSearchChord('cmd+left', 'darwin')).toEqual({ mod: true, code: 'ArrowLeft' })
    expect(parseSearchChord('cmd+,', 'darwin')).toEqual({ mod: true, code: 'Comma' })
  })

  // A "chord" with no modifier could never match a real binding anyway —
  // every one requires a modifier (hasRequiredModifier) — so this isn't just
  // pickiness, it's entailed.
  it('refuses a bare key with no modifier', () => {
    expect(parseSearchChord('t', 'darwin')).toBeNull()
  })

  it('refuses more than one non-modifier token', () => {
    expect(parseSearchChord('cmd+t+w', 'darwin')).toBeNull()
  })

  it('refuses an unrecognized key token, and ordinary text with no plus at all', () => {
    expect(parseSearchChord('cmd+nonsense', 'darwin')).toBeNull()
    expect(parseSearchChord('new tab', 'darwin')).toBeNull()
    expect(parseSearchChord('', 'darwin')).toBeNull()
  })
})

describe('formatChordAsQuery', () => {
  it('spells the platform modifier as a word, lowercased', () => {
    expect(formatChordAsQuery({ mod: true, code: 'KeyT' }, 'darwin')).toBe('cmd+t')
    expect(formatChordAsQuery({ mod: true, code: 'KeyT' }, 'other')).toBe('ctrl+t')
  })

  it('orders modifiers mod/ctrl/alt/shift, matching toAccelerator', () => {
    expect(formatChordAsQuery({ mod: true, alt: true, shift: true, code: 'KeyT' }, 'darwin')).toBe(
      'cmd+alt+shift+t'
    )
  })

  it('formats named and punctuation keys the same way toAccelerator spells them, lowercased', () => {
    expect(formatChordAsQuery({ mod: true, code: 'ArrowLeft' }, 'darwin')).toBe('cmd+left')
    expect(formatChordAsQuery({ mod: true, code: 'Comma' }, 'darwin')).toBe('cmd+,')
  })

  it('returns null for a key with no accelerator spelling', () => {
    expect(formatChordAsQuery({ mod: true, code: 'NumpadDivide' }, 'darwin')).toBeNull()
  })

  // What a search box does with a pressed chord: convert it to text, then
  // parse that text back — the whole point is that both ends agree.
  it('round-trips through parseSearchChord for every shipped default', () => {
    for (const action of SHORTCUT_ACTIONS) {
      const text = formatChordAsQuery(action.defaultBinding, 'darwin')
      expect(text).not.toBeNull()
      expect(parseSearchChord(text!, 'darwin')).toEqual(action.defaultBinding)
    }
  })
})
