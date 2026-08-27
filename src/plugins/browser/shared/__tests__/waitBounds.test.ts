import { describe, expect, it } from 'vitest'
import {
  clampWaitPoll,
  clampWaitTimeout,
  WAIT_DEFAULT_POLL_MS,
  WAIT_DEFAULT_TIMEOUT_MS,
  WAIT_MAX_TIMEOUT_MS,
  WAIT_MIN_POLL_MS
} from '../externalControl'

/**
 * The wait clamps are the arithmetic both processes must agree on: the
 * renderer runs its wait on clampWaitTimeout's number and main prices the
 * relay as the same number plus headroom, so "the relay always outlives the
 * wait" holds exactly as long as these stay total functions over untyped wire
 * input — a NaN or a string reaching either side unclamped would open the gap.
 */
describe('clampWaitTimeout', () => {
  it('defaults when absent, and on anything non-numeric off the wire', () => {
    expect(clampWaitTimeout(undefined)).toBe(WAIT_DEFAULT_TIMEOUT_MS)
    expect(clampWaitTimeout('9000' as unknown)).toBe(WAIT_DEFAULT_TIMEOUT_MS)
    expect(clampWaitTimeout(Number.NaN)).toBe(WAIT_DEFAULT_TIMEOUT_MS)
    expect(clampWaitTimeout(Number.POSITIVE_INFINITY)).toBe(WAIT_DEFAULT_TIMEOUT_MS)
  })

  it('passes a reasonable request through, rounded', () => {
    expect(clampWaitTimeout(3000)).toBe(3000)
    expect(clampWaitTimeout(2500.7)).toBe(2501)
  })

  it('caps at the ceiling and floors at zero (one immediate check)', () => {
    expect(clampWaitTimeout(WAIT_MAX_TIMEOUT_MS + 1)).toBe(WAIT_MAX_TIMEOUT_MS)
    expect(clampWaitTimeout(-5)).toBe(0)
  })
})

describe('clampWaitPoll', () => {
  it('defaults when absent or non-numeric, and floors at the minimum', () => {
    expect(clampWaitPoll(undefined)).toBe(WAIT_DEFAULT_POLL_MS)
    expect(clampWaitPoll('fast' as unknown)).toBe(WAIT_DEFAULT_POLL_MS)
    expect(clampWaitPoll(1)).toBe(WAIT_MIN_POLL_MS)
    expect(clampWaitPoll(400)).toBe(400)
  })
})
