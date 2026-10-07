import Foundation

/// One of core's typed event streams. Only core defines channels and only
/// core publishes: plugins listen to core, never to each other.
public struct EventChannel<Payload: Sendable>: Hashable, Sendable {
    public let id: String
    package init(_ id: String) { self.id = id }
}

@MainActor
public protocol EventBus: AnyObject {
    /// The subscription lives until cancelled or until the plugin deactivates
    /// (or fails to activate) — dropping the returned value does not cancel it.
    @discardableResult
    func subscribe<Payload>(_ channel: EventChannel<Payload>, _ handler: @escaping @MainActor (Payload) -> Void) -> Subscription
}

/// A cancellable registration (event handler, settings observer).
@MainActor
public final class Subscription {
    private var onCancel: (@MainActor () -> Void)?

    package init(onCancel: @escaping @MainActor () -> Void) {
        self.onCancel = onCancel
    }

    public var isCancelled: Bool { onCancel == nil }

    public func cancel() {
        let action = onCancel
        onCancel = nil
        action?()
    }
}

public struct PaneEvent: Hashable, Sendable {
    public let paneID: PaneID
    public let windowID: WindowID
    public let contentType: ContentTypeID?

    public init(paneID: PaneID, windowID: WindowID, contentType: ContentTypeID?) {
        self.paneID = paneID
        self.windowID = windowID
        self.contentType = contentType
    }
}

public extension EventChannel where Payload == PaneEvent {
    static var paneOpened: Self { Self("tabs.paneOpened") }
    static var paneClosed: Self { Self("tabs.paneClosed") }
    static var activePaneChanged: Self { Self("tabs.activePaneChanged") }
    /// A pane moved to another window; the event carries the new one.
    static var paneMoved: Self { Self("tabs.paneMoved") }

    /// A pane offered a new value for `capability`, or withdrew it; read it
    /// with `Workspace.capability(_:of:)`.
    static func capabilityChanged<Value>(_ capability: PaneCapability<Value>) -> Self {
        Self("tabs.capabilityChanged.\(capability.id)")
    }
}
