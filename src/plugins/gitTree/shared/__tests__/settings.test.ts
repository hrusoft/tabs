import { describe, expect, it } from 'vitest'
import {
  DEFAULT_GIT_TREE_SETTINGS,
  type GitTreeSettings,
  gitTreeSettingsDescriptor,
  mergeGitTreeSettings
} from '../settings'

describe('mergeGitTreeSettings', () => {
  it('is wired onto the descriptor, so core actually calls it', () => {
    expect(gitTreeSettingsDescriptor.merge).toBe(mergeGitTreeSettings)
  })

  it('returns the defaults for nothing persisted', () => {
    expect(mergeGitTreeSettings(undefined)).toEqual(DEFAULT_GIT_TREE_SETTINGS)
  })

  it('lets a persisted value override the default', () => {
    expect(mergeGitTreeSettings({ autoRefreshOnFocus: true })).toEqual({
      autoRefreshOnFocus: true
    } satisfies GitTreeSettings)
  })

  it('never throws, whatever shape the persisted value is', () => {
    // Totality is the whole contract: a throw here makes loadSettings fall
    // back to DEFAULT_SETTINGS wholesale and the next save persists the wipe.
    const hostile = [undefined, null, 0, 'x', [], [1, 2], true, { autoRefreshOnFocus: 'nope' }]
    for (const persisted of hostile) {
      expect(() => mergeGitTreeSettings(persisted)).not.toThrow()
    }
  })
})
