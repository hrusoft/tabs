import type { CaffeinateFlags } from '@shared/api'
import { useState } from 'react'
import { openModal } from '../core/modal'

/**
 * Sensible defaults: keep the Mac running (idle sleep + AC-power system
 * sleep both blocked) but let the display itself sleep — the common case
 * for a long build/download/agent run, where you don't need the screen lit
 * the whole time. Disk idle sleep and "declare the user active" are the two
 * options someone has to opt into on purpose.
 */
const DEFAULT_FLAGS: CaffeinateFlags = {
  preventDisplaySleep: false,
  preventIdleSleep: true,
  preventDiskSleep: false,
  preventSystemSleep: true,
  declareUserActive: false
}

interface FieldRowProps {
  testId: string
  label: string
  hint?: string
  checked: boolean
  onChange: (checked: boolean) => void
}

function FieldRow({ testId, label, hint, checked, onChange }: FieldRowProps) {
  return (
    <label className="caffeinate-row">
      <input
        type="checkbox"
        data-testid={testId}
        checked={checked}
        onChange={(event) => onChange(event.target.checked)}
      />
      <span className="caffeinate-row-text">
        <span className="caffeinate-row-label">{label}</span>
        {hint && <span className="caffeinate-row-hint">{hint}</span>}
      </span>
    </label>
  )
}

/** Minutes the timer input shows and accepts — parsed back to whole seconds for the flags CaffeinateFlags.timerSeconds carries. Empty means "run until Decaf". */
function parseTimerMinutes(text: string): number | undefined {
  const trimmed = text.trim()
  if (trimmed === '') return undefined
  const minutes = Number(trimmed)
  if (!Number.isFinite(minutes) || !Number.isInteger(minutes) || minutes <= 0) return undefined
  return minutes * 60
}

/**
 * The form File → Caffeinate… opens (see installCaffeinate.ts) — five
 * `caffeinate(8)` assertion flags plus an optional timer, a Start button
 * that resolves the flags to launch with, and a Cancel that resolves null.
 * Built on `openModal` with no shell change: its own local `useState` for
 * the field values lives inside this component, which `openModal` mounts
 * exactly once and never re-creates while the dialog is open.
 */
function CaffeinateForm({
  onStart,
  onCancel
}: {
  onStart: (flags: CaffeinateFlags) => void
  onCancel: () => void
}) {
  const [flags, setFlags] = useState<CaffeinateFlags>(DEFAULT_FLAGS)
  const [timerText, setTimerText] = useState('')

  const set = (key: keyof Omit<CaffeinateFlags, 'timerSeconds'>) => (checked: boolean) =>
    setFlags((prev) => ({ ...prev, [key]: checked }))

  const handleStart = (): void => {
    const timerSeconds = parseTimerMinutes(timerText)
    onStart(timerSeconds === undefined ? flags : { ...flags, timerSeconds })
  }

  return (
    <div className="modal-body">
      <FieldRow
        testId="caffeinate-field-display"
        label="Prevent display sleep"
        checked={flags.preventDisplaySleep}
        onChange={set('preventDisplaySleep')}
      />
      <FieldRow
        testId="caffeinate-field-idle"
        label="Prevent idle system sleep"
        checked={flags.preventIdleSleep}
        onChange={set('preventIdleSleep')}
      />
      <FieldRow
        testId="caffeinate-field-disk"
        label="Prevent disk idle sleep"
        checked={flags.preventDiskSleep}
        onChange={set('preventDiskSleep')}
      />
      <FieldRow
        testId="caffeinate-field-system"
        label="Prevent system sleep"
        hint="Only applies on AC power."
        checked={flags.preventSystemSleep}
        onChange={set('preventSystemSleep')}
      />
      <FieldRow
        testId="caffeinate-field-active"
        label="Declare the user active"
        hint="Wakes the display; lasts 5 seconds unless a timer is also set below."
        checked={flags.declareUserActive}
        onChange={set('declareUserActive')}
      />
      <label className="caffeinate-row caffeinate-timer-row">
        <span className="caffeinate-row-text">
          <span className="caffeinate-row-label">Stop after</span>
          <span className="caffeinate-row-hint">Leave empty to run until Decaf.</span>
        </span>
        <span className="caffeinate-timer-input">
          <input
            type="number"
            min="1"
            step="1"
            inputMode="numeric"
            data-testid="caffeinate-field-timer"
            value={timerText}
            onChange={(event) => setTimerText(event.target.value)}
            aria-label="Minutes"
          />
          <span>minutes</span>
        </span>
      </label>
      <div className="modal-actions">
        <button
          type="button"
          className="modal-button"
          data-testid="caffeinate-cancel-button"
          onClick={onCancel}
        >
          Cancel
        </button>
        <button
          type="button"
          className="modal-button modal-button-primary"
          data-testid="caffeinate-start-button"
          onClick={handleStart}
        >
          Start
        </button>
      </div>
    </div>
  )
}

/** Opens the Caffeinate dialog; resolves the chosen flags on Start, or null on Cancel/Escape/backdrop. */
export function openCaffeinateDialog(): Promise<CaffeinateFlags | null> {
  return openModal<CaffeinateFlags | null>({
    // No ellipsis: that belongs to the menu item that opens this (it opens a
    // dialog, so the label promises one), not to the dialog's own title.
    title: 'Caffeinate',
    testId: 'caffeinate-dialog',
    dismissValue: null,
    render: (resolve) => <CaffeinateForm onStart={resolve} onCancel={() => resolve(null)} />
  })
}
