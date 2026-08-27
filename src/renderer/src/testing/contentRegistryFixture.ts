import { afterEach } from 'vitest'
import type { ContentRendererDef } from '../core/registry/registry'
import { contentRegistry } from '../core/registry/registry'

/**
 * Test-only content types, registered against the singleton `contentRegistry`
 * and unregistered when the test ends.
 *
 * The registry is module-level state shared by every test in a file, and it
 * *throws* on a duplicate id rather than treating it as a remount — so a test
 * that registers without cleaning up fails the next test that registers the
 * same type, not itself. Every file that registers types was writing out the
 * same id list, the same `afterEach` and the same defaults; this is that,
 * once.
 *
 * Call at module scope: the `afterEach` below is registered at the importing
 * file's collection time, exactly where a hand-written one would be.
 *
 *     const registerType = installTemporaryContentTypes()
 *     registerType({ type: 'plain' })
 *     registerType({ type: 'blocker', mayBlockClose: true })
 */
export function installTemporaryContentTypes(): (
  def: Partial<ContentRendererDef> & { type: string }
) => void {
  const registered: string[] = []
  afterEach(() => {
    for (const type of registered.splice(0)) contentRegistry.unregister(type)
  })
  return (def) => {
    // `displayName` and `Component` default to the least interesting thing that
    // satisfies the registry, so a test states only the field it is about.
    contentRegistry.register({ displayName: def.type, Component: () => null, ...def })
    registered.push(def.type)
  }
}

/** A bare leaf node — the shape most registry tests need one of, and nothing more. */
export function testLeaf(id: string, type: string, config: Record<string, unknown> = {}) {
  return { id, type, config }
}
