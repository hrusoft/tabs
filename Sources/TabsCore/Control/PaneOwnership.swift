import Foundation
import TabsPluginSDK

/// Which pane controls which. A pane a control verb created belongs to the
/// pane whose shell ran the verb, and only its owner may target it.
///
/// **Ownership is per app run, never persisted, never expired.** A pane an agent
/// created stays readable and scriptable by it until the pane closes,
/// including after the user has navigated it somewhere else by hand — an
/// accepted product tradeoff the skill's own SKILL.md states plainly. It ends
/// only when the pane is gone: the caller's `close-pane`, or the user closing
/// it by hand.
///
/// **The refusal is uniform, and the tombstone changes only its wording.** A
/// pane id is a persisted layout id, not a per-boot credential, so answering an
/// unowned id differently depending on whether such a pane exists would leak
/// pane liveness to a caller with no claim on it. A closed pane's tombstone
/// keeps the boundary where it was and only tells the one caller who already
/// knew the pane existed — because it created it — that it is gone. Everyone
/// else still gets `not the owner of this pane`.
///
/// Pure bookkeeping: the pane runtime raises and withdraws the `controlled`
/// signal around it.
@MainActor
package final class PaneOwnership {
    /// How many closed panes are remembered; the oldest go first, the right
    /// end to lose (a caller most likely follows up on the pane it just
    /// closed), and the cap only stops a loop that opens and closes panes
    /// from growing this without bound.
    package static let closedPaneMemory = 100

    private var ownerOf: [PaneID: PaneID] = [:]
    private var closedBy: [PaneID: PaneID] = [:]
    /// Tombstones, oldest first.
    private var closedOrder: [PaneID] = []
    /// The callers of each plugin's control verbs that are still running, with
    /// how many are: the only panes a plugin may name as a new pane's controller.
    private var running: [PluginID: [PaneID: Int]] = [:]

    package init() {}

    /// `pane` was created by, and now belongs to, `owner`.
    package func grant(_ pane: PaneID, to owner: PaneID) {
        ownerOf[pane] = owner
    }

    /// The pane that owns `pane`, if it has an owner.
    package func owner(of pane: PaneID) -> PaneID? { ownerOf[pane] }

    package func isOwned(_ pane: PaneID) -> Bool { ownerOf[pane] != nil }

    /// Every owned pane.
    package var ownedPanes: [PaneID] { Array(ownerOf.keys) }

    /// `pane` is gone: its ledger entry ends and its owner is remembered, so a
    /// later request for it can be told it is *gone*. Returns whether it had
    /// an owner. Only for a pane that is really gone (a failed close must not
    /// strand a live pane as unownable).
    @discardableResult
    package func release(_ pane: PaneID) -> Bool {
        guard let owner = ownerOf.removeValue(forKey: pane) else { return false }
        if closedBy.updateValue(owner, forKey: pane) == nil {
            closedOrder.append(pane)
            // One insertion can only push it one over: at most one goes.
            if closedOrder.count > Self.closedPaneMemory { closedBy[closedOrder.removeFirst()] = nil }
        }
        return true
    }

    /// `pane` never opened (it was refused a place): it leaves the ledger
    /// without a trace.
    package func forget(_ pane: PaneID) {
        ownerOf[pane] = nil
    }

    /// Whether `caller` created `pane` and it has since closed.
    package func wasClosed(_ pane: PaneID, by caller: PaneID) -> Bool { closedBy[pane] == caller }

    /// Forgets everything (a test reset). Verbs still running are not.
    package func reset() {
        ownerOf.removeAll()
        closedBy.removeAll()
        closedOrder.removeAll()
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
