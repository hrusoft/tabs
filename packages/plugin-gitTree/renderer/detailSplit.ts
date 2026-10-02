import { ROW_HEIGHT } from './GitGraph'

/**
 * How a git tree pane divides its body between the commit list (above) and
 * the detail panel (below) — the model behind `DetailDivider`, kept pure so
 * the snapping and clamping rules are testable without a layout engine.
 *
 * The split lives in the leaf's own config (`detailFraction`,
 * `detailCollapsed`) rather than component state. The body remounts on a
 * directory change, a branch-scope change and a pane move, so anything less
 * durable would snap back to the default on each of those, not just on a
 * relaunch.
 */

/** The detail panel's share of the body in a pane whose divider has never been dragged — the fixed 60/40 this pane always had. */
export const DEFAULT_DETAIL_FRACTION = 0.4

/** The commit list never gets dragged below three rows. */
export const LIST_MIN_HEIGHT = 3 * ROW_HEIGHT

/**
 * The detail panel's smallest open height. Dragging it below half of this
 * collapses it; between half and all of it, it holds here — the snap that
 * makes "drag it to the bottom" a gesture rather than a precise aim.
 */
export const DETAIL_MIN_HEIGHT = 60

export interface DetailSplit {
  /** The detail panel's share of the body height while open, strictly between 0 and 1. */
  fraction: number
  collapsed: boolean
}

/**
 * The split a pane's config asks for. Persisted values are checked rather than
 * trusted — a hand-edited or stale layout file is the ordinary way to get a
 * fraction that would lay out as nothing, or as everything.
 */
export function readDetailSplit(config: Record<string, unknown>): DetailSplit {
  const fraction = config.detailFraction
  return {
    fraction:
      typeof fraction === 'number' && Number.isFinite(fraction) && fraction > 0 && fraction < 1
        ? fraction
        : DEFAULT_DETAIL_FRACTION,
    collapsed: config.detailCollapsed === true
  }
}

/**
 * The split for a drag that would give the detail panel `detailHeight` pixels
 * of a `bodyHeight`-pixel body. Collapsing keeps `previous.fraction`, so the
 * last open size is never lost to a collapse.
 *
 * The upper bound goes through `max` because a body shorter than both
 * minimums together would otherwise make the range inverted — the details
 * keep their minimum and the list gives way, rather than either going
 * negative.
 */
export function resolveDetailDrag(
  detailHeight: number,
  bodyHeight: number,
  previous: DetailSplit
): DetailSplit {
  // A body with no height has nothing to divide (a pane hidden mid-gesture).
  if (bodyHeight <= 0) return previous
  if (detailHeight < DETAIL_MIN_HEIGHT / 2) return { fraction: previous.fraction, collapsed: true }
  const upper = Math.max(DETAIL_MIN_HEIGHT, bodyHeight - LIST_MIN_HEIGHT)
  const height = Math.min(Math.max(detailHeight, DETAIL_MIN_HEIGHT), upper)
  // Capped just short of the whole body: `readDetailSplit` rejects 1, so a
  // value it would refuse must never be what a drag saves.
  return { fraction: Math.min(height / bodyHeight, 0.99), collapsed: false }
}
