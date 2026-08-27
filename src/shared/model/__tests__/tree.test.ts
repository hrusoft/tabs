import { describe, expect, it } from 'vitest'
import { createLeaf, createSplit, createTab, createTabs } from '../factories'
import {
  addTab,
  canDockPane,
  canDockTab,
  canMovePaneToTabs,
  canMoveTabToTabs,
  closePane,
  closeTab,
  collectLeaves,
  dockPane,
  dockTab,
  findNode,
  findTab,
  firstPaneId,
  MIN_PANE_SIZE,
  mapLeaves,
  movePaneToTabs,
  moveTab,
  normalize,
  openContent,
  removeNode,
  renamePane,
  renameTab,
  replaceContent,
  resizeSplit,
  setLeafConfig,
  setLiveTitle,
  splitContent,
  ungroupTabs,
  withPaneDetached,
  wrapInTabs
} from '../tree'
import type { ContentNode, LeafContent, SplitContent, TabsContent } from '../types'
import { isSplit, isTabs } from '../types'

function welcomeTab(title = 'Welcome'): ReturnType<typeof createTab> {
  return createTab(title, createLeaf('welcome'))
}

/** Stands in for the real registry-backed titler, which the model never sees. */
const titleOf = (node: ContentNode): string => node.type

describe('mapLeaves', () => {
  it('replaces matching leaves and leaves the rest by reference', () => {
    const target = createLeaf('terminal', { cwd: '~' })
    const other = createLeaf('terminal', { cwd: '~' })
    const root = createSplit('horizontal', [target, other])

    const result = mapLeaves(root, (leaf) =>
      leaf.id === target.id ? { ...leaf, config: { cwd: '/tmp/x' } } : leaf
    ) as SplitContent

    expect((result.children[0] as LeafContent).config.cwd).toBe('/tmp/x')
    expect(result.children[1]).toBe(other)
  })

  it('returns the same root reference when fn changes nothing', () => {
    const root = createSplit('horizontal', [createLeaf('terminal'), createLeaf('empty')])
    const result = mapLeaves(root, (leaf) => leaf)
    expect(result).toBe(root)
  })

  it('updates a leaf nested inside a tab group', () => {
    const tab = createTab('Tab', createLeaf('terminal', { cwd: '~' }))
    const root = createTabs([tab])

    const result = mapLeaves(root, (leaf) => ({
      ...leaf,
      config: { cwd: '/tmp/y' }
    })) as TabsContent

    expect(result.tabs[0]!.content).not.toBe(tab.content)
    expect((result.tabs[0]!.content as LeafContent).config.cwd).toBe('/tmp/y')
  })
})

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

describe('addTab', () => {
  it('appends to the target group and activates the new tab', () => {
    const first = welcomeTab('First')
    const root = createTabs([first])
    const added = welcomeTab('Second')

    const next = addTab(root, root.id, added) as TabsContent

    expect(next.tabs.map((t) => t.title)).toEqual(['First', 'Second'])
    expect(next.activeTabId).toBe(added.id)
  })

  it('inserts at an explicit index', () => {
    const root = createTabs([welcomeTab('A'), welcomeTab('C')])

    const next = addTab(root, root.id, welcomeTab('B'), 1) as TabsContent

    expect(next.tabs.map((t) => t.title)).toEqual(['A', 'B', 'C'])
  })
})

describe('closeTab', () => {
  it('activates the next tab when closing the active tab', () => {
    const [a, b, c] = [welcomeTab('A'), welcomeTab('B'), welcomeTab('C')]
    const root = createTabs([a, b, c], { activeTabId: b.id })

    const next = closeTab(root, b.id) as TabsContent

    // Three tabs closed down to two: still a group, not a collapse.
    expect(isTabs(next)).toBe(true)
    expect(next.tabs.map((t) => t.title)).toEqual(['A', 'C'])
    expect(next.activeTabId).toBe(c.id)
  })

  it('activates the previous tab when closing the last active tab', () => {
    const [a, b, c] = [welcomeTab('A'), welcomeTab('B'), welcomeTab('C')]
    const root = createTabs([a, b, c], { activeTabId: c.id })

    const next = closeTab(root, c.id) as TabsContent

    expect(next.tabs.map((t) => t.title)).toEqual(['A', 'B'])
    expect(next.activeTabId).toBe(b.id)
  })

  it('leaves activation alone when closing an inactive tab', () => {
    const [a, b, c] = [welcomeTab('A'), welcomeTab('B'), welcomeTab('C')]
    const root = createTabs([a, b, c], { activeTabId: a.id })

    const next = closeTab(root, c.id) as TabsContent

    expect(next.tabs.map((t) => t.title)).toEqual(['A', 'B'])
    expect(next.activeTabId).toBe(a.id)
  })

  it('turns the root into an empty pane after closing its only tab', () => {
    const only = welcomeTab('Only')
    const root = createTabs([only])

    const next = closeTab(root, only.id) as LeafContent

    expect(next.type).toBe('empty')
  })

  it("collapses a two-tab group to the surviving tab's own content, preserving its identity", () => {
    const [a, b] = [welcomeTab('A'), welcomeTab('B')]
    const root = createTabs([a, b], { activeTabId: b.id })

    const next = closeTab(root, b.id)

    // The mirror of openContent's promotion: the group's slot is replaced by
    // the survivor's content by reference, not a clone — anything keyed by
    // its id (a live pty) survives the collapse.
    expect(isTabs(next)).toBe(false)
    expect(next).toBe(a.content)
  })

  it('empties a pane in place instead of collapsing its split', () => {
    const leftTab = welcomeTab('Left')
    const left = createTabs([leftTab])
    const right = createTabs([welcomeTab('Right')])
    const split = createSplit('horizontal', [left, right])
    const rootTab = createTab('Root', split)
    const root = createTabs([rootTab])

    const next = closeTab(root, leftTab.id) as TabsContent
    const nextSplit = next.tabs[0]!.content as SplitContent

    // The left pane becomes an empty leaf in its same slot; the split
    // itself, and the untouched right pane, are unaffected.
    expect(nextSplit.children).toHaveLength(2)
    expect(nextSplit.children[0]!.type).toBe('empty')
    expect(nextSplit.children[1]).toBe(right)
  })

  it('collapses a two-tab group inside a split, leaving the split and its sibling untouched', () => {
    const [leftA, leftB] = [welcomeTab('Left A'), welcomeTab('Left B')]
    const left = createTabs([leftA, leftB])
    const right = createTabs([welcomeTab('Right')])
    const split = createSplit('horizontal', [left, right])
    const rootTab = createTab('Root', split)
    const root = createTabs([rootTab])

    const next = closeTab(root, leftB.id) as TabsContent
    const nextSplit = next.tabs[0]!.content as SplitContent

    expect(nextSplit.children).toHaveLength(2)
    expect(nextSplit.children[0]).toBe(leftA.content)
    expect(nextSplit.children[1]).toBe(right)
  })

  it('empties a nested tab group without dropping the tab that contains it', () => {
    const innerTab = welcomeTab('Inner')
    const inner = createTabs([innerTab])
    const outerTab = createTab('Outer', inner)
    const root = createTabs([outerTab])

    const next = closeTab(root, innerTab.id) as TabsContent

    expect(next.tabs.map((t) => t.title)).toEqual(['Outer'])
    expect(next.tabs[0]!.content.type).toBe('empty')
  })

  it('collapses a nested tab group without dropping the outer tab that contains it', () => {
    const [innerA, innerB] = [welcomeTab('Inner A'), welcomeTab('Inner B')]
    const inner = createTabs([innerA, innerB])
    const outerTab = createTab('Outer', inner)
    const root = createTabs([outerTab])

    const next = closeTab(root, innerB.id) as TabsContent

    expect(next.tabs.map((t) => t.title)).toEqual(['Outer'])
    expect(next.tabs[0]!.content).toBe(innerA.content)
  })
})

describe('renameTab', () => {
  it('renames the tab in place, leaving its content untouched', () => {
    const tab = welcomeTab('Old')
    const root = createTabs([tab])

    const next = renameTab(root, tab.id, 'New') as TabsContent

    expect(next.tabs[0]!.title).toBe('New')
    expect(next.tabs[0]!.content).toBe(tab.content)
  })

  it('is a no-op for an unknown tab id', () => {
    const root = createTabs([welcomeTab('A')])

    expect(renameTab(root, 'missing', 'New')).toBe(root)
  })

  it('is a no-op when the title is unchanged', () => {
    const root = createTabs([welcomeTab('Same')])

    expect(renameTab(root, root.tabs[0]!.id, 'Same')).toBe(root)
  })
})

describe('renamePane', () => {
  it('sets a title override on a leaf, read back via the leaf itself', () => {
    const leaf = createLeaf('terminal')
    const root = createSplit('horizontal', [leaf, createLeaf('welcome')])

    const next = renamePane(root, leaf.id, 'My terminal') as SplitContent

    expect((next.children[0] as LeafContent).title).toBe('My terminal')
  })

  it('clears an override back to undefined', () => {
    const titled: LeafContent = { ...createLeaf('terminal'), title: 'Custom' }

    const next = renamePane(titled, titled.id, undefined) as LeafContent

    expect(next.title).toBeUndefined()
  })

  it('is a no-op for an unknown id', () => {
    const root = createLeaf('terminal')

    expect(renamePane(root, 'missing', 'New')).toBe(root)
  })

  it('is a no-op on a tabs group (no header title of its own)', () => {
    const root = createTabs([welcomeTab('A')])

    expect(renamePane(root, root.id, 'New')).toBe(root)
  })

  it('is a no-op on a split (never rendered with a header)', () => {
    const root = createSplit('horizontal', [createLeaf('terminal'), createLeaf('welcome')])

    expect(renamePane(root, root.id, 'New')).toBe(root)
  })

  it('is a no-op when the title is unchanged', () => {
    const leaf: LeafContent = { ...createLeaf('terminal'), title: 'Same', titleIsManual: true }

    expect(renamePane(leaf, leaf.id, 'Same')).toBe(leaf)
  })

  it('marks the pane titleIsManual when setting a title', () => {
    const leaf = createLeaf('terminal')

    const next = renamePane(leaf, leaf.id, 'My terminal') as LeafContent

    expect(next.titleIsManual).toBe(true)
  })

  it('un-marks titleIsManual when clearing the title', () => {
    const leaf: LeafContent = { ...createLeaf('terminal'), title: 'Custom', titleIsManual: true }

    const next = renamePane(leaf, leaf.id, undefined) as LeafContent

    expect(next.titleIsManual).toBe(false)
  })
})

describe('setLiveTitle', () => {
  it('sets a title on a leaf with no existing title', () => {
    const leaf = createLeaf('terminal')

    const next = setLiveTitle(leaf, leaf.id, 'vim ~/notes.md') as LeafContent

    expect(next.title).toBe('vim ~/notes.md')
    expect(next.titleIsManual).toBeFalsy()
  })

  it('updates an existing auto title', () => {
    const leaf: LeafContent = { ...createLeaf('terminal'), title: 'old title' }

    const next = setLiveTitle(leaf, leaf.id, 'new title') as LeafContent

    expect(next.title).toBe('new title')
  })

  it('is a no-op when the pane title was set manually', () => {
    const leaf: LeafContent = { ...createLeaf('terminal'), title: 'Custom', titleIsManual: true }

    expect(setLiveTitle(leaf, leaf.id, 'from the process')).toBe(leaf)
  })

  it('is a no-op when the title is unchanged', () => {
    const leaf: LeafContent = { ...createLeaf('terminal'), title: 'Same' }

    expect(setLiveTitle(leaf, leaf.id, 'Same')).toBe(leaf)
  })

  it('treats an empty title the same as clearing it back to undefined', () => {
    const leaf: LeafContent = { ...createLeaf('terminal'), title: 'Custom' }

    const next = setLiveTitle(leaf, leaf.id, '') as LeafContent

    expect(next.title).toBeUndefined()
  })

  it('is a no-op for an unknown id', () => {
    const root = createLeaf('terminal')

    expect(setLiveTitle(root, 'missing', 'New')).toBe(root)
  })

  it('is a no-op on a tabs group (no header title of its own)', () => {
    const root = createTabs([welcomeTab('A')])

    expect(setLiveTitle(root, root.id, 'New')).toBe(root)
  })

  it('is a no-op on a split (never rendered with a header)', () => {
    const root = createSplit('horizontal', [createLeaf('terminal'), createLeaf('welcome')])

    expect(setLiveTitle(root, root.id, 'New')).toBe(root)
  })
})

describe('setLeafConfig', () => {
  it('merges new keys into an existing config', () => {
    const leaf = createLeaf('browser', { url: 'about:blank' })

    const next = setLeafConfig(leaf, leaf.id, { url: 'https://example.com' }) as LeafContent

    expect(next.config).toEqual({ url: 'https://example.com' })
  })

  it('preserves existing config keys not present in the merge', () => {
    const leaf = createLeaf('browser', { url: 'about:blank', zoom: 1 })

    const next = setLeafConfig(leaf, leaf.id, { url: 'https://example.com' }) as LeafContent

    expect(next.config).toEqual({ url: 'https://example.com', zoom: 1 })
  })

  it('is a no-op when every key already matches', () => {
    const leaf = createLeaf('browser', { url: 'https://example.com' })

    expect(setLeafConfig(leaf, leaf.id, { url: 'https://example.com' })).toBe(leaf)
  })

  it('is a no-op for an unknown id', () => {
    const root = createLeaf('browser', { url: 'about:blank' })

    expect(setLeafConfig(root, 'missing', { url: 'https://example.com' })).toBe(root)
  })

  it('is a no-op on a tabs group (no config of its own)', () => {
    const root = createTabs([welcomeTab('A')])

    expect(setLeafConfig(root, root.id, { url: 'https://example.com' })).toBe(root)
  })

  it('is a no-op on a split (never rendered with a header)', () => {
    const root = createSplit('horizontal', [createLeaf('terminal'), createLeaf('welcome')])

    expect(setLeafConfig(root, root.id, { url: 'https://example.com' })).toBe(root)
  })
})

describe('splitContent', () => {
  it('replaces a leaf with a 50/50 split of [old, new]', () => {
    const leaf = createLeaf('welcome')
    const tab = createTab('Tab', leaf)
    const root = createTabs([tab])
    const pane = createTabs([welcomeTab()])

    const next = splitContent(root, leaf.id, 'horizontal', pane) as TabsContent
    const split = next.tabs[0]!.content as SplitContent

    expect(isSplit(split)).toBe(true)
    expect(split.direction).toBe('horizontal')
    expect(split.children.map((c) => c.id)).toEqual([leaf.id, pane.id])
    expect(split.sizes).toEqual([0.5, 0.5])
  })

  it('splices into a same-direction split instead of nesting', () => {
    const [a, b] = [createLeaf('welcome'), createLeaf('welcome')]
    const split = createSplit('horizontal', [a, b], { sizes: [0.6, 0.4] })
    const tab = createTab('Tab', split)
    const root = createTabs([tab])
    const added = createLeaf('welcome')

    const next = splitContent(root, a.id, 'horizontal', added) as TabsContent
    const result = next.tabs[0]!.content as SplitContent

    expect(result.children.map((c) => c.id)).toEqual([a.id, added.id, b.id])
    expect(result.sizes[0]).toBeCloseTo(0.3)
    expect(result.sizes[1]).toBeCloseTo(0.3)
    expect(result.sizes[2]).toBeCloseTo(0.4)
    // No nested same-direction split survived.
    expect(result.children.some((c) => isSplit(c) && c.direction === 'horizontal')).toBe(false)
  })

  it('splits the root node itself', () => {
    const root = createTabs([welcomeTab()])
    const pane = createTabs([welcomeTab()])

    const next = splitContent(root, root.id, 'vertical', pane)

    expect(isSplit(next)).toBe(true)
    expect((next as SplitContent).children.map((c) => c.id)).toEqual([root.id, pane.id])
  })
})

describe('resizeSplit', () => {
  it('renormalizes sizes to sum to 1', () => {
    const split = createSplit('horizontal', [createLeaf('welcome'), createLeaf('welcome')])

    const next = resizeSplit(split, split.id, [2, 6]) as SplitContent

    expect(next.sizes[0]).toBeCloseTo(0.25)
    expect(next.sizes[1]).toBeCloseTo(0.75)
  })

  it('clamps below-minimum sizes', () => {
    const split = createSplit('horizontal', [createLeaf('welcome'), createLeaf('welcome')])

    const next = resizeSplit(split, split.id, [0.01, 0.99]) as SplitContent

    expect(next.sizes[0]).toBeCloseTo(MIN_PANE_SIZE)
    expect(next.sizes[0]! + next.sizes[1]!).toBeCloseTo(1)
  })

  it('ignores a sizes array of the wrong length', () => {
    const split = createSplit('horizontal', [createLeaf('welcome'), createLeaf('welcome')])

    const next = resizeSplit(split, split.id, [1])

    expect(next).toBe(split)
  })
})

describe('moveTab', () => {
  it("moves a tab across groups, collapsing the two-tab source to its survivor's content", () => {
    const moved = welcomeTab('Moved')
    const stays = welcomeTab('Stays')
    const source = createTabs([moved, stays], { activeTabId: moved.id })
    const targetTab = welcomeTab('Existing')
    const target = createTabs([targetTab])
    const split = createSplit('horizontal', [source, target])
    const rootTab = createTab('Root', split)
    const root = createTabs([rootTab])

    const next = moveTab(root, moved.id, target.id) as TabsContent
    const nextSplit = next.tabs[0]!.content as SplitContent
    const [nextSource, nextTarget] = nextSplit.children

    // The source group had only two tabs; losing one collapses it to the
    // survivor's own content, unwrapped in place, same object as before —
    // the mirror of openContent's promotion.
    expect(isTabs(nextSource!)).toBe(false)
    expect(nextSource).toBe(stays.content)

    const targetGroup = nextTarget as TabsContent
    expect(targetGroup.tabs.map((t) => t.title)).toEqual(['Existing', 'Moved'])
    expect(targetGroup.activeTabId).toBe(moved.id)
    // The tab object itself is preserved, not cloned.
    expect(targetGroup.tabs[1]).toBe(moved)
  })

  it('moves a tab out of a three-tab source, which stays a group and repairs activation', () => {
    const moved = welcomeTab('Moved')
    const stays = welcomeTab('Stays')
    const other = welcomeTab('Other')
    const source = createTabs([moved, stays, other], { activeTabId: moved.id })
    const target = createTabs([welcomeTab('Existing')])
    const split = createSplit('horizontal', [source, target])
    const rootTab = createTab('Root', split)
    const root = createTabs([rootTab])

    const next = moveTab(root, moved.id, target.id) as TabsContent
    const nextSplit = next.tabs[0]!.content as SplitContent
    const nextSource = nextSplit.children[0] as TabsContent

    expect(isTabs(nextSource)).toBe(true)
    expect(nextSource.tabs.map((t) => t.title)).toEqual(['Stays', 'Other'])
    expect(nextSource.activeTabId).toBe(stays.id)
  })

  it('empties the source pane in place instead of collapsing its split', () => {
    const only = welcomeTab('Only')
    const source = createTabs([only])
    const target = createTabs([welcomeTab('Existing')])
    const split = createSplit('horizontal', [source, target])
    const rootTab = createTab('Root', split)
    const root = createTabs([rootTab])

    const next = moveTab(root, only.id, target.id) as TabsContent
    const nextSplit = next.tabs[0]!.content as SplitContent
    const nextTarget = nextSplit.children[1] as TabsContent

    expect(nextSplit.children).toHaveLength(2)
    expect(nextSplit.children[0]!.type).toBe('empty')
    expect(nextTarget.tabs.map((t) => t.title)).toEqual(['Existing', 'Only'])
  })

  it('refuses to move a tab into a group nested inside itself', () => {
    const inner = createTabs([welcomeTab('Inner')])
    const outerTab = createTab('Outer', inner)
    const root = createTabs([outerTab, welcomeTab('Other')])

    const next = moveTab(root, outerTab.id, inner.id)

    expect(next).toBe(root)
  })

  it('reorders tabs within the same group by index', () => {
    const [a, b, c] = [welcomeTab('A'), welcomeTab('B'), welcomeTab('C')]
    const root = createTabs([a, b, c])

    const next = moveTab(root, a.id, root.id, 2) as TabsContent

    expect(next.tabs.map((t) => t.title)).toEqual(['B', 'C', 'A'])
    expect(next.activeTabId).toBe(a.id)
  })

  it('drops a tab onto an empty pane, converting it into a tabs group of just that tab', () => {
    const moved = welcomeTab('Moved')
    const stays = welcomeTab('Stays')
    const source = createTabs([moved, stays], { activeTabId: moved.id })
    const empty = createLeaf('empty')
    const split = createSplit('horizontal', [source, empty])
    const rootTab = createTab('Root', split)
    const root = createTabs([rootTab])

    const next = moveTab(root, moved.id, empty.id) as TabsContent
    const nextSplit = next.tabs[0]!.content as SplitContent
    const [nextSource, nextTarget] = nextSplit.children

    // The two-tab source collapses to its survivor's own content.
    expect(isTabs(nextSource!)).toBe(false)
    expect(nextSource).toBe(stays.content)

    const targetGroup = nextTarget as TabsContent
    expect(targetGroup.type).toBe('tabs')
    // The empty pane's own id is preserved: it's the same pane, now full.
    expect(targetGroup.id).toBe(empty.id)
    expect(targetGroup.tabs.map((t) => t.title)).toEqual(['Moved'])
    expect(targetGroup.activeTabId).toBe(moved.id)
  })

  it('collapses the source tab bar to empty when its last tab is dropped on an empty pane', () => {
    const only = welcomeTab('Only')
    const source = createTabs([only])
    const empty = createLeaf('empty')
    const split = createSplit('horizontal', [source, empty])
    const rootTab = createTab('Root', split)
    const root = createTabs([rootTab])

    const next = moveTab(root, only.id, empty.id) as TabsContent
    const nextSplit = next.tabs[0]!.content as SplitContent

    expect(nextSplit.children[0]!.type).toBe('empty')
    expect((nextSplit.children[1] as TabsContent).tabs.map((t) => t.title)).toEqual(['Only'])
  })

  it('is a no-op when the target is neither a tabs group nor an empty pane', () => {
    const moved = welcomeTab('Moved')
    const source = createTabs([moved])
    const other = createLeaf('welcome')
    const split = createSplit('horizontal', [source, other])
    const rootTab = createTab('Root', split)
    const root = createTabs([rootTab])

    expect(moveTab(root, moved.id, other.id)).toBe(root)
  })
})

describe('dockTab', () => {
  it('splices a right-docked tab into a same-direction split as a new single-tab group', () => {
    const moved = welcomeTab('Moved')
    const stays = welcomeTab('Stays')
    const source = createTabs([moved, stays], { activeTabId: moved.id })
    const target = createTabs([welcomeTab('Existing')])
    const root = createSplit('horizontal', [source, target])

    const next = dockTab(root, moved.id, target.id, 'right', titleOf) as SplitContent

    // Same-direction split: spliced beside the target, taking half its share.
    expect(next.direction).toBe('horizontal')
    expect(next.children).toHaveLength(3)
    expect(next.children[0]).toBe(stays.content)
    expect(next.children[1]).toBe(target)
    expect(next.sizes[0]).toBeCloseTo(0.5)
    expect(next.sizes[1]).toBeCloseTo(0.25)
    expect(next.sizes[2]).toBeCloseTo(0.25)

    // The new pane is a single-tab group holding the tab object itself.
    const landed = next.children[2] as TabsContent
    expect(isTabs(landed)).toBe(true)
    expect(landed.tabs).toHaveLength(1)
    expect(landed.tabs[0]).toBe(moved)
    expect(landed.activeTabId).toBe(moved.id)
  })

  it('left-docks before the target, wrapping a cross-direction pane in a nested split', () => {
    const moved = welcomeTab('Moved')
    const stays = welcomeTab('Stays')
    const source = createTabs([moved, stays])
    const target = createTabs([welcomeTab('Existing')])
    const root = createSplit('vertical', [source, target])

    const next = dockTab(root, moved.id, target.id, 'left', titleOf) as SplitContent
    const nested = next.children[1] as SplitContent

    // The collapsed source keeps its slot; the target's slot becomes a
    // horizontal 50/50 split with the new group before it.
    expect(next.direction).toBe('vertical')
    expect(next.children[0]).toBe(stays.content)
    expect(isSplit(nested)).toBe(true)
    expect(nested.direction).toBe('horizontal')
    expect(nested.sizes).toEqual([0.5, 0.5])
    expect((nested.children[0] as TabsContent).tabs[0]).toBe(moved)
    expect(nested.children[1]).toBe(target)
  })

  it('maps top and bottom zones to a vertical split before/after the target', () => {
    const target = createTabs([welcomeTab('Existing')])
    const buildRoot = (): { moved: ReturnType<typeof createTab>; root: SplitContent } => {
      const moved = welcomeTab('Moved')
      const source = createTabs([moved, welcomeTab('Stays')])
      return { moved, root: createSplit('horizontal', [source, target]) }
    }

    const top = buildRoot()
    const afterTop = dockTab(top.root, top.moved.id, target.id, 'top', titleOf) as SplitContent
    const topNested = afterTop.children[1] as SplitContent
    expect(topNested.direction).toBe('vertical')
    expect((topNested.children[0] as TabsContent).tabs[0]).toBe(top.moved)
    expect(topNested.children[1]).toBe(target)

    const bottom = buildRoot()
    const afterBottom = dockTab(
      bottom.root,
      bottom.moved.id,
      target.id,
      'bottom',
      titleOf
    ) as SplitContent
    const bottomNested = afterBottom.children[1] as SplitContent
    expect(bottomNested.direction).toBe('vertical')
    expect(bottomNested.children[0]).toBe(target)
    expect((bottomNested.children[1] as TabsContent).tabs[0]).toBe(bottom.moved)
  })

  it("edge-docks a tab against its own two-tab group, splitting off the survivor's content", () => {
    const moved = welcomeTab('Moved')
    const stays = welcomeTab('Stays')
    const root = createTabs([moved, stays])

    const next = dockTab(root, moved.id, root.id, 'right', titleOf) as SplitContent

    // Removing the tab collapses the group to the survivor's content — a
    // different node id — and the split forms against that survivor.
    expect(isSplit(next)).toBe(true)
    expect(next.direction).toBe('horizontal')
    expect(next.children[0]).toBe(stays.content)
    expect((next.children[1] as TabsContent).tabs[0]).toBe(moved)
  })

  it('center-docks onto another group, appending the tab and collapsing the source', () => {
    const moved = welcomeTab('Moved')
    const stays = welcomeTab('Stays')
    const source = createTabs([moved, stays], { activeTabId: moved.id })
    const target = createTabs([welcomeTab('Existing')])
    const root = createSplit('horizontal', [source, target])

    const next = dockTab(root, moved.id, target.id, 'center', titleOf) as SplitContent
    const targetGroup = next.children[1] as TabsContent

    expect(next.children[0]).toBe(stays.content)
    expect(targetGroup.tabs.map((t) => t.title)).toEqual(['Existing', 'Moved'])
    expect(targetGroup.tabs[1]).toBe(moved)
    expect(targetGroup.activeTabId).toBe(moved.id)
  })

  it('center-docks onto an empty pane, converting it in place like a drop', () => {
    const moved = welcomeTab('Moved')
    const source = createTabs([moved, welcomeTab('Stays')])
    const empty = createLeaf('empty')
    const root = createSplit('horizontal', [source, empty])

    const next = dockTab(root, moved.id, empty.id, 'center', titleOf) as SplitContent
    const landed = next.children[1] as TabsContent

    // The empty pane's own id is preserved: it's the same pane, now full.
    expect(landed.id).toBe(empty.id)
    expect(landed.tabs).toHaveLength(1)
    expect(landed.tabs[0]).toBe(moved)
  })

  it('center-docks onto a bare leaf, promoting it into a two-tab group by reference', () => {
    const moved = welcomeTab('Moved')
    const source = createTabs([moved, welcomeTab('Stays')])
    const terminal = createLeaf('terminal')
    const root = createSplit('horizontal', [source, terminal])

    const next = dockTab(root, moved.id, terminal.id, 'center', titleOf) as SplitContent
    const landed = next.children[1] as TabsContent

    expect(isTabs(landed)).toBe(true)
    expect(landed.tabs).toHaveLength(2)
    // Identity is the contract: a live pty is registered against this node's id.
    expect(landed.tabs[0]!.content).toBe(terminal)
    expect(landed.tabs[0]!.title).toBe('terminal')
    expect(landed.tabs[1]).toBe(moved)
    expect(landed.activeTabId).toBe(moved.id)
  })

  it('is a no-op for every zone canDockTab declines', () => {
    const only = welcomeTab('Only')
    const soloGroup = createTabs([only])
    expect(dockTab(soloGroup, only.id, soloGroup.id, 'right', titleOf)).toBe(soloGroup)

    const [a, b] = [welcomeTab('A'), welcomeTab('B')]
    const group = createTabs([a, b])
    expect(dockTab(group, a.id, group.id, 'center', titleOf)).toBe(group)

    // A target nested inside the dragged tab's own content.
    const innerLeaf = createLeaf('welcome')
    const innerSplit = createSplit('horizontal', [innerLeaf, createLeaf('welcome')])
    const outerTab = createTab('Outer', innerSplit)
    const root = createTabs([outerTab, welcomeTab('Other')])
    expect(dockTab(root, outerTab.id, innerLeaf.id, 'right', titleOf)).toBe(root)
    expect(dockTab(root, outerTab.id, innerLeaf.id, 'center', titleOf)).toBe(root)

    // Unknown ids and split targets.
    expect(dockTab(root, 'missing', root.id, 'left', titleOf)).toBe(root)
    expect(dockTab(root, outerTab.id, 'missing', 'left', titleOf)).toBe(root)
    expect(dockTab(root, root.tabs[1]!.id, innerSplit.id, 'left', titleOf)).toBe(root)
  })
})

describe('canDockTab', () => {
  it('accepts zones that would change the layout', () => {
    const moved = welcomeTab('Moved')
    const stays = welcomeTab('Stays')
    const source = createTabs([moved, stays])
    const terminal = createLeaf('terminal')
    const root = createSplit('horizontal', [source, terminal])

    expect(canDockTab(root, moved.id, terminal.id, 'left')).toBe(true)
    expect(canDockTab(root, moved.id, terminal.id, 'center')).toBe(true)
    // Edge-docking against the tab's own group works while other tabs remain.
    expect(canDockTab(root, moved.id, source.id, 'bottom')).toBe(true)
  })

  it('declines self, cyclic, and unresolvable targets', () => {
    const inner = createLeaf('welcome')
    const draggedTab = createTab(
      'Dragged',
      createSplit('horizontal', [inner, createLeaf('welcome')])
    )
    const root = createTabs([draggedTab])

    // Center on the tab's own group, and edges when it's the only tab.
    expect(canDockTab(root, draggedTab.id, root.id, 'center')).toBe(false)
    expect(canDockTab(root, draggedTab.id, root.id, 'left')).toBe(false)
    // Anywhere inside the dragged tab's own content, including the content itself.
    expect(canDockTab(root, draggedTab.id, inner.id, 'right')).toBe(false)
    expect(canDockTab(root, draggedTab.id, draggedTab.content.id, 'center')).toBe(false)
    // Unknown ids.
    expect(canDockTab(root, 'missing', root.id, 'left')).toBe(false)
    expect(canDockTab(root, draggedTab.id, 'missing', 'left')).toBe(false)
  })
})

describe('closePane', () => {
  it('removes a split child, collapsing the split to the sibling by reference', () => {
    const left = createLeaf('terminal')
    const right = createLeaf('welcome')
    const root = createSplit('horizontal', [left, right])

    expect(closePane(root, left.id)).toBe(right)
  })

  it('closes a tab-content pane through its tab, collapsing a two-tab group to the survivor', () => {
    const closed = welcomeTab('Closed')
    const stays = welcomeTab('Stays')
    const root = createTabs([closed, stays])

    // Routed through closeTab: the lone survivor unwraps in place, where a
    // bare removeNode would leave a single-tab group standing.
    expect(closePane(root, closed.content.id)).toBe(stays.content)
  })

  it('activates the right neighbor when closing a tab-content pane in a larger group', () => {
    const [a, b, c] = [welcomeTab('A'), welcomeTab('B'), welcomeTab('C')]
    const root = createTabs([a, b, c], { activeTabId: b.id })

    const next = closePane(root, b.content.id) as TabsContent

    expect(next.tabs).toEqual([a, c])
    expect(next.activeTabId).toBe(c.id)
  })

  it('resets the root to a fresh empty pane', () => {
    const root = createLeaf('terminal')

    const next = closePane(root, root.id) as LeafContent

    expect(next.type).toBe('empty')
    expect(next.id).not.toBe(root.id)
  })

  it("returns a closed last child's freed space to its left neighbor in a 3-child split", () => {
    const [p1, a, b] = [createLeaf('terminal'), createLeaf('welcome'), createLeaf('browser')]
    const root = createSplit('horizontal', [p1, a, b], { sizes: [0.5, 0.25, 0.25] })

    const next = closePane(root, b.id) as SplitContent

    expect(next.children.map((c) => c.id)).toEqual([p1.id, a.id])
    expect(next.sizes[0]).toBeCloseTo(0.5)
    expect(next.sizes[1]).toBeCloseTo(0.5)
  })

  it("returns a closed first child's freed space to its right neighbor", () => {
    const [a, b, c] = [createLeaf('terminal'), createLeaf('welcome'), createLeaf('browser')]
    const root = createSplit('horizontal', [a, b, c], { sizes: [0.3, 0.1, 0.6] })

    const next = closePane(root, a.id) as SplitContent

    expect(next.children.map((child) => child.id)).toEqual([b.id, c.id])
    expect(next.sizes[0]).toBeCloseTo(0.4)
    expect(next.sizes[1]).toBeCloseTo(0.6)
  })

  it("splits a closed middle child's freed space evenly between both neighbors in a 4-child split", () => {
    const [a, b, c, d] = [
      createLeaf('terminal'),
      createLeaf('welcome'),
      createLeaf('browser'),
      createLeaf('terminal')
    ]
    const root = createSplit('horizontal', [a, b, c, d], { sizes: [0.1, 0.2, 0.3, 0.4] })

    const next = closePane(root, c.id) as SplitContent

    expect(next.children.map((n) => n.id)).toEqual([a.id, b.id, d.id])
    expect(next.sizes[0]).toBeCloseTo(0.1)
    expect(next.sizes[1]).toBeCloseTo(0.35)
    expect(next.sizes[2]).toBeCloseTo(0.55)
  })

  it("restores the original pane's exact pre-split size on a split-then-close round trip, with existing siblings", () => {
    const [p1, p2, a] = [createLeaf('terminal'), createLeaf('welcome'), createLeaf('browser')]
    const root = createSplit('horizontal', [p1, p2, a], { sizes: [0.3, 0.3, 0.4] })

    const split = splitContent(root, a.id, 'horizontal', createLeaf('welcome')) as SplitContent
    const newPane = split.children[split.children.length - 1]!

    const restored = closePane(split, newPane.id) as SplitContent

    expect(restored.children.map((n) => n.id)).toEqual([p1.id, p2.id, a.id])
    expect(restored.sizes[0]).toBeCloseTo(0.3)
    expect(restored.sizes[1]).toBeCloseTo(0.3)
    expect(restored.sizes[2]).toBeCloseTo(0.4)
  })
})

describe('wrapInTabs', () => {
  it('wraps a split child into a single-tab group by reference, titled by titleOf', () => {
    const terminal = createLeaf('terminal')
    const other = createLeaf('welcome')
    const root = createSplit('horizontal', [terminal, other])

    const next = wrapInTabs(root, terminal.id, titleOf) as SplitContent
    const group = next.children[0] as TabsContent

    expect(isTabs(group)).toBe(true)
    expect(group.tabs).toHaveLength(1)
    expect(group.tabs[0]!.content).toBe(terminal)
    expect(group.tabs[0]!.title).toBe('terminal')
    expect(group.activeTabId).toBe(group.tabs[0]!.id)
    expect(next.children[1]).toBe(other)
  })

  it('wraps the root, and the single-tab group survives normalize', () => {
    const root = createLeaf('terminal')

    const wrapped = wrapInTabs(root, root.id, titleOf) as TabsContent

    expect(isTabs(wrapped)).toBe(true)
    expect(wrapped.tabs[0]!.content).toBe(root)
    // Only removal paths collapse a lone tab; a deliberate wrap persists.
    expect(normalize(wrapped)).toBe(wrapped)
  })

  it("wraps a tab's content into a nested group without disturbing the outer tab", () => {
    const inner = createLeaf('terminal')
    const outerTab = createTab('Outer', inner)
    const other = welcomeTab('Other')
    const root = createTabs([outerTab, other])

    const next = wrapInTabs(root, inner.id, titleOf) as TabsContent
    const nested = next.tabs[0]!.content as TabsContent

    expect(next.tabs[0]!.id).toBe(outerTab.id)
    expect(next.tabs[0]!.title).toBe('Outer')
    expect(isTabs(nested)).toBe(true)
    expect(nested.tabs[0]!.content).toBe(inner)
    expect(next.tabs[1]).toBe(other)
  })

  it('is a no-op for a missing id', () => {
    const root = createLeaf('terminal')

    expect(wrapInTabs(root, 'missing', titleOf)).toBe(root)
  })
})

describe('ungroupTabs', () => {
  it("collapses a single-tab group to that tab's own content, by reference", () => {
    const only = welcomeTab('Only')
    const root = createTabs([only])

    const next = ungroupTabs(root, root.id)

    expect(isTabs(next)).toBe(false)
    expect(next).toBe(only.content)
  })

  it('is a no-op for a group with more than one tab', () => {
    const [a, b] = [welcomeTab('A'), welcomeTab('B')]
    const root = createTabs([a, b])

    expect(ungroupTabs(root, root.id)).toBe(root)
  })

  it('collapses a single-tab group inside a split, leaving the split and its sibling untouched', () => {
    const only = welcomeTab('Only')
    const left = createTabs([only])
    const right = createTabs([welcomeTab('Right')])
    const split = createSplit('horizontal', [left, right])

    const next = ungroupTabs(split, left.id) as SplitContent

    expect(next.children).toHaveLength(2)
    expect(next.children[0]).toBe(only.content)
    expect(next.children[1]).toBe(right)
  })

  it('is a no-op for a missing id', () => {
    const root = createTabs([welcomeTab('Only')])

    expect(ungroupTabs(root, 'missing')).toBe(root)
  })
})

describe('canDockPane', () => {
  it('accepts detachable panes against outside targets, wherever they live', () => {
    const inner = createLeaf('terminal')
    const innerSplit = createSplit('vertical', [inner, createLeaf('welcome')])
    const tabContent = createLeaf('welcome')
    const group = createTabs([createTab('T', tabContent)])
    const root = createSplit('horizontal', [innerSplit, group])

    expect(canDockPane(root, group.id, inner.id, 'left')).toBe(true)
    // A nested split's child is just as detachable as a top-level one.
    expect(canDockPane(root, inner.id, group.id, 'center')).toBe(true)
    // A tab's content travels alone, independent of its tab.
    expect(canDockPane(root, tabContent.id, inner.id, 'right')).toBe(true)
  })

  it('declines the root, split targets, self/descendants, and unknown ids', () => {
    const inner = createLeaf('terminal')
    const innerSplit = createSplit('vertical', [inner, createLeaf('welcome')])
    const tabContent = createLeaf('welcome')
    const group = createTabs([createTab('T', tabContent)])
    const root = createSplit('horizontal', [innerSplit, group])

    // The root has nowhere else to go.
    expect(canDockPane(root, root.id, group.id, 'left')).toBe(false)
    // Splits are containers, not dock targets.
    expect(canDockPane(root, group.id, innerSplit.id, 'left')).toBe(false)
    // A pane can't land on itself or anything inside its own subtree.
    expect(canDockPane(root, group.id, group.id, 'left')).toBe(false)
    expect(canDockPane(root, group.id, tabContent.id, 'center')).toBe(false)
    // Unknown ids.
    expect(canDockPane(root, 'missing', group.id, 'left')).toBe(false)
    expect(canDockPane(root, group.id, 'missing', 'left')).toBe(false)
  })

  it("governs docking against the pane's own enclosing group by what would remain", () => {
    const only = createLeaf('terminal')
    const soloGroup = createTabs([createTab('Only', only)])
    const other = createLeaf('welcome')
    const soloRoot = createSplit('horizontal', [soloGroup, other])

    // A one-tab group leaves with its pane: nothing to split against.
    expect(canDockPane(soloRoot, only.id, soloGroup.id, 'right')).toBe(false)
    expect(canDockPane(soloRoot, only.id, soloGroup.id, 'center')).toBe(false)

    const a = createLeaf('terminal')
    const b = createLeaf('welcome')
    const pairGroup = createTabs([createTab('A', a), createTab('B', b)])

    // With a survivor, an edge split rearranges; center would only re-group
    // what is already grouped.
    expect(canDockPane(pairGroup, a.id, pairGroup.id, 'right')).toBe(true)
    expect(canDockPane(pairGroup, a.id, pairGroup.id, 'center')).toBe(false)
  })
})

describe('canMovePaneToTabs', () => {
  it('accepts groups outside the pane, requiring its own bar to outlive the detach', () => {
    const [t1, t2, t3] = [welcomeTab('T1'), welcomeTab('T2'), welcomeTab('T3')]
    const group = createTabs([t1, t2, t3])
    const otherGroup = createTabs([welcomeTab('Other')])
    const root = createSplit('horizontal', [group, otherGroup])

    expect(canMovePaneToTabs(root, t1.content.id, otherGroup.id)).toBe(true)
    // Three tabs: the bar survives losing the pane's own tab.
    expect(canMovePaneToTabs(root, t1.content.id, group.id)).toBe(true)
  })

  it('declines bars that would collapse with the detach, subtrees, and non-groups', () => {
    const [t1, t2] = [welcomeTab('T1'), welcomeTab('T2')]
    const pairGroup = createTabs([t1, t2])
    const nested = createLeaf('welcome')
    const nestedGroup = createTabs([createTab('Nested', nested)])
    const leaf = createLeaf('terminal')
    const root = createSplit('horizontal', [
      pairGroup,
      createSplit('vertical', [nestedGroup, leaf])
    ])

    // Two tabs: losing the pane's own tab collapses the bar it would join.
    expect(canMovePaneToTabs(root, t1.content.id, pairGroup.id)).toBe(false)
    // One tab: the whole group departs with the pane.
    expect(canMovePaneToTabs(root, nested.id, nestedGroup.id)).toBe(false)
    // A group inside the dragged pane's own subtree.
    expect(canMovePaneToTabs(root, pairGroup.id, pairGroup.id)).toBe(false)
    // Non-group targets, the root, unknown ids.
    expect(canMovePaneToTabs(root, leaf.id, leaf.id)).toBe(false)
    expect(canMovePaneToTabs(root, root.id, pairGroup.id)).toBe(false)
    expect(canMovePaneToTabs(root, 'missing', pairGroup.id)).toBe(false)
    expect(canMovePaneToTabs(root, leaf.id, 'missing')).toBe(false)
  })
})

describe('canMoveTabToTabs', () => {
  it('accepts another group, and the tab’s own bar (a reorder)', () => {
    const tab = welcomeTab('Moving')
    const group = createTabs([tab, welcomeTab('Sibling')])
    const otherGroup = createTabs([welcomeTab('Other')])
    const root = createSplit('horizontal', [group, otherGroup])

    expect(canMoveTabToTabs(root, tab.id, otherGroup.id)).toBe(true)
    expect(canMoveTabToTabs(root, tab.id, group.id)).toBe(true)
  })

  it('declines a group nested inside the dragged tab’s own content, non-groups, unknown ids', () => {
    const nestedGroup = createTabs([welcomeTab('Nested')])
    const tab = createTab('Holder', nestedGroup)
    const group = createTabs([tab])
    const leaf = createLeaf('terminal')
    const root = createSplit('horizontal', [group, leaf])

    expect(canMoveTabToTabs(root, tab.id, nestedGroup.id)).toBe(false)
    expect(canMoveTabToTabs(root, tab.id, leaf.id)).toBe(false)
    expect(canMoveTabToTabs(root, 'missing', group.id)).toBe(false)
    expect(canMoveTabToTabs(root, tab.id, 'missing')).toBe(false)
  })
})

describe('dockPane', () => {
  it('splices an edge-docked pane into a same-direction split, landing bare', () => {
    const a = createLeaf('terminal')
    const b = createLeaf('welcome')
    const c = createTabs([welcomeTab('Existing')])
    const root = createSplit('horizontal', [a, b, c], { sizes: [0.5, 0.25, 0.25] })

    const next = dockPane(root, a.id, c.id, 'right', titleOf) as SplitContent

    expect(next.direction).toBe('horizontal')
    expect(next.children).toHaveLength(3)
    expect(next.children[0]).toBe(b)
    expect(next.children[1]).toBe(c)
    // The pane lands bare — it's already standalone content, no group wrapper.
    expect(next.children[2]).toBe(a)
    // The freed share rescales away; the target's share splits with the pane.
    expect(next.sizes[0]).toBeCloseTo(0.5)
    expect(next.sizes[1]).toBeCloseTo(0.25)
    expect(next.sizes[2]).toBeCloseTo(0.25)
  })

  it('top-docks across directions, unwrapping the vacated two-child split', () => {
    const moved = createLeaf('terminal')
    const stays = createLeaf('welcome')
    const root = createSplit('horizontal', [moved, stays])

    const next = dockPane(root, moved.id, stays.id, 'top', titleOf) as SplitContent

    expect(next.direction).toBe('vertical')
    expect(next.children[0]).toBe(moved)
    expect(next.children[1]).toBe(stays)
    expect(next.sizes).toEqual([0.5, 0.5])
  })

  it('center-docks onto a group, appending one tab holding the pane', () => {
    const moved = createLeaf('terminal')
    const target = createTabs([welcomeTab('Existing')])
    const root = createSplit('horizontal', [moved, target])

    const next = dockPane(root, moved.id, target.id, 'center', titleOf) as TabsContent

    // The vacated split unwraps down to the target group itself.
    expect(next.id).toBe(target.id)
    expect(next.tabs).toHaveLength(2)
    expect(next.tabs[1]!.content).toBe(moved)
    expect(next.tabs[1]!.title).toBe('terminal')
    expect(next.activeTabId).toBe(next.tabs[1]!.id)
  })

  it('center-docks a tab-group pane as a single tab holding the whole group', () => {
    const movedGroup = createTabs([welcomeTab('A'), welcomeTab('B')])
    const target = createTabs([welcomeTab('Existing')])
    const root = createSplit('horizontal', [movedGroup, target])

    const next = dockPane(root, movedGroup.id, target.id, 'center', titleOf) as TabsContent

    expect(next.id).toBe(target.id)
    expect(next.tabs).toHaveLength(2)
    // Recursive identity: the group nests as one tab — unmerged, by reference.
    expect(next.tabs[1]!.content).toBe(movedGroup)
  })

  it("center-docks onto an empty pane, taking over its slot under the pane's own id", () => {
    const moved = createLeaf('terminal')
    const stays = createLeaf('welcome')
    const empty = createLeaf('empty')
    const root = createSplit('horizontal', [createSplit('vertical', [moved, stays]), empty])

    const next = dockPane(root, moved.id, empty.id, 'center', titleOf) as SplitContent

    expect(next.children[0]).toBe(stays)
    // Unlike a tab drop, the travelling node keeps its own id — live content
    // is keyed to it — and the placeholder's id disappears.
    expect(next.children[1]).toBe(moved)
    expect(findNode(next, empty.id)).toBeNull()
  })

  it('center-docks onto a bare leaf, promoting both into a two-tab group by reference', () => {
    const moved = createLeaf('terminal')
    const target = createLeaf('welcome')
    const root = createSplit('horizontal', [moved, target])

    const next = dockPane(root, moved.id, target.id, 'center', titleOf) as TabsContent

    expect(isTabs(next)).toBe(true)
    expect(next.tabs).toHaveLength(2)
    expect(next.tabs[0]!.content).toBe(target)
    expect(next.tabs[0]!.title).toBe('welcome')
    expect(next.tabs[1]!.content).toBe(moved)
    expect(next.activeTabId).toBe(next.tabs[1]!.id)
  })

  it('closes the tab it leaves behind, collapsing a two-tab group to the survivor', () => {
    const moved = createLeaf('terminal')
    const stays = createLeaf('welcome')
    const group = createTabs([createTab('Moved', moved), createTab('Stays', stays)])
    const other = createTabs([welcomeTab('Existing')])
    const root = createSplit('horizontal', [group, other])

    const next = dockPane(root, moved.id, other.id, 'right', titleOf) as SplitContent

    // The pane travelled alone: its tab closed, and the group — down to one
    // tab — collapsed to the survivor's bare content in the same slot.
    expect(next.children).toHaveLength(3)
    expect(next.children[0]).toBe(stays)
    expect(next.children[1]).toBe(other)
    expect(next.children[2]).toBe(moved)
    expect(findNode(next, group.id)).toBeNull()
  })

  it('dissolves a one-tab group entirely when its pane is dragged out', () => {
    const moved = createLeaf('terminal')
    const group = createTabs([createTab('Only', moved)])
    const other = createLeaf('welcome')
    const root = createSplit('horizontal', [group, other])

    const next = dockPane(root, moved.id, other.id, 'left', titleOf) as SplitContent

    // No husk where the move began: the emptied group gave up its slot, so
    // only the target and the landed pane remain.
    expect(next.direction).toBe('horizontal')
    expect(next.children).toHaveLength(2)
    expect(next.children[0]).toBe(moved)
    expect(next.children[1]).toBe(other)
    expect(findNode(next, group.id)).toBeNull()
    expect(next.children.some((child) => child.type === 'empty')).toBe(false)
  })

  it("edge-docks against the pane's own two-tab group by splitting off the survivor", () => {
    const moved = createLeaf('terminal')
    const stays = createLeaf('welcome')
    const root = createTabs([createTab('Moved', moved), createTab('Stays', stays)])

    const next = dockPane(root, moved.id, root.id, 'right', titleOf) as SplitContent

    // Removing the pane's tab collapses the group to the survivor's content —
    // a different node id — and the split forms against that survivor.
    expect(isSplit(next)).toBe(true)
    expect(next.direction).toBe('horizontal')
    expect(next.children[0]).toBe(stays)
    expect(next.children[1]).toBe(moved)
  })

  it('is a no-op for every case canDockPane declines', () => {
    const tabContent = createLeaf('welcome')
    const group = createTabs([createTab('T', tabContent)])
    const leaf = createLeaf('terminal')
    const root = createSplit('horizontal', [group, leaf])

    expect(dockPane(root, root.id, leaf.id, 'left', titleOf)).toBe(root)
    expect(dockPane(root, leaf.id, leaf.id, 'center', titleOf)).toBe(root)
    expect(dockPane(root, leaf.id, root.id, 'left', titleOf)).toBe(root)
    expect(dockPane(root, group.id, tabContent.id, 'center', titleOf)).toBe(root)
    // The pane's own one-tab group would leave with it: nothing to dock against.
    expect(dockPane(root, tabContent.id, group.id, 'right', titleOf)).toBe(root)
    expect(dockPane(root, 'missing', leaf.id, 'left', titleOf)).toBe(root)
    expect(dockPane(root, leaf.id, 'missing', 'left', titleOf)).toBe(root)
  })

  it("edge-docking onto a tab's own content splits within that tab, leaving its group untouched", () => {
    const moved = createLeaf('terminal')
    const active = createLeaf('welcome')
    const activeTab = createTab('Active', active)
    const otherTab = createTab('Other', createLeaf('welcome'))
    const group = createTabs([activeTab, otherTab], { activeTabId: activeTab.id })
    const root = createSplit('horizontal', [group, moved])

    const next = dockPane(root, moved.id, active.id, 'right', titleOf) as TabsContent

    // The group itself is untouched — same id, same tab count — only the
    // active tab's own content became a split of [active, moved].
    expect(next.id).toBe(group.id)
    expect(next.tabs).toHaveLength(2)
    expect(next.tabs[1]).toBe(otherTab)
    const splitContentNode = next.tabs[0]!.content as SplitContent
    expect(isSplit(splitContentNode)).toBe(true)
    expect(splitContentNode.direction).toBe('horizontal')
    expect(splitContentNode.children[0]).toBe(active)
    expect(splitContentNode.children[1]).toBe(moved)
  })
})

describe('withPaneDetached', () => {
  it("drops a split child's slot and its size entry", () => {
    const [a, b, c] = [createLeaf('terminal'), createLeaf('browser'), createLeaf('terminal')]
    const root = createSplit('horizontal', [a, b, c], { sizes: [0.2, 0.3, 0.5] })

    const next = withPaneDetached(root, b.id) as SplitContent

    expect(next.children.map((child) => child.id)).toEqual([a.id, c.id])
    expect(next.sizes).toEqual([0.2, 0.5])
  })

  it('closes only the tab that held the pane', () => {
    const pane = createLeaf('terminal')
    const root = createTabs([welcomeTab('A'), createTab('B', pane), welcomeTab('C')])

    const next = withPaneDetached(root, pane.id) as TabsContent

    expect(next.tabs.map((tab) => tab.title)).toEqual(['A', 'C'])
  })

  it('removes a one-tab group entirely, leaving no placeholder behind', () => {
    const pane = createLeaf('terminal')
    const survivor = createLeaf('browser')
    const group = createTabs([createTab('Only', pane)])
    const root = createSplit('horizontal', [group, survivor])

    const next = withPaneDetached(root, pane.id) as SplitContent

    expect(next.children.map((child) => child.id)).toEqual([survivor.id])
  })

  it('returns null when the pane is the whole tree', () => {
    const root = createLeaf('terminal')

    expect(withPaneDetached(root, root.id)).toBeNull()
  })
})

describe('movePaneToTabs', () => {
  it('moves a pane into a group as a tab at the index, activated', () => {
    const moved = createLeaf('terminal')
    const target = createTabs([welcomeTab('A'), welcomeTab('B')])
    const root = createSplit('horizontal', [moved, target])

    const next = movePaneToTabs(root, moved.id, target.id, titleOf, 1) as TabsContent

    // The vacated split unwraps down to the group itself.
    expect(next.id).toBe(target.id)
    expect(next.tabs.map((t) => t.title)).toEqual(['A', 'terminal', 'B'])
    expect(next.tabs[1]!.content).toBe(moved)
    expect(next.activeTabId).toBe(next.tabs[1]!.id)
  })

  it('collapses the vacated split and keeps untouched siblings by reference', () => {
    const moved = createLeaf('terminal')
    const stays = createLeaf('welcome')
    const target = createTabs([welcomeTab('Existing')])
    const root = createSplit('horizontal', [createSplit('vertical', [moved, stays]), target])

    const next = movePaneToTabs(root, moved.id, target.id, titleOf) as SplitContent
    const landed = next.children[1] as TabsContent

    expect(next.children[0]).toBe(stays)
    expect(landed.id).toBe(target.id)
    expect(landed.tabs).toHaveLength(2)
    expect(landed.tabs[1]!.content).toBe(moved)
  })

  it("moves a tab's pane to another bar, closing the tab behind it", () => {
    const moved = createLeaf('terminal')
    const stays = createLeaf('welcome')
    const source = createTabs([createTab('Moved', moved), createTab('Stays', stays)])
    const target = createTabs([welcomeTab('Existing')])
    const root = createSplit('horizontal', [source, target])

    const next = movePaneToTabs(root, moved.id, target.id, titleOf) as SplitContent
    const landed = next.children[1] as TabsContent

    // The pane travelled alone: its tab closed, the two-tab source collapsed
    // to the survivor's content, and only the pane joined the target bar.
    expect(next.children[0]).toBe(stays)
    expect(findNode(next, source.id)).toBeNull()
    expect(landed.id).toBe(target.id)
    expect(landed.tabs).toHaveLength(2)
    expect(landed.tabs[1]!.content).toBe(moved)
    expect(landed.tabs[1]!.title).toBe('terminal')
  })

  it('dissolves a one-tab group when its pane moves to another bar', () => {
    const moved = createLeaf('terminal')
    const group = createTabs([createTab('Only', moved)])
    const target = createTabs([welcomeTab('Existing')])
    const root = createSplit('horizontal', [group, target])

    const next = movePaneToTabs(root, moved.id, target.id, titleOf) as TabsContent

    // The emptied group gave up its slot, so the vacated split unwrapped
    // down to the target bar itself — no husk left behind.
    expect(next.id).toBe(target.id)
    expect(next.tabs).toHaveLength(2)
    expect(next.tabs[1]!.content).toBe(moved)
    expect(findNode(next, group.id)).toBeNull()
  })

  it('declines non-group targets, targets inside the pane, and undetachable panes', () => {
    const tabContent = createLeaf('welcome')
    const innerGroup = createTabs([createTab('Inner', tabContent)])
    const leaf = createLeaf('terminal')
    const root = createSplit('horizontal', [innerGroup, leaf])

    expect(movePaneToTabs(root, leaf.id, leaf.id, titleOf)).toBe(root)
    expect(movePaneToTabs(root, root.id, innerGroup.id, titleOf)).toBe(root)
    // The pane's own one-tab bar leaves with it: nothing to join.
    expect(movePaneToTabs(root, tabContent.id, innerGroup.id, titleOf)).toBe(root)
    expect(movePaneToTabs(root, innerGroup.id, innerGroup.id, titleOf)).toBe(root)
    expect(movePaneToTabs(root, 'missing', innerGroup.id, titleOf)).toBe(root)
    expect(movePaneToTabs(root, leaf.id, 'missing', titleOf)).toBe(root)
  })
})

describe('normalize', () => {
  it('flattens nested same-direction splits', () => {
    const [a, b, c] = [createLeaf('welcome'), createLeaf('welcome'), createLeaf('welcome')]
    const inner = createSplit('horizontal', [a, b])
    const outer = createSplit('horizontal', [inner, c], { sizes: [0.5, 0.5] })

    const next = normalize(outer) as SplitContent

    expect(next.children.map((n) => n.id)).toEqual([a.id, b.id, c.id])
    expect(next.sizes[0]).toBeCloseTo(0.25)
    expect(next.sizes[2]).toBeCloseTo(0.5)
  })

  it('repairs a stale activeTabId', () => {
    const tab = welcomeTab('A')
    const root = createTabs([tab], { activeTabId: 'gone' })

    const next = normalize(root) as TabsContent

    expect(next.activeTabId).toBe(tab.id)
  })

  it('falls back to an empty pane when the root collapses entirely', () => {
    const root = createSplit('horizontal', [])

    const next = normalize(root) as LeafContent

    expect(next.type).toBe('empty')
  })
})

describe('firstPaneId', () => {
  it('returns a tabs/leaf root directly', () => {
    const root = createTabs([welcomeTab()])

    expect(firstPaneId(root)).toBe(root.id)
  })

  it('descends into the first child of nested splits', () => {
    const leaf = createLeaf('empty')
    const inner = createSplit('vertical', [leaf, createLeaf('empty')])
    const root = createSplit('horizontal', [inner, createLeaf('empty')])

    expect(firstPaneId(root)).toBe(leaf.id)
  })
})

describe('structural sharing', () => {
  it('keeps sibling subtrees reference-equal after addTab in the other pane', () => {
    const left = createTabs([welcomeTab('Left')])
    const right = createTabs([welcomeTab('Right')])
    const split = createSplit('horizontal', [left, right])
    const rootTab = createTab('Root', split)
    const root = createTabs([rootTab])

    const next = addTab(root, left.id, welcomeTab('New')) as TabsContent
    const nextSplit = next.tabs[0]!.content as SplitContent

    expect(next).not.toBe(root)
    expect(nextSplit.children[0]).not.toBe(left)
    expect(nextSplit.children[1]).toBe(right)
  })

  it('keeps sibling subtrees reference-equal after openContent in the other pane', () => {
    const left = createTabs([welcomeTab('Left')])
    const right = createTabs([welcomeTab('Right')])
    const root = createSplit('horizontal', [left, right])

    const next = openContent(root, left.id, createLeaf('terminal'), titleOf) as SplitContent

    expect(next.children[0]).not.toBe(left)
    expect(next.children[1]).toBe(right)
  })

  it('returns the same root when the target id does not exist', () => {
    const root = createTabs([welcomeTab()])

    expect(addTab(root, 'missing', welcomeTab())).toBe(root)
  })
})

describe('replaceContent', () => {
  it('swaps a leaf for new content in place', () => {
    const leaf = createLeaf('empty')
    const root = createTabs([createTab('Tab', leaf)])
    const group = createTabs([welcomeTab()])

    const next = replaceContent(root, leaf.id, group) as TabsContent

    expect(next.tabs[0]!.content).toBe(group)
  })

  it('replaces the root itself', () => {
    const root = createTabs([welcomeTab()])
    const leaf = createLeaf('empty')

    expect(replaceContent(root, root.id, leaf)).toBe(leaf)
  })
})

describe('removeNode', () => {
  it('removing a split pane collapses the split', () => {
    const empty = createLeaf('empty')
    const group = createTabs([welcomeTab()])
    const root = createSplit('horizontal', [group, empty])

    const next = removeNode(root, empty.id)

    expect(next).toBe(group)
  })

  it('removing the root resets it to an empty pane', () => {
    const root = createTabs([welcomeTab()])

    const next = removeNode(root, root.id) as LeafContent

    expect(next.type).toBe('empty')
    expect(next.id).not.toBe(root.id)
  })
})

describe('openContent', () => {
  it('promotes an occupied pane into a group holding both, rather than replacing it', () => {
    const existing = createLeaf('terminal')
    const added = createLeaf('terminal')

    const next = openContent(existing, existing.id, added, titleOf) as TabsContent

    expect(isTabs(next)).toBe(true)
    expect(next.tabs.map((t) => t.title)).toEqual(['terminal', 'terminal'])
    expect(next.tabs[1]!.content).toBe(added)
    expect(next.activeTabId).toBe(next.tabs[1]!.id)
  })

  it('preserves the promoted content by reference rather than cloning it', () => {
    const existing = createLeaf('terminal', { cwd: '~' })

    const next = openContent(existing, existing.id, createLeaf('terminal'), titleOf) as TabsContent

    // Identity is the contract: a live pty is registered against this node's id.
    expect(next.tabs[0]!.content).toBe(existing)
  })

  it('fills an empty pane in place instead of opening a group beside it', () => {
    const empty = createLeaf('empty')
    const root = createTabs([createTab('Tab', empty)])
    const terminal = createLeaf('terminal')

    const next = openContent(root, empty.id, terminal, titleOf) as TabsContent

    expect(next.tabs).toHaveLength(1)
    expect(next.tabs[0]!.content).toBe(terminal)
  })

  it('opens a blank pane as a group of exactly one tab, dropping the placeholder', () => {
    const empty = createLeaf('empty')
    const added = createLeaf('empty')

    const next = openContent(empty, empty.id, added, titleOf) as TabsContent

    expect(isTabs(next)).toBe(true)
    expect(next.tabs).toHaveLength(1)
    expect(next.tabs[0]!.content).toBe(added)
  })

  it("adds a sibling tab when the target is a tab's own content", () => {
    const terminal = createLeaf('terminal')
    const root = createTabs([createTab('Terminal', terminal)])
    const added = createLeaf('terminal')

    const next = openContent(root, terminal.id, added, titleOf) as TabsContent

    expect(next.id).toBe(root.id)
    expect(next.tabs).toHaveLength(2)
    expect(next.tabs[0]!.content).toBe(terminal)
    expect(next.tabs[1]!.content).toBe(added)
    expect(next.activeTabId).toBe(next.tabs[1]!.id)
    // The sibling joined this group; no group was nested inside the tab.
    expect(next.tabs.some((t) => isTabs(t.content))).toBe(false)
  })

  it('appends a tab when the target is the group itself', () => {
    const root = createTabs([welcomeTab('First')])
    const added = createLeaf('terminal')

    const next = openContent(root, root.id, added, titleOf) as TabsContent

    expect(next.tabs.map((t) => t.title)).toEqual(['First', 'terminal'])
    expect(next.activeTabId).toBe(next.tabs[1]!.id)
  })

  it('joins the nearest enclosing group, not an outer one', () => {
    const terminal = createLeaf('terminal')
    const inner = createTabs([createTab('Inner', terminal)])
    const outer = createTabs([createTab('Outer', inner)])
    const added = createLeaf('terminal')

    const next = openContent(outer, terminal.id, added, titleOf) as TabsContent
    const nextInner = next.tabs[0]!.content as TabsContent

    expect(next.tabs).toHaveLength(1)
    expect(nextInner.tabs).toHaveLength(2)
    expect(nextInner.tabs[1]!.content).toBe(added)
  })

  it('keeps a split intact, sizes and all, when opening in one of its panes', () => {
    const left = createLeaf('empty')
    const right = createLeaf('terminal')
    const root = createSplit('horizontal', [left, right], { sizes: [0.3, 0.7] })

    const next = openContent(root, left.id, createLeaf('empty'), titleOf) as SplitContent

    expect(next.children).toHaveLength(2)
    expect(next.sizes).toEqual([0.3, 0.7])
    expect(isTabs(next.children[0]!)).toBe(true)
    expect(next.children[1]).toBe(right)
  })

  it('nests a tab group opened onto occupied content, inside its own new tab', () => {
    const terminal = createLeaf('terminal')
    const group = createTabs([createTab('New Tab', createLeaf('empty'))])

    const next = openContent(terminal, terminal.id, group, titleOf) as TabsContent

    expect(next.tabs[0]!.content).toBe(terminal)
    expect(next.tabs[1]!.content).toBe(group)
  })

  it('returns the same root when the target id does not exist', () => {
    const root = createTabs([welcomeTab()])

    expect(openContent(root, 'missing', createLeaf('terminal'), titleOf)).toBe(root)
  })
})

describe('lookup helpers', () => {
  it('findNode and findTab locate deeply nested nodes', () => {
    const leaf = createLeaf('welcome')
    const innerTab = createTab('Inner', leaf)
    const inner = createTabs([innerTab])
    const split = createSplit('vertical', [inner, createTabs([welcomeTab()])])
    const root = createTabs([createTab('Root', split)])

    expect(findNode(root, leaf.id)).toBe(leaf)
    expect(findTab(root, innerTab.id)?.group).toBe(inner)
  })
})
