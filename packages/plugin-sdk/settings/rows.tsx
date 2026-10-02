/**
 * The presentational settings-row components a content-type package's own
 * Settings page may use — sanctioned UI kit, so a package binding these to
 * keys inside its own `contentTypes` blob doesn't drift from core's styling
 * the first time it moves. Split out of `src/renderer/src/settings/settingsRows.tsx`,
 * which stays core-owned for `SettingsRowGroup` and the row-union types
 * bound to the *whole* `Settings` interface (`BooleanSettingKey`,
 * `StringSettingKey`, `SettingRow`, `SettingsRowSection`) — a package's own
 * page never binds to those, only to its own settings shape.
 *
 * `RowText` moves too: it's the shared title/description markup every row
 * here (and several that stay core-only) renders — one definition, so core's
 * own `SettingsActionRow`/`SettingsAnchorRow`/the inline range row in
 * `SettingsRowGroup` import it back rather than each keeping a copy.
 */

/** The title/description pair every row carries, text-left of its control. `tone` stamps `data-tone` on the description. */
export function RowText({
  title,
  description,
  tone
}: {
  title: string
  description: string
  tone?: string | undefined
}) {
  return (
    <span className="settings-row-text">
      <span className="settings-row-title">{title}</span>
      <span className="settings-row-desc" data-tone={tone}>
        {description}
      </span>
    </span>
  )
}

/**
 * One checkbox row, purely presentational — the shared markup for boolean
 * settings wherever they live: core's `SettingsRowGroup` binds it to core's
 * flat Settings keys, while a content type's own page binds it to keys
 * inside its contentTypes blob.
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
 * SettingsCheckboxRow above, and shared for the same reason.
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
 * chrome. `onChange` gets `parseNumberInput`'s reading of the field —
 * undefined while it holds no number.
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
