import Foundation
import TabsPluginSDK
import Testing

@testable import TabsCore

/// The ownership ledger on its own: `ownerOf` and `closedBy`.
@MainActor
@Suite struct PaneOwnershipTests {
    let ledger = PaneOwnership()

    @Test func aPaneBelongsToTheCallerThatMadeIt() {
        ledger.grant("child", to: "shell")
        #expect(ledger.owner(of: "child") == "shell")
        #expect(ledger.isOwned("child"))
        #expect(ledger.owner(of: "other") == nil)
        #expect(!ledger.isOwned("other"))
        #expect(ledger.ownedPanes == ["child"])
    }

    @Test func releasingRemembersWhoOwnedItSoOnlyThatCallerIsToldItIsGone() {
        ledger.grant("child", to: "shell")
        #expect(ledger.release("child"))
        #expect(ledger.owner(of: "child") == nil)
        #expect(ledger.wasClosed("child", by: "shell"))
        #expect(!ledger.wasClosed("child", by: "stranger"), "nobody else learns the pane ever was")
        #expect(!ledger.wasClosed("never", by: "shell"))
    }

    @Test func releasingAPaneNobodyOwnsLeavesNoTrace() {
        #expect(!ledger.release("user-pane"))
        #expect(!ledger.wasClosed("user-pane", by: "shell"))
    }

    @Test func aPaneThatNeverOpenedIsForgottenWithoutATombstone() {
        ledger.grant("child", to: "shell")
        ledger.forget("child")
        #expect(!ledger.isOwned("child"))
        #expect(!ledger.wasClosed("child", by: "shell"))
    }

    @Test func aHundredClosedPanesAreRememberedAndTheOldestGoFirst() {
        let limit = PaneOwnership.closedPaneMemory
        #expect(limit == 100)
        for index in 0...limit {
            ledger.grant(PaneID("p\(index)"), to: "shell")
            ledger.release(PaneID("p\(index)"))
        }
        #expect(!ledger.wasClosed("p0", by: "shell"), "the oldest was forgotten")
        #expect(ledger.wasClosed("p1", by: "shell"))
        #expect(ledger.wasClosed(PaneID("p\(limit)"), by: "shell"))
    }

    @Test func resettingForgetsEverything() {
        ledger.grant("a", to: "shell")
        ledger.grant("b", to: "shell")
        ledger.release("b")
        ledger.reset()
        #expect(ledger.ownedPanes.isEmpty)
        #expect(!ledger.wasClosed("b", by: "shell"))
    }

    @Test func aVerbInFlightIsCountedPerPluginAndCaller() {
        #expect(!ledger.isRunning("web", for: "shell"))
        ledger.verbBegan(of: "web", for: "shell")
        ledger.verbBegan(of: "web", for: "shell")
        #expect(ledger.isRunning("web", for: "shell"))
        #expect(!ledger.isRunning("web", for: "other"))
        #expect(!ledger.isRunning("elsewhere", for: "shell"))
        ledger.verbEnded(of: "web", for: "shell")
        #expect(ledger.isRunning("web", for: "shell"), "one still runs")
        ledger.verbEnded(of: "web", for: "shell")
        #expect(!ledger.isRunning("web", for: "shell"))
        ledger.verbEnded(of: "web", for: "shell")
        #expect(!ledger.isRunning("web", for: "shell"), "an extra end is harmless")
    }
}
