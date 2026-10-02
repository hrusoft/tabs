import { describe, expect, it } from 'vitest'
import { createLeaf, createSplit, createTab, createTabs } from '../factories'
import { collectLeaves } from '../types'

describe('collectLeaves', () => {
  it('returns a single leaf as itself', () => {
    const leaf = createLeaf('terminal')
    expect(collectLeaves(leaf)).toEqual([leaf])
  })

  it('collects every leaf nested across a split and a tab group, depth-first', () => {
    const tabbed = createLeaf('terminal')
    const other = createLeaf('empty')
    const direct = createLeaf('terminal')
    const root = createSplit('horizontal', [
      createTabs([createTab('Tab', tabbed), createTab('Other', other)]),
      direct
    ])

    expect(collectLeaves(root)).toEqual([tabbed, other, direct])
  })
})
