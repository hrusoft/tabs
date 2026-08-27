import type { GraphRow } from '../shared/graph'

/**
 * One row's slice of the commit gutter, as an SVG.
 *
 * Per row rather than one overlay for the whole list, deliberately: the rows
 * are an ordinary scrolling list, so a single absolutely-positioned SVG would
 * have to be kept in sync with scroll position and row heights by hand, while
 * a small SVG inside each row scrolls because it *is* the row. The cost is one
 * extra element per commit, which at a 500-row page is nothing.
 *
 * All the thinking already happened in `assignLanes`
 * (src/plugins/gitTree/shared/graph.ts) — this only turns lane indices into
 * coordinates, which is why there is no logic here worth testing separately
 * from what it draws.
 */

/** Row height in px. The single source of truth: GitTreeRenderer publishes it to CSS as `--git-row-height`. */
export const ROW_HEIGHT = 24

/** Horizontal distance between lane centres. */
const LANE_WIDTH = 12

/**
 * The lane palette. These are content, not chrome — the same boundary
 * CLAUDE.md draws for the terminal's palette: fixed mid-tone hues chosen to
 * hold their own against both a near-black and a near-white background, not
 * derived from `--accent`, because deriving them would give shades of one hue
 * and the whole point is telling branches apart. They cycle by lane index.
 *
 * Owned here and published to CSS as `--git-lane-*` by GitTreeRenderer (the
 * way ROW_HEIGHT already is), so the cycle length below and the swatch count
 * in the stylesheet are one value and cannot drift apart.
 */
export const LANE_COLORS = ['#4f8cff', '#e0a44a', '#59b871', '#c76fd0', '#46bcc4', '#e0705a']

const RADIUS = 3.5

function laneX(lane: number): number {
  return lane * LANE_WIDTH + LANE_WIDTH / 2
}

function laneColor(lane: number): string {
  return `var(--git-lane-${lane % LANE_COLORS.length})`
}

/**
 * A line between two lanes across the row's full height, as a smooth S-curve.
 *
 * The control points sit at the row's vertical midpoint, so a line that
 * changes lane leaves and arrives vertically and bends in the middle — which
 * is what lets a branch merging in read as joining rather than as a stray
 * diagonal. When the two lanes are equal this degenerates to a straight
 * vertical line at no cost.
 */
function curve(fromLane: number, toLane: number, fromY: number, toY: number): string {
  const x1 = laneX(fromLane)
  const x2 = laneX(toLane)
  const mid = (fromY + toY) / 2
  return `M ${x1} ${fromY} C ${x1} ${mid}, ${x2} ${mid}, ${x2} ${toY}`
}

export function GitGraph({
  row,
  laneCount,
  selected
}: {
  row: GraphRow
  laneCount: number
  selected: boolean
}) {
  const width = Math.max(laneCount, 1) * LANE_WIDTH
  const centerY = ROW_HEIGHT / 2

  return (
    <svg
      className="git-graph"
      width={width}
      height={ROW_HEIGHT}
      viewBox={`0 0 ${width} ${ROW_HEIGHT}`}
      aria-hidden="true"
    >
      {/* Lines that pass this row by, drawn first so a commit's own edges and
          its dot always sit on top of an unrelated branch crossing behind. */}
      {row.through.map((lane) => (
        <path
          key={`through-${lane}`}
          d={curve(lane, lane, 0, ROW_HEIGHT)}
          fill="none"
          stroke={laneColor(lane)}
          strokeWidth={1.5}
        />
      ))}
      {row.incoming.map((from) => (
        <path
          key={`in-${from}`}
          d={curve(from, row.lane, 0, centerY)}
          fill="none"
          stroke={laneColor(from)}
          strokeWidth={1.5}
        />
      ))}
      {row.outgoing.map((to) => (
        <path
          key={`out-${to}`}
          d={curve(row.lane, to, centerY, ROW_HEIGHT)}
          fill="none"
          stroke={laneColor(to)}
          strokeWidth={1.5}
        />
      ))}
      {/* The dot is filled when this row is selected and hollow otherwise, so
          selection reads in the gutter as well as in the row's background —
          the gutter is where the eye already is when arrowing through. */}
      <circle
        cx={laneX(row.lane)}
        cy={centerY}
        r={RADIUS}
        fill={selected ? laneColor(row.lane) : 'var(--bg)'}
        stroke={laneColor(row.lane)}
        strokeWidth={1.5}
      />
    </svg>
  )
}
