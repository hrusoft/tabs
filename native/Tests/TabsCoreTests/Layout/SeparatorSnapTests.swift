import Foundation
import Testing

@testable import TabsCore

/// Separator snapping — ported from the Electron app's
/// src/shared/model/__tests__/separatorSnap.test.ts
/// (`computeSnappedSizes` is `snappedSizes`, `applyBoundaryAtPixel` is
/// `applyBoundary`, `boundaryPixelPosition` is `boundaryPosition`).
@Suite struct SeparatorSnapTests {
    static func snapped(_ sizes: [Double], index: Int = 1, start: Double = 0, length: Double = 1000, candidates: [Double]) -> [Double]? {
        SeparatorSnap.snappedSizes(sizes: sizes, index: index, containerStart: start, containerLength: length, candidates: candidates)
    }

    static func applied(_ sizes: [Double], index: Int = 1, start: Double = 0, length: Double = 1000, target: Double) -> [Double]? {
        SeparatorSnap.applyBoundary(sizes: sizes, index: index, containerStart: start, containerLength: length, target: target)
    }

    @Suite struct ComputeSnappedSizes {
        @Test("snaps when a candidate is within the threshold")
        func snaps() {
            let result = snapped([0.5, 0.5], candidates: [505])
            #expect(result != nil)
            #expect(isClose(result?[safe: 0], 0.505))
            #expect(isClose(result?[safe: 1], 0.495))
        }

        @Test("returns null when no candidate is within the threshold")
        func none() {
            #expect(snapped([0.5, 0.5], candidates: [600]) == nil)
        }

        @Test("picks the nearest candidate among several within range")
        func nearest() {
            #expect(isClose(snapped([0.5, 0.5], candidates: [520, 504, 493])?[safe: 0], 0.504))
        }

        @Test("only adjusts the two panes adjacent to the dragged separator")
        func adjacentOnly() {
            let result = snapped([0.3, 0.3, 0.4], candidates: [306])
            #expect(isClose(result?[safe: 0], 0.306))
            #expect(isClose(result?[safe: 1], 0.294))
            #expect(isClose(result?[safe: 2], 0.4))
        }

        @Test("rejects a snap that would push a pane below MIN_PANE_SIZE")
        func belowMinimum() {
            // 7px away, within the threshold, but lands the left pane at 0.045.
            #expect(snapped([0.052, 0.948], candidates: [45]) == nil)
        }

        @Test("is right at the edge of the threshold")
        func edgeOfThreshold() {
            #expect(snapped([0.5, 0.5], candidates: [500 + SeparatorSnap.snapThreshold]) != nil)
            #expect(snapped([0.5, 0.5], candidates: [500 + SeparatorSnap.snapThreshold + 1]) == nil)
        }

        @Test("returns null for a degenerate container or out-of-range index")
        func degenerate() {
            #expect(snapped([0.5, 0.5], length: 0, candidates: [500]) == nil)
            #expect(snapped([0.5, 0.5], index: 0, candidates: [500]) == nil)
            #expect(snapped([0.5, 0.5], index: 2, candidates: [500]) == nil)
        }
    }

    @Suite struct ApplyBoundaryAtPixel {
        @Test("moves the boundary to exactly targetPx, regardless of distance")
        func exact() {
            // Far past the snap threshold — there is no threshold here.
            let result = applied([0.5, 0.5], target: 700)
            #expect(isClose(result?[safe: 0], 0.7))
            #expect(isClose(result?[safe: 1], 0.3))
        }

        @Test("only adjusts the two panes adjacent to the boundary")
        func adjacentOnly() {
            let result = applied([0.3, 0.3, 0.4], target: 360)
            #expect(isClose(result?[safe: 0], 0.36))
            #expect(isClose(result?[safe: 1], 0.24))
            #expect(isClose(result?[safe: 2], 0.4))
        }

        @Test("rejects a move that would push a pane below MIN_PANE_SIZE")
        func belowMinimum() {
            #expect(applied([0.5, 0.5], target: 10) == nil)
        }

        @Test("returns null for a degenerate container or out-of-range index")
        func degenerate() {
            #expect(applied([0.5, 0.5], length: 0, target: 500) == nil)
            #expect(applied([0.5, 0.5], index: 0, target: 500) == nil)
            #expect(applied([0.5, 0.5], index: 2, target: 500) == nil)
        }

        @Test("is the inverse of boundaryPixelPosition: applying at the current position is a no-op")
        func inverse() {
            let sizes = [0.3, 0.3, 0.4]
            let current = SeparatorSnap.boundaryPosition(sizes: sizes, index: 2, containerStart: 0, containerLength: 1000)
            let result = applied(sizes, index: 2, target: current)
            #expect(isClose(result?[safe: 0], sizes[0]))
            #expect(isClose(result?[safe: 1], sizes[1]))
            #expect(isClose(result?[safe: 2], sizes[2]))
        }
    }

    @Suite struct BoundaryPixelPosition {
        @Test("computes the pixel position of a boundary from ratios and container geometry")
        func position() {
            #expect(isClose(SeparatorSnap.boundaryPosition(sizes: [0.3, 0.7], index: 1, containerStart: 0, containerLength: 1000), 300))
            #expect(
                isClose(SeparatorSnap.boundaryPosition(sizes: [0.3, 0.3, 0.4], index: 2, containerStart: 0, containerLength: 1000), 600))
        }

        @Test("accounts for a non-zero container start")
        func offset() {
            #expect(isClose(SeparatorSnap.boundaryPosition(sizes: [0.5, 0.5], index: 1, containerStart: 200, containerLength: 1000), 700))
        }
    }
}
