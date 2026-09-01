import { describe, expect, it } from 'vitest'
import {
  BROWSER_NEW_PANE_PLACEMENTS,
  browserSettingsDescriptor,
  DEFAULT_BROWSER_NEW_PANE_PLACEMENT,
  DEFAULT_BROWSER_SETTINGS,
  mergeBrowserSettings,
  resolveNewPanePlacement
} from '../settings'

describe('resolveNewPanePlacement', () => {
  it('passes every known placement through unchanged', () => {
    for (const placement of BROWSER_NEW_PANE_PLACEMENTS) {
      expect(resolveNewPanePlacement(placement)).toBe(placement)
    }
  })

  it('falls back to the default for anything a hand-edited settings.json could hold', () => {
    // Tolerated at read rather than rejected at load — see the function's own
    // comment: this drives a branch in handleCreateBrowserPane, not just CSS.
    for (const value of ['sideways', '', null, undefined, 3, { placement: 'tab' }]) {
      expect(resolveNewPanePlacement(value)).toBe(DEFAULT_BROWSER_NEW_PANE_PLACEMENT)
    }
  })
})

describe('mergeBrowserSettings', () => {
  it('is wired onto the descriptor, so core actually calls it', () => {
    expect(browserSettingsDescriptor.merge).toBe(mergeBrowserSettings)
  })

  it('returns the defaults for nothing persisted', () => {
    expect(mergeBrowserSettings(undefined)).toEqual(DEFAULT_BROWSER_SETTINGS)
  })

  it('lets a persisted value override the default', () => {
    expect(mergeBrowserSettings({ controlledPanePlacement: 'unpinned' })).toEqual({
      controlledPanePlacement: 'unpinned'
    })
  })

  it('normalizes a garbage placement rather than passing it through', () => {
    expect(mergeBrowserSettings({ controlledPanePlacement: 'sideways' })).toEqual({
      controlledPanePlacement: DEFAULT_BROWSER_NEW_PANE_PLACEMENT
    })
  })

  it('never throws, whatever shape the persisted value is', () => {
    // Totality is the whole contract: a throw here makes loadSettings fall
    // back to DEFAULT_SETTINGS wholesale and the next save persists the wipe.
    const hostile = [undefined, null, 0, 'x', [], [1, 2], true, { controlledPanePlacement: 9 }]
    for (const persisted of hostile) {
      expect(() => mergeBrowserSettings(persisted)).not.toThrow()
    }
  })
})
