import { createLeaf, createTabs } from '@shared/model/factories'
import type { LeafContent } from '@shared/model/types'
import { afterEach, describe, expect, it } from 'vitest'
import { contentRegistry } from '../registry'
import { paneTitleForContent } from '../titles'

const TYPE = 'test-leaf-type'

afterEach(() => {
  contentRegistry.unregister(TYPE)
  contentRegistry.unregister('tabs')
})

describe('paneTitleForContent', () => {
  it('prefers a stored title over the registered display name', () => {
    contentRegistry.register({ type: TYPE, displayName: 'Test Leaf', Component: () => null })
    const leaf: LeafContent = { ...createLeaf(TYPE), title: 'My custom title' }

    expect(paneTitleForContent(leaf)).toBe('My custom title')
  })

  it('falls back to the registered display name with no stored title', () => {
    contentRegistry.register({ type: TYPE, displayName: 'Test Leaf', Component: () => null })

    expect(paneTitleForContent(createLeaf(TYPE))).toBe('Test Leaf')
  })

  it('falls back to the raw type for an unregistered type', () => {
    expect(paneTitleForContent(createLeaf('totally-unregistered'))).toBe('totally-unregistered')
  })

  it("derives a tabs group's label from the registry, never a stored title", () => {
    contentRegistry.register({ type: 'tabs', displayName: 'Tabs', Component: () => null })

    expect(paneTitleForContent(createTabs([]))).toBe('Tabs')
  })
})
