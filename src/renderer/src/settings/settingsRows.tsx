import type { NewPaneSpawnPosition } from '@shared/model/floating'
import {
  NEW_PANE_SPAWN_POSITIONS,
  resolveSpawnPosition,
  SPAWN_COLUMNS
} from '@shared/model/floating'
import type { Settings } from '@shared/settings'
import { RowText, SettingsCheckboxRow, SettingsSelectRow } from '@tabs/plugin-sdk/settings/rows'
import type { KeyboardEvent, ReactNode } from 'react'

export {
  parseNumberInput,
  SettingsCheckboxRow,
  SettingsNumberRow,
  SettingsSelectRow
} from '@tabs/plugin-sdk/settings/rows'

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

type SettingRow = CheckboxRow | SelectRow | RangeRow | AnchorRow

export interface SettingsRowSection {
  /** Omit when the page's own `<h1>` already names this section — see PanesSettings.tsx. */
  title?: string
  rows: SettingRow[]
}

/**
 * A row whose control is one or more buttons rather than a bound setting —
 * what the skill installer (AiSettings.tsx) and the shortcut editor
 * (KeyboardSettings.tsx) share. Presentational like the rows above, and
 * deliberately not a `SettingRow` member: that union is bound to persisted
 * Settings keys, and an action row persists nothing. `tone` lands on the
 * description as `data-tone`, which is how the shortcut row colours a notice
 * shown in place of the description (`.settings-row-desc[data-tone]`).
 */
export function SettingsActionRow({
  title,
  description,
  tone,
  children
}: {
  title: string
  description: string
  tone?: string | undefined
  children: ReactNode
}) {
  return (
    <div className="settings-row settings-row-action">
      <RowText title={title} description={description} tone={tone} />
      <span className="settings-row-buttons">{children}</span>
    </div>
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
