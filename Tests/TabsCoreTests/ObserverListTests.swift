import Foundation
import TabsPluginSDK
import Testing

@testable import TabsCore

/// The one list every observer registry keeps (core's and the SDK's `PluginSettings`): ordered,
/// queued delivery, safe to change from inside an observer.
@MainActor
@Suite struct ObserverListTests {
    @Test func observersHearEachValueInTheOrderTheyWereAdded() {
        let list = ObserverList<Int>()
        var heard: [String] = []
        let subscriptions = ["a", "b", "c"].map { name in list.add { heard.append("\(name)\($0)") } }
        list.notify(1)
        list.notify(2)
        #expect(heard == ["a1", "b1", "c1", "a2", "b2", "c2"])
        withExtendedLifetime(subscriptions) {}
    }

    @Test func aValueNotifiedDuringADeliveryWaitsUntilEveryoneHeardTheCurrentOne() {
        let list = ObserverList<Int>()
        var heard: [String] = []
        let first = list.add { value in
            heard.append("first \(value)")
            if value == 1 { list.notify(2) }
        }
        let second = list.add { heard.append("second \($0)") }
        list.notify(1)
        #expect(heard == ["first 1", "second 1", "first 2", "second 2"])
        withExtendedLifetime((first, second)) {}
    }

    @Test func severalValuesAtOnceAreAllHeardBeforeOneAnObserverNotifies() {
        let list = ObserverList<Int>()
        var heard: [Int] = []
        let first = list.add { if $0 == 1 { list.notify(3) } }
        let second = list.add { heard.append($0) }
        list.notify(each: [1, 2])
        #expect(heard == [1, 2, 3])
        withExtendedLifetime((first, second)) {}
    }

    @Test func anObserverAddedDuringADeliveryHearsOnlyLaterValues() {
        let list = ObserverList<Int>()
        var heard: [String] = []
        var added: [Subscription] = []
        let first = list.add { value in
            heard.append("first \(value)")
            if value == 1 { added.append(list.add { heard.append("added \($0)") }) }
        }
        list.notify(1)
        list.notify(2)
        #expect(heard == ["first 1", "first 2", "added 2"])
        withExtendedLifetime((first, added)) {}
    }

    @Test func anObserverCancelledDuringADeliveryHearsNothingMore() {
        let list = ObserverList<Int>()
        var heard: [String] = []
        var second: Subscription?
        let first = list.add { value in
            heard.append("first \(value)")
            second?.cancel()
        }
        second = list.add { heard.append("second \($0)") }
        list.notify(1)
        list.notify(2)
        #expect(heard == ["first 1", "first 2"], "not even the rest of the delivery it was cancelled in")
        #expect(list.count == 1)
        withExtendedLifetime(first) {}
    }

    @Test func aCancelledObserverHearsNothingAndCancellingTwiceIsHarmless() {
        let list = ObserverList<Int>()
        var heard: [Int] = []
        let subscription = list.add { heard.append($0) }
        list.notify(1)
        subscription.cancel()
        subscription.cancel()
        list.notify(2)
        #expect(heard == [1])
        #expect(subscription.isCancelled)
        #expect(list.count == 0)
    }

    @Test func droppingTheSubscriptionDoesNotCancelIt() {
        let list = ObserverList<Int>()
        var heard: [Int] = []
        _ = list.add { heard.append($0) }
        list.notify(1)
        #expect(heard == [1])
    }

    @Test func anObserverBoundToAnOwnerLastsAsLongAsTheOwner() {
        final class Owner { var heard: [Int] = [] }
        let list = ObserverList<Int>()
        var owner: Owner? = Owner()
        let kept = Owner()
        list.add(while: owner!) { owner, value in owner.heard.append(value) }
        list.add(while: kept) { owner, value in owner.heard.append(value) }
        list.notify(1)
        #expect(owner?.heard == [1])
        owner = nil
        list.notify(2)
        #expect(kept.heard == [1, 2])
        #expect(list.count == 1, "the gone owner's observer was dropped")
    }

    @Test func anObserverBoundToAnOwnerAddedDuringADeliveryIsKept() {
        final class Owner { var heard: [Int] = [] }
        let list = ObserverList<Int>()
        let owner = Owner()
        let first = list.add { value in
            if value == 1 { list.add(while: owner) { owner, value in owner.heard.append(value) } }
        }
        list.notify(1)
        list.notify(2)
        #expect(owner.heard == [2])
        withExtendedLifetime(first) {}
    }

    @Test func removingEveryObserverSilencesEvenTheRestOfADelivery() {
        let list = ObserverList<Int>()
        var heard: [String] = []
        let first = list.add { value in
            heard.append("first \(value)")
            list.removeAll()
        }
        let second = list.add { heard.append("second \($0)") }
        list.notify(1)
        list.notify(2)
        #expect(heard == ["first 1"])
        #expect(list.count == 0)
        withExtendedLifetime((first, second)) {}
    }
}
