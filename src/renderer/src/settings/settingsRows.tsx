import type { NewPaneSpawnPosition } from '@shared/model/floating'
import {
  NEW_PANE_SPAWN_POSITIONS,
  resolveSpawnPosition,
  SPAWN_COLUMNS
} from '@shared/model/floating'
import type { Settings } from '@shared/settings'
import type { KeyboardEvent } from 'react'
import type { SettingsState } from '../core/store/settingsStore'

/** Keys of the boolean settings, i.e. every setting rendered as a checkbox row. */
type BooleanSettingKey = {
  [K in keyof Settings]: Settings[K] extends boolean ? K : never
}[keyof Settings]

/** Keys of the string-valued settings, i.e. every setting rendered as a select row. */
type StringSettingKey = {
  [K in keyof Settings]: Settings[K] extends string ? K : never
}[keyof Settings]

interface CheckboxRow {
  type: 'checkbox'
  key: BooleanSettingKey
  testId: string
  title: string
  description: string
}

/**
 * A mapped union rather than one interface over the whole key union: written
 * that way, each concrete key gets its own member, so a row's `options` are
 * checked against *that* key's value type and can't be mixed up with another
 * select's. (Before there was a second select, this was pinned to a single
 * key outright.)
 */
type SelectRow = {
  [K in StringSettingKey]: {
    type: 'select'
    key: K
    testId: string
    title: string
    description: string
    options: Array<{ value: Settings[K]; label: string }>
  }
}[StringSettingKey]

interface RangeRow {
  type: 'range'
  key: 'dimInactivePanesIntensity'
  testId: string
  title: string
  description: string
  min: number
  max: number
  step: number
  /** Another boolean setting this row's control is disabled without — the intensity slider only matters once dimming itself is on. */
  enabledBy: BooleanSettingKey
}

/**
 * The 3x3 position picker. Pinned to its one key the way `RangeRow` is pinned
 * to `dimInactivePanesIntensity`: the row union's other members are generic
 * over a *category* of key (every boolean, every string), and there is no
 * category of "setting shaped like a position" for this to be generic over.
 */
interface AnchorRow {
  type: 'anchor'
  key: 'newUnpinnedPanePosition'
  testId: string
  title: string
  description: string
}

export type SettingRow = CheckboxRow | SelectRow | RangeRow | AnchorRow

export interface SettingsRowSection {
  /** Omit when the page's own `<h1>` already names this section — see PanesSettings.tsx. */
  title?: string
  rows: SettingRow[]
}

/** The title/description pair every row carries, text-left of its control. */
function RowText({ title, description }: { title: string; description: string }) {
  return (
    <span className="settings-row-text">
      <span className="settings-row-title">{title}</span>
      <span className="settings-row-desc">{description}</span>
    </span>
  )
}

/**
 * One checkbox row, purely presentational — the shared markup for boolean
 * settings wherever they live: SettingsRowGroup below binds it to core's
 * flat Settings keys, while a content type's own page (see
 * TerminalSettingsPage.tsx) binds it to keys inside its contentTypes blob.
 */
export function SettingsCheckboxRow({
  testId,
  title,
  description,
  checked,
  onChange
}: {
  testId: string
  title: string
  description: string
  checked: boolean
  onChange: (checked: boolean) => void
}) {
  return (
    <label className="settings-row">
      <input
        type="checkbox"
        data-testid={testId}
        checked={checked}
        onChange={(event) => onChange(event.target.checked)}
      />
      <RowText title={title} description={description} />
    </label>
  )
}

/**
 * One select row, purely presentational — the select-shaped twin of
 * SettingsCheckboxRow above, and shared for the same reason: SettingsRowGroup
 * binds it to core's flat Settings keys, while a content type's own page (see
 * BrowserSettingsPage.tsx) binds it to keys inside its contentTypes blob, and
 * neither should be restating `.settings-row-select`'s markup contract.
 *
 * Generic over the value type so a package's page keeps its own string union
 * end to end. The one cast is `event.target.value`, which the DOM types as a
 * bare string: sound because the options a caller renders are the only values
 * the control can produce.
 */
export function SettingsSelectRow<T extends string>({
  testId,
  title,
  description,
  value,
  options,
  onChange
}: {
  testId: string
  title: string
  description: string
  value: T
  options: ReadonlyArray<{ value: T; label: string }>
  onChange: (value: T) => void
}) {
  return (
    <label className="settings-row settings-row-select">
      <RowText title={title} description={description} />
      <select
        data-testid={testId}
        value={value}
        onChange={(event) => onChange(event.target.value as T)}
      >
        {options.map((option) => (
          <option key={option.value} value={option.value}>
            {option.label}
          </option>
        ))}
      </select>
    </label>
  )
}

/**
 * What a number input reports, as a number — or undefined mid-edit. The
 * input reports '' when cleared (or holding invalid intermediate text), and
 * Number('') is 0, which a live setting would apply instantly; undefined lets
 * the caller leave the setting untouched until the box holds a real number
 * again. Range and rounding stay the caller's policy; this is only the part
 * intrinsic to the control, so every number field shares the one guard.
 */
export function parseNumberInput(raw: string): number | undefined {
  if (raw.trim() === '') return undefined
  const value = Number(raw)
  return Number.isNaN(value) ? undefined : value
}

/**
 * A number field on the select row's layout — same text-left, control-right
 * chrome (`.settings-row-select input[type="number"]` in global.css).
 * `onChange` gets `parseNumberInput`'s reading of the field — undefined
 * while it holds no number.
 */
export function SettingsNumberRow({
  testId,
  title,
  description,
  value,
  min,
  step,
  onChange
}: {
  testId: string
  title: string
  description: string
  value: number
  min?: number
  step?: number
  onChange: (value: number | undefined) => void
}) {
  return (
    <label className="settings-row settings-row-select">
      <RowText title={title} description={description} />
      <input
        type="number"
        min={min}
        step={step}
        data-testid={testId}
        value={value}
        onChange={(event) => onChange(parseNumberInput(event.target.value))}
      />
    </label>
  )
}

/** "middle-center" → "Middle center", the name assistive tech announces for a cell. */
function anchorLabel(position: NewPaneSpawnPosition): string {
  const [row, column] = position.split('-') as [string, string]
  return `${row[0]!.toUpperCase()}${row.slice(1)} ${column}`
}

/**
 * A rectangle standing in for the pane, split into the nine sections a new
 * unpinned pane can spawn in, with the chosen one filled in the accent color.
 *
 * Nine native radios in a fieldset, rather than divs carrying click handlers:
 * the platform then owns the group semantics, the roving focus and the focus
 * ring, and no static element carries an interaction for the linter to object
 * to. Cells come from NEW_PANE_SPAWN_POSITIONS, so the grid and the type that
 * describes it are the same list.
 *
 * What the platform does *not* do is treat a radio group as two-dimensional:
 * ArrowDown means "the next radio in the DOM", which in a 3-column grid is the
 * cell to the right. `handleArrowKeys` is the whole of the difference — the
 * vertical arrows step by a row instead, wrapping the way the native
 * horizontal ones already do.
 */
function SettingsAnchorRow({
  row,
  value,
  onChange
}: {
  row: AnchorRow
  value: NewPaneSpawnPosition
  onChange: (next: NewPaneSpawnPosition) => void
}) {
  const handleArrowKeys = (event: KeyboardEvent<HTMLFieldSetElement>): void => {
    const columns = SPAWN_COLUMNS.length
    const step = event.key === 'ArrowDown' ? columns : event.key === 'ArrowUp' ? -columns : 0
    if (step === 0) return
    // Left alone, the native handling would move by a single cell — sideways.
    event.preventDefault()
    const count = NEW_PANE_SPAWN_POSITIONS.length
    const index = NEW_PANE_SPAWN_POSITIONS.indexOf(value)
    const next = NEW_PANE_SPAWN_POSITIONS[(index + step + count) % count]!
    onChange(next)
    // Focus follows selection, as it does in a native radio group.
    event.currentTarget.querySelector<HTMLInputElement>(`input[value="${next}"]`)?.focus()
  }
  return (
    <div className="settings-row settings-row-anchor">
      <RowText title={row.title} description={row.description} />
      <fieldset className="settings-anchor-grid" onKeyDown={handleArrowKeys}>
        {/* The row's own title says this on screen; the legend is for the
            accessibility tree, which cannot see the title next to it. */}
        <legend className="settings-anchor-legend">{row.title}</legend>
        {NEW_PANE_SPAWN_POSITIONS.map((position) => (
          <input
            key={position}
            type="radio"
            className="settings-anchor-cell"
            name={row.key}
            value={position}
            aria-label={anchorLabel(position)}
            data-testid={`${row.testId}-${position}`}
            checked={position === value}
            onChange={() => onChange(position)}
          />
        ))}
      </fieldset>
    </div>
  )
}

/**
 * Renders one titled group of setting rows — a category page composes one or
 * more of these.
 */
export function SettingsRowGroup({
  section,
  settings
}: {
  section: SettingsRowSection
  settings: SettingsState
}) {
  return (
    <section className="settings-section">
      {section.title && <h3 className="settings-section-title">{section.title}</h3>}
      {section.rows.map((row) => {
        if (row.type === 'select') {
          // setSetting correlates its key and value generically, which TS
          // can't track through a union-typed `row.key` at the call site. The
          // widening asserted here is the sound one — every StringSettingKey
          // holds a string — and the values themselves are already checked
          // against the right key where the row is declared.
          const setValue = settings.setSetting as (key: StringSettingKey, value: string) => void
          return (
            <SettingsSelectRow
              key={row.key}
              testId={row.testId}
              title={row.title}
              description={row.description}
              value={settings[row.key]}
              options={row.options}
              onChange={(value) => setValue(row.key, value)}
            />
          )
        }
        if (row.type === 'anchor') {
          return (
            <SettingsAnchorRow
              key={row.key}
              row={row}
              // Read through the resolver, so a hand-edited settings.json
              // showing garbage still lights the cell that will actually be
              // used rather than lighting none of them.
              value={resolveSpawnPosition(settings[row.key])}
              onChange={(next) => settings.setSetting(row.key, next)}
            />
          )
        }
        if (row.type === 'range') {
          const disabled = !settings[row.enabledBy]
          return (
            <label
              key={row.key}
              className="settings-row settings-row-range"
              data-disabled={disabled || undefined}
            >
              <RowText title={row.title} description={row.description} />
              <input
                type="range"
                data-testid={row.testId}
                min={row.min}
                max={row.max}
                step={row.step}
                disabled={disabled}
                value={settings[row.key]}
                onChange={(event) => settings.setSetting(row.key, Number(event.target.value))}
              />
            </label>
          )
        }
        return (
          <SettingsCheckboxRow
            key={row.key}
            testId={row.testId}
            title={row.title}
            description={row.description}
            checked={settings[row.key]}
            onChange={(checked) => settings.setSetting(row.key, checked)}
          />
        )
      })}
    </section>
  )
}
