import './terminalSettingsPage.css'
import { useEffect, useState } from 'react'
import {
  type PluginSettingsPageDef,
  parseNumberInput,
  SettingsCheckboxRow,
  SettingsNumberRow
} from '../../../renderer/src/plugin/settingsApi'
import { TerminalIcon } from '../renderer/TerminalIcon'
import { updateTerminalSettings, useTerminalSetting } from '../renderer/terminalSettingsAccess'
import { manifest as terminalManifest } from '../shared/manifest'
import type {
  TerminalAnsiColors,
  TerminalAppearance,
  TerminalCursorStyle
} from '../shared/settings'
import { terminalSettingsCtx } from './pluginContext'

/**
 * Exhaustive by construction: the Record means an ANSI color added to the
 * shared type without a label here is a compile error, not a silently
 * missing swatch. The editor's two rows are derived from it below (split on
 * the bright prefix, in this declaration order), so every key gets exactly
 * one swatch and there is no second list to keep aligned.
 */
const ANSI_LABELS: Record<keyof TerminalAnsiColors, string> = {
  black: 'Black',
  red: 'Red',
  green: 'Green',
  yellow: 'Yellow',
  blue: 'Blue',
  magenta: 'Magenta',
  cyan: 'Cyan',
  white: 'White',
  brightBlack: 'Bright Black',
  brightRed: 'Bright Red',
  brightGreen: 'Bright Green',
  brightYellow: 'Bright Yellow',
  brightBlue: 'Bright Blue',
  brightMagenta: 'Bright Magenta',
  brightCyan: 'Bright Cyan',
  brightWhite: 'Bright White'
}

const ANSI_KEYS = Object.keys(ANSI_LABELS) as Array<keyof TerminalAnsiColors>

const ANSI_ROWS: Array<{
  label: string
  colors: Array<{ key: keyof TerminalAnsiColors; label: string }>
}> = [
  {
    label: 'Normal',
    colors: ANSI_KEYS.filter((key) => !key.startsWith('bright')).map((key) => ({
      key,
      label: ANSI_LABELS[key]
    }))
  },
  {
    label: 'Bright',
    colors: ANSI_KEYS.filter((key) => key.startsWith('bright')).map((key) => ({
      key,
      label: ANSI_LABELS[key]
    }))
  }
]

const CURSOR_STYLES: Array<{ value: TerminalCursorStyle; label: string }> = [
  { value: 'block', label: 'Block' },
  { value: 'bar', label: 'Bar' },
  { value: 'underline', label: 'Underline' }
]

// The test ids predate this table and don't all derive from the key, so
// they stay explicit rather than computed.
const MAIN_COLORS: Array<{
  key: 'background' | 'foreground' | 'cursorColor' | 'selectionBackground'
  label: string
  testId: string
}> = [
  { key: 'background', label: 'Background', testId: 'settings-terminal-background-color' },
  { key: 'foreground', label: 'Foreground', testId: 'settings-terminal-foreground-color' },
  { key: 'cursorColor', label: 'Cursor', testId: 'settings-terminal-cursor-color' },
  { key: 'selectionBackground', label: 'Selection', testId: 'settings-terminal-selection-color' }
]

/**
 * Installed system font families, for the font-family dropdown below (see
 * src/main/fonts.ts — macOS only, via Cocoa's font registry). Resolves to
 * null on any other platform, or if the query comes back empty for any
 * reason, in which case the caller falls back to a free-text input.
 */
function useLocalFontFamilies(): string[] | null {
  const [families, setFamilies] = useState<string[] | null>(null)

  useEffect(() => {
    let cancelled = false
    terminalSettingsCtx
      .get()
      .listFontFamilies()
      .then((fonts) => {
        if (cancelled || fonts.length === 0) return
        setFamilies([...fonts].sort((a, b) => a.localeCompare(b)))
      })
    return () => {
      cancelled = true
    }
  }, [])

  return families
}

/**
 * The terminal content type's settings page — behavior toggles, then a
 * manually-edited font/color config for every terminal pane, matching what
 * macOS Terminal.app's own profile editor exposes. See TerminalRenderer.tsx
 * for where the appearance is applied (live, to already-open panes as well
 * as new ones). All writes go through updateTerminalSettings, which persists
 * the whole terminal blob (the contentTypes write contract).
 */
function TerminalSettingsPage() {
  const terminal = useTerminalSetting((settings) => settings)
  const appearance = terminal.appearance
  const fontFamilies = useLocalFontFamilies()

  const update = (patch: Partial<TerminalAppearance>): void => {
    updateTerminalSettings({ appearance: { ...appearance, ...patch } })
  }
  const updateAnsi = (key: keyof TerminalAnsiColors, value: string): void => {
    update({ ansi: { ...appearance.ansi, [key]: value } })
  }
  // Undefined (the box mid-edit — see parseNumberInput) leaves the setting
  // untouched until it holds a real number again.
  const updateNumber = (key: 'fontSize' | 'lineHeight', raw: string): void => {
    const value = parseNumberInput(raw)
    if (value !== undefined) update({ [key]: value })
  }
  const updateScrollback = (value: number | undefined): void => {
    if (value === undefined || value < 0) return
    updateTerminalSettings({ scrollback: Math.round(value) })
  }

  // Always includes the current value, even if it's not in the queried list
  // (a name typed by hand, or the query hasn't resolved yet) so the select
  // never silently shows blank.
  const fontOptions = fontFamilies
    ? Array.from(new Set([appearance.fontFamily, ...fontFamilies]))
    : null

  return (
    <div data-testid="settings-page-terminal">
      <h1 className="settings-page-title">Terminal</h1>
      <section className="settings-section">
        <SettingsCheckboxRow
          testId="settings-webgl-rendering-checkbox"
          title="WebGL rendering"
          description="Render terminal panes with WebGL acceleration. Experimental — applies to newly opened panes only."
          checked={terminal.enableWebglRendering}
          onChange={(checked) => updateTerminalSettings({ enableWebglRendering: checked })}
        />
        <SettingsCheckboxRow
          testId="settings-inherit-cwd-checkbox"
          title="Inherit working directory"
          description="New splits and tabs start in the current terminal's directory."
          checked={terminal.inheritCwdOnNewPane}
          onChange={(checked) => updateTerminalSettings({ inheritCwdOnNewPane: checked })}
        />
        <SettingsNumberRow
          testId="settings-terminal-scrollback-input"
          title="Scrollback"
          description="Lines of history kept above the visible screen, per pane. Applies live to already-open panes. 0 disables scrollback."
          value={terminal.scrollback}
          min={0}
          step={100}
          onChange={updateScrollback}
        />
      </section>

      <section className="settings-section">
        <h3 className="settings-section-title">Appearance</h3>
        <div className="terminal-appearance-field">
          <label htmlFor="terminal-font-family">Font family</label>
          {fontOptions ? (
            <select
              id="terminal-font-family"
              data-testid="settings-terminal-font-family-select"
              value={appearance.fontFamily}
              onChange={(event) => update({ fontFamily: event.target.value })}
            >
              {fontOptions.map((family) => (
                <option key={family} value={family}>
                  {family}
                </option>
              ))}
            </select>
          ) : (
            <input
              id="terminal-font-family"
              type="text"
              data-testid="settings-terminal-font-family-input"
              value={appearance.fontFamily}
              onChange={(event) => update({ fontFamily: event.target.value })}
            />
          )}
        </div>

        <div className="terminal-appearance-row">
          <div className="terminal-appearance-field">
            <label htmlFor="terminal-font-size">Font size</label>
            <input
              id="terminal-font-size"
              type="number"
              min={8}
              max={32}
              step={1}
              data-testid="settings-terminal-font-size-input"
              value={appearance.fontSize}
              onChange={(event) => updateNumber('fontSize', event.target.value)}
            />
          </div>
          <div className="terminal-appearance-field">
            <label htmlFor="terminal-line-height">Line height</label>
            <input
              id="terminal-line-height"
              type="number"
              min={0.8}
              max={2}
              step={0.05}
              data-testid="settings-terminal-line-height-input"
              value={appearance.lineHeight}
              onChange={(event) => updateNumber('lineHeight', event.target.value)}
            />
          </div>
        </div>

        <div className="terminal-appearance-row">
          <div className="terminal-appearance-field">
            <label htmlFor="terminal-cursor-style">Cursor style</label>
            <select
              id="terminal-cursor-style"
              data-testid="settings-terminal-cursor-style-select"
              value={appearance.cursorStyle}
              onChange={(event) =>
                update({ cursorStyle: event.target.value as TerminalCursorStyle })
              }
            >
              {CURSOR_STYLES.map(({ value, label }) => (
                <option key={value} value={value}>
                  {label}
                </option>
              ))}
            </select>
          </div>
          <label className="terminal-appearance-checkbox">
            <input
              type="checkbox"
              data-testid="settings-terminal-cursor-blink-checkbox"
              checked={appearance.cursorBlink}
              onChange={(event) => update({ cursorBlink: event.target.checked })}
            />
            Cursor blink
          </label>
        </div>

        <div className="terminal-appearance-colors">
          {MAIN_COLORS.map(({ key, label, testId }) => (
            <label className="terminal-appearance-color" key={key}>
              <input
                type="color"
                data-testid={testId}
                value={appearance[key]}
                onChange={(event) => update({ [key]: event.target.value })}
              />
              {label}
            </label>
          ))}
        </div>

        <div className="terminal-appearance-ansi">
          {ANSI_ROWS.map((row) => (
            <div className="terminal-appearance-ansi-row" key={row.label}>
              <span className="terminal-appearance-ansi-row-label">{row.label}</span>
              {row.colors.map(({ key, label }) => (
                <input
                  key={key}
                  type="color"
                  className="terminal-appearance-ansi-swatch"
                  title={label}
                  aria-label={label}
                  data-testid={`settings-terminal-ansi-${key}-color`}
                  value={appearance.ansi[key]}
                  onChange={(event) => updateAnsi(key, event.target.value)}
                />
              ))}
            </div>
          ))}
        </div>
      </section>
    </div>
  )
}

/**
 * The terminal's sidebar contribution — registered by this package's settings
 * `activate`. Id and label come from the shared census, so the
 * `settings-tab-terminal` test id and the sidebar text follow the same source
 * as the pane header's (see shared/content/registry.ts). The context stamps
 * the owning content type on registration, which is what hides the page while
 * the terminal is turned off.
 */
export const terminalSettingsPageDef: PluginSettingsPageDef = {
  id: terminalManifest.type,
  label: terminalManifest.displayName,
  Icon: TerminalIcon,
  Component: TerminalSettingsPage
}
