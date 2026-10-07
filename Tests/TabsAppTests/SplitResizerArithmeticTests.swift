import Testing

@testable import Tabs
@testable import TabsCore

/// A separator drag's arithmetic without a window (`SplitResizer.adjustLayoutByDelta`): sizes in
/// percent, the panes on the shrinking side giving way from the separator outward, each down to
/// 5%. The drag itself, its cursor, snapping and crossings are `UITests.SplitResize`'.
@MainActor
@Suite struct SplitResizerArithmeticTests {
    private let third = 100.0 / 3

    /// Moves the separator before pane `separator` by `delta` percent.
    private func adjust(_ delta: Double, _ sizes: [Double], at separator: Int) -> [Double] {
        SplitResizer.adjustLayoutByDelta(
            delta: delta, initial: sizes, prev: sizes, pivots: (separator - 1, separator), minSize: Tree.minPaneSize * 100)
    }

    private func near(_ a: [Double], _ b: [Double]) -> Bool { a.count == b.count && zip(a, b).allSatisfy { abs($0 - $1) < 0.01 } }

    @Test func aPaneNeverGoesBelowFivePercentAndThePushCarriesOn() {
        let thirds = [third, third, third]
        #expect(near(adjust(10, thirds, at: 1), [third + 10, third - 10, third]), "a move within reach")
        #expect(near(adjust(65.9, thirds, at: 1), [90, 5, 5]), "B stops at 5%, then C does")
        #expect(near(adjust(-33, thirds, at: 1), [5, third + (third - 5), third]), "A stops at 5%: nothing beyond it")
        #expect(near(adjust(-90, thirds, at: 2), [5, 5, 90]), "the other way across both, as far as they go")
        #expect(adjust(0, thirds, at: 1) == thirds)
    }

    @Test func aMoveWithNothingLeftToGiveChangesNothing() {
        let pinned = [5.0, 95.0]
        #expect(adjust(-10, pinned, at: 1) == pinned)
    }
}
