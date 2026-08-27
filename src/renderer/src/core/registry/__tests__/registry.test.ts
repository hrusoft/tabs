import { describe, expect, it, vi } from 'vitest'
import type { ContentRendererDef } from '../registry'
import { ContentRegistry } from '../registry'

function defFor(type: string): ContentRendererDef {
  return { type, displayName: type, Component: () => null }
}

describe('ContentRegistry', () => {
  it('round-trips register/get and reports has', () => {
    const registry = new ContentRegistry()
    const def = defFor('welcome')

    registry.register(def)

    expect(registry.get('welcome')).toBe(def)
    expect(registry.has('welcome')).toBe(true)
  })

  it('throws on duplicate registration', () => {
    const registry = new ContentRegistry()
    registry.register(defFor('welcome'))

    expect(() => registry.register(defFor('welcome'))).toThrow(/already registered/)
  })

  it('returns undefined for unknown types', () => {
    const registry = new ContentRegistry()

    expect(registry.get('nope')).toBeUndefined()
    expect(registry.has('nope')).toBe(false)
  })

  it('notifies subscribers on register/unregister and stops after dispose', () => {
    const registry = new ContentRegistry()
    const listener = vi.fn()
    const dispose = registry.subscribe(listener)

    registry.register(defFor('a'))
    expect(listener).toHaveBeenCalledTimes(1)

    registry.unregister('a')
    expect(listener).toHaveBeenCalledTimes(2)

    // Unregistering something absent does not notify.
    registry.unregister('a')
    expect(listener).toHaveBeenCalledTimes(2)

    dispose()
    registry.register(defFor('b'))
    expect(listener).toHaveBeenCalledTimes(2)
  })

  it('lists defs in registration order', () => {
    const registry = new ContentRegistry()
    expect(registry.list()).toEqual([])

    const a = defFor('a')
    const b = defFor('b')
    const c = defFor('c')
    registry.register(a)
    registry.register(b)
    registry.register(c)

    expect(registry.list()).toEqual([a, b, c])
  })

  it('moves a re-registered def to the end of the list', () => {
    const registry = new ContentRegistry()
    const b = defFor('b')
    registry.register(defFor('a'))
    registry.register(b)
    registry.register(defFor('c'))

    registry.unregister('b')
    registry.register(b)

    expect(registry.list().map((def) => def.type)).toEqual(['a', 'c', 'b'])
  })

  it('bumps the version on every change', () => {
    const registry = new ContentRegistry()
    const before = registry.getVersion()

    registry.register(defFor('a'))
    registry.unregister('a')

    expect(registry.getVersion()).toBe(before + 2)
  })
})
