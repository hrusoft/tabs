import Foundation
import TabsPluginSDK
import Testing

@testable import TabsCore

/// The control registry on its own: its pairs, its tombstones, what it tells
/// its observers.
@MainActor
@Suite struct PaneOwnershipTests {
    let ledger = PaneOwnership { _ in true }

    /// Every change the registry announces, in order.
    @MainActor final class Heard {
        var changes: [ControlChange] = []
        var controllers: [PaneID?] = []
    }

    private func listen() -> Heard {
        let heard = Heard()
        ledger.observe { heard.changes.append($0) }
        return heard
    }

    private func pair(_ controller: PaneID, _ controlled: PaneID) -> ControlPair {
        ControlPair(controller: controller, controlled: controlled)
    }

    @Test func enablingControlPairsTwoPanes() {
        let enabled = ledger.enableControl(of: "child", from: "shell")
        #expect(enabled)
        #expect(ledger.controller(of: "child") == "shell")
        #expect(ledger.isControlled("child"))
        #expect(!ledger.isControlled("shell"), "the controller isn't controlled")
        #expect(ledger.controlled(by: "shell") == ["child"])
        #expect(ledger.pairs == [pair("shell", "child")])
    }

    @Test func thePairsAreListedByControllerThenControlled() {
        ledger.enableControl(of: "b", from: "t2")
        ledger.enableControl(of: "c", from: "t1")
        ledger.enableControl(of: "a", from: "t1")
        #expect(ledger.pairs == [pair("t1", "a"), pair("t1", "c"), pair("t2", "b")])
        #expect(ledger.controlled(by: "t1") == ["a", "c"])
    }

    @Test func onlyOpenPanesTakePartAndNeverAPaneWithItself() {
        let ledger = PaneOwnership { ["shell", "child", "other"].contains($0) }
        let heard = Heard()
        ledger.observe { heard.changes.append($0) }
        let byItself = ledger.enableControl(of: "shell", from: "shell")
        let byAClosedPane = ledger.enableControl(of: "child", from: "gone")
        let ofAClosedPane = ledger.enableControl(of: "gone", from: "shell")
        #expect(!byItself)
        #expect(!byAClosedPane)
        #expect(!ofAClosedPane, "a pair for an id no open pane has would wait for whatever pane takes that id later")
        #expect(ledger.pairs.isEmpty)
        #expect(heard.changes.isEmpty)
        let ofAnOpenPane = ledger.enableControl(of: "child", from: "shell")
        #expect(ofAnOpenPane)
    }

    @Test func aPaneBeingMadeComesUnderControlBeforeItIsOpenFromAnOpenControllerOnly() {
        let ledger = PaneOwnership { $0 == "shell" }
        let fromAnOpenPane = ledger.enableControl(ofNewPane: "new", from: "shell")
        let fromAClosedPane = ledger.enableControl(ofNewPane: "other", from: "gone")
        #expect(fromAnOpenPane)
        #expect(!fromAClosedPane, "an agent whose terminal closed mid-verb gets no pane")
        #expect(ledger.pairs == [pair("shell", "new")])
    }

    @Test func aControlledPaneRefusesASecondControllerUntilTheFirstIsDisabled() {
        ledger.enableControl(of: "child", from: "t1")
        let heard = listen()
        let takenOver = ledger.enableControl(of: "child", from: "t2")
        #expect(!takenOver, "never taken over")
        #expect(ledger.controller(of: "child") == "t1")
        #expect(heard.changes.isEmpty)
        ledger.disableControl(of: "child", from: "t1")
        let handedOver = ledger.enableControl(of: "child", from: "t2")
        #expect(handedOver)
        #expect(ledger.controller(of: "child") == "t2")
        #expect(heard.changes == [.disabled(pair("t1", "child")), .enabled(pair("t2", "child"))])
    }

    @Test func enablingWhatIsAlreadySoChangesNothing() {
        ledger.enableControl(of: "child", from: "t1")
        let heard = listen()
        let again = ledger.enableControl(of: "child", from: "t1")
        #expect(again)
        #expect(heard.changes.isEmpty)
    }

    @Test func disablingEndsOnlyThatPairAndLeavesNoTombstone() {
        ledger.enableControl(of: "child", from: "t1")
        let heard = listen()
        ledger.disableControl(of: "child", from: "t2")
        #expect(ledger.controller(of: "child") == "t1", "another pane's pair is not its to end")
        ledger.disableControl(of: "child", from: "t1")
        #expect(!ledger.isControlled("child"))
        #expect(!ledger.wasClosed("child", by: "t1"), "the pane is still open: no tombstone")
        #expect(heard.changes == [.disabled(pair("t1", "child"))])
    }

    @Test func closingAControlledPaneRemembersWhoControlledItSoOnlyThatCallerIsToldItIsGone() {
        ledger.enableControl(of: "child", from: "shell")
        let heard = listen()
        ledger.paneClosed("child")
        #expect(ledger.controller(of: "child") == nil)
        #expect(ledger.wasClosed("child", by: "shell"))
        #expect(!ledger.wasClosed("child", by: "stranger"), "nobody else learns the pane ever was")
        #expect(!ledger.wasClosed("never", by: "shell"))
        #expect(heard.changes == [.disabled(pair("shell", "child"))])
    }

    @Test func closingAControllerFreesEveryPaneItControlledAndDropsItsTombstones() {
        ledger.enableControl(of: "a", from: "shell")
        ledger.enableControl(of: "b", from: "shell")
        ledger.enableControl(of: "c", from: "other")
        ledger.enableControl(of: "old", from: "shell")
        ledger.paneClosed("old")
        let heard = listen()
        ledger.paneClosed("shell")
        #expect(ledger.pairs == [pair("other", "c")])
        #expect(!ledger.wasClosed("a", by: "shell"), "a freed pane is still open: no tombstone")
        #expect(!ledger.wasClosed("old", by: "shell"), "nobody is left to ask about it")
        #expect(heard.changes == [.disabled(pair("shell", "a")), .disabled(pair("shell", "b"))])
    }

    @Test func closingAPaneThatIsBothEndsBothItsPairs() {
        ledger.enableControl(of: "middle", from: "top")
        ledger.enableControl(of: "bottom", from: "middle")
        let heard = listen()
        ledger.paneClosed("middle")
        #expect(ledger.pairs.isEmpty)
        #expect(ledger.wasClosed("middle", by: "top"))
        #expect(heard.changes == [.disabled(pair("top", "middle")), .disabled(pair("middle", "bottom"))])
    }

    @Test func closingAPaneInNoPairLeavesNoTrace() {
        let heard = listen()
        ledger.paneClosed("user-pane")
        #expect(!ledger.wasClosed("user-pane", by: "shell"))
        #expect(heard.changes.isEmpty)
    }

    @Test func anObserverReadsTheSettledRegistryAndACancelledOneHearsNothing() {
        let seen = Heard()
        let ledger = ledger
        let subscription = ledger.observe { change in
            seen.changes.append(change)
            seen.controllers.append(ledger.controller(of: change.pair.controlled))
        }
        ledger.enableControl(of: "child", from: "t1")
        ledger.disableControl(of: "child", from: "t1")
        ledger.enableControl(of: "child", from: "t2")
        #expect(seen.controllers == ["t1", nil, "t2"], "told once each change has landed")
        subscription.cancel()
        ledger.paneClosed("child")
        #expect(seen.changes.count == 3)
    }

    @Test func everyObserverHearsTheChangesInTheOrderTheyHappenedEvenOnesAnObserverMakes() {
        ledger.enableControl(of: "a", from: "shell")
        ledger.enableControl(of: "b", from: "shell")
        // The first observer hands a freed pane to a fallback as soon as it hears of it.
        let ledger = ledger
        ledger.observe { change in
            if case .disabled(let pair) = change, pair.controlled == "a" { ledger.enableControl(of: "a", from: "fallback") }
        }
        let heard = Heard()
        ledger.observe { change in
            heard.changes.append(change)
            heard.controllers.append(ledger.controller(of: change.pair.controlled))
        }
        ledger.paneClosed("shell")
        #expect(heard.changes == [.disabled(pair("shell", "a")), .disabled(pair("shell", "b")), .enabled(pair("fallback", "a"))])
        #expect(heard.controllers == ["fallback", nil, "fallback"], "the registry as it is now, already further along")
    }

    @Test func aHundredClosedPanesAreRememberedAndTheOldestGoFirst() {
        let limit = PaneOwnership.closedPaneMemory
        #expect(limit == 100)
        for index in 0...limit {
            ledger.enableControl(of: PaneID("p\(index)"), from: "shell")
            ledger.paneClosed(PaneID("p\(index)"))
        }
        #expect(!ledger.wasClosed("p0", by: "shell"), "the oldest was forgotten")
        #expect(ledger.wasClosed("p1", by: "shell"))
        #expect(ledger.wasClosed(PaneID("p\(limit)"), by: "shell"))
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
