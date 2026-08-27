import type { ContentNode } from '@shared/model/types'
import { describe, expect, it, vi } from 'vitest'
import type { ContentRendererDef, PaneCreationAction } from '../../core/registry/registry'
import {
  installTemporaryContentTypes,
  testLeaf as leaf
} from '../../testing/contentRegistryFixture'
import { createContentFor } from '../createFrom'
import { exposedCwdOf } from '../exposedCwd'

// `.tsx` despite holding no JSX, for the same reason contentLike.test.tsx is:
// the vitest project is selected by extension, and this file's imports reach
// the content registry, whose neighbours read window.api at module-eval time.

const registerContentType = installTemporaryContentTypes()

/** A creation action that always makes a leaf of `type`, with `config` as its seed. */
function action(type: string, config: Record<string, unknown> = {}): PaneCreationAction {
  return {
    testId: `pane-new-${type}-button`,
    label: `New ${type}`,
    Icon: () => null,
    createContent: () => ({ id: 'fresh', type, config })
  }
}

describe('createContentFor', () => {
  it('builds what the action asks for, from an origin of an entirely different type', async () => {
    // The case `createContentLike` structurally cannot express: the origin is
    // one type and the new content is another.
    registerContentType({ type: 'origin-kind' })
    registerContentType({ type: 'made-kind' })

    const content = await createContentFor(
      action('made-kind', { seed: 1 }),
      leaf('a', 'origin-kind')
    )

    expect(content).toMatchObject({ type: 'made-kind', config: { seed: 1 } })
  })

  it("runs the *created* type's deriveConfig, not the origin's", async () => {
    // The inversion this module exists for. Both types declare a hook; only
    // the one belonging to what is being made may run.
    const originHook = vi.fn().mockResolvedValue({ from: 'origin' })
    const madeHook = vi.fn().mockResolvedValue({ from: 'made' })
    registerContentType({ type: 'origin-kind', deriveConfig: originHook })
    registerContentType({ type: 'made-kind', deriveConfig: madeHook })

    const content = await createContentFor(action('made-kind'), leaf('a', 'origin-kind'))

    expect(content).toMatchObject({ config: { from: 'made' } })
    expect(originHook).not.toHaveBeenCalled()
  })

  it('hands the created type the origin leaf itself', async () => {
    const deriveConfig = vi.fn().mockResolvedValue(undefined)
    registerContentType({ type: 'made-kind', deriveConfig })
    const origin = leaf('a', 'origin-kind', { marker: true })

    await createContentFor(action('made-kind'), origin)

    expect(deriveConfig).toHaveBeenCalledExactlyOnceWith(origin)
  })

  it('resolves a container origin to its entry leaf, the way navigation would', async () => {
    const deriveConfig = vi.fn().mockResolvedValue(undefined)
    registerContentType({ type: 'made-kind', deriveConfig })
    const active = leaf('active-leaf', 'origin-kind')
    const origin: ContentNode = {
      id: 'g',
      type: 'tabs',
      activeTabId: 't2',
      tabs: [
        { id: 't1', title: 'other', content: leaf('other-leaf', 'origin-kind') },
        { id: 't2', title: 'active', content: active }
      ]
    }

    await createContentFor(action('made-kind'), origin)

    expect(deriveConfig).toHaveBeenCalledExactlyOnceWith(active)
  })

  it('merges the derived config over the action’s own seed', async () => {
    registerContentType({ type: 'made-kind', deriveConfig: async () => ({ cwd: '/derived' }) })

    const content = await createContentFor(
      action('made-kind', { cwd: '/seed', kept: 1 }),
      leaf('a', 'x')
    )

    expect(content).toMatchObject({ config: { cwd: '/derived', kept: 1 } })
  })

  it('keeps the action’s own content when the hook declines', async () => {
    registerContentType({ type: 'made-kind', deriveConfig: async () => undefined })

    const content = await createContentFor(action('made-kind', { cwd: '/seed' }), leaf('a', 'x'))

    expect(content).toMatchObject({ config: { cwd: '/seed' } })
  })

  it('takes the plain content when the created type declares no hook at all', async () => {
    registerContentType({ type: 'made-kind' })

    const content = await createContentFor(action('made-kind', { seed: 2 }), leaf('a', 'x'))

    expect(content).toMatchObject({ type: 'made-kind', config: { seed: 2 } })
  })

  it('rejects when the hook rejects, rather than creating half-configured content', async () => {
    registerContentType({
      type: 'made-kind',
      deriveConfig: async () => {
        throw new Error('lookup failed')
      }
    })

    await expect(createContentFor(action('made-kind'), leaf('a', 'x'))).rejects.toThrow(
      'lookup failed'
    )
  })
})

describe('exposedCwdOf', () => {
  it("asks the leaf's own type", async () => {
    const exposeCwd = vi.fn().mockResolvedValue('/live')
    registerContentType({ type: 'has-cwd', exposeCwd })
    const origin = leaf('a', 'has-cwd')

    expect(await exposedCwdOf(origin)).toBe('/live')
    expect(exposeCwd).toHaveBeenCalledExactlyOnceWith(origin)
  })

  it('answers undefined for a type that declares none', async () => {
    registerContentType({ type: 'no-cwd' })

    expect(await exposedCwdOf(leaf('a', 'no-cwd'))).toBeUndefined()
  })

  it('answers undefined for a type nobody registered', async () => {
    // The empty pane is the case that matters: it is the origin whenever a
    // creation button is pressed from a blank pane's toolbar, and it must
    // degrade rather than throw.
    expect(await exposedCwdOf(leaf('a', 'never-registered'))).toBeUndefined()
  })

  it('answers undefined when a type offers nothing for this particular leaf', async () => {
    registerContentType({ type: 'sometimes', exposeCwd: async () => undefined })

    expect(await exposedCwdOf(leaf('a', 'sometimes'))).toBeUndefined()
  })
})

describe('the two hooks together', () => {
  /**
   * The whole feature in one test, with no real content type involved: a type
   * that wants a directory asks for it through the *origin's* capability, and
   * gets one from a type it has never heard of.
   */
  it('lets a created type read a directory off an origin type it knows nothing about', async () => {
    registerContentType({ type: 'shell-ish', exposeCwd: async () => '/live/from/shell' })
    registerContentType({
      type: 'repo-ish',
      deriveConfig: async (origin) => {
        const cwd = await exposedCwdOf(origin)
        return cwd ? { cwd } : undefined
      }
    })

    const content = await createContentFor(action('repo-ish'), leaf('a', 'shell-ish'))

    expect(content).toMatchObject({ config: { cwd: '/live/from/shell' } })
  })

  it('degrades to the bare action when the origin exposes nothing', async () => {
    registerContentType({ type: 'inert' })
    registerContentType({
      type: 'repo-ish',
      deriveConfig: async (origin) => {
        const cwd = await exposedCwdOf(origin)
        return cwd ? { cwd } : undefined
      }
    })

    const content = await createContentFor(action('repo-ish'), leaf('a', 'inert'))

    // No cwd key at all, so whatever the renderer does for "no directory
    // configured" is what happens — not an empty string, not a broken pane.
    expect(content).toMatchObject({ type: 'repo-ish', config: {} })
  })
})

/** Type-level: the field exists on the def and has the shape the docs claim. */
it('declares exposeCwd on the renderer def', () => {
  const def: Pick<ContentRendererDef, 'exposeCwd'> = {
    exposeCwd: async (leafNode) => leafNode.config.cwd as string | undefined
  }
  expect(typeof def.exposeCwd).toBe('function')
})
