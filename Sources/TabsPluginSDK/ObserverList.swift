import Foundation

/// The observers of one kind of change, and its delivery: every registry of observers in core
/// and the SDK keeps one, so they all deliver alike (core's `EventHub`, whose queue spans all its
/// channels, delivers the same way with its own).
///
/// - Observers hear values in the order they were added.
/// - Delivery is queued: a value notified while another is being delivered (an observer changed
///   something itself) waits until every observer has heard the current one, so all observers
///   hear the same values in the same order.
/// - An observer added during a delivery hears only later values; one cancelled during a
///   delivery hears nothing more, not even the rest of the current one.
@MainActor
package final class ObserverList<Value> {
    @MainActor
    private final class Entry {
        /// False: the observer is gone (its owner was released), so it's dropped.
        let deliver: @MainActor (Value) -> Bool
        var isActive = true

        init(_ deliver: @escaping @MainActor (Value) -> Bool) {
            self.deliver = deliver
        }
    }

    private var entries: [Entry] = []
    private var queued: [Value] = []
    private var isDelivering = false

    package nonisolated init() {}

    /// How many observers there are now.
    package var count: Int { entries.count }

    /// `handler` hears every value notified from now on, until the subscription is cancelled.
    package func add(_ handler: @escaping @MainActor (Value) -> Void) -> Subscription {
        let entry = Entry { value in
            handler(value)
            return true
        }
        entries.append(entry)
        return Subscription { [weak self] in self?.remove(entry) }
    }

    /// `handler` hears every value notified from now on, for as long as `owner` lives: the first
    /// value after it's gone drops it.
    package func add<Owner: AnyObject>(while owner: Owner, _ handler: @escaping @MainActor (Owner, Value) -> Void) {
        entries.append(
            Entry { [weak owner] value in
                guard let owner else { return false }
                handler(owner, value)
                return true
            })
    }

    /// Tells every observer `value`, after any value still being delivered.
    package func notify(_ value: Value) {
        notify(each: [value])
    }

    /// Tells every observer each of `values` in turn, after any value still being delivered.
    package func notify(each values: [Value]) {
        queued.append(contentsOf: values)
        guard !isDelivering else { return }
        isDelivering = true
        defer { isDelivering = false }
        while !queued.isEmpty {
            let value = queued.removeFirst()
            // The observers as delivery starts; each is asked again whether it's still there.
            for entry in entries where entry.isActive {
                if !entry.deliver(value) { remove(entry) }
            }
        }
    }

    /// Drops every observer: none hears anything more, not even the rest of a delivery under way.
    package func removeAll() {
        for entry in entries { entry.isActive = false }
        entries.removeAll()
    }

    private func remove(_ entry: Entry) {
        entry.isActive = false
        entries.removeAll { $0 === entry }
    }
}
