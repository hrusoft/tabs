import type { ContentNode, LeafContent } from '@shared/model/types'
import { EMPTY_TYPE } from '@shared/model/types'
import { beforeEach, describe, expect, it, vi } from 'vitest'
import type { ContentRendererDef } from '../../core/registry/registry'
import { useSettingsStore } from '../../core/store/settingsStore'
import {
  installTemporaryContentTypes,
  testLeaf as leaf
} from '../../testing/contentRegistryFixture'
import { createContentLike } from '../contentLike'

// `.tsx` despite holding no JSX, and that is load-bearing: the vitest
// `components` (jsdom) project is selected by extension, and createContentLike
// consults settingsStore, which reads `window.api.settings.getSync()` at
// module-eval time. In the node project this file would fail on import. Same
// reasoning as content/__tests__/externalControlVerbs.test.tsx.

const registerContentType = installTemporaryContentTypes()

/** This file's vocabulary — every case here is about a type's `deriveConfig` hook. */
function registerType(type: string, deriveConfig?: ContentRendererDef['deriveConfig']): void {
  registerContentType({ type, deriveConfig })
}

// Stated rather than inherited from DEFAULT_SETTINGS: the cases below are
// about which types are enabled, so each one says so.
beforeEach(() => {
  useSettingsStore.setState({ disabledContentTypes: [] })
})

describe('createContentLike', () => {
  it('copies the origin type and config into a fresh leaf, dropping the title', async () => {
    registerType('plain')
    const origin: LeafContent = {
      ...leaf('a', 'plain', { greeting: 'hi' }),
      title: 'custom',
      titleIsManual: true
    }

    const content = await createContentLike(origin)

    expect(content).toEqual({ id: expect.any(String), type: 'plain', config: { greeting: 'hi' } })
    expect(content.id).not.toBe('a')
  })

  it('plain-copies an unregistered origin type', async () => {
    const content = await createContentLike(leaf('a', 'never-registered', { k: 1 }))

    expect(content).toMatchObject({ type: 'never-registered', config: { k: 1 } })
  })

  it('hands the hook the resolved entry leaf of a container origin', async () => {
    const deriveConfig = vi.fn().mockResolvedValue(undefined)
    registerType('hooked', deriveConfig)
    const active = leaf('active-leaf', 'hooked')
    const origin: ContentNode = {
      id: 'g',
      type: 'tabs',
      activeTabId: 't2',
      tabs: [
        { id: 't1', title: 'other', content: leaf('other-leaf', 'hooked') },
        { id: 't2', title: 'active', content: active }
      ]
    }

    await createContentLike(origin)

    expect(deriveConfig).toHaveBeenCalledExactlyOnceWith(active)
  })

  it('merges a derived config over the copy, overriding colliding keys', async () => {
    registerType('hooked', async () => ({ cwd: '/live', extra: true }))

    const content = await createContentLike(leaf('a', 'hooked', { cwd: '/stale', kept: 1 }))

    expect(content).toMatchObject({ config: { cwd: '/live', kept: 1, extra: true } })
  })

  it('keeps the plain copy when the hook returns undefined', async () => {
    registerType('hooked', async () => undefined)

    const content = await createContentLike(leaf('a', 'hooked', { cwd: '/stale' }))

    expect(content).toMatchObject({ config: { cwd: '/stale' } })
  })

  it('rejects when the hook rejects', async () => {
    registerType('hooked', async () => {
      throw new Error('lookup failed')
    })

    await expect(createContentLike(leaf('a', 'hooked'))).rejects.toThrow('lookup failed')
  })

  it('falls back to an empty leaf for a tabs group with no tabs, without calling any hook', async () => {
    const deriveConfig = vi.fn().mockResolvedValue({ never: true })
    registerType('hooked', deriveConfig)
    const origin: ContentNode = { id: 'g', type: 'tabs', activeTabId: null, tabs: [] }

    const content = await createContentLike(origin)

    expect(content).toMatchObject({ type: EMPTY_TYPE, config: {} })
    expect(deriveConfig).not.toHaveBeenCalled()
  })

  // Without this, a single surviving pane of a disabled type would still spawn
  // new ones through New Tab / either split / New Unpinned Pane forever.
  it('yields an empty leaf when the origin type is disabled, without calling its hook', async () => {
    const deriveConfig = vi.fn().mockResolvedValue({ never: true })
    registerType('hooked', deriveConfig)
    useSettingsStore.setState({ disabledContentTypes: ['hooked'] })

    const content = await createContentLike(leaf('a', 'hooked', { cwd: '/live' }))

    expect(content).toMatchObject({ type: EMPTY_TYPE, config: {} })
    expect(deriveConfig).not.toHaveBeenCalled()
  })

  it('still copies a type that is enabled while a sibling type is disabled', async () => {
    registerType('plain')
    useSettingsStore.setState({ disabledContentTypes: ['some-other-type'] })

    const content = await createContentLike(leaf('a', 'plain', { greeting: 'hi' }))

    expect(content).toMatchObject({ type: 'plain', config: { greeting: 'hi' } })
  })

  // Disabling a structural type from a hand-edited settings.json must not
  // wedge anything: the fallback is unconditional, including when the origin
  // was already empty.
  it('still yields an empty leaf when the empty type itself is disabled', async () => {
    useSettingsStore.setState({ disabledContentTypes: [EMPTY_TYPE] })

    const content = await createContentLike(leaf('a', EMPTY_TYPE))

    expect(content).toMatchObject({ type: EMPTY_TYPE, config: {} })
  })
})
