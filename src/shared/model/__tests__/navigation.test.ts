import { describe, expect, it } from 'vitest'
import { createLeaf, createSplit, createTab, createTabs } from '../factories'
import {
  ancestorTabSteps,
  entryPaneId,
  focusAfterClose,
  type NavRect,
  navTarget,
  pickSpatialTarget,
  pickWrapTarget
} from '../navigation'
import { closePane } from '../tree'
import type { SplitContent, TabsContent } from '../types'

function rect(left: number, top: number, right: number, bottom: number): NavRect {
  return { left, top, right, bottom }
}

function welcomeTab(title = 'Welcome'): ReturnType<typeof createTab> {
  return createTab(title, createLeaf('welcome'))
}

describe('pickSpatialTarget', () => {
  // Panes in one window share edges give or take a splitter, so fixtures use
  // a 4px gap (the splitter) or a 1px overlap (adjoining borders).
  const current = rect(0, 0, 100, 100)

  it('returns null when no candidate lies in the direction', () => {
    expect(pickSpatialTarget(current, [], 'right')).toBeNull()
    const leftward = [{ id: 'l', rect: rect(-104, 0, -4, 100) }]
    expect(pickSpatialTarget(current, leftward, 'right')).toBeNull()
  })

  it('picks the pane across the splitter gap', () => {
    const candidates = [{ id: 'r', rect: rect(104, 0, 200, 100) }]
    expect(pickSpatialTarget(current, candidates, 'right')).toBe('r')
  })

  it('tolerates a 1px border overlap at the shared edge', () => {
    const candidates = [{ id: 'r', rect: rect(99, 0, 200, 100) }]
    expect(pickSpatialTarget(current, candidates, 'right')).toBe('r')
  })

  it('rejects a pane that substantially overlaps the current one', () => {
    const candidates = [{ id: 'o', rect: rect(50, 0, 150, 100) }]
    expect(pickSpatialTarget(current, candidates, 'right')).toBeNull()
  })

  it('picks the topmost pane in the adjacent column', () => {
    const candidates = [
      { id: 'low', rect: rect(104, 200, 200, 300) },
      { id: 'high', rect: rect(104, 0, 200, 100) }
    ]
    expect(pickSpatialTarget(current, candidates, 'right')).toBe('high')
  })

  it('prefers the adjacent column over a farther column, even one with a higher pane', () => {
    // "Pick the topmost" applies within the nearest column: a literal global
    // topmost would vault over the neighbor to the far column's top pane.
    const tall = rect(0, 0, 100, 300)
    const candidates = [
      { id: 'near-low', rect: rect(104, 200, 200, 300) },
      { id: 'far-high', rect: rect(204, 0, 300, 100) }
    ]
    expect(pickSpatialTarget(tall, candidates, 'right')).toBe('near-low')
  })

  it('treats columns within the tie epsilon as one and takes the topmost', () => {
    const candidates = [
      { id: 'nearer-low', rect: rect(100, 50, 200, 100) },
      { id: 'barely-farther-high', rect: rect(103, 0, 200, 40) }
    ]
    expect(pickSpatialTarget(current, candidates, 'right')).toBe('barely-farther-high')
  })

  it('mirrors for leftward movement', () => {
    const fromRight = rect(100, 0, 200, 100)
    const candidates = [
      { id: 'low', rect: rect(0, 50, 96, 100) },
      { id: 'high', rect: rect(0, 0, 96, 40) }
    ]
    expect(pickSpatialTarget(fromRight, candidates, 'left')).toBe('high')
  })

  it('picks the leftmost pane in the adjacent row when moving down', () => {
    const wide = rect(0, 0, 200, 100)
    const candidates = [
      { id: 'right', rect: rect(100, 104, 200, 200) },
      { id: 'left', rect: rect(0, 104, 96, 200) }
    ]
    expect(pickSpatialTarget(wide, candidates, 'down')).toBe('left')
  })

  it('mirrors for upward movement', () => {
    const fromBottom = rect(0, 100, 200, 200)
    const candidates = [
      { id: 'right', rect: rect(100, 0, 200, 96) },
      { id: 'left', rect: rect(0, 0, 96, 96) }
    ]
    expect(pickSpatialTarget(fromBottom, candidates, 'up')).toBe('left')
  })

  it('breaks a tie by proximity to the current pane’s own row, not always topmost (2x2 grid)', () => {
    // From the bottom-left pane of a 2x2 grid, moving right should land on
    // the bottom-right pane, not vault to the top-right pane just because
    // it's higher on screen.
    const bottomLeft = rect(0, 104, 100, 204)
    const candidates = [
      { id: 'top-right', rect: rect(104, 0, 200, 100) },
      { id: 'bottom-right', rect: rect(104, 104, 200, 204) }
    ]
    expect(pickSpatialTarget(bottomLeft, candidates, 'right')).toBe('bottom-right')
  })

  it('breaks a tie by proximity to the current pane’s own column, not always leftmost (2x2 grid)', () => {
    // From the top-right pane of a 2x2 grid, moving down should land on the
    // bottom-right pane, not fall back to the bottom-left pane just because
    // it's further left.
    const topRight = rect(104, 0, 204, 100)
    const candidates = [
      { id: 'bottom-left', rect: rect(0, 104, 100, 200) },
      { id: 'bottom-right', rect: rect(104, 104, 204, 200) }
    ]
    expect(pickSpatialTarget(topRight, candidates, 'down')).toBe('bottom-right')
  })
})

describe('pickWrapTarget', () => {
  const current = rect(0, 0, 100, 100)

  it('returns null when there are no other panes', () => {
    expect(pickWrapTarget(current, [], 'right')).toBeNull()
  })

  it('picks the leftmost pane when wrapping rightward', () => {
    const candidates = [
      { id: 'right', rect: rect(200, 0, 300, 100) },
      { id: 'left', rect: rect(0, 0, 100, 100) }
    ]
    expect(pickWrapTarget(current, candidates, 'right')).toBe('left')
  })

  it('picks the rightmost pane when wrapping leftward', () => {
    const candidates = [
      { id: 'right', rect: rect(200, 0, 300, 100) },
      { id: 'left', rect: rect(0, 0, 100, 100) }
    ]
    expect(pickWrapTarget(current, candidates, 'left')).toBe('right')
  })

  it('picks the topmost pane when wrapping downward', () => {
    const candidates = [
      { id: 'bottom', rect: rect(0, 200, 100, 300) },
      { id: 'top', rect: rect(0, 0, 100, 100) }
    ]
    expect(pickWrapTarget(current, candidates, 'down')).toBe('top')
  })

  it('picks the bottommost pane when wrapping upward', () => {
    const candidates = [
      { id: 'bottom', rect: rect(0, 200, 100, 300) },
      { id: 'top', rect: rect(0, 0, 100, 100) }
    ]
    expect(pickWrapTarget(current, candidates, 'up')).toBe('bottom')
  })

  it('breaks a wrap tie by proximity to the current row, not always topmost (2x2 grid)', () => {
    // Wrapping right from the bottom row should continue on the bottom row —
    // landing on the bottom-left pane, not vaulting to the top-left pane
    // just because it's higher on screen.
    const bottomRight = rect(104, 104, 204, 204)
    const candidates = [
      { id: 'top-left', rect: rect(0, 0, 100, 100) },
      { id: 'bottom-left', rect: rect(0, 104, 100, 204) }
    ]
    expect(pickWrapTarget(bottomRight, candidates, 'right')).toBe('bottom-left')
  })

  it('breaks a wrap tie by proximity to the current column, not always leftmost (2x2 grid)', () => {
    // Wrapping down from the right column should continue on the right
    // column — landing on the top-right pane, not falling back to the
    // top-left pane just because it's further left.
    const bottomRight = rect(104, 104, 204, 204)
    const candidates = [
      { id: 'top-left', rect: rect(0, 0, 100, 100) },
      { id: 'top-right', rect: rect(104, 0, 204, 100) }
    ]
    expect(pickWrapTarget(bottomRight, candidates, 'down')).toBe('top-right')
  })

  it('breaks a horizontal-wrap tie toward the current pane’s own row', () => {
    const candidates = [
      { id: 'low', rect: rect(0, 200, 100, 300) },
      { id: 'high', rect: rect(0, 0, 100, 100) }
    ]
    // `current`'s own row (top 0) sits right against 'high'.
    expect(pickWrapTarget(current, candidates, 'right')).toBe('high')
    expect(pickWrapTarget(current, candidates, 'left')).toBe('high')
  })

  it('breaks a vertical-wrap tie toward the current pane’s own column', () => {
    const candidates = [
      { id: 'right', rect: rect(200, 0, 300, 100) },
      { id: 'left', rect: rect(0, 0, 100, 100) }
    ]
    // `current`'s own column (left 0) sits right against 'left'.
    expect(pickWrapTarget(current, candidates, 'down')).toBe('left')
    expect(pickWrapTarget(current, candidates, 'up')).toBe('left')
  })
})

describe('entryPaneId', () => {
  it('lands on a leaf itself regardless of direction', () => {
    const leaf = createLeaf('welcome')
    for (const direction of ['left', 'right', 'up', 'down'] as const) {
      expect(entryPaneId(leaf, direction)).toBe(leaf.id)
    }
  })

  it('enters a horizontal split from the side the movement crossed', () => {
    const [a, b, c] = [createLeaf('welcome'), createLeaf('welcome'), createLeaf('welcome')]
    const split = createSplit('horizontal', [a, b, c])

    expect(entryPaneId(split, 'right')).toBe(a.id) // entering rightward → leftmost
    expect(entryPaneId(split, 'left')).toBe(c.id) // entering leftward → rightmost
    // Vertical movement crosses the top/bottom edge, which every column
    // touches equally: the leftmost wins the tie.
    expect(entryPaneId(split, 'down')).toBe(a.id)
    expect(entryPaneId(split, 'up')).toBe(a.id)
  })

  it('enters a vertical split from the side the movement crossed', () => {
    const [a, b] = [createLeaf('welcome'), createLeaf('welcome')]
    const split = createSplit('vertical', [a, b])

    expect(entryPaneId(split, 'down')).toBe(a.id) // entering downward → topmost
    expect(entryPaneId(split, 'up')).toBe(b.id) // entering upward → bottommost
    expect(entryPaneId(split, 'right')).toBe(a.id)
    expect(entryPaneId(split, 'left')).toBe(a.id)
  })

  it('recurses through nested splits toward the crossed edge', () => {
    const [a, b, c] = [createLeaf('welcome'), createLeaf('welcome'), createLeaf('welcome')]
    const root = createSplit('horizontal', [createSplit('vertical', [a, b]), c])

    // Entering upward: any horizontal child touches the bottom edge, so the
    // first (leftmost) column is entered, then its bottommost pane.
    expect(entryPaneId(root, 'up')).toBe(b.id)
    // Entering leftward: the rightmost column is the plain leaf.
    expect(entryPaneId(root, 'left')).toBe(c.id)
  })

  it('descends into the visible tab of a tab group', () => {
    const [x, y] = [createLeaf('welcome'), createLeaf('welcome')]
    const behind = welcomeTab('Behind')
    const shown = createTab('Shown', createSplit('horizontal', [x, y]))
    const group = createTabs([behind, shown], { activeTabId: shown.id })

    expect(entryPaneId(group, 'right')).toBe(x.id)
    expect(entryPaneId(group, 'left')).toBe(y.id)
  })

  it('descends into the first tab when the active one has gone stale', () => {
    const [x, y] = [createLeaf('welcome'), createLeaf('welcome')]
    const group = createTabs([createTab('X', x), createTab('Y', y)], { activeTabId: 'gone' })
    expect(entryPaneId(group, 'right')).toBe(x.id)
  })

  it('falls back to the group itself only when it has no tabs at all', () => {
    const group = createTabs([])
    expect(entryPaneId(group, 'right')).toBe(group.id)
  })

  it('drills to the first child/active tab when called with no direction', () => {
    const [a, b] = [createLeaf('welcome'), createLeaf('welcome')]
    const split = createSplit('horizontal', [a, b])
    expect(entryPaneId(split)).toBe(a.id)

    const [x, y] = [createLeaf('welcome'), createLeaf('welcome')]
    const behind = welcomeTab('Behind')
    const shown = createTab('Shown', createSplit('horizontal', [x, y]))
    const group = createTabs([behind, shown], { activeTabId: shown.id })
    expect(entryPaneId(group)).toBe(x.id)

    const leaf = createLeaf('welcome')
    expect(entryPaneId(leaf)).toBe(leaf.id)
  })
})

describe('ancestorTabSteps', () => {
  it('returns one step per ancestor tab, innermost first', () => {
    const leaf = createLeaf('browser')
    const innerTab = createTab('Inner', leaf)
    // The inner tab is deliberately not the active one: the steps say which
    // tabs *would need* activating, regardless of current visibility.
    const innerGroup = createTabs([welcomeTab('Front'), innerTab])
    const outerTab = createTab(
      'Outer',
      createSplit('horizontal', [innerGroup, createLeaf('welcome')])
    )
    const outerGroup = createTabs([outerTab, welcomeTab('Other')])

    expect(ancestorTabSteps(outerGroup, leaf.id)).toEqual([
      { groupId: innerGroup.id, tabId: innerTab.id },
      { groupId: outerGroup.id, tabId: outerTab.id }
    ])
  })

  it('is empty for a pane under no tab, the root itself, and an absent id', () => {
    const leaf = createLeaf('welcome')
    const root = createSplit('horizontal', [leaf, createLeaf('welcome')])

    expect(ancestorTabSteps(root, leaf.id)).toEqual([])
    expect(ancestorTabSteps(root, root.id)).toEqual([])
    expect(ancestorTabSteps(root, 'missing')).toEqual([])
  })
})

describe('navTarget', () => {
  it('hands over to the next child of a split laid out along the pressed axis', () => {
    const [a, b, c] = [createLeaf('welcome'), createLeaf('welcome'), createLeaf('welcome')]
    const root = createSplit('horizontal', [a, b, c])

    expect(navTarget(root, a.id, 'right')).toEqual({ node: b, tabSwitch: null, wrapped: false })
    expect(navTarget(root, b.id, 'left')?.node).toBe(a)
  })

  it('walks up past a split laid out across the pressed axis', () => {
    const [a, b, c] = [createLeaf('welcome'), createLeaf('welcome'), createLeaf('welcome')]
    const column = createSplit('vertical', [a, b])
    const root = createSplit('horizontal', [column, c])

    // The column can't move sideways, so the row above it hands over instead.
    expect(navTarget(root, b.id, 'right')?.node).toBe(c)
    // Within the column, moving down is a plain step.
    expect(navTarget(root, a.id, 'down')?.node).toBe(b)
    // And entering it from the right is the column as a whole.
    expect(navTarget(root, c.id, 'left')?.node).toBe(column)
  })

  it('steps to the next tab before leaving the group for its sibling', () => {
    const [p, q, r] = [createLeaf('welcome'), createLeaf('welcome'), createLeaf('welcome')]
    const [first, second] = [createTab('One', p), createTab('Two', q)]
    const group = createTabs([first, second], { activeTabId: first.id })
    const root = createSplit('horizontal', [group, r])

    // `r` sits right there on screen, but the rest of the group comes first.
    const target = navTarget(root, p.id, 'right')
    expect(target?.node).toBe(q)
    expect(target?.tabSwitch).toEqual({ groupId: group.id, tabId: second.id })
    expect(target?.wrapped).toBe(false)

    // Only once the group is exhausted does focus leave it.
    const onward = navTarget(root, q.id, 'right')
    expect(onward?.node).toBe(r)
    expect(onward?.tabSwitch).toBeNull()
  })

  it('never switches tabs for up/down', () => {
    const [a, b] = [welcomeTab('A'), welcomeTab('B')]
    const root = createTabs([a, b], { activeTabId: a.id })

    // A tab group holding one pane per tab has nothing above or below.
    expect(navTarget(root, a.content.id, 'down')).toBeNull()
    expect(navTarget(root, a.content.id, 'up')).toBeNull()
    expect(navTarget(root, a.content.id, 'right')?.node).toBe(b.content)
  })

  it('moves between a pane and the tab group beside it without cycling its tabs', () => {
    const above = createLeaf('welcome')
    const [first, second] = [welcomeTab('One'), welcomeTab('Two')]
    const group = createTabs([first, second], { activeTabId: second.id })
    const root = createSplit('vertical', [above, group])

    // Downward hands over the group itself — the caller enters its visible tab.
    expect(navTarget(root, above.id, 'down')?.node).toBe(group)
    const back = navTarget(root, second.content.id, 'up')
    expect(back?.node).toBe(above)
    expect(back?.tabSwitch).toBeNull()
  })

  it('walks up past a single-tab group to the multi-tab one above it', () => {
    const leaf = createLeaf('welcome')
    const inner = createTabs([createTab('Only', leaf)])
    const other = welcomeTab('Other')
    const root = createTabs([createTab('Nested', inner), other])

    const target = navTarget(root, leaf.id, 'right')
    expect(target?.node).toBe(other.content)
    expect(target?.tabSwitch).toEqual({ groupId: root.id, tabId: other.id })
  })

  it('wraps the outermost container along the axis when nothing lies ahead', () => {
    const [a, b, c] = [createLeaf('welcome'), createLeaf('welcome'), createLeaf('welcome')]
    const root = createSplit('horizontal', [a, b, c])

    expect(navTarget(root, c.id, 'right')).toEqual({ node: a, tabSwitch: null, wrapped: true })
    expect(navTarget(root, a.id, 'left')?.node).toBe(c)
  })

  it('wraps the outermost tab group rather than a split nested inside it', () => {
    const [x, y] = [createLeaf('welcome'), createLeaf('welcome')]
    const first = welcomeTab('One')
    const second = createTab('Two', createSplit('horizontal', [x, y]))
    const root = createTabs([first, second], { activeTabId: second.id })

    // The inner split could wrap back to `x`, but the group's edge is the
    // one the press ran into.
    const target = navTarget(root, y.id, 'right')
    expect(target?.tabSwitch).toEqual({ groupId: root.id, tabId: first.id })
    expect(target?.wrapped).toBe(true)
    // Vertically the group is transparent, so there is nowhere to wrap at all.
    expect(navTarget(root, y.id, 'down')).toBeNull()
  })

  it('cycles a focused tab group itself, the same as its content would', () => {
    const [a, b] = [welcomeTab('A'), welcomeTab('B')]
    const root = createTabs([a, b], { activeTabId: a.id })

    expect(navTarget(root, root.id, 'right')?.node).toBe(b.content)
    expect(navTarget(root, root.id, 'left')?.wrapped).toBe(true)
  })

  it('returns null when no ancestor can move in that direction', () => {
    const leaf = createLeaf('welcome')
    expect(navTarget(leaf, leaf.id, 'right')).toBeNull()

    const single = createTabs([createTab('Only', leaf)])
    expect(navTarget(single, leaf.id, 'right')).toBeNull()
  })
})

describe('focusAfterClose', () => {
  it('lands on the left neighbor when closing the last child of a 3-way split', () => {
    const [a, b, c] = [createLeaf('welcome'), createLeaf('welcome'), createLeaf('welcome')]
    const root = createSplit('horizontal', [a, b, c])
    const next = closePane(root, c.id)
    expect(focusAfterClose(root, next, c.id)).toBe(b.id)
  })

  it('lands on the right neighbor when closing the middle child of a 3-way split', () => {
    const [a, b, c] = [createLeaf('welcome'), createLeaf('welcome'), createLeaf('welcome')]
    const root = createSplit('horizontal', [a, b, c])
    const next = closePane(root, b.id)
    expect(focusAfterClose(root, next, b.id)).toBe(c.id)
  })

  it('still lands on the sole survivor when a 2-way split collapses', () => {
    const [a, b] = [createLeaf('welcome'), createLeaf('welcome')]
    const root = createSplit('horizontal', [a, b])
    const next = closePane(root, b.id)
    expect(focusAfterClose(root, next, b.id)).toBe(a.id)
  })

  it("lands on the next tab's content when closing the active middle tab of a 3-tab group", () => {
    const [a, b, c] = [welcomeTab('A'), welcomeTab('B'), welcomeTab('C')]
    const root = createTabs([a, b, c], { activeTabId: b.id })
    const next = closePane(root, b.content.id)
    expect(focusAfterClose(root, next, b.content.id)).toBe(c.content.id)
  })

  it('falls back to the fresh leaf that replaces a 1-tab group nested in a split', () => {
    const leaf = createLeaf('welcome')
    const group = createTabs([createTab('Only', leaf)])
    const other = createLeaf('welcome')
    const root = createSplit('horizontal', [group, other])

    const next = closePane(root, leaf.id) as SplitContent
    const replacement = next.children[0]!

    expect(replacement.id).not.toBe(group.id)
    expect(focusAfterClose(root, next, leaf.id)).toBe(replacement.id)
  })

  it("falls back to the fresh leaf when a 1-tab group sits inside another tab's content", () => {
    const leaf = createLeaf('welcome')
    const inner = createTabs([createTab('Only', leaf)])
    const outerTab = createTab('Outer', inner)
    const sibling = welcomeTab('Sibling')
    const root = createTabs([outerTab, sibling])

    const next = closePane(root, leaf.id) as TabsContent
    const replacementTab = next.tabs.find((t) => t.id === outerTab.id)
    if (!replacementTab) throw new Error('expected the outer tab to survive the close')
    const replacement = replacementTab.content

    expect(replacement.id).not.toBe(inner.id)
    expect(focusAfterClose(root, next, leaf.id)).toBe(replacement.id)
  })

  it('returns null when the closed pane was the whole tree, deferring to the default fallback', () => {
    const root = createLeaf('terminal')
    const next = closePane(root, root.id)
    expect(focusAfterClose(root, next, root.id)).toBeNull()
  })
})
