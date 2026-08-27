import type { Page } from '@playwright/test'
import { LAYOUT_VERSION } from '../../src/shared/layout'
import { createLeaf, createSplit, evenSizes } from '../../src/shared/model/factories'
import type { SplitContent, TabsContent } from '../../src/shared/model/types'
import { dragSeparatorX } from '../helpers/drag'
import { requireBox } from '../helpers/geometry'
import { emitSettingsChange, expect, test } from './helpers/harness'

// Regression coverage for TODO/bug-aligned-separator-intersection-drag.md:
// dragging from where several aligned separators meet should move *all* of
// them, not just the ones react-resizable-panels happens to have natively
// hit-tested at pointerdown (which, in this app's slicing/guillotine layout
// tree, is provably capped at 3 for any single geometric point — see
// split-resize.spec.ts's build2x2Grid). "Aligned" here means co-linear (same
// orientation, within SEPARATOR_ALIGNMENT_THRESHOLD_PX of each other) but not
// necessarily touching the same point — e.g. independent stacked rows whose
// column separators share an x. This fixture seeds 4 such rows directly:
// every row is an even 2-column split, so all 4 column separators start at
// the exact same x by construction, with no need to snap-drag them into
// alignment first.
//
// This is unconditional — unlike the snapResizeSeparators-gated
// snap-toward-alignment convenience (self-snap; see split-resize.spec.ts),
// carrying an already-aligned cluster along together is judged purely on
// current geometry and works identically whether the setting is on or off.

const ROW_COUNT = 4

function buildFourRowGrid() {
  const rows = Array.from({ length: ROW_COUNT }, (_, i) =>
    createSplit('horizontal', [createLeaf('empty'), createLeaf('empty')], { id: `row${i}` })
  )
  return createSplit('vertical', rows, { id: 'root', sizes: evenSizes(ROW_COUNT) })
}

const root = buildFourRowGrid()
const firstLeafId = (root.children[0] as ReturnType<typeof createSplit>).children[0]!.id

test.use({
  seed: {
    layout: { version: LAYOUT_VERSION, root, activePaneId: firstLeafId }
  }
})

/** Each row's column separator, in row order (row0's first, row1's, ...). */
function columnSeparators(page: Page) {
  return Array.from({ length: ROW_COUNT }, (_, i) =>
    page.locator(`.split-separator[data-split-id="row${i}"]`)
  )
}

/** The (horizontal) root separator directly between rowA and rowB, i.e. their shared boundary. */
function rowBoundarySeparator(page: Page, index: number) {
  return page.locator(`.split-separator[data-split-id="root"][data-separator-index="${index}"]`)
}

test('dragging at a row boundary moves every aligned row, not just the adjacent pair', async ({
  page
}) => {
  await emitSettingsChange(page, { snapResizeSeparators: true })

  const columns = columnSeparators(page)
  const boxesBefore = await Promise.all(columns.map((sep) => requireBox(sep)))
  // All 4 column separators start at the same x by construction.
  for (const box of boxesBefore) expect(box.x).toBeCloseTo(boxesBefore[0]!.x, 0)

  // Drag from the row0/row1 boundary — the true point-intersection react-
  // resizable-panels natively grabs (root's separator + row0's + row1's) —
  // sideways. row2 and row3 are only *aligned*, not at this point at all.
  await dragSeparatorX(rowBoundarySeparator(page, 1), 120)

  const boxesAfter = await Promise.all(columns.map((sep) => requireBox(sep)))
  for (const box of boxesAfter) {
    expect(box.x).toBeCloseTo(boxesAfter[0]!.x, 0)
    expect(box.x - boxesBefore[0]!.x).toBeGreaterThan(100)
  }

  // Live-DOM alignment alone doesn't prove the commit reached the store —
  // imperative setLayout moves the uncontrolled Group without it. Wait out
  // persistLayout's 400ms debounce (layoutStore.ts) and check what actually
  // got persisted for every row, not just the two the library natively
  // dragged.
  await page.waitForTimeout(500)
  const snapshots = await page.evaluate(() => window.__fakeApi?.layoutSets() ?? [])
  // The persisted root is always a tab group now (ensureTabsRoot in tree.ts)
  // — our custom split lives unchanged one level down, as its sole tab's
  // content.
  const persistedWrapper = snapshots.at(-1)?.root as TabsContent
  const persistedRoot = persistedWrapper.tabs[0]!.content as SplitContent
  const rowFirstSizes = Array.from(
    { length: ROW_COUNT },
    (_, i) => (persistedRoot.children[i] as SplitContent).sizes[0]
  )
  for (const size of rowFirstSizes) expect(size).toBeCloseTo(rowFirstSizes[0]!, 2)
  expect(rowFirstSizes[0]).toBeGreaterThan(0.55) // moved from the 0.5 baseline
})

test('a member pushed to its minimum re-aligns once the drag reverses back past it', async ({
  page
}) => {
  await emitSettingsChange(page, { snapResizeSeparators: true })

  const columns = columnSeparators(page)
  const boxesBefore = await Promise.all(columns.map((sep) => requireBox(sep)))
  const containerWidth = (await requireBox(page.locator('.split-view').first())).width

  // Out far enough to push every row's left pane well past MIN_PANE_SIZE (5%),
  // then back to (near) the start without lifting: every row, including the
  // ones clamped at the extreme, should re-align rather than staying stuck.
  await dragSeparatorX(rowBoundarySeparator(page, 1), containerWidth * 0.4, 15)

  const boxesAfter = await Promise.all(columns.map((sep) => requireBox(sep)))
  for (const box of boxesAfter) {
    expect(box.x).toBeCloseTo(boxesAfter[0]!.x, 0)
  }
  expect(boxesAfter[0]!.x - boxesBefore[0]!.x).toBeCloseTo(15, 0)
})

test('dragging at a row boundary moves every aligned row identically when the setting is off', async ({
  page
}) => {
  // snapResizeSeparators defaults to true (src/shared/settings.ts) — turn it
  // off explicitly. Cluster mirroring doesn't check the setting (only
  // maybeSnap's snap-toward-alignment convenience does — see
  // discoverCluster's doc comment), so this should behave exactly like the
  // "moves every aligned row" test above, setting or no.
  await emitSettingsChange(page, { snapResizeSeparators: false })

  const columns = columnSeparators(page)
  const boxesBefore = await Promise.all(columns.map((sep) => requireBox(sep)))
  for (const box of boxesBefore) expect(box.x).toBeCloseTo(boxesBefore[0]!.x, 0)

  await dragSeparatorX(rowBoundarySeparator(page, 1), 120)

  const boxesAfter = await Promise.all(columns.map((sep) => requireBox(sep)))
  // All 4 rows move together — row2 and row3 are not natively hit-tested at
  // all (only root+row0+row1 are), so this only passes if cluster mirroring
  // ran despite the setting being off.
  for (const box of boxesAfter) {
    expect(box.x).toBeCloseTo(boxesAfter[0]!.x, 0)
    expect(box.x - boxesBefore[0]!.x).toBeGreaterThan(100)
  }
})

test('a row just outside the alignment margin does not join the cluster, even genuinely-aligned ones still do', async ({
  page
}) => {
  // Setting off throughout, so row3's nudge below (a couple px past
  // SEPARATOR_ALIGNMENT_THRESHOLD_PX) lands exactly where the mouse says —
  // maybeSnap's own (different, wider) 8px threshold would otherwise pull it
  // right back into alignment.
  await emitSettingsChange(page, { snapResizeSeparators: false })

  const columns = columnSeparators(page)
  const row3Before = await requireBox(columns[3]!)
  const midY = row3Before.y + row3Before.height / 2
  await page.mouse.move(row3Before.x, midY)
  await page.mouse.down()
  await page.mouse.move(row3Before.x + 7, midY)
  await page.mouse.up()
  const row3Nudged = await requireBox(columns[3]!)
  expect(row3Nudged.x - row3Before.x).toBeGreaterThan(5) // outside the 5px cluster margin
  expect(row3Nudged.x - row3Before.x).toBeLessThan(8) // but inside maybeSnap's unrelated 8px

  const boxesBefore = await Promise.all(columns.map((sep) => requireBox(sep)))

  await dragSeparatorX(rowBoundarySeparator(page, 1), 120)

  const boxesAfter = await Promise.all(columns.map((sep) => requireBox(sep)))
  // row0/row1 (native) and row2 (genuinely aligned) all move together.
  expect(boxesAfter[0]!.x - boxesBefore[0]!.x).toBeGreaterThan(100)
  expect(boxesAfter[1]!.x - boxesBefore[1]!.x).toBeGreaterThan(100)
  expect(boxesAfter[2]!.x - boxesBefore[2]!.x).toBeGreaterThan(100)
  // row3 — just outside the margin — is left behind.
  expect(boxesAfter[3]!.x).toBeCloseTo(boxesBefore[3]!.x, 0)
})

test.describe("a cluster member nested inside the primary drag's own reflowing pane", () => {
  // row0 = horizontal[row0Left(0.8875), row0Right(0.1125)] — row0Right is
  // deliberately narrow so a separator nested inside it can land within
  // SEPARATOR_ALIGNMENT_THRESHOLD_PX of row0Right's own left edge, which is
  // exactly where row0/row1's shared column separator sits.
  //   row0Right = vertical[row0RightTop, row0RightBottom]
  //   row0RightBottom = horizontal[X, Y]  <- the reflowing member
  // row1 = horizontal[row1Left(0.8875), row1Right(0.1125)], aligned with row0.
  //
  // Two MIN_PANE_SIZE floors compound here: row0Right can't shrink below 5%
  // of row0's own (full-viewport) width, and X can't shrink below 5% of
  // row0Right's *current* width — so the smallest X can land is ~5% of
  // row0Right's own 5%-of-viewport floor, a quantity that scales with
  // viewport width. At the default 1280px viewport that floor alone (~3.2px)
  // leaves next to no margin under the 5px cluster threshold once any
  // passive pre-discovery drift is added — this test.use narrows the
  // viewport specifically to open up real room (see the ratios above, sized
  // for 640px) without needing a razor-thin, flake-prone margin.
  function buildReflowFixture() {
    const row0RightBottom = createSplit('horizontal', [createLeaf('empty'), createLeaf('empty')], {
      id: 'row0-right-bottom',
      sizes: [0.5, 0.5]
    })
    const row0Right = createSplit('vertical', [createLeaf('empty'), row0RightBottom], {
      id: 'row0-right',
      sizes: [0.5, 0.5]
    })
    const row0 = createSplit('horizontal', [createLeaf('empty'), row0Right], {
      id: 'row0',
      sizes: [0.8875, 0.1125]
    })
    const row1 = createSplit('horizontal', [createLeaf('empty'), createLeaf('empty')], {
      id: 'row1',
      sizes: [0.8875, 0.1125]
    })
    return createSplit('vertical', [row0, row1], { id: 'root', sizes: [0.5, 0.5] })
  }

  const reflowRoot = buildReflowFixture()
  const reflowFirstLeafId = (reflowRoot.children[0] as SplitContent).children[0]!.id

  test.use({
    viewport: { width: 640, height: 480 },
    seed: {
      layout: { version: LAYOUT_VERSION, root: reflowRoot, activePaneId: reflowFirstLeafId }
    }
  })

  test('the nested member tracks the cursor even as its own container reflows', async ({
    page
  }) => {
    await emitSettingsChange(page, { snapResizeSeparators: true })

    // The root separator is the horizontal *line* between row0/row1 — a
    // full-width box whose own x is just 0, not the aligned column position.
    // The aligned column position is row0's (== row1's) own separator x.
    const rowBoundary = page.locator(
      '.split-separator[data-split-id="root"][data-separator-index="1"]'
    )
    const row0Column = page.locator(
      '.split-separator[data-split-id="row0"][data-separator-index="1"]'
    )
    const nestedMember = page.locator(
      '.split-separator[data-split-id="row0-right-bottom"][data-separator-index="1"]'
    )

    const targetX = (await requireBox(row0Column)).x

    // Drag the nested member's separator onto row0/row1's shared boundary —
    // row0Right is narrow enough that this lands within the snap threshold
    // even clamped at the nested split's own MIN_PANE_SIZE. Aim a couple px
    // past the target (matching split-resize.spec.ts's dragSeparatorTo
    // pattern) so the snap, not exact mouse placement, decides the landing.
    const memberBoxBefore = await requireBox(nestedMember)
    const my = memberBoxBefore.y + memberBoxBefore.height / 2
    await page.mouse.move(memberBoxBefore.x + memberBoxBefore.width / 2, my)
    await page.mouse.down()
    await page.mouse.move(targetX + 2, my, { steps: 10 })
    await page.mouse.up()
    // row0RightBottom's own MIN_PANE_SIZE floor (5% of row0Right's ~72px
    // width, ~3.6px) caps how close this can land — well short of
    // pixel-perfect, but still comfortably within
    // SEPARATOR_ALIGNMENT_THRESHOLD_PX (5px), which is what matters for
    // cluster discovery to pick it up below (a tighter bar than maybeSnap's
    // own, unrelated 8px).
    const alignedBox = await requireBox(nestedMember)
    expect(Math.abs(alignedBox.x - targetX)).toBeLessThan(5)

    // Now drag from the row0/row1 intersection (at the aligned column x, so
    // the native hit-test also grabs row0's and row1's own separators, not
    // just root's) — natively co-dragging root + row0 + row1, which
    // continuously shrinks row0Right's (and so row0RightBottom's) container
    // width for the whole gesture. row0Right's own ~72px width only leaves
    // ~40px of room before row0 hits its own MIN_PANE_SIZE, so this drag
    // (unlike the coarser cluster tests above) has to stay modest.
    const boundaryBox = await requireBox(rowBoundary)
    const y = boundaryBox.y + boundaryBox.height / 2
    const startX = targetX
    await page.mouse.move(startX, y)
    await page.mouse.down()
    // Cluster discovery only runs starting on this gesture's *second* tick
    // (wasCoDraggedLastTick — see separatorRegistry.ts), and row0RightBottom
    // passively drifts a little even before it's ever mirrored, simply
    // because its own container (row0Right) moves as row0's separator does.
    // Two small opening steps keep that pre-discovery drift inside
    // SEPARATOR_ALIGNMENT_THRESHOLD_PX so discovery still finds it, before
    // the real move that actually exercises reflow tracking.
    await page.mouse.move(startX + 1, y)
    await page.mouse.move(startX + 2, y)
    await page.mouse.move(startX + 25, y, { steps: 15 })
    await page.mouse.up()

    // The member started a few px off row0Column (its own MIN_PANE_SIZE
    // floor — see above), not exactly on it, so the invariant isn't
    // "converges to 0" but "that initial offset stays constant" — proving
    // the member tracked the primary's live delta rather than drifting as
    // its own (shrinking) container reflowed underneath it.
    const initialOffset = alignedBox.x - targetX

    const columnAfter = await requireBox(row0Column)
    const memberAfter = await requireBox(nestedMember)
    expect(columnAfter.x - targetX).toBeGreaterThan(18)
    // The nested member must have followed — not frozen at its pre-drag
    // position, and not drifted by anywhere near the amount a stale cached
    // container produces. This geometry is tight enough (row0Right is only
    // ~72px wide, most of it consumed by MIN_PANE_SIZE floors either side)
    // that even the fix carries a few px of residual float/measurement
    // slop — checked against the pre-fix behavior directly: reverting the
    // fresh-measurement change in mirrorClusterMembers back to caching
    // containerStart/containerLength at discovery time (as ClusterMember
    // once did) drifts this same drag noticeably more than the fix does.
    expect(Math.abs(memberAfter.x - columnAfter.x - initialOffset)).toBeLessThan(10)
  })
})
