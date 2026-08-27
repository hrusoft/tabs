import { describe, expect, it } from 'vitest'
import { assignLanes } from '../graph'
import type { Commit } from '../types'

/**
 * Lane assignment against hand-written graphs.
 *
 * These are the tests that matter most in this content type: the algorithm is
 * the only non-obvious logic in it, everything else is plumbing, and a subtly
 * wrong lane produces a picture that looks plausible and is a lie about the
 * history. So each case states the shape it is drawing in a comment, oldest
 * commit at the bottom, the way the pane renders it.
 *
 * Commits are given newest-first, which is what `git log` emits.
 */

/** A commit with only the fields lane assignment reads; the rest are noise here. */
function commit(hash: string, ...parents: string[]): Commit {
  return { hash, parents, author: 'A', date: '2026-01-01T00:00:00Z', refs: [], subject: hash }
}

describe('a linear history', () => {
  // c
  // |
  // b
  // |
  // a
  const graph = assignLanes([commit('c', 'b'), commit('b', 'a'), commit('a')])

  it('keeps every commit in one column', () => {
    expect(graph.rows.map((row) => row.lane)).toEqual([0, 0, 0])
    expect(graph.laneCount).toBe(1)
  })

  it('links each row to the next through the dot, with nothing passing by', () => {
    // The tip has nothing above it; every later row is entered by exactly the
    // line its child left behind.
    expect(graph.rows.map((row) => row.incoming)).toEqual([[], [0], [0]])
    expect(graph.rows.map((row) => row.outgoing)).toEqual([[0], [0], []])
    expect(graph.rows.every((row) => row.through.length === 0)).toBe(true)
  })

  it('leaves the root commit with no line below it', () => {
    expect(graph.rows[2]!.outgoing).toEqual([])
  })
})

describe('a fork', () => {
  // Two tips over a shared history: `c` and `d` both descend from `b`.
  //
  // c d
  // |/
  // b
  // |
  // a
  const graph = assignLanes([commit('c', 'b'), commit('d', 'b'), commit('b', 'a'), commit('a')])

  it('gives the second tip a lane of its own', () => {
    expect(graph.rows.map((row) => row.lane)).toEqual([0, 1, 0, 0])
    expect(graph.laneCount).toBe(2)
  })

  it('converges both branches into the commit they share', () => {
    // `b`'s row is entered by two lines — one from each child — and the dot
    // sits in the leftmost of them.
    expect(graph.rows[2]!.incoming).toEqual([0, 1])
    expect(graph.rows[2]!.lane).toBe(0)
  })

  it('draws the first tip past the second row rather than through its dot', () => {
    // `d`'s row has `c`'s line crossing it untouched, since `c` is waiting for
    // `b` and `d` is not on that line.
    expect(graph.rows[1]!.through).toEqual([0])
    expect(graph.rows[1]!.incoming).toEqual([])
  })

  it('is back to one lane by the root', () => {
    expect(graph.rows[3]!.lane).toBe(0)
    expect(graph.rows[3]!.through).toEqual([])
  })
})

describe('a merge', () => {
  // `m` merges `b` (its first parent) and `c`.
  //
  // m
  // |\
  // | c
  // b |
  // |/
  // a
  const graph = assignLanes([
    commit('m', 'b', 'c'),
    commit('c', 'a'),
    commit('b', 'a'),
    commit('a')
  ])

  it('leaves the merge commit by two lines, first parent in its own lane', () => {
    expect(graph.rows[0]!.lane).toBe(0)
    expect(graph.rows[0]!.outgoing).toEqual([0, 1])
  })

  it('places the second parent in the lane the merge opened for it', () => {
    // Given newest-first order `c` is reached before `b`, so it is the row
    // right under the merge — in lane 1, the one its edge was drawn to.
    expect(graph.rows[1]!.commit.hash).toBe('c')
    expect(graph.rows[1]!.lane).toBe(1)
    expect(graph.rows[1]!.incoming).toEqual([1])
    // And the first parent's line runs past it, untouched.
    expect(graph.rows[1]!.through).toEqual([0])
  })

  it('brings both sides back together at their common ancestor', () => {
    expect(graph.rows[3]!.commit.hash).toBe('a')
    expect(graph.rows[3]!.incoming).toEqual([0, 1])
    expect(graph.rows[3]!.lane).toBe(0)
  })

  it('never needs more than two columns', () => {
    expect(graph.laneCount).toBe(2)
  })
})

describe('a diamond', () => {
  // Two siblings fork from the same parent and later merge back together —
  // e.g. a branch merged into the line it forked from. Both `c` and `d` name
  // `a` as their *only* parent, so once `d` is processed two lanes end up
  // waiting for the identical hash `a`.
  //
  // m
  // |\
  // d c
  // |/
  // a
  const graph = assignLanes([
    commit('m', 'd', 'c'),
    commit('c', 'a'),
    commit('d', 'a'),
    commit('a')
  ])

  it('draws no line out of the row between the fork and its shared parent', () => {
    // `d`'s row has exactly one real edge below it — its own outgoing line —
    // and the sibling line still waiting for `a` must pass by untouched
    // rather than appear to merge into `d`'s lane.
    expect(graph.rows[2]!.commit.hash).toBe('d')
    expect(graph.rows[2]!.outgoing).toEqual([0])
    expect(graph.rows[2]!.through).toEqual([1])
  })

  it('brings both siblings back together at the shared parent', () => {
    expect(graph.rows[3]!.commit.hash).toBe('a')
    expect(graph.rows[3]!.incoming).toEqual([0, 1])
  })
})

describe('an octopus merge', () => {
  // Three parents at once, which git permits and most renderers get wrong.
  //
  // m
  // |\\
  // | |\
  // b c d
  //  \|/
  //   a
  const graph = assignLanes([
    commit('m', 'b', 'c', 'd'),
    commit('b', 'a'),
    commit('c', 'a'),
    commit('d', 'a'),
    commit('a')
  ])

  it('opens one lane per parent', () => {
    expect(graph.rows[0]!.outgoing).toEqual([0, 1, 2])
    expect(graph.laneCount).toBe(3)
  })

  it('lands each parent in the lane its edge pointed at', () => {
    expect(graph.rows.slice(1, 4).map((row) => [row.commit.hash, row.lane])).toEqual([
      ['b', 0],
      ['c', 1],
      ['d', 2]
    ])
  })

  it('collapses all three back into the shared root', () => {
    expect(graph.rows[4]!.incoming).toEqual([0, 1, 2])
    expect(graph.rows[4]!.lane).toBe(0)
    expect(graph.rows[4]!.outgoing).toEqual([])
  })
})

describe('multiple roots', () => {
  // Two histories with no commit in common — an orphan branch, e.g. a docs
  // branch created with `checkout --orphan`.
  //
  // b   d
  // |   |
  // a   c
  const graph = assignLanes([commit('b', 'a'), commit('a'), commit('d', 'c'), commit('c')])

  it('reuses the lane the first history freed rather than growing the gutter', () => {
    // `a` is a root, so its lane is released; `d` is the next tip and takes
    // the same column back. Two independent histories, one column.
    expect(graph.rows.map((row) => row.lane)).toEqual([0, 0, 0, 0])
    expect(graph.laneCount).toBe(1)
  })

  it('draws no line between the two histories', () => {
    // `a` ends its line and `d` starts a fresh one: nothing connects them.
    expect(graph.rows[1]!.outgoing).toEqual([])
    expect(graph.rows[2]!.incoming).toEqual([])
  })
})

describe('a lane freed mid-history', () => {
  // A short branch that ends at its own root while a longer one continues, so
  // the freed column is reused by a later tip rather than left as a gap.
  //
  // c t     <- t is a tip appearing after the branch b/x ended
  // | |
  // b |
  // | |
  // a x
  const graph = assignLanes([
    commit('c', 'b'),
    commit('x'),
    commit('b', 'a'),
    commit('t'),
    commit('a')
  ])

  it('hands the freed lane to the next tip', () => {
    // `x` is a root in lane 1; once it ends, `t` claims lane 1 again instead
    // of opening a third column.
    expect(graph.rows[1]!.commit.hash).toBe('x')
    expect(graph.rows[1]!.lane).toBe(1)
    expect(graph.rows[3]!.commit.hash).toBe('t')
    expect(graph.rows[3]!.lane).toBe(1)
    expect(graph.laneCount).toBe(2)
  })
})

describe('a truncated log', () => {
  // What `--max-count` leaves behind: the oldest commit shown still names a
  // parent, and that parent is never reached.
  const graph = assignLanes([commit('c', 'b'), commit('b', 'a')])

  it('still draws the dangling line out of the last row', () => {
    // The line has to leave the bottom edge — the history continues past the
    // page, and a lane stopping dead would read as a root commit.
    expect(graph.rows[1]!.outgoing).toEqual([0])
  })
})

describe('an empty log', () => {
  it('produces no rows and no gutter', () => {
    expect(assignLanes([])).toEqual({ rows: [], laneCount: 0 })
  })
})
