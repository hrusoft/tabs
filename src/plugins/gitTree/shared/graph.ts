import type { Commit } from './types'

/**
 * Lane assignment: turning a flat list of commits into the columns and lines
 * that make it read as a DAG rather than as a chronological list.
 *
 * Pure, and in src/shared for that reason — no DOM, no React, no Electron, so
 * the whole of the interesting logic in this content type is unit-testable
 * against hand-written graphs (see __tests__/graph.test.ts) rather than only
 * through a rendered pane.
 *
 * ## The model
 *
 * A row is drawn as a box. Lines enter through its **top edge** at lane
 * positions and leave through its **bottom edge** at lane positions; the
 * commit's own dot sits at `lane`, vertically centred. Three kinds of line
 * exist and they are kept apart because they are drawn differently:
 *
 * - `incoming` — top edge → the dot. One per lane that was waiting for this
 *   commit. Several means several children converge here.
 * - `outgoing` — the dot → bottom edge. One per parent. Two or more is a
 *   merge; zero is a root commit.
 * - `through` — top edge → bottom edge, untouched by this commit. These are
 *   the other branches, passing by.
 *
 * Splitting them this way means the renderer never has to work out whether a
 * line should stop at the dot, and a row with no lines through it costs no
 * geometry at all.
 *
 * ## The algorithm
 *
 * One pass, with an array of *open lanes*. Lane `i` holds the hash it is
 * waiting to see, or `undefined` if it is free. For each commit:
 *
 *  1. Find every lane waiting for this hash. The dot goes in the leftmost
 *     (so a merge visually lands on the branch that has been running
 *     longest); the rest are released. A commit no lane was waiting for is a
 *     branch tip and claims the leftmost free lane.
 *  2. The first parent inherits the dot's own lane, which is what keeps a
 *     linear history in one straight column.
 *  3. Each further parent takes a lane already waiting for it if one exists
 *     (so two branches merging back together converge rather than doubling
 *     up), otherwise the leftmost free lane.
 *
 * Reusing freed lanes rather than always appending is what keeps the gutter
 * narrow; the cost is that a line can jump columns when a branch ends, which
 * is what every `git log --graph`-style renderer does too.
 *
 * Commits are consumed in the order given. Feed it `--date-order` (or
 * `--topo-order`) output: this makes no attempt to sort, because a renderer
 * silently reordering history is worse than one that draws exactly what it
 * was handed.
 */

/** One commit's row, with everything needed to draw its slice of the gutter. */
export interface GraphRow {
  commit: Commit
  /** Column the commit's dot sits in. */
  lane: number
  /** Top-edge lanes of the lines converging into the dot. */
  incoming: number[]
  /** Bottom-edge lanes of the lines leaving the dot, one per parent, in git's parent order. */
  outgoing: number[]
  /**
   * Lanes carrying lines that cross this row without touching the dot — same
   * lane at the top edge and the bottom, since nothing placed during this
   * commit ever writes to an already-occupied lane (see the comment where
   * this is built).
   */
  through: number[]
}

interface CommitGraph {
  rows: GraphRow[]
  /**
   * How many columns the gutter needs — the widest any row got, so the whole
   * list shares one gutter width and the rows' subjects line up. 1 for a
   * purely linear history, 0 only for an empty graph.
   */
  laneCount: number
}

/** Leftmost free slot, appending if every lane is busy. */
function claimLane(lanes: (string | undefined)[]): number {
  const free = lanes.indexOf(undefined)
  if (free !== -1) return free
  lanes.push(undefined)
  return lanes.length - 1
}

/** Drops trailing free lanes so the gutter shrinks back once a branch ends. */
function trim(lanes: (string | undefined)[]): void {
  while (lanes.length > 0 && lanes[lanes.length - 1] === undefined) lanes.pop()
}

export function assignLanes(commits: readonly Commit[]): CommitGraph {
  // Lane i is waiting for lanes[i]; undefined means free.
  const lanes: (string | undefined)[] = []
  const rows: GraphRow[] = []
  let laneCount = 0

  for (const commit of commits) {
    // 1. Where this commit's dot goes, and which lanes were waiting for it.
    const waiting: number[] = []
    for (let i = 0; i < lanes.length; i++) {
      if (lanes[i] === commit.hash) waiting.push(i)
    }
    const lane = waiting.length > 0 ? waiting[0]! : claimLane(lanes)

    // The lanes still open *around* this commit, captured before the parents
    // are placed: anything here that isn't one of `waiting` is a line passing
    // this row by. Nothing below ever writes to one of these slots — parent
    // placement only touches `waiting` indices (excluded here by
    // construction) and freshly claimed `undefined` slots (also excluded,
    // since a passing lane is by definition still occupied) — so each one is
    // both the line's top-edge and bottom-edge lane, unchanged, and doubles
    // as `through` directly. Resolving by hash instead of by index used to be
    // the bug here: when two lanes end up waiting for the identical hash
    // (e.g. two siblings that share a parent), `indexOf` can't tell them
    // apart and silently merges one lane's line into the other's.
    const through: number[] = []
    for (let i = 0; i < lanes.length; i++) {
      const hash = lanes[i]
      if (hash !== undefined && hash !== commit.hash) through.push(i)
    }

    // Every lane that was waiting is consumed here; the dot's own lane is
    // re-filled by the first parent below (or released with the rest if this
    // is a root commit).
    for (const index of waiting) lanes[index] = undefined

    // 2 & 3. Place the parents. The first inherits the dot's lane so linear
    // history stays in one column; the rest converge onto an existing lane
    // where one is already waiting for them, else claim a free one.
    const outgoing: number[] = []
    for (const [index, parent] of commit.parents.entries()) {
      if (index === 0) {
        lanes[lane] = parent
        outgoing.push(lane)
        continue
      }
      const existing = lanes.indexOf(parent)
      if (existing !== -1) {
        outgoing.push(existing)
        continue
      }
      const claimed = claimLane(lanes)
      lanes[claimed] = parent
      outgoing.push(claimed)
    }

    trim(lanes)
    rows.push({ commit, lane, incoming: waiting, outgoing, through })

    // The widest point of this row: the dot, every line's ends, and whatever
    // stayed open underneath it.
    let widest = lane
    for (const index of waiting) widest = Math.max(widest, index)
    for (const index of outgoing) widest = Math.max(widest, index)
    for (const index of through) widest = Math.max(widest, index)
    widest = Math.max(widest, lanes.length - 1)
    laneCount = Math.max(laneCount, widest + 1)
  }

  return { rows, laneCount }
}
