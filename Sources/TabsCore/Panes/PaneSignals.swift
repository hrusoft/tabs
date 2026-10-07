import Foundation
import QuartzCore
import TabsPluginSDK

/// A kind of pane signal as core keeps it: the declaration and who made it
/// (nil: core).
package struct SignalKind {
    package let owner: PluginID?
    package let value: PaneSignalContribution

    package var id: String { value.id }
}

/// One signal on one pane, and when it went up (in `CACurrentMediaTime`'s
/// clock): its pulse runs from then, so the icon and the outline — and a
/// view built later, after a move — breathe together.
package struct RaisedSignal: Equatable, Sendable {
    package let id: String
    package let since: TimeInterval
}

/// A signal a pane shows: its kind, and when it went up.
package typealias ShownSignal = (kind: SignalKind, signal: RaisedSignal)

/// What the signals ask of the rest of core: the layout engine, which knows
/// the windows and asks the renderer which one has focus.
@MainActor
package protocol PaneSignalHost: AnyObject {
    /// The user is looking at `pane`: it is its window's active pane (exactly:
    /// a tab group being active doesn't count for the leaves in it) and that
    /// window has the focus.
    func isLookedAt(_ pane: PaneID) -> Bool
    /// Whether the window holding `pane` has the focus (false: in none).
    func isWindowFocused(holding pane: PaneID) -> Bool
    /// The signals on these panes changed.
    func signalsDidChange(on panes: Set<PaneID>)
    /// Asks the user to come back to the app (the Dock icon bounces once).
    func requestUserAttention()
}

/// Which panes carry which signals: one mechanism for every kind any plugin
/// (or core) declares.
///
/// - Raising: an `.untilSeen` kind is dropped while its setting is off, or
///   while the user is looking at the pane; a kind that requests attention
///   bounces the Dock while the pane's window isn't focused, a repeat
///   included; raising what a pane already carries changes nothing else.
/// - Seeing: the pane becoming its window's active pane, or its window
///   gaining focus while it's active, clears its `.untilSeen` signals.
/// - A signal ends with its pane, and follows it everywhere else — across
///   windows too.
/// - A kind's setting off hides what's up without clearing it (the host
///   hears of the panes whose signals it hides or shows again).
@MainActor
package final class PaneSignals {
    package weak var host: (any PaneSignalHost)?
    /// The clock `since` is read from (tests replace it).
    package var clock: () -> TimeInterval = { CACurrentMediaTime() }

    private let registry: ContributionRegistry
    private let plugins: PluginHost
    private let settings: SettingsStore
    /// Kinds core declared itself (in the app only `controlled`, which is
    /// always last; the bell's stand-in in tests and the visual comparison).
    private var coreKinds: [PaneSignalContribution] = [ControlledSignal.kind]
    private var raised: [PaneID: [RaisedSignal]] = [:]
    /// The kinds in order, as of a contribution generation (plugins' ranks are
    /// fixed once they load; core's declarations reset it).
    private var catalog: Catalog?
    /// The switches off as last told: a change redraws the panes it concerns.
    private var disabled: Set<String>
    private var settingsSubscription: Subscription?

    private struct Catalog {
        let generation: Int
        let kinds: [SignalKind]
        /// Each kind's place in `kinds`, by id.
        let index: [String: Int]
    }

    package init(registry: ContributionRegistry, plugins: PluginHost, settings: SettingsStore) {
        self.registry = registry
        self.plugins = plugins
        self.settings = settings
        disabled = Set(settings.panes.disabledSignals)
        settingsSubscription = settings.observePanes { [weak self] panes in self?.switchesDidChange(Set(panes.disabledSignals)) }
    }

    // MARK: Kinds

    /// Declares a kind of core's own, after every plugin's and before
    /// `controlled`, which stays last. The app declares none besides that one.
    package func declare(_ kind: PaneSignalContribution) {
        precondition(self.kind(kind.id) == nil, "\(kind.id) declared twice")
        if let problem = CoreExtensionPoints.problem(with: kind) { preconditionFailure("\(kind.id): \(problem)") }
        coreKinds.insert(kind, at: coreKinds.count - 1)
        catalog = nil
    }

    /// Every kind, in order: plugins' in UI order, each in registration order,
    /// then core's. Icons are shown in this order; the outline is the last one's.
    package var kinds: [SignalKind] { currentCatalog.kinds }

    package func kind(_ id: String) -> SignalKind? {
        let catalog = currentCatalog
        return catalog.index[id].map { catalog.kinds[$0] }
    }

    private var currentCatalog: Catalog {
        if let catalog, catalog.generation == registry.generation { return catalog }
        let contributed = registry.contributions(to: .paneSignals).enumerated()
            .sorted { a, b in
                let ra = plugins.rank(of: a.element.owner)
                let rb = plugins.rank(of: b.element.owner)
                return ra != rb ? ra < rb : a.offset < b.offset
            }
            .map { SignalKind(owner: $0.element.owner, value: $0.element.value) }
        let kinds = contributed + coreKinds.map { SignalKind(owner: nil, value: $0) }
        let index = Dictionary(kinds.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { first, _ in first })
        let built = Catalog(generation: registry.generation, kinds: kinds, index: index)
        catalog = built
        return built
    }

    /// The kinds whose switch Settings ▸ Panes & Tabs shows: core's and those
    /// of plugins the user hasn't disabled (like their settings pages).
    package var settingKinds: [SignalKind] {
        kinds.filter { kind in kind.owner.map { plugins.record(for: $0)?.userEnabled == true } ?? true }
    }

    /// Whether the kind's switch is on (Settings ▸ Panes & Tabs).
    package func isEnabled(_ id: String) -> Bool { !settings.panes.disabledSignals.contains(id) }

    /// Switches flipped: the panes carrying those kinds show or hide them.
    private func switchesDidChange(_ now: Set<String>) {
        let flipped = now.symmetricDifference(disabled)
        guard !flipped.isEmpty else { return }
        disabled = now
        let affected = Set(raised.filter { $0.value.contains { flipped.contains($0.id) } }.keys)
        if !affected.isEmpty { host?.signalsDidChange(on: affected) }
    }

    // MARK: Raising and withdrawing

    /// `owner` (nil: core) puts `signal` on `pane`. A plugin may raise only
    /// its own kinds; core, any. Returns whether the pane now carries it.
    @discardableResult
    package func raise(_ signal: PaneSignal, on pane: PaneID, by owner: PluginID?) -> Bool {
        guard let kind = kind(signal.id) else {
            refuse("raised \(signal.id), which no plugin declared", on: pane, by: owner)
            return false
        }
        if let owner, kind.owner != owner {
            refuse("raised \(signal.id), which is \(kind.owner.map { "\($0)'s" } ?? "core's"), not its own", on: pane, by: owner)
            return false
        }
        let enabled = isEnabled(kind.id)
        let seenKind = kind.value.lifetime == .untilSeen
        // An attention signal the user has switched off is dropped outright:
        // not kept for later, no Dock bounce (`ctx.bell.ring`'s gate).
        if seenKind && !enabled { return false }
        if kind.value.requestsAttention && enabled && host?.isWindowFocused(holding: pane) != true {
            host?.requestUserAttention()
        }
        // The pane the user is looking at doesn't need flagging (a completion
        // beep in the pane being typed in).
        if seenKind && host?.isLookedAt(pane) == true { return false }
        if raised[pane]?.contains(where: { $0.id == kind.id }) == true { return true }
        raised[pane, default: []].append(RaisedSignal(id: kind.id, since: clock()))
        host?.signalsDidChange(on: [pane])
        return true
    }

    /// Takes `signal` off `pane`. A plugin may withdraw only its own kinds.
    package func withdraw(_ signal: PaneSignal, from pane: PaneID, by owner: PluginID?) {
        if let owner, let kind = kind(signal.id), kind.owner != owner {
            refuse("withdrew \(signal.id), which isn't its own", on: pane, by: owner)
            return
        }
        remove(on: pane) { $0.id == signal.id }
    }

    /// The user looked at `pane`: its `.untilSeen` signals clear.
    package func seen(_ pane: PaneID) {
        remove(on: pane) { kind($0.id)?.value.lifetime != .untilWithdrawn }
    }

    /// The pane is gone: so are its signals.
    package func paneClosed(_ pane: PaneID) {
        remove(on: pane) { _ in true }
    }

    /// Drops the signals of every pane not in `panes` (they left the layout).
    package func retain(only panes: Set<PaneID>) {
        for pane in raised.keys where !panes.contains(pane) { paneClosed(pane) }
    }

    private func remove(on pane: PaneID, where drop: (RaisedSignal) -> Bool) {
        guard let current = raised[pane] else { return }
        let kept = current.filter { !drop($0) }
        guard kept.count != current.count else { return }
        raised[pane] = kept.isEmpty ? nil : kept
        host?.signalsDidChange(on: [pane])
    }

    private func refuse(_ what: String, on pane: PaneID, by owner: PluginID?) {
        let log = owner.map(Log.plugin) ?? Log.core
        log.fault("pane \(pane.rawValue, privacy: .public) \(what, privacy: .public); ignored")
    }

    // MARK: Reading

    /// Everything on `pane`, shown or not, in kind order.
    package func raised(on pane: PaneID) -> [RaisedSignal] {
        guard let signals = raised[pane] else { return [] }
        let index = currentCatalog.index
        return signals.sorted { (index[$0.id] ?? .max) < (index[$1.id] ?? .max) }
    }

    /// What `pane` shows (its kinds' switches on), in kind order.
    package func shown(on pane: PaneID) -> [ShownSignal] {
        guard raised[pane] != nil else { return [] }
        return raised(on: pane).compactMap { signal in
            guard isEnabled(signal.id), let kind = kind(signal.id) else { return nil }
            return (kind, signal)
        }
    }

    /// The signal whose color outlines `pane`: the last it shows.
    package func outline(of pane: PaneID) -> ShownSignal? { shown(on: pane).last }

    /// What a tab holding `leaves` shows: each tab-marking kind shown on any
    /// of them, once, running from the earliest (when the tab's icon appeared).
    package func tabMarks(for leaves: [PaneID]) -> [ShownSignal] {
        var earliest: [String: RaisedSignal] = [:]
        for leaf in leaves {
            for (kind, signal) in shown(on: leaf) where kind.value.marksTabs {
                if let current = earliest[kind.id], current.since <= signal.since { continue }
                earliest[kind.id] = signal
            }
        }
        guard !earliest.isEmpty else { return [] }
        return kinds.compactMap { kind in earliest[kind.id].map { (kind, $0) } }
    }

    /// Every pane carrying a signal.
    package var panes: Set<PaneID> { Set(raised.keys) }
}
