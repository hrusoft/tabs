import type { Page } from '@playwright/test'
import { createLeaf, createSplit } from '@tabs/plugin-sdk/shared/model/factories'
import type { SplitContent, TabsContent } from '@tabs/plugin-sdk/shared/model/types'
import { LAYOUT_VERSION } from '../../src/shared/layout'
import { closePane, paneById, splitHorizontal } from '../helpers/pane'
import { expect, test } from './helpers/harness'

// A split keeps its children's DOM when one of them comes or goes.
//
// SplitRenderer used to key its react-resizable-panels group by the joined
// child ids, so the whole group — and every pane in it — remounted whenever a
// child was added or removed. For stub content that is invisible; for a
// `<webview>` it is a real DOM reparent, which destroys the guest and reloads
// the page (CLAUDE.md's webview-reparent entry). The Electron tier proves the
// page survives (e2e/external-control.spec.ts); this tier pins the mechanism
// — element identity — plus the two things dropping the remount put at risk:
// that the sizes shown still come from the model, and that the separators'
// index tags follow an insertion before them.

// The harness's stub content type (src/renderer/src/testing/stubContent.tsx) —
// named literally, since importing that module would pull the stores into
// this Node-side spec.
const STUB_TYPE = 'stub'
const SPLIT_ID = 'row'
const LEFT = 'left'
const RIGHT = 'right'

test.use({
  seed: {
    layout: {
      version: LAYOUT_VERSION,
      root: createSplit(
        'horizontal',
        [createLeaf(STUB_TYPE, {}, LEFT), createLeaf(STUB_TYPE, {}, RIGHT)],
        { id: SPLIT_ID }
      ),
      activePaneId: LEFT
    }
  }
})

/** Remembers the current element of each pane, to compare against after a change. */
async function markPanes(page: Page, ids: string[]): Promise<void> {
  await page.evaluate((paneIds) => {
    const marked = new Map<string, Element | null>()
    for (const id of paneIds) marked.set(id, document.querySelector(`[data-dock-id="${id}"]`))
    ;(window as unknown as { __marked: Map<string, Element | null> }).__marked = marked
  }, ids)
}

/** For each marked pane: is it still the very same, still connected, element? */
function sameElements(page: Page): Promise<Record<string, boolean>> {
  return page.evaluate(() => {
    const marked = (window as unknown as { __marked: Map<string, Element | null> }).__marked
    const answer: Record<string, boolean> = {}
    for (const [id, before] of marked) {
      const now = document.querySelector(`[data-dock-id="${id}"]`)
      answer[id] = before !== null && now === before && before.isConnected
    }
    return answer
  })
}

/** The split's children in order, as the model holds them after persistLayout's debounce. */
async function persistedSplit(page: Page): Promise<SplitContent> {
  // persistLayout debounces 400ms (layoutStore.ts); waiting it out is how a
  // test reads what the model settled on rather than a mid-flight state.
  await page.waitForTimeout(500)
  const snapshots = await page.evaluate(() => window.__fakeApi?.layoutSets() ?? [])
  const wrapper = snapshots.at(-1)?.root as TabsContent
  return wrapper.tabs[0]!.content as SplitContent
}

/** Each panel's share of the split's width, in DOM (= model) order. */
function panelShares(page: Page): Promise<number[]> {
  return page.evaluate(() => {
    const group = document.querySelector('.split-view')
    const panels = group ? Array.from(group.querySelectorAll(':scope > [data-panel]')) : []
    const widths = panels.map((panel) => panel.getBoundingClientRect().width)
    const total = widths.reduce((sum, width) => sum + width, 0)
    return widths.map((width) => width / total)
  })
}

/** The newest pane: the one id in the split that the test did not seed. */
async function newPaneId(page: Page, known: string[]): Promise<string> {
  const split = await persistedSplit(page)
  const fresh = split.children.map((child) => child.id).filter((id) => !known.includes(id))
  expect(fresh).toHaveLength(1)
  return fresh[0]!
}

test('adding and removing a split child leaves its siblings mounted', async ({ page }) => {
  await markPanes(page, [LEFT, RIGHT])

  // Splitting the left pane horizontally splices a new pane in beside it,
  // inside this same split (splitContent in tree.ts), rather than nesting.
  await splitHorizontal(paneById(page, LEFT))
  const added = await newPaneId(page, [LEFT, RIGHT])
  expect((await persistedSplit(page)).children.map((child) => child.id)).toEqual([
    LEFT,
    added,
    RIGHT
  ])
  expect(await sameElements(page)).toEqual({ [LEFT]: true, [RIGHT]: true })

  await closePane(paneById(page, added))
  await expect(paneById(page, added)).toHaveCount(0)
  expect(await sameElements(page)).toEqual({ [LEFT]: true, [RIGHT]: true })
})

test('a pane set seen before is sized from the model, not the proportions it had then', async ({
  page
}) => {
  // 50/50 → split the left half → 25/25/50 → close the new pane. The model
  // hands the closed pane's share to its neighbours, so this id set comes
  // back at something other than 50/50 — while react-resizable-panels
  // remembers it at exactly 50/50 and would restore that without the reseed.
  await splitHorizontal(paneById(page, LEFT))
  const added = await newPaneId(page, [LEFT, RIGHT])
  await expect
    .poll(() => panelShares(page))
    .toEqual([expect.closeTo(0.25, 2), expect.closeTo(0.25, 2), expect.closeTo(0.5, 2)])

  await closePane(paneById(page, added))
  const afterClose = await persistedSplit(page)
  // Non-vacuous only while the model disagrees with the remembered 50/50.
  expect(Math.abs((afterClose.sizes[0] ?? 0) - 0.5)).toBeGreaterThan(0.05)
  await expect
    .poll(() => panelShares(page))
    .toEqual(afterClose.sizes.map((size) => expect.closeTo(size, 2)))

  // And a set never seen before (a fresh child id) still comes out of the
  // model too.
  await splitHorizontal(paneById(page, LEFT))
  const readded = await persistedSplit(page)
  expect(readded.children).toHaveLength(3)
  await expect
    .poll(() => panelShares(page))
    .toEqual(readded.sizes.map((size) => expect.closeTo(size, 2)))
})

/**
 * A pane added to a split that is already mounted must be its real size by
 * the time its content's first passive effect runs, because that is when a
 * terminal measures itself and sizes its pty. The library renders an id it
 * hasn't registered at flexGrow 1 — a ~1% sliver — and a click-driven commit
 * flushes passive effects before the library's corrective re-render: a
 * terminal there resized its pty to 2 columns and back, losing scrollback
 * (see SplitRenderer's first-commit sizing). The stub publishes the width it
 * saw at that moment as data-mount-width.
 */
test('a pane added to a mounted split is its real size when its content first measures', async ({
  page
}) => {
  const mountedAt = async (id: string) => {
    const content = paneById(page, id).getByTestId('stub-content')
    return {
      mounted: Number(await content.getAttribute('data-mount-width')),
      now: Math.round((await content.boundingBox())?.width ?? 0)
    }
  }
  await splitHorizontal(paneById(page, LEFT))
  const added = await newPaneId(page, [LEFT, RIGHT])
  const first = await mountedAt(added)
  expect(first.now).toBeGreaterThan(100)
  expect(Math.abs(first.mounted - first.now)).toBeLessThanOrEqual(2)

  // A pane set the library has seen before (closed, then split again) gets no
  // pass either: the new child is a new id, and must be sized all the same.
  await closePane(paneById(page, added))
  await splitHorizontal(paneById(page, LEFT))
  const again = await newPaneId(page, [LEFT, RIGHT])
  const second = await mountedAt(again)
  expect(Math.abs(second.mounted - second.now)).toBeLessThanOrEqual(2)
})

test('a separator that survives an insertion before it is retagged with its new index', async ({
  page
}) => {
  const separatorIndices = () =>
    page
      .locator(`.split-separator[data-split-id="${SPLIT_ID}"]`)
      .evaluateAll((els) => els.map((el) => el.getAttribute('data-separator-index')))
  expect(await separatorIndices()).toEqual(['1'])

  // The new pane lands at index 1, so the separator in front of RIGHT moves
  // from index 1 to 2 while staying the same element — the index is what a
  // cluster drag uses to address the boundary it moves (discoverCluster).
  await page.evaluate(() => {
    ;(window as unknown as { __sep: Element | null }).__sep =
      document.querySelector('.split-separator')
  })
  await splitHorizontal(paneById(page, LEFT))
  await expect.poll(separatorIndices).toEqual(['1', '2'])
  const survivorIndex = await page.evaluate(() => {
    const sep = (window as unknown as { __sep: Element | null }).__sep
    return sep?.isConnected ? sep.getAttribute('data-separator-index') : null
  })
  expect(survivorIndex).toBe('2')
})
