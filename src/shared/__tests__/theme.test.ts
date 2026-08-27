import { describe, expect, it } from 'vitest'
import {
  DARK_THEME,
  getTheme,
  LIGHT_THEME,
  resolveTheme,
  THEMES,
  type Theme,
  themeSettingOptions
} from '../theme'

describe('resolveTheme', () => {
  it('returns the named theme regardless of the OS preference', () => {
    expect(resolveTheme('dark', false)).toBe(DARK_THEME)
    expect(resolveTheme('dark', true)).toBe(DARK_THEME)
    expect(resolveTheme('light', false)).toBe(LIGHT_THEME)
    expect(resolveTheme('light', true)).toBe(LIGHT_THEME)
  })

  it('follows the OS preference for "system"', () => {
    expect(resolveTheme('system', true)).toBe(DARK_THEME)
    expect(resolveTheme('system', false)).toBe(LIGHT_THEME)
  })
})

describe('getTheme', () => {
  it('resolves each shipped id', () => {
    for (const theme of THEMES) expect(getTheme(theme.id)).toBe(theme)
  })

  // A settings.json is user-editable and can survive a downgrade, so an id
  // naming a theme this build doesn't have must degrade, not throw.
  it('falls back to dark for an unknown id', () => {
    expect(getTheme('solarized')).toBe(DARK_THEME)
    expect(getTheme('')).toBe(DARK_THEME)
  })
})

describe('theme definitions', () => {
  // The guard that makes "adding a third theme" safe: a new theme that forgot
  // a token would leave that custom property at whatever the previous theme
  // set, since applyTheme writes each theme's own keys onto the same element.
  // TypeScript's Record already requires exhaustiveness; this catches the
  // same mistake in a theme that arrives as plain data (a future user theme).
  it('every theme defines exactly the same token set', () => {
    const expected = Object.keys(DARK_THEME.tokens).sort()
    for (const theme of THEMES) {
      expect(Object.keys(theme.tokens).sort(), `theme "${theme.id}"`).toEqual(expected)
    }
  })

  it('every token has a non-empty value', () => {
    for (const theme of THEMES) {
      for (const [token, value] of Object.entries(theme.tokens)) {
        expect(value.trim(), `${theme.id} ${token}`).not.toBe('')
      }
    }
  })

  // The two -rgb tokens are substituted into `rgb(var(--x) / <alpha>)`, so
  // they must be a bare channel triple — a '#rrggbb' here would silently
  // produce an invalid declaration that the browser drops, and the rule would
  // render with no background/shadow at all rather than fail loudly.
  it('the -rgb tokens are bare channel triples', () => {
    for (const theme of THEMES) {
      for (const [token, value] of Object.entries(theme.tokens)) {
        if (!token.endsWith('-rgb')) continue
        expect(value, `${theme.id} ${token}`).toMatch(/^\d{1,3} \d{1,3} \d{1,3}$/)
      }
    }
  })

  // Substituted into `calc(0.4 * var(--shadow-strength))`, so it has to be a
  // bare number — a unit here ('0.45px') makes every shadow declaration
  // invalid and silently drops it.
  it('--shadow-strength is a bare number', () => {
    for (const theme of THEMES) {
      expect(theme.tokens['--shadow-strength'], theme.id).toMatch(/^\d+(\.\d+)?$/)
    }
  })

  it('ids are unique', () => {
    const ids = THEMES.map((theme) => theme.id)
    expect(new Set(ids).size).toBe(ids.length)
  })

  it('dark holds the palette the app is designed against', () => {
    // Pinned deliberately, so a token can't drift by accident — every one of
    // these is a value the UI was laid out and reviewed against, not a
    // default. `--bg` / `--bg-elevated` in particular are also the depth
    // striping pair every nested tab bar alternates between (see `--surface`
    // in global.css), so the step between them is a design measurement:
    // --bg-elevated moved from the original #26272e to #2a2c33 to make the
    // stripe read, which is the one value here that has ever changed.
    expect(DARK_THEME.tokens['--bg']).toBe('#1e1f24')
    expect(DARK_THEME.tokens['--bg-elevated']).toBe('#2a2c33')
    expect(DARK_THEME.tokens['--border']).toBe('#3a3b44')
    expect(DARK_THEME.tokens['--text']).toBe('#e6e6eb')
    expect(DARK_THEME.tokens['--text-dim']).toBe('#9a9ba6')
    expect(DARK_THEME.tokens['--accent']).toBe('#4f8cff')
    expect(DARK_THEME.tokens['--bell-alert']).toBe('#ff453a')
    expect(DARK_THEME.tokens['--agent']).toBe('#b48cff')
  })
})

describe('themeSettingOptions', () => {
  it('lists every theme plus the system alias last', () => {
    const options = themeSettingOptions()
    expect(options.map((option) => option.value)).toEqual([...THEMES.map((t) => t.id), 'system'])
  })

  // The picker is built from this, so a theme appended to THEMES must show up
  // with no edit to the settings page.
  it('derives its entries from THEMES rather than a parallel list', () => {
    const extra: Theme = { ...LIGHT_THEME, id: 'light', label: 'Renamed' }
    expect(themeSettingOptions().some((option) => option.label === extra.label)).toBe(false)
    expect(themeSettingOptions().map((option) => option.label)).toEqual([
      ...THEMES.map((t) => t.label),
      'System'
    ])
  })
})
