import { describe, expect, it } from 'vitest'
import { migrateTerminalSettings, terminalSettingsDescriptor } from '../settings'

/**
 * The terminal's `migrate` hook in isolation. Its behaviour *through* a real
 * load is covered end to end by src/main/__tests__/settings.test.ts's
 * "migration from the flat pre-contentTypes shape" block; what's asserted here
 * is the descriptor contract itself — the two things core relies on and cannot
 * check for itself (see ContentTypeSettingsDescriptor.migrate).
 */
describe('migrateTerminalSettings', () => {
  it('is wired onto the descriptor, so core actually calls it', () => {
    expect(terminalSettingsDescriptor.migrate).toBe(migrateTerminalSettings)
  })

  it('hoists each legacy root key only when the namespaced blob lacks it', () => {
    const { blob } = migrateTerminalSettings(
      {
        inheritCwdOnNewPane: false,
        enableWebglRendering: false,
        terminal: { fontSize: 19 }
      },
      { enableWebglRendering: true }
    )
    expect(blob).toEqual({
      // Absent from the blob, so the legacy root value is taken.
      inheritCwdOnNewPane: false,
      // Present in the blob, so the legacy root value loses — the downgrade
      // round-trip rule.
      enableWebglRendering: true,
      appearance: { fontSize: 19 }
    })
  })

  it('reports its root keys as consumed even when the file carried none', () => {
    // "Mine", not "found": a current-shape file that still holds a stale copy
    // of a legacy key must get it stripped too, not carried at both levels.
    const { consumed } = migrateTerminalSettings({}, { inheritCwdOnNewPane: true })
    expect([...consumed].sort()).toEqual([
      'enableWebglRendering',
      'inheritCwdOnNewPane',
      'terminal'
    ])
  })

  it('never throws, whatever shape either side is', () => {
    // Totality is the whole contract: a throw here makes loadSettings fall
    // back to DEFAULT_SETTINGS wholesale and the next save persists the wipe.
    const hostile = [undefined, null, 0, 'x', [], [1, 2], true, { appearance: 'not-an-object' }]
    for (const root of hostile) {
      for (const blob of hostile) {
        expect(() =>
          migrateTerminalSettings(root as unknown as Record<string, unknown>, blob)
        ).not.toThrow()
      }
    }
  })
})
