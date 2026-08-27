import { describe, expect, it } from 'vitest'
import {
  applyBoundaryAtPixel,
  boundaryPixelPosition,
  computeSnappedSizes,
  SEPARATOR_SNAP_THRESHOLD_PX
} from '../separatorSnap'

describe('computeSnappedSizes', () => {
  it('snaps when a candidate is within the threshold', () => {
    const result = computeSnappedSizes({
      sizes: [0.5, 0.5],
      index: 1,
      containerStart: 0,
      containerLength: 1000,
      candidates: [505]
    })
    expect(result).not.toBeNull()
    expect(result?.[0]).toBeCloseTo(0.505)
    expect(result?.[1]).toBeCloseTo(0.495)
  })

  it('returns null when no candidate is within the threshold', () => {
    const result = computeSnappedSizes({
      sizes: [0.5, 0.5],
      index: 1,
      containerStart: 0,
      containerLength: 1000,
      candidates: [600]
    })
    expect(result).toBeNull()
  })

  it('picks the nearest candidate among several within range', () => {
    const result = computeSnappedSizes({
      sizes: [0.5, 0.5],
      index: 1,
      containerStart: 0,
      containerLength: 1000,
      candidates: [520, 504, 493]
    })
    expect(result?.[0]).toBeCloseTo(0.504)
  })

  it('only adjusts the two panes adjacent to the dragged separator', () => {
    const result = computeSnappedSizes({
      sizes: [0.3, 0.3, 0.4],
      index: 1,
      containerStart: 0,
      containerLength: 1000,
      candidates: [306]
    })
    expect(result?.[0]).toBeCloseTo(0.306)
    expect(result?.[1]).toBeCloseTo(0.294)
    expect(result?.[2]).toBeCloseTo(0.4)
  })

  it('rejects a snap that would push a pane below MIN_PANE_SIZE', () => {
    const result = computeSnappedSizes({
      sizes: [0.052, 0.948],
      index: 1,
      containerStart: 0,
      containerLength: 1000,
      candidates: [45] // 7px away, within threshold, but lands the left pane at 0.045
    })
    expect(result).toBeNull()
  })

  it('is right at the edge of the threshold', () => {
    const atThreshold = computeSnappedSizes({
      sizes: [0.5, 0.5],
      index: 1,
      containerStart: 0,
      containerLength: 1000,
      candidates: [500 + SEPARATOR_SNAP_THRESHOLD_PX]
    })
    expect(atThreshold).not.toBeNull()

    const justPast = computeSnappedSizes({
      sizes: [0.5, 0.5],
      index: 1,
      containerStart: 0,
      containerLength: 1000,
      candidates: [500 + SEPARATOR_SNAP_THRESHOLD_PX + 1]
    })
    expect(justPast).toBeNull()
  })

  it('returns null for a degenerate container or out-of-range index', () => {
    expect(
      computeSnappedSizes({
        sizes: [0.5, 0.5],
        index: 1,
        containerStart: 0,
        containerLength: 0,
        candidates: [500]
      })
    ).toBeNull()
    expect(
      computeSnappedSizes({
        sizes: [0.5, 0.5],
        index: 0,
        containerStart: 0,
        containerLength: 1000,
        candidates: [500]
      })
    ).toBeNull()
    expect(
      computeSnappedSizes({
        sizes: [0.5, 0.5],
        index: 2,
        containerStart: 0,
        containerLength: 1000,
        candidates: [500]
      })
    ).toBeNull()
  })
})

describe('applyBoundaryAtPixel', () => {
  it('moves the boundary to exactly targetPx, regardless of distance', () => {
    const result = applyBoundaryAtPixel({
      sizes: [0.5, 0.5],
      index: 1,
      containerStart: 0,
      containerLength: 1000,
      targetPx: 700 // far past SEPARATOR_SNAP_THRESHOLD_PX — no threshold here
    })
    expect(result?.[0]).toBeCloseTo(0.7)
    expect(result?.[1]).toBeCloseTo(0.3)
  })

  it('only adjusts the two panes adjacent to the boundary', () => {
    const result = applyBoundaryAtPixel({
      sizes: [0.3, 0.3, 0.4],
      index: 1,
      containerStart: 0,
      containerLength: 1000,
      targetPx: 360
    })
    expect(result?.[0]).toBeCloseTo(0.36)
    expect(result?.[1]).toBeCloseTo(0.24)
    expect(result?.[2]).toBeCloseTo(0.4)
  })

  it('rejects a move that would push a pane below MIN_PANE_SIZE', () => {
    const result = applyBoundaryAtPixel({
      sizes: [0.5, 0.5],
      index: 1,
      containerStart: 0,
      containerLength: 1000,
      targetPx: 10
    })
    expect(result).toBeNull()
  })

  it('returns null for a degenerate container or out-of-range index', () => {
    expect(
      applyBoundaryAtPixel({
        sizes: [0.5, 0.5],
        index: 1,
        containerStart: 0,
        containerLength: 0,
        targetPx: 500
      })
    ).toBeNull()
    expect(
      applyBoundaryAtPixel({
        sizes: [0.5, 0.5],
        index: 0,
        containerStart: 0,
        containerLength: 1000,
        targetPx: 500
      })
    ).toBeNull()
    expect(
      applyBoundaryAtPixel({
        sizes: [0.5, 0.5],
        index: 2,
        containerStart: 0,
        containerLength: 1000,
        targetPx: 500
      })
    ).toBeNull()
  })

  it('is the inverse of boundaryPixelPosition: applying at the current position is a no-op', () => {
    const sizes = [0.3, 0.3, 0.4]
    const containerStart = 0
    const containerLength = 1000
    const index = 2
    const currentPx = boundaryPixelPosition({ sizes, index, containerStart, containerLength })
    const result = applyBoundaryAtPixel({
      sizes,
      index,
      containerStart,
      containerLength,
      targetPx: currentPx
    })
    expect(result?.[0]).toBeCloseTo(sizes[0]!)
    expect(result?.[1]).toBeCloseTo(sizes[1]!)
    expect(result?.[2]).toBeCloseTo(sizes[2]!)
  })
})

describe('boundaryPixelPosition', () => {
  it('computes the pixel position of a boundary from ratios and container geometry', () => {
    expect(
      boundaryPixelPosition({
        sizes: [0.3, 0.7],
        index: 1,
        containerStart: 0,
        containerLength: 1000
      })
    ).toBeCloseTo(300)
    expect(
      boundaryPixelPosition({
        sizes: [0.3, 0.3, 0.4],
        index: 2,
        containerStart: 0,
        containerLength: 1000
      })
    ).toBeCloseTo(600)
  })

  it('accounts for a non-zero container start', () => {
    expect(
      boundaryPixelPosition({
        sizes: [0.5, 0.5],
        index: 1,
        containerStart: 200,
        containerLength: 1000
      })
    ).toBeCloseTo(700)
  })
})
