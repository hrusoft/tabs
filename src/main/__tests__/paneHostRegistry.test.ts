import type { WebContents } from 'electron'
import { afterEach, describe, expect, it } from 'vitest'
import {
  getPaneHost,
  hasPaneHost,
  registerPaneHost,
  resetPaneHostsForTests
} from '../paneHostRegistry'

/** The registry only ever compares hosts by identity, so a bare object suffices. */
function fakeHost(overrides: Partial<WebContents> = {}): WebContents {
  return overrides as WebContents
}

// The host Map is module state; wipe it or it leaks into the next test.
afterEach(() => {
  resetPaneHostsForTests()
})

describe('registerPaneHost', () => {
  it('an unregistered id has no host and fails the caller check', () => {
    expect(getPaneHost('pane-1')).toBeUndefined()
    expect(hasPaneHost('pane-1')).toBe(false)
  })

  it('registering makes the exact host retrievable and the caller check pass', () => {
    const host = fakeHost()
    registerPaneHost('pane-1', host)
    expect(getPaneHost('pane-1')).toBe(host)
    expect(hasPaneHost('pane-1')).toBe(true)
  })

  it('re-registering an id replaces the mapping — a reattach is routine, not a conflict', () => {
    const first = fakeHost()
    const second = fakeHost()
    registerPaneHost('pane-1', first)
    registerPaneHost('pane-1', second)
    expect(getPaneHost('pane-1')).toBe(second)
  })

  it('the returned disposer removes the mapping it created', () => {
    const dispose = registerPaneHost('pane-1', fakeHost())
    dispose()
    expect(hasPaneHost('pane-1')).toBe(false)
    expect(getPaneHost('pane-1')).toBeUndefined()
  })

  it('a stale disposer from before a re-register is a no-op — the replacement survives', () => {
    const staleDispose = registerPaneHost('pane-1', fakeHost())
    const replacement = fakeHost()
    registerPaneHost('pane-1', replacement)
    staleDispose()
    expect(getPaneHost('pane-1')).toBe(replacement)
  })

  it('the disposer is idempotent', () => {
    const dispose = registerPaneHost('pane-1', fakeHost())
    dispose()
    dispose()
    expect(hasPaneHost('pane-1')).toBe(false)
  })
})

describe('hasPaneHost', () => {
  it('is registration-only — a destroyed host still authenticates until deregistered', () => {
    // Pins the auth/relay asymmetry: relayToRenderer checks isDestroyed()
    // itself, while the caller-identity check must not (see paneHostRegistry.ts).
    registerPaneHost('pane-1', fakeHost({ isDestroyed: () => true }))
    expect(hasPaneHost('pane-1')).toBe(true)
  })
})

describe('resetPaneHostsForTests', () => {
  it('clears every mapping', () => {
    registerPaneHost('pane-1', fakeHost())
    registerPaneHost('pane-2', fakeHost())
    resetPaneHostsForTests()
    expect(hasPaneHost('pane-1')).toBe(false)
    expect(hasPaneHost('pane-2')).toBe(false)
  })
})
