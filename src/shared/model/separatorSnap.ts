import { MIN_PANE_SIZE } from './tree'

/** Pixel distance within which a dragged separator snaps to another's position. */
export const SEPARATOR_SNAP_THRESHOLD_PX = 8

/**
 * Pixel distance within which two separators are considered already aligned
 * for cluster-mirroring purposes (see SplitRenderer.tsx's discoverCluster) —
 * deliberately tighter than, and independent of, SEPARATOR_SNAP_THRESHOLD_PX.
 * The snap-toward-alignment convenience (computeSnappedSizes) is a distinct,
 * opt-in feature gated by the snapResizeSeparators setting; carrying already-
 * aligned separators along together when one of them is dragged is not —
 * it's judged purely on current geometry, on or off.
 */
export const SEPARATOR_ALIGNMENT_THRESHOLD_PX = 5

/**
 * What every calculation here needs: one split's current division, and where
 * that split sits on screen along its own resize axis. Each exported function
 * takes this plus whatever else it specifically needs.
 */
interface BoundaryInput {
  /** Current ratios for every child of the split, summing to 1. */
  sizes: number[]
  /** Index of the boundary in question; a move adjusts sizes[index - 1] and sizes[index] only. */
  index: number
  /** Pixel offset of the split's container leading edge (left for a horizontal split, top for vertical). */
  containerStart: number
  /** Pixel length of the split's container along its resize axis (width for horizontal, height for vertical). */
  containerLength: number
}

interface SeparatorSnapInput extends BoundaryInput {
  /** Pixel positions of other same-orientation separators elsewhere in the layout. */
  candidates: number[]
}

interface BoundaryAtPixelInput extends BoundaryInput {
  /** The pixel position the boundary should end up at. */
  targetPx: number
}

/** The fraction of the container that comes before boundary `index`. */
function boundaryRatioOf(sizes: number[], index: number): number {
  return sizes.slice(0, index).reduce((sum, size) => sum + size, 0)
}

/** The pixel position boundary `index` currently sits at, given `sizes` and the container's geometry. */
export function boundaryPixelPosition({
  sizes,
  index,
  containerStart,
  containerLength
}: BoundaryInput): number {
  return containerStart + boundaryRatioOf(sizes, index) * containerLength
}

/**
 * The sizes array with boundary `index` moved to land exactly at `targetPx`
 * — or null when the container/index are invalid, or when doing so would
 * push either adjacent pane below MIN_PANE_SIZE (the model would just repair
 * it back on commit anyway, per resizeSplit/normalizeSizes, so a move that
 * can't be honored is the same as no move). Unlike computeSnappedSizes, this
 * has no notion of "close enough" — the caller has already decided the
 * target.
 */
export function applyBoundaryAtPixel({
  sizes,
  index,
  containerStart,
  containerLength,
  targetPx
}: BoundaryAtPixelInput): number[] | null {
  if (containerLength <= 0 || index < 1 || index >= sizes.length) return null

  const boundaryRatio = boundaryRatioOf(sizes, index)
  const targetRatio = (targetPx - containerStart) / containerLength
  const delta = targetRatio - boundaryRatio
  const next = [...sizes]
  next[index - 1]! += delta
  next[index]! -= delta
  if (next[index - 1]! < MIN_PANE_SIZE || next[index]! < MIN_PANE_SIZE) return null
  return next
}

/**
 * The sizes array to apply instead of the live drag's own, when the dragged
 * separator's current pixel position lands within SEPARATOR_SNAP_THRESHOLD_PX
 * of one of `candidates` — or null when nothing is close enough, or when
 * snapping would push either adjacent pane below MIN_PANE_SIZE (see
 * applyBoundaryAtPixel).
 */
export function computeSnappedSizes({
  sizes,
  index,
  containerStart,
  containerLength,
  candidates
}: SeparatorSnapInput): number[] | null {
  if (containerLength <= 0 || index < 1 || index >= sizes.length) return null

  const currentPx = boundaryPixelPosition({ sizes, index, containerStart, containerLength })

  let target: number | null = null
  let bestDist = SEPARATOR_SNAP_THRESHOLD_PX
  for (const candidate of candidates) {
    const dist = Math.abs(candidate - currentPx)
    if (dist <= bestDist) {
      bestDist = dist
      target = candidate
    }
  }
  if (target === null) return null

  return applyBoundaryAtPixel({ sizes, index, containerStart, containerLength, targetPx: target })
}
