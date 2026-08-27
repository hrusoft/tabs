import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { createReattachRegistry } from '../reattachRegistry'

describe('createReattachRegistry', () => {
  beforeEach(() => {
    vi.useFakeTimers()
  })
  afterEach(() => {
    vi.useRealTimers()
  })

  it('creates on first acquire and returns the same instance after', () => {
    const registry = createReattachRegistry<{ n: number }>(300)
    const create = vi.fn(() => ({ n: 1 }))
    const first = registry.acquire('a', create)
    expect(registry.acquire('a', create)).toBe(first)
    expect(create).toHaveBeenCalledTimes(1)
  })

  it('keys instances independently', () => {
    const registry = createReattachRegistry<{ n: number }>(300)
    const a = registry.acquire('a', () => ({ n: 1 }))
    expect(registry.acquire('b', () => ({ n: 2 }))).not.toBe(a)
  })

  it('disposes only once the grace period elapses', () => {
    const registry = createReattachRegistry<{ n: number }>(300)
    const dispose = vi.fn()
    const instance = registry.acquire('a', () => ({ n: 1 }))
    registry.release('a', dispose)
    vi.advanceTimersByTime(299)
    expect(dispose).not.toHaveBeenCalled()
    vi.advanceTimersByTime(1)
    expect(dispose).toHaveBeenCalledExactlyOnceWith(instance)
  })

  it('re-acquiring within the grace period cancels the disposal and reattaches', () => {
    const registry = createReattachRegistry<{ n: number }>(300)
    const dispose = vi.fn()
    const first = registry.acquire('a', () => ({ n: 1 }))
    registry.release('a', dispose)
    expect(registry.acquire('a', () => ({ n: 2 }))).toBe(first)
    vi.advanceTimersByTime(1000)
    expect(dispose).not.toHaveBeenCalled()
  })

  it('creates fresh once a disposal has completed', () => {
    const registry = createReattachRegistry<{ n: number }>(300)
    registry.acquire('a', () => ({ n: 1 }))
    registry.release('a', () => {})
    vi.advanceTimersByTime(300)
    expect(registry.acquire('a', () => ({ n: 2 }))).toEqual({ n: 2 })
  })

  it('releasing an unknown id is a no-op', () => {
    const registry = createReattachRegistry<{ n: number }>(300)
    expect(() => registry.release('missing', () => {})).not.toThrow()
  })

  it('releasing twice schedules one disposal, so a re-acquire cannot be orphaned', () => {
    const registry = createReattachRegistry<{ n: number }>(300)
    const dispose = vi.fn()
    const first = registry.acquire('a', () => ({ n: 1 }))
    registry.release('a', dispose)
    vi.advanceTimersByTime(100)
    registry.release('a', dispose)
    // The re-acquire must cancel the one live timer; a second timer from the
    // double release would fire anyway and dispose the live instance.
    expect(registry.acquire('a', () => ({ n: 2 }))).toBe(first)
    vi.advanceTimersByTime(1000)
    expect(dispose).not.toHaveBeenCalled()
  })
})
