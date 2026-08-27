/**
 * Color themes for the app's own chrome.
 *
 * A theme is DATA, not stylesheet text: every value a surface can paint with
 * is one entry in `colors`, keyed by the literal CSS custom-property name it
 * lands on. That's what makes a third theme purely additive — append a `Theme`
 * to `THEMES` and the picker, the type checker, and the parity test all pick
 * it up with no other edit. Keying by `'--bg'` rather than `bg` deliberately
 * removes the camelCase→kebab mapping layer, which would otherwise be one more
 * thing to hand-sync (see applyTheme in renderer/core/theme/installTheme.ts,
 * which just iterates this record).
 *
 * SCOPE — the theme owns app chrome; a content type's own profile owns its
 * content. Concretely: the terminal's 20-color palette
 * (DEFAULT_TERMINAL_APPEARANCE in src/plugins/terminal/shared/settings.ts) does NOT switch with
 * the theme, and that is deliberate, not an oversight. See the color-theme
 * gotcha in CLAUDE.md before "fixing" it.
 *
 * Process-agnostic by the src/shared rule: no DOM, React, or Electron here.
 * The renderer applies `colors` to documentElement; the main process reads
 * `windowBackground` for the native window (see main/theme.ts).
 */

/** A real theme. `system` is not one of these — it's an alias that resolves to one. */
type ThemeId = 'dark' | 'light'

/**
 * What the user picked. `system` isn't a theme of its own: it resolves to
 * `dark` or `light` from the OS preference, and re-resolves while the app runs
 * when that preference changes.
 */
export type ThemeSetting = ThemeId | 'system'

/**
 * Every custom property a theme defines, named exactly as it appears in
 * global.css. A theme missing one is a compile error, which is the point.
 *
 * Not all of them are colors, which is why the field holding them is `tokens`
 * rather than `colors`:
 *
 * - The `-rgb` pair holds a bare space-separated channel triple, so the rules
 *   using them keep their own alpha: `rgb(var(--hover-rgb) / 0.12)`. That
 *   preserves every existing alpha in global.css byte-for-byte while letting a
 *   light theme flip the wash from white to black — a single `--hover` color
 *   could not do both.
 * - `--shadow-strength` is a bare multiplier applied to every shadow's alpha
 *   (`calc(0.4 * var(--shadow-strength))`). Shadow alphas tuned against a
 *   near-black UI read as heavy grey smudges on white, and they all need to
 *   move together, so one knob scales the set rather than each theme
 *   restating four alphas.
 */
export type ThemeToken =
  | '--bg'
  | '--bg-elevated'
  | '--border'
  | '--text'
  | '--text-dim'
  | '--accent'
  | '--on-accent'
  | '--bell-alert'
  | '--agent'
  | '--hover-rgb'
  | '--shadow-rgb'
  | '--shadow-strength'

export interface Theme {
  id: ThemeId
  /** Shown in the Settings picker. */
  label: string
  /**
   * Drives the CSS `color-scheme` property, which is what Chromium reads to
   * paint things the app never styles itself: scrollbars, and the native
   * chrome of `<select>` / `<input type="color">` / `<input type="range">` in
   * the Settings window.
   */
  colorScheme: 'dark' | 'light'
  /**
   * What the OS window paints before the renderer's first frame. Without it
   * both windows flash Chromium's default white on launch.
   */
  windowBackground: string
  tokens: Record<ThemeToken, string>
}

/**
 * The app's original palette, unchanged — this is the theme that shipped
 * before there were themes, lifted out verbatim so introducing theming is a
 * visual no-op for anyone who doesn't touch the setting.
 */
export const DARK_THEME: Theme = {
  id: 'dark',
  label: 'Dark',
  colorScheme: 'dark',
  windowBackground: '#1e1f24',
  tokens: {
    '--bg': '#1e1f24',
    // The two of these are also the app's depth-striping pair — every nested
    // tab bar alternates between them (see `--surface` in global.css), so the
    // step between them has to be legible as a stripe, not just as "chrome vs
    // content". Lifted from the design mock rather than tuned by eye.
    '--bg-elevated': '#2a2c33',
    '--border': '#3a3b44',
    '--text': '#e6e6eb',
    '--text-dim': '#9a9ba6',
    '--accent': '#4f8cff',
    '--on-accent': '#ffffff',
    '--bell-alert': '#ff453a',
    '--agent': '#b48cff',
    '--hover-rgb': '255 255 255',
    '--shadow-rgb': '0 0 0',
    // 1 = the alphas exactly as they were written before theming existed.
    '--shadow-strength': '1'
  }
}

/**
 * The light counterpart, built by mirroring the dark theme's *relationships*
 * rather than inverting its values: `--bg` is the content surface and
 * `--bg-elevated` the chrome around it, which means elevated is lighter than
 * bg in dark and slightly darker in light.
 *
 * `--accent`, `--bell-alert` and `--agent` are deepened rather than reused:
 * the dark theme's versions are tuned to carry on a near-black background and
 * wash out on white (and `--on-accent` white text needs the accent fill dark
 * enough to sit on).
 */
export const LIGHT_THEME: Theme = {
  id: 'light',
  label: 'Light',
  colorScheme: 'light',
  windowBackground: '#ffffff',
  tokens: {
    '--bg': '#ffffff',
    '--bg-elevated': '#eff0f3',
    '--border': '#d2d3da',
    '--text': '#1c1d22',
    '--text-dim': '#63646e',
    '--accent': '#2f6fe4',
    '--on-accent': '#ffffff',
    '--bell-alert': '#d70015',
    '--agent': '#7b45d8',
    '--hover-rgb': '0 0 0',
    '--shadow-rgb': '0 0 0',
    // Measured on screen, not guessed: at full strength the context menu and
    // floating windows cast a grey smudge on white rather than a shadow.
    '--shadow-strength': '0.45'
  }
}

/**
 * Every theme that ships. Adding one here is the whole job: `getTheme`, the
 * Settings picker (see themeSettingOptions), and the token-parity unit test
 * are all driven off this list.
 */
export const THEMES: readonly Theme[] = [DARK_THEME, LIGHT_THEME]

/** Falls back to the dark theme for an unknown id — a settings.json can hold anything. */
export function getTheme(id: string): Theme {
  return THEMES.find((theme) => theme.id === id) ?? DARK_THEME
}

/**
 * The theme to actually paint. `systemPrefersDark` is the OS-level preference,
 * which only matters when the setting is `system`; the caller supplies it (the
 * renderer from `prefers-color-scheme`, the main process from
 * `nativeTheme.shouldUseDarkColors`) so this stays pure and testable.
 */
export function resolveTheme(setting: ThemeSetting, systemPrefersDark: boolean): Theme {
  if (setting === 'system') return systemPrefersDark ? DARK_THEME : LIGHT_THEME
  return getTheme(setting)
}

/**
 * The Settings picker's options, derived from THEMES so a new theme appears in
 * the UI without touching the settings page. `system` is appended rather than
 * listed among them because it isn't a theme — it's the alias.
 */
export function themeSettingOptions(): Array<{ value: ThemeSetting; label: string }> {
  return [
    ...THEMES.map((theme) => ({ value: theme.id as ThemeSetting, label: theme.label })),
    { value: 'system', label: 'System' }
  ]
}
