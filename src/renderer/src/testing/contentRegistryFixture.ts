import type { ContentNode } from '@shared/model/types'
import { onTestFinished } from 'vitest'
import type { ContentRendererDef } from '../core/registry/registry'
import { contentRegistry } from '../core/registry/registry'

/**
 * Registers a test-only content type against the singleton `contentRegistry`
 * for the rest of the current test, and unregisters it when the test ends —
 * pass or fail, with no afterEach or try/finally of the caller's own.
 *
 * The registry is module-level state shared by every test in a file, and it
 * *throws* on a duplicate id rather than treating it as a remount — so a test
 * that registers without cleaning up fails the next test that registers the
 * same type, not itself. `displayName` and `Component` default to the least
 * interesting thing that satisfies the registry, so a test states only the
 * field it is about:
 *
 *     registerTestContentType({ type: 'blocker', mayBlockClose: true })
 */
export function registerTestContentType<N extends ContentNode>(
  def: Partial<ContentRendererDef<N>> & { type: string }
): void {
  contentRegistry.register<N>({ displayName: def.type, Component: () => null, ...def })
  onTestFinished(() => contentRegistry.unregister(def.type))
}

/** A bare leaf node — the shape most registry tests need one of, and nothing more. */
export function testLeaf(id: string, type: string, config: Record<string, unknown> = {}) {
  return { id, type, config }
}
