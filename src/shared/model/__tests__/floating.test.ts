import { describe, expect, it } from 'vitest'
import { createLeaf, createSplit, createTab, createTabs } from '../factories'
import {
  captureAnchor,
  clampRect,
  DEFAULT_FLOAT_RECT,
  DEFAULT_NEW_PANE_SPAWN_POSITION,
  detachForFloat,
  type FloatingPane,
  type FloatRect,
  floatOwning,
  MIN_FLOAT_SIZE,
  NEW_PANE_SPAWN_POSITIONS,
  NEW_PANE_SPAWN_SPACING,
  raiseFloating,
  replaceFloating,
  resolveSpawnPosition,
  restoreFloating,
  sanitizeFloating,
  spawnRectIn
} from '../floating'
import { findNode, moveTab } from '../tree'
import type { ContentNode, SplitContent, TabsContent } from '../types'

const titleOf = (node: ContentNode): string => node.type
const RECT: FloatRect = { x: 40, y: 60, width: 500, height: 300 }

function float(content: ContentNode, id = 'float-1'): FloatingPane {
  return { id, content, rect: RECT, anchor: { kind: 'root' } }
}

describe('captureAnchor', () => {
  it('anchors a split child by its split, index, size and both neighbours', () => {
    const [a, b, c] = [createLeaf('terminal'), createLeaf('browser'), createLeaf('terminal')]
    const root = createSplit('horizontal', [a, b, c], { sizes: [0.2, 0.3, 0.5] })

    expect(captureAnchor(root, b.id)).toEqual({
      kind: 'split',
      splitId: root.id,
      direction: 'horizontal',
      index: 1,
      size: 0.3,
      beforeId: a.id,
      afterId: c.id
    })
  })

  it("anchors a tab's content by its group, index and the tab's own title", () => {
    const [a, b] = [createLeaf('terminal'), createLeaf('browser')]
    const [first, second] = [createTab('One', a), createTab('Two', b)]
    const root = createTabs([first, second])

    expect(captureAnchor(root, b.id)).toEqual({
      kind: 'tab',
      groupId: root.id,
      index: 1,
      title: 'Two',
      beforeTabId: first.id,
      afterTabId: undefined
    })
  })

  it('anchors the root as root', () => {
    const root = createLeaf('terminal')
    expect(captureAnchor(root, root.id)).toEqual({ kind: 'root' })
  })

  it('returns null for an id that is not in the tree', () => {
    expect(captureAnchor(createLeaf('terminal'), 'nope')).toBeNull()
  })
})

describe('detachForFloat', () => {
  it('lifts a split child out, collapsing a two-child split to its sibling', () => {
    const [a, b] = [createLeaf('terminal'), createLeaf('browser')]
    const root = createSplit('horizontal', [a, b])

    const result = detachForFloat(root, a.id, RECT)

    expect(result?.root.id).toBe(b.id)
    expect(result?.floating.content.id).toBe(a.id)
  })

  it('closes the tab behind a floated pane, keeping the group other tabs', () => {
    const [a, b, c] = [createLeaf('terminal'), createLeaf('browser'), createLeaf('terminal')]
    const tabs = [createTab('One', a), createTab('Two', b), createTab('Three', c)]
    const root = createTabs(tabs)

    const result = detachForFloat(root, b.id, RECT)
    const remaining = result?.root as TabsContent

    expect(remaining.tabs.map((tab) => tab.title)).toEqual(['One', 'Three'])
  })

  it('removes a one-tab group entirely rather than leaving a placeholder behind', () => {
    const [a, c] = [createLeaf('terminal'), createLeaf('browser')]
    const group = createTabs([createTab('One', a)])
    const root = createSplit('horizontal', [group, c])

    const result = detachForFloat(root, a.id, RECT)

    expect(result?.root.id).toBe(c.id)
  })

  it('floats a whole tab group, tabs intact', () => {
    const [a, b, c] = [createLeaf('terminal'), createLeaf('browser'), createLeaf('terminal')]
    const group = createTabs([createTab('One', a), createTab('Two', b)])
    const root = createSplit('horizontal', [group, c])

    const result = detachForFloat(root, group.id, RECT)

    expect(result?.root.id).toBe(c.id)
    expect(result?.floating.content).toBe(group)
  })

  it('leaves a fresh empty pane behind when the root itself floats', () => {
    const root = createLeaf('terminal')

    const result = detachForFloat(root, root.id, RECT)

    expect(result?.root.type).toBe('empty')
    expect(result?.floating.anchor).toEqual({ kind: 'root' })
  })

  it('carries the node by reference, so live content keyed by its id survives', () => {
    const [a, b] = [createLeaf('terminal'), createLeaf('browser')]
    const root = createSplit('horizontal', [a, b])

    expect(detachForFloat(root, a.id, RECT)?.floating.content).toBe(a)
  })

  it('returns null for an unknown id', () => {
    expect(detachForFloat(createLeaf('terminal'), 'nope', RECT)).toBeNull()
  })
})

describe('restoreFloating', () => {
  it('puts a split child back at its old index while the split still exists', () => {
    const [a, b, c] = [createLeaf('terminal'), createLeaf('browser'), createLeaf('terminal')]
    const root = createSplit('horizontal', [a, b, c])
    const detached = detachForFloat(root, b.id, RECT)
    if (!detached) throw new Error('expected a detach')

    const next = restoreFloating(detached.root, detached.floating, titleOf, a.id) as SplitContent

    expect(next.children.map((child) => child.id)).toEqual([a.id, b.id, c.id])
  })

  it('restores approximately the fraction the pane used to hold', () => {
    const [a, b] = [createLeaf('terminal'), createLeaf('browser')]
    const root = createSplit('horizontal', [a, b], { sizes: [0.25, 0.75] })
    const detached = detachForFloat(root, a.id, RECT)
    if (!detached) throw new Error('expected a detach')

    const next = restoreFloating(detached.root, detached.floating, titleOf, b.id) as SplitContent

    expect(next.sizes[0]).toBeCloseTo(0.25)
    expect(next.sizes[1]).toBeCloseTo(0.75)
  })

  it('re-splits against the surviving neighbour when the split collapsed', () => {
    const [a, b] = [createLeaf('terminal'), createLeaf('browser')]
    const root = createSplit('vertical', [a, b])
    const detached = detachForFloat(root, a.id, RECT)
    if (!detached) throw new Error('expected a detach')
    // The split is gone entirely — it unwrapped to `b` the moment `a` left.
    expect(detached.root.id).toBe(b.id)

    const next = restoreFloating(detached.root, detached.floating, titleOf, b.id) as SplitContent

    expect(next.direction).toBe('vertical')
    expect(next.children.map((child) => child.id)).toEqual([a.id, b.id])
  })

  it('restores a tab at its old index in its old group, under its old title', () => {
    const [a, b, c] = [createLeaf('terminal'), createLeaf('browser'), createLeaf('terminal')]
    const root = createTabs([createTab('One', a), createTab('Two', b), createTab('Three', c)])
    const detached = detachForFloat(root, b.id, RECT)
    if (!detached) throw new Error('expected a detach')

    const next = restoreFloating(detached.root, detached.floating, titleOf, a.id) as TabsContent

    expect(next.tabs.map((tab) => tab.title)).toEqual(['One', 'Two', 'Three'])
    expect(next.tabs.map((tab) => tab.content.id)).toEqual([a.id, b.id, c.id])
  })

  it('lands beside the surviving neighbour tab when the group is gone', () => {
    const [a, b, c, d] = [
      createLeaf('terminal'),
      createLeaf('browser'),
      createLeaf('terminal'),
      createLeaf('browser')
    ]
    const first = createTab('One', a)
    const source = createTabs([first, createTab('Two', b), createTab('Three', c)])
    const other = createTabs([createTab('Four', d)])
    const root = createSplit('horizontal', [source, other])
    const detached = detachForFloat(root, b.id, RECT)
    if (!detached) throw new Error('expected a detach')

    // The source group dissolves once its remaining tabs scatter, but tab
    // "One" itself survives the move — tabs relocate by reference.
    const scattered = moveTab(detached.root, first.id, other.id)
    expect(findNode(scattered, source.id)).toBeNull()

    const next = restoreFloating(scattered, detached.floating, titleOf, d.id)
    const group = findNode(next, other.id) as TabsContent

    expect(group.tabs.map((tab) => tab.title)).toEqual(['Four', 'One', 'Two'])
  })

  it('fills the empty root that a root-anchored float left behind', () => {
    const root = createLeaf('terminal')
    const detached = detachForFloat(root, root.id, RECT)
    if (!detached) throw new Error('expected a detach')

    const next = restoreFloating(detached.root, detached.floating, titleOf, detached.root.id)

    expect(next).toBe(root)
  })

  it('falls back to opening beside the fallback target when every landmark is gone', () => {
    const [a, b] = [createLeaf('terminal'), createLeaf('browser')]
    const detached = detachForFloat(createSplit('horizontal', [a, b]), a.id, RECT)
    if (!detached) throw new Error('expected a detach')
    const unrelated = createLeaf('terminal')

    const next = restoreFloating(unrelated, detached.floating, titleOf, unrelated.id) as TabsContent

    expect(next.type).toBe('tabs')
    expect(next.tabs.map((tab) => tab.content.id)).toEqual([unrelated.id, a.id])
  })

  it('never loses the content, whatever the layout has become', () => {
    const [a, b] = [createLeaf('terminal'), createLeaf('browser')]
    const anchors = [
      detachForFloat(createSplit('horizontal', [a, b]), a.id, RECT),
      detachForFloat(createTabs([createTab('One', a), createTab('Two', b)]), a.id, RECT),
      detachForFloat(a, a.id, RECT)
    ]
    const mangled: ContentNode[] = [
      createLeaf('empty'),
      createLeaf('terminal'),
      createTabs([createTab('Elsewhere', createLeaf('browser'))]),
      createSplit('vertical', [createLeaf('terminal'), createLeaf('browser')])
    ]

    for (const detached of anchors) {
      if (!detached) throw new Error('expected a detach')
      for (const root of mangled) {
        const next = restoreFloating(root, detached.floating, titleOf, root.id)
        expect(findNode(next, a.id)).not.toBeNull()
      }
    }
  })
})

describe('unpin then re-pin', () => {
  it('restores the original tree shape for a split child', () => {
    const [a, b] = [createLeaf('terminal'), createLeaf('browser')]
    const root = createSplit('horizontal', [a, b], { sizes: [0.4, 0.6] })
    const detached = detachForFloat(root, a.id, RECT)
    if (!detached) throw new Error('expected a detach')

    const next = restoreFloating(detached.root, detached.floating, titleOf, b.id) as SplitContent

    expect(next.direction).toBe('horizontal')
    expect(next.children.map((child) => child.id)).toEqual([a.id, b.id])
    expect(next.sizes[0]).toBeCloseTo(0.4)
  })

  it('restores the original tree shape for a pane in a tab group', () => {
    const [a, b, c] = [createLeaf('terminal'), createLeaf('browser'), createLeaf('terminal')]
    const root = createTabs([createTab('One', a), createTab('Two', b), createTab('Three', c)])
    const detached = detachForFloat(root, b.id, RECT)
    if (!detached) throw new Error('expected a detach')

    const next = restoreFloating(detached.root, detached.floating, titleOf, a.id) as TabsContent

    expect(next.id).toBe(root.id)
    expect(next.tabs.map((tab) => tab.title)).toEqual(['One', 'Two', 'Three'])
  })

  it('restores the original tree shape for the root', () => {
    const root = createLeaf('terminal')
    const detached = detachForFloat(root, root.id, RECT)
    if (!detached) throw new Error('expected a detach')

    expect(restoreFloating(detached.root, detached.floating, titleOf, detached.root.id)).toBe(root)
  })

  it('restores a whole tab group with its tabs and active tab intact', () => {
    const [a, b, d] = [createLeaf('terminal'), createLeaf('browser'), createLeaf('terminal')]
    const second = createTab('Two', b)
    const group = createTabs([createTab('One', a), second], { activeTabId: second.id })
    const root = createSplit('horizontal', [group, d])
    const detached = detachForFloat(root, group.id, RECT)
    if (!detached) throw new Error('expected a detach')

    const next = restoreFloating(detached.root, detached.floating, titleOf, d.id) as SplitContent
    const restored = next.children[0] as TabsContent

    expect(next.children.map((child) => child.id)).toEqual([group.id, d.id])
    expect(restored.tabs.map((tab) => tab.title)).toEqual(['One', 'Two'])
    expect(restored.activeTabId).toBe(second.id)
  })
})

describe('floatOwning', () => {
  it('finds the window whose subtree contains the id', () => {
    const [a, b] = [createLeaf('terminal'), createLeaf('browser')]
    const group = createTabs([createTab('One', b)])
    const list = [float(a, 'first'), float(group, 'second')]

    expect(floatOwning(list, b.id)?.id).toBe('second')
    expect(floatOwning(list, 'nope')).toBeUndefined()
  })
})

describe('raiseFloating', () => {
  it('moves the named window to the end of the list', () => {
    const list = [float(createLeaf('terminal'), 'a'), float(createLeaf('browser'), 'b')]

    expect(raiseFloating(list, 'a').map((entry) => entry.id)).toEqual(['b', 'a'])
  })

  it('returns the same array when it is already topmost', () => {
    const list = [float(createLeaf('terminal'), 'a'), float(createLeaf('browser'), 'b')]

    expect(raiseFloating(list, 'b')).toBe(list)
  })

  it('returns the same array for an unknown id', () => {
    const list = [float(createLeaf('terminal'), 'a')]

    expect(raiseFloating(list, 'nope')).toBe(list)
  })
})

describe('replaceFloating', () => {
  it('returns the same array when the entry is unchanged', () => {
    const list = [float(createLeaf('terminal'), 'a')]

    expect(replaceFloating(list, 'a', (entry) => entry)).toBe(list)
    expect(replaceFloating(list, 'nope', () => float(createLeaf('browser')))).toBe(list)
  })

  it('swaps in the replacement entry', () => {
    const list = [float(createLeaf('terminal'), 'a'), float(createLeaf('browser'), 'b')]
    const moved = { ...list[0]!, rect: { ...RECT, x: 999 } }

    expect(replaceFloating(list, 'a', () => moved)[0]).toBe(moved)
  })
})

describe('clampRect', () => {
  const viewport = { width: 1000, height: 800 }

  it('keeps a window that runs off the right edge partly on screen', () => {
    const next = clampRect({ ...RECT, x: 5000 }, viewport)

    expect(next.x).toBeLessThan(viewport.width)
    expect(next.x + next.width).toBeGreaterThan(0)
  })

  it('keeps a window dragged off the left edge grabbable', () => {
    const next = clampRect({ ...RECT, x: -5000 }, viewport)

    expect(next.x + next.width).toBeGreaterThan(0)
  })

  it('never lets the top edge go above zero', () => {
    expect(clampRect({ ...RECT, y: -200 }, viewport).y).toBe(0)
  })

  it('raises a below-minimum size to the minimum', () => {
    const next = clampRect({ x: 0, y: 0, width: 10, height: 10 }, viewport)

    expect(next.width).toBe(MIN_FLOAT_SIZE.width)
    expect(next.height).toBe(MIN_FLOAT_SIZE.height)
  })

  it('never returns a window larger than the viewport', () => {
    const next = clampRect({ x: 0, y: 0, width: 9000, height: 9000 }, viewport)

    expect(next.width).toBe(viewport.width)
    expect(next.height).toBe(viewport.height)
  })
})

describe('sanitizeFloating', () => {
  const root = createLeaf('empty')

  it('returns an empty list for anything that is not an array', () => {
    expect(sanitizeFloating(undefined, root)).toEqual([])
    expect(sanitizeFloating({ nope: true }, root)).toEqual([])
  })

  it('drops an entry whose content is not a plausible node', () => {
    expect(sanitizeFloating([{ id: 'a', content: null, rect: RECT }], root)).toEqual([])
  })

  it('drops an entry holding a node id the docked root already claims', () => {
    const docked = createSplit('horizontal', [createLeaf('terminal'), createLeaf('browser')])
    const clash = float(docked.children[0]!)

    expect(sanitizeFloating([clash], docked)).toEqual([])
  })

  it('drops a second entry that repeats an earlier one node id', () => {
    const shared = createLeaf('terminal')

    const result = sanitizeFloating([float(shared, 'a'), float(shared, 'b')], root)

    expect(result.map((entry) => entry.id)).toEqual(['a'])
  })

  it('normalizes each surviving entry content', () => {
    const tab = createTab('Shell', createLeaf('terminal'))
    const stale = { ...createTabs([tab]), activeTabId: 'gone' }

    const result = sanitizeFloating([float(stale)], root)

    expect((result[0]!.content as TabsContent).activeTabId).toBe(tab.id)
  })

  it('repairs an unusable rect rather than losing the pane', () => {
    const content = createLeaf('terminal')
    const broken = { id: 'a', content, rect: { x: Number.NaN, y: 0 }, anchor: { kind: 'root' } }

    const result = sanitizeFloating([broken], root)

    expect(result).toHaveLength(1)
    expect(Object.values(result[0]!.rect).every(Number.isFinite)).toBe(true)
  })

  it('repairs an unrecognized anchor to the root anchor', () => {
    const broken = { id: 'a', content: createLeaf('terminal'), rect: RECT, anchor: { kind: 'huh' } }

    expect(sanitizeFloating([broken], root)[0]!.anchor).toEqual({ kind: 'root' })
  })

  it('mints an id for an entry that lost its own', () => {
    const broken = { content: createLeaf('terminal'), rect: RECT, anchor: { kind: 'root' } }

    expect(sanitizeFloating([broken], root)[0]!.id).toBeTruthy()
  })

  it('re-mints a duplicated window id rather than dropping the second window', () => {
    // React keys, gesture sessions and the z-order list all hang off the
    // window id (see FloatingPane.id) — two windows sharing one would leave
    // only the first reachable, but the pane inside the second is worth
    // keeping, so it is repaired the way a broken rect is.
    const result = sanitizeFloating(
      [float(createLeaf('terminal'), 'same'), float(createLeaf('browser'), 'same')],
      root
    )

    expect(result).toHaveLength(2)
    expect(result[0]!.id).toBe('same')
    expect(result[1]!.id).not.toBe('same')
  })

  it('rebuilds an anchor field-by-field, dropping unknown keys and mistyped neighbours', () => {
    // Anchors round-trip into every future save (same contract as
    // sanitizeRect), so a passthrough would persist foreign keys forever and
    // hand a non-string neighbour id to findTab.
    const entry = {
      id: 'a',
      content: createLeaf('terminal'),
      rect: RECT,
      anchor: { kind: 'tab', groupId: 'g', index: 1, title: 'T', beforeTabId: 42, extra: true }
    }

    expect(sanitizeFloating([entry], root)[0]!.anchor).toEqual({
      kind: 'tab',
      groupId: 'g',
      index: 1,
      title: 'T',
      beforeTabId: undefined,
      afterTabId: undefined
    })
  })
})

describe('spawnRectIn', () => {
  /** Comfortably bigger than the default float, so every inset is visible. */
  const PANE: FloatRect = { x: 100, y: 50, width: 1000, height: 700 }
  const S = NEW_PANE_SPAWN_SPACING

  /** Gap between the pane's trailing edges and the window's, per axis. */
  function trailingGaps(rect: FloatRect): { x: number; y: number } {
    return {
      x: PANE.x + PANE.width - (rect.x + rect.width),
      y: PANE.y + PANE.height - (rect.y + rect.height)
    }
  }

  it('sizes the window off the origin pane, capped at the default geometry', () => {
    expect(spawnRectIn(PANE, 'top-right')).toMatchObject({
      width: DEFAULT_FLOAT_RECT.width,
      height: DEFAULT_FLOAT_RECT.height
    })

    const modest = spawnRectIn({ x: 0, y: 0, width: 400, height: 300 }, 'top-right')
    expect(modest.width).toBe(400 - S * 2)
    expect(modest.height).toBe(300 - S * 2)
  })

  it('never asks for a window below the minimum float size', () => {
    const tiny = spawnRectIn({ x: 0, y: 0, width: 120, height: 80 }, 'top-left')

    expect(tiny.width).toBe(MIN_FLOAT_SIZE.width)
    expect(tiny.height).toBe(MIN_FLOAT_SIZE.height)
  })

  it('insets an edge-anchored position by the spawn spacing, on that edge', () => {
    const topLeft = spawnRectIn(PANE, 'top-left')
    expect(topLeft.x - PANE.x).toBe(S)
    expect(topLeft.y - PANE.y).toBe(S)

    expect(trailingGaps(spawnRectIn(PANE, 'bottom-right'))).toEqual({ x: S, y: S })
  })

  it('still spawns where the hardcoded top-right corner did, at the shipped default', () => {
    // The shipped default has to be a visual no-op for anyone who never opens
    // the picker, which means matching the single corner that preceded it.
    const rect = spawnRectIn(PANE, DEFAULT_NEW_PANE_SPAWN_POSITION)

    expect(rect.y - PANE.y).toBe(S)
    expect(trailingGaps(rect).x).toBe(S)
  })

  it('centers exactly, with no edge inset left over on either side', () => {
    // The bug a nine-case table produces: corners inset by the spacing and
    // centers quietly off by half of it.
    const rect = spawnRectIn(PANE, 'middle-center')

    expect(rect.x - PANE.x).toBe(trailingGaps(rect).x)
    expect(rect.y - PANE.y).toBe(trailingGaps(rect).y)
  })

  it('resolves the two axes independently', () => {
    const rect = spawnRectIn(PANE, 'bottom-center')

    expect(trailingGaps(rect).y).toBe(S)
    expect(rect.x - PANE.x).toBe(trailingGaps(rect).x)
  })

  it('puts each of the nine positions somewhere distinct', () => {
    const corners = NEW_PANE_SPAWN_POSITIONS.map((position) => {
      const rect = spawnRectIn(PANE, position)
      return `${rect.x},${rect.y}`
    })

    expect(new Set(corners).size).toBe(NEW_PANE_SPAWN_POSITIONS.length)
  })

  it('overhangs the leading edge when the pane is smaller than the window it spawns', () => {
    // Deliberate, not an oversight: clamping the span at zero instead would
    // make all nine positions identical over a small pane, and this is exactly
    // what the hardcoded top-right spawn did before the setting existed.
    const pane: FloatRect = { x: 0, y: 0, width: 200, height: 100 }

    const rect = spawnRectIn(pane, 'bottom-right')

    expect(rect.width).toBeGreaterThan(pane.width)
    expect(rect.x).toBeLessThan(pane.x)
  })

  it('stays bottom-anchored after being clamped into the viewport', () => {
    // The failure this guards is the setting silently becoming a no-op near a
    // screen edge: clampRect pulling a bottom/right anchor back to a top/left
    // one. It can't, because the window is never smaller than the clamp's own
    // keep-on-screen margin.
    const viewport = { width: 1200, height: 800 }
    const pane: FloatRect = { x: 0, y: 40, width: 1200, height: 760 }

    const bottom = spawnRectIn(pane, 'bottom-right')
    const top = spawnRectIn(pane, 'top-right')

    expect(clampRect(bottom, viewport)).toEqual(bottom)
    expect(clampRect(bottom, viewport).y).toBeGreaterThan(clampRect(top, viewport).y)
  })
})

describe('resolveSpawnPosition', () => {
  it('passes every known position through unchanged', () => {
    for (const position of NEW_PANE_SPAWN_POSITIONS) {
      expect(resolveSpawnPosition(position)).toBe(position)
    }
  })

  it('falls back to the default for anything a hand-edited settings.json could hold', () => {
    // Tolerated at read rather than rejected at load — see the function's own
    // comment, and getTheme, which gives colorTheme the same contract.
    for (const value of ['top', 'top_right', 'banana', '', null, undefined, 3, { row: 'top' }]) {
      expect(resolveSpawnPosition(value)).toBe(DEFAULT_NEW_PANE_SPAWN_POSITION)
    }
  })
})
