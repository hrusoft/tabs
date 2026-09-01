import { describe, expect, it } from 'vitest'
import { macWindowCornerRadius } from '../windowChrome'

describe('macWindowCornerRadius', () => {
  it('returns the measured value for a known major version', () => {
    expect(macWindowCornerRadius('14.5')).toBe(10)
  })

  it('handles a multi-segment version string', () => {
    expect(macWindowCornerRadius('26.6.2')).toBe(16)
  })

  it('carries the latest known value forward for a newer, unmeasured major version', () => {
    expect(macWindowCornerRadius('27.0')).toBe(16)
  })

  it('falls back for a major version older than anything measured', () => {
    expect(macWindowCornerRadius('10.15')).toBe(10)
  })

  it('falls back for an unparseable version string', () => {
    expect(macWindowCornerRadius('not-a-version')).toBe(10)
  })
})
