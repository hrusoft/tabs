import Foundation
import TabsPluginSDK

/// Core's event bus. Only core declares channels and only core publishes;
/// plugins subscribe through their own `PluginEvents`, which tags every
/// subscription with its owner.
///
/// - A channel carries the one payload type it was declared with. Subscribing
///   to an undeclared channel, or with another payload type, is refused (the
///   plugin's context records why) rather than silently never firing.
/// - Events arrive in the order they were published, for every subscriber.
///   An event published while another is being delivered — a handler opened
///   or focused a pane — waits until every subscriber has had the first, so
///   no subscriber sees a newer event before an older one.
@MainActor
package final class EventHub {
    private struct Handler {
        let token: Int
        let owner: PluginID?
        let call: @MainActor (Any) -> Void
    }

    private var handlers: [String: [Handler]] = [:]
    private var payloadTypes: [String: (id: ObjectIdentifier, name: String)] = [:]
    private var nextToken = 0
    private var pending: [@MainActor () -> Void] = []
    private var isDelivering = false

    package init() {}

    /// Declares one of core's channels and its payload type.
    package func declare<Payload>(_ channel: EventChannel<Payload>) {
        precondition(payloadTypes[channel.id] == nil, "\(channel.id) declared twice")
        payloadTypes[channel.id] = (ObjectIdentifier(Payload.self), String(reflecting: Payload.self))
    }

    /// nil if `channel` is declared with `Payload`, otherwise why not.
    package func problem<Payload>(with channel: EventChannel<Payload>) -> String? {
        guard let declared = payloadTypes[channel.id] else { return "no channel \(channel.id) is declared" }
        return declared.id == ObjectIdentifier(Payload.self)
            ? nil : "channel \(channel.id) carries \(declared.name), not \(String(reflecting: Payload.self))"
    }

    /// nil (subscribing to nothing) when the channel isn't declared with `Payload`.
    package func subscribe<Payload>(
        _ channel: EventChannel<Payload>, owner: PluginID?, _ handler: @escaping @MainActor (Payload) -> Void
    ) -> Subscription? {
        if let problem = problem(with: channel) {
            Log.plugins.fault("refused subscription by \(owner?.rawValue ?? "core", privacy: .public): \(problem, privacy: .public)")
            return nil
        }
        nextToken += 1
        let token = nextToken
        handlers[channel.id, default: []].append(
            Handler(token: token, owner: owner) { payload in
                if let payload = payload as? Payload { handler(payload) }
            })
        return Subscription { [weak self] in
            self?.handlers[channel.id]?.removeAll { $0.token == token }
        }
    }

    /// Delivers to everyone subscribed when delivery starts, in subscription
    /// order — after any event still being delivered.
    package func publish<Payload>(_ channel: EventChannel<Payload>, _ payload: Payload) {
        if let problem = problem(with: channel) {
            assertionFailure(problem)
            Log.core.fault("refused publish: \(problem, privacy: .public)")
            return
        }
        pending.append { [weak self] in
            for handler in self?.handlers[channel.id] ?? [] { handler.call(payload) }
        }
        guard !isDelivering else { return }
        isDelivering = true
        defer { isDelivering = false }
        while !pending.isEmpty { pending.removeFirst()() }
    }

    package func subscriberCount(channelID: String, owner: PluginID? = nil) -> Int {
        (handlers[channelID] ?? []).filter { owner == nil || $0.owner == owner }.count
    }
}
