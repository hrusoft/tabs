import Foundation
import TabsPluginSDK

/// One control link: `controller` drives `controlled`.
package struct ControlPair: Hashable, Sendable {
    package let controller: PaneID
    package let controlled: PaneID

    package init(controller: PaneID, controlled: PaneID) {
        self.controller = controller
        self.controlled = controlled
    }
}

/// What changed in the registry, told to its observers once it has settled.
package enum ControlChange: Equatable, Sendable {
    case enabled(ControlPair)
    case disabled(ControlPair)

    package var pair: ControlPair {
        switch self {
        case .enabled(let pair), .disabled(let pair): pair
        }
    }
}

/// Which pane controls which: the one place control is enabled, disabled,
/// listed and ended. Only a pane's controller may target it.
///
/// - A pane may control any number of panes, and is controlled by at most one,
///   never itself. Control is never taken over: while a pane has a controller,
///   enabling another is refused until the first is disabled, so an agent never
///   loses a pane in the middle of its work by someone else's call.
/// - Both panes are open. The one exception is a pane `PaneRuntime.openPane`
///   is making (`enableControl(ofNewPane:from:)`), so its first load already
///   knows; it ends that pair itself if the pane never opens.
/// - Control carries no further: a controller drives its own panes, never
///   theirs, so two panes may even control each other.
/// - **Closing a pane ends every pair it is in, on either side.** The panes a
///   closed controller drove are nobody's from then on. Only
///   `PaneRuntime.detach` says a pane closed.
/// - Every change is told to every observer, in the order the changes
///   happened: the `controlled` cue is one (`PaneRuntime`), and anything else
///   that follows control subscribes the same way rather than being called by
///   hand.
/// - Control is checked as each request arrives (`ControlPlane.dispatch`): a
///   request already running when control ends finishes.
/// - **Per app run, never persisted, never expired.** A pane an agent created
///   stays readable and scriptable by it — including after the user has
///   navigated it somewhere else by hand, an accepted product tradeoff the
///   skill's own SKILL.md states plainly — until one of the two closes or
///   control is disabled.
///
/// **The refusal is uniform, and the tombstone changes only its wording.** A
/// pane id is a persisted layout id, not a per-boot credential, so answering an
/// unowned id differently depending on whether such a pane exists would leak
/// pane liveness to a caller with no claim on it. A closed pane's tombstone
/// keeps the boundary where it was and only tells the one caller who already
/// knew the pane existed — because it controlled it — that it is gone. Everyone
/// else still gets `not the owner of this pane`.
@MainActor
package final class PaneOwnership {
    /// How many closed panes are remembered; the oldest go first, the right
    /// end to lose (a caller most likely follows up on the pane it just
    /// closed), and the cap only stops a loop that opens and closes panes
    /// from growing this without bound.
    package static let closedPaneMemory = 100

    /// Whether a pane is open now: only open panes take part in control.
    private let isOpen: @MainActor (PaneID) -> Bool

    private var controllerOf: [PaneID: PaneID] = [:]
    private var closedBy: [PaneID: PaneID] = [:]
    /// Tombstones, oldest first.
    private var closedOrder: [PaneID] = []
    /// The callers of each plugin's control verbs that are still running, with
    /// how many are: the only panes a plugin may name as a new pane's controller.
    private var running: [PluginID: [PaneID: Int]] = [:]
    private let observers = ObserverList<ControlChange>()

    /// - Parameter isOpen: whether a pane is open now (the pane runtime's answer).
    package init(isOpen: @escaping @MainActor (PaneID) -> Bool) {
        self.isOpen = isOpen
    }

    // MARK: Changing control

    /// `controller` controls `controlled` from now on. Whether it does
    /// (true too if it already did); refused for a pane another pane controls
    /// (disable that first), a pane controlling itself, or a pane that isn't
    /// open.
    @discardableResult
    package func enableControl(of controlled: PaneID, from controller: PaneID) -> Bool {
        isOpen(controlled) && enable(controlled, from: controller)
    }

    /// `enableControl` for a pane being made, before its plugin builds it:
    /// only the controller is open yet. `PaneRuntime.openPane`'s alone, which
    /// disables it again if the pane never opens.
    @discardableResult
    package func enableControl(ofNewPane pane: PaneID, from controller: PaneID) -> Bool {
        enable(pane, from: controller)
    }

    private func enable(_ controlled: PaneID, from controller: PaneID) -> Bool {
        if let current = controllerOf[controlled] { return current == controller }
        guard controlled != controller, isOpen(controller) else { return false }
        controllerOf[controlled] = controller
        notify([.enabled(ControlPair(controller: controller, controlled: controlled))])
        return true
    }

    /// `controller` no longer controls `controlled` (nothing if it didn't).
    /// The pane is still open, so no tombstone: its former controller is
    /// refused like anyone else.
    package func disableControl(of controlled: PaneID, from controller: PaneID) {
        guard controllerOf[controlled] == controller else { return }
        controllerOf[controlled] = nil
        notify([.disabled(ControlPair(controller: controller, controlled: controlled))])
    }

    /// `pane` is gone: every pair it is in ends. If it was controlled, its
    /// controller is remembered, so a later request for it can be told it is
    /// *gone*; if it controlled others, they are free, and the tombstones it
    /// held go too (nobody is left to ask). `PaneRuntime.detach`'s alone: on a
    /// pane still open it would leave a tombstone and strand the pane.
    package func paneClosed(_ pane: PaneID) {
        var ended: [ControlPair] = []
        if let controller = controllerOf.removeValue(forKey: pane) {
            ended.append(ControlPair(controller: controller, controlled: pane))
            remember(pane, closedBy: controller)
        }
        for controlled in controlled(by: pane) {
            controllerOf[controlled] = nil
            ended.append(ControlPair(controller: pane, controlled: controlled))
        }
        if closedBy.values.contains(pane) {
            closedBy = closedBy.filter { $0.value != pane }
            closedOrder.removeAll { closedBy[$0] == nil }
        }
        notify(ended.map(ControlChange.disabled))
    }

    private func remember(_ pane: PaneID, closedBy controller: PaneID) {
        guard closedBy.updateValue(controller, forKey: pane) == nil else { return }
        closedOrder.append(pane)
        // One insertion can only push it one over: at most one goes.
        if closedOrder.count > Self.closedPaneMemory { closedBy[closedOrder.removeFirst()] = nil }
    }

    // MARK: Reading

    /// The pane that controls `pane`, if one does.
    package func controller(of pane: PaneID) -> PaneID? { controllerOf[pane] }

    package func isControlled(_ pane: PaneID) -> Bool { controllerOf[pane] != nil }

    /// The panes `controller` controls, by id.
    package func controlled(by controller: PaneID) -> [PaneID] {
        controllerOf.compactMap { $0.value == controller ? $0.key : nil }.sorted()
    }

    /// Every pair, by controller then controlled.
    package var pairs: [ControlPair] {
        controllerOf.map { ControlPair(controller: $0.value, controlled: $0.key) }
            .sorted { ($0.controller, $0.controlled) < ($1.controller, $1.controlled) }
    }

    /// Whether `caller` controlled `pane` and it has since closed.
    package func wasClosed(_ pane: PaneID, by caller: PaneID) -> Bool { closedBy[pane] == caller }

    // MARK: Observing

    /// `handler` hears every change from now on, in the order the changes
    /// happened, once the registry has settled. It may read or change the
    /// registry from there: a change it makes waits until everyone has heard
    /// the one being told, so the registry may already be further along than
    /// the change it hears — read it as it is now.
    @discardableResult
    package func observe(_ handler: @escaping @MainActor (ControlChange) -> Void) -> Subscription {
        observers.add(handler)
    }

    /// Tells every observer every change, oldest first: a change made while
    /// one is being told joins the queue, so all observers hear one order.
    private func notify(_ changes: [ControlChange]) {
        observers.notify(each: changes)
    }

    // MARK: Who may name a controller

    /// A control verb of `plugin` is running for `caller`.
    package func verbBegan(of plugin: PluginID, for caller: PaneID) {
        running[plugin, default: [:]][caller, default: 0] += 1
    }

    package func verbEnded(of plugin: PluginID, for caller: PaneID) {
        guard var callers = running[plugin], let count = callers[caller] else { return }
        callers[caller] = count > 1 ? count - 1 : nil
        running[plugin] = callers.isEmpty ? nil : callers
    }

    /// Whether `plugin` is answering a control verb for `caller` right now.
    package func isRunning(_ plugin: PluginID, for caller: PaneID) -> Bool { running[plugin]?[caller] != nil }
}
