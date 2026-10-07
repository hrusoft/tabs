import AppKit
import TabsPluginSDK

/// What the layout (today the AppKit workspace; later a split/tab tree) does
/// for the pane runtime: place, focus, close, and say which pane is active.
/// Everything a plugin can observe about panes lives in `PaneRuntime`, so the
/// layout can be replaced without changing what plugins see.
@MainActor
package protocol WorkspaceShell: AnyObject {
    /// Where `.automatic` and `.tab(near: nil)` put a new pane.
    var frontmostWindowID: WindowID? { get }
    /// The active pane of the key (or frontmost) window.
    var activePaneID: PaneID? { get }
    /// Puts a created pane where `placement` asks — degrading what the layout
    /// can't do yet — and calls `PaneRuntime.attach` once it is in a window:
    /// at once, or (placed from plugin code during a layout pass) by the pass
    /// that follows. Returns false if there is nowhere to put it.
    func place(_ pane: LivePane, placement: PanePlacement) -> Bool
    func focus(_ pane: PaneID)
    /// A plugin asked to close its pane; the shell may confirm with the user.
    func requestClose(_ pane: PaneID)
    func paneTitleDidChange(_ pane: PaneID)
    /// The pane's persisted state changed: schedule a save.
    func paneStateDidChange(_ pane: PaneID)
    /// A pane asked for a context menu at `point` in `view`.
    func paneShowContextMenu(_ items: [PaneMenuItem], at point: NSPoint, in view: NSView, for pane: PaneID)
    /// A pane asked a question: show it and call `completion` once with the answer.
    func paneShowDialog(_ dialog: PaneDialog, for pane: PaneID, completion: @escaping @MainActor (PaneDialog.Answer) -> Void)
    /// A pane asked for a file or directory: `completion` gets nil when cancelled.
    func paneShowPicker(_ picker: PanePicker, for pane: PaneID, completion: @escaping @MainActor (URL?) -> Void)
    /// Makes a pane visible — every tab above it shown, its floating window
    /// raised — without making it active or giving it the keyboard.
    func reveal(_ pane: PaneID)
    /// The pane's title as a control verb reports it: the user's own, else the
    /// plugin's live one, else "".
    func controlTitle(of pane: PaneID) -> String
    /// Every pane in the layout, in layout order (each window's docked tree,
    /// then its floating panes).
    func layoutPaneOrder() -> [PaneID]?
}

extension WorkspaceShell {
    func reveal(_ pane: PaneID) {}
    func controlTitle(of pane: PaneID) -> String { "" }
    func layoutPaneOrder() -> [PaneID]? { nil }
}

/// A pane with plugin content: the controller the plugin made, the context
/// core gave it, and the state core keeps about it.
@MainActor
package final class LivePane {
    package let context: PaneContextImpl
    package let controller: any PaneController
    package let contribution: ContentTypeContribution
    package let owner: PluginID
    package fileprivate(set) var isAttached = false
    /// Whether it is the visible tab of its window, as last reported.
    package fileprivate(set) var isVisible = false
    /// Whether the plugin was last told the user is looking at it.
    package fileprivate(set) var isAttended = false
    /// The theme and depth its plugin was last told (nil: not yet).
    fileprivate var toldAppearance: (theme: PaneTheme, depth: Int)?
    /// The last config that could be written as JSON; what a save uses when
    /// the plugin hands back one that can't.
    fileprivate var lastGoodConfig: JSONValue
    /// Whether the keyboard skips this pane the next time it becomes active
    /// (`PaneRequest.activates == false`): spent once.
    fileprivate var keyboardExempt = false

    fileprivate init(context: PaneContextImpl, controller: any PaneController, contribution: ContentTypeContribution, owner: PluginID) {
        self.context = context
        self.controller = controller
        self.contribution = contribution
        self.owner = owner
        // Never seeded with something a save couldn't write.
        self.lastGoodConfig = context.initialConfig.isRepresentableInJSON ? context.initialConfig : .emptyObject
    }

    /// The layout asks when it is about to give an active pane the keyboard:
    /// true — once — for a pane opened without taking it.
    package func consumeKeyboardExemption() -> Bool {
        defer { keyboardExempt = false }
        return keyboardExempt
    }

    package var id: PaneID { context.paneID }
    package var windowID: WindowID { context.windowID }
    package var contentType: ContentTypeID { context.contentType }
    package var title: String { context.title ?? contribution.displayName }
}

/// A saved leaf, turned back into a pane body.
@MainActor
package enum RestoredPane {
    case empty
    case live(LivePane)
    /// No active plugin provides the type: keep the leaf verbatim, show why.
    case unavailable(reason: String)
}

/// The pane half of the plugin contract: creation (behind the creation
/// gate), restoration, contexts, titles, snapshots, capabilities, visibility
/// and the pane events — in a defined order:
///
/// - `paneOpened` once a live pane is in a window (created, restored, or an
///   empty pane filled in place), never before;
/// - `paneClosed` only for panes that were opened;
/// - `activePaneChanged` when the active pane — or its content type — actually
///   changes, not on every window activation;
/// - `paneMoved` when an opened pane changes window;
/// - `capabilityChanged(c)` when an opened pane offers a different value.
///
/// Capabilities are core's: declared here (anything else is refused), offered
/// by panes through their context, and stored here, so reading one never runs
/// another plugin's code.
///
/// It is also the `Workspace` every plugin's handle forwards to.
@MainActor
package final class PaneRuntime: Workspace {
    package weak var shell: (any WorkspaceShell)?

    private let registry: ContributionRegistry
    private let hub: EventHub
    private let host: PluginHost
    private var panes: [PaneID: LivePane] = [:]
    private var order: [PaneID] = []
    private var lastActive: (pane: PaneID, type: ContentTypeID?)?
    private var declaredCapabilities: Set<String> = []
    /// Capability changes waiting to be announced, by pane and capability.
    private var unannounced: Set<String> = []
    /// Where the control socket listens, for panes' child environments.
    package var controlSocketPath: String?
    /// The environment children start from: the app's own (tests replace it).
    package var baseEnvironment = ProcessInfo.processInfo.environment
    /// How the app itself was launched — never passed on, or a Tabs started
    /// from a pane would share this one's data, socket, hidden mode or test plugins.
    package static let launchSettings: Set<String> = ["TABS_DATA_DIR", "TABS_LISTEN_SOCKET", "TABS_E2E_HIDDEN", "TABS_E2E_PLUGINS"]
    /// For panes asking whether a key is an app shortcut.
    package weak var shortcuts: Shortcuts?
    /// Where panes' signals go.
    package weak var signals: PaneSignals?
    /// Which pane controls which (control verbs' created panes).
    package let ownership = PaneOwnership()

    package init(registry: ContributionRegistry, hub: EventHub, host: PluginHost) {
        self.registry = registry
        self.hub = hub
        self.host = host
    }

    /// Declares one of core's capabilities (and its change channel).
    package func declare<Value>(_ capability: PaneCapability<Value>) {
        precondition(declaredCapabilities.insert(capability.id).inserted, "\(capability.id) declared twice")
        hub.declare(EventChannel<PaneEvent>.capabilityChanged(capability))
    }

    package func isDeclared(_ capabilityID: String) -> Bool { declaredCapabilities.contains(capabilityID) }

    // MARK: Creation and restoration

    /// Content types the user may create now, in UI order: registered by an
    /// active plugin the user hasn't disabled.
    package func creatableTypes() -> [Owned<ContentTypeContribution>] {
        registry.contributions(to: .contentTypes)
            .filter { host.offersCreation($0.owner) }
            .sorted { host.rank(of: $0.owner) < host.rank(of: $1.owner) }
    }

    package func canCreate(_ type: ContentTypeID) -> Bool {
        registry.contribution(to: .contentTypes, id: type.rawValue).map { host.offersCreation($0.owner) } ?? false
    }

    /// Makes a new pane (not yet placed or attached). nil if the type isn't
    /// creatable, its config isn't valid JSON, or the plugin refused to build
    /// it. `id` lets an empty pane be filled in place.
    package func create(_ request: PaneRequest, id: PaneID = .make(), in window: WindowID) -> LivePane? {
        guard canCreate(request.type), let contribution = registry.contribution(to: .contentTypes, id: request.type.rawValue) else {
            return nil
        }
        let config = request.config ?? contribution.value.initialConfig(PaneCreation(origin: request.origin))
        guard config.isRepresentableInJSON else {
            Log.plugin(contribution.owner).fault(
                "refused to create a \(request.type.rawValue, privacy: .public) pane: its config is not valid JSON (NaN or infinity)")
            return nil
        }
        do {
            return try make(contribution, id: id, window: window, config: config, title: nil)
        } catch {
            Log.plugin(contribution.owner).error(
                "\(request.type.rawValue, privacy: .public) refused to build a pane: \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    /// Rebuilds a saved pane. Not gated: a pane the user already has keeps
    /// working even when its type is disabled for creation. If the plugin
    /// refuses the saved config, the pane stays unavailable — and its leaf is
    /// saved back verbatim — rather than being replaced by an empty one.
    package func restore(_ leaf: LayoutLeaf, in window: WindowID) -> RestoredPane {
        guard let type = leaf.type else { return .empty }
        guard let contribution = registry.contribution(to: .contentTypes, id: type.rawValue) else {
            return .unavailable(reason: unavailableReason(for: type))
        }
        do {
            return .live(try make(contribution, id: leaf.id, window: window, config: leaf.config, title: leaf.title))
        } catch {
            return .unavailable(reason: "\(contribution.value.displayName) could not open this pane's saved state: \(error)")
        }
    }

    private func make(
        _ contribution: Owned<ContentTypeContribution>, id requested: PaneID, window: WindowID, config: JSONValue, title: String?
    ) throws -> LivePane {
        // Pane ids are unique; a clash (a hand-edited layout) gets a fresh id
        // rather than silently replacing — and later tearing down — another pane.
        var id = requested
        if panes[id] != nil {
            Log.core.fault("pane id \(requested.rawValue, privacy: .public) is already live; using a new one")
            id = .make()
        }
        let context = PaneContextImpl(
            paneID: id, windowID: window, contentType: contribution.value.id, owner: contribution.owner, initialConfig: config,
            title: title)
        context.runtime = self
        let controller = try contribution.value.makePane(context)
        let pane = LivePane(context: context, controller: controller, contribution: contribution.value, owner: contribution.owner)
        panes[id] = pane
        order.append(id)
        return pane
    }

    private func unavailableReason(for type: ContentTypeID) -> String {
        guard let record = host.records.first(where: { $0.declaredContentTypes.contains(type) }) else {
            return "No installed plugin provides it."
        }
        return "Its plugin, \(record.displayName), is \(record.state.label)" + (record.state.detail.map { ": \($0)." } ?? ".")
    }

    // MARK: Lifecycle reported by the shell

    /// The pane is in a window. Publishes `paneOpened`, and — if it is the
    /// active pane filling in place — `activePaneChanged` for its new type.
    package func attach(_ pane: LivePane, in window: WindowID) {
        pane.context.windowID = window
        guard !pane.isAttached else { return }
        pane.isAttached = true
        // Owned since before it was placed: the cue goes up with the pane
        // (the layout keeps signals only for panes it holds).
        if ownership.isOwned(pane.id) { signals?.raise(ControlledSignal.signal, on: pane.id, by: nil) }
        hub.publish(.paneOpened, PaneEvent(paneID: pane.id, windowID: window, contentType: pane.contentType))
        if lastActive?.pane == pane.id { activePaneDidChange(to: pane.id, in: window) }
    }

    /// A pane moved to another window. Publishes `paneMoved` for an opened
    /// pane whose window actually changed.
    package func paneDidMove(_ id: PaneID, to window: WindowID) {
        guard let pane = panes[id], pane.context.windowID != window else { return }
        pane.context.windowID = window
        guard pane.isAttached else { return }
        hub.publish(.paneMoved, PaneEvent(paneID: id, windowID: window, contentType: pane.contentType))
    }

    /// The pane became (or stopped being) the visible tab of its window.
    /// Tells the plugin on a change only.
    package func visibilityDidChange(_ id: PaneID, visible: Bool) {
        guard let pane = panes[id], pane.isVisible != visible else { return }
        pane.isVisible = visible
        if visible { pane.controller.paneDidShow() } else { pane.controller.paneDidHide() }
    }

    /// The user is (or no longer is) looking at the pane. Tells the plugin on a
    /// change only, and never about a pane that hasn't been opened.
    package func attentionDidChange(_ id: PaneID, attended: Bool) {
        guard let pane = panes[id], pane.isAttached || !attended, pane.isAttended != attended else { return }
        pane.isAttended = attended
        if attended { pane.controller.paneDidBecomeAttended() } else { pane.controller.paneDidLoseAttention() }
    }

    /// The pane is drawn with `theme` at `depth` (the renderer says so on
    /// every draw). Tells the plugin the first time, and on a change after.
    package func appearanceDidChange(_ id: PaneID, theme: PaneTheme, depth: Int) {
        guard let pane = panes[id] else { return }
        if let told = pane.toldAppearance, told.theme == theme, told.depth == depth { return }
        pane.toldAppearance = (theme, depth)
        pane.context.theme = theme
        pane.context.depth = depth
        pane.controller.paneAppearanceDidChange(theme: theme, depth: depth)
    }

    /// The pane is going away for good. Tells the plugin, then publishes
    /// `paneClosed` if the pane had been opened. Empty and placeholder panes
    /// have no live pane and publish nothing.
    package func detach(_ id: PaneID) {
        guard let pane = panes.removeValue(forKey: id) else { return }
        order.removeAll { $0 == id }
        if pane.isAttended {
            pane.isAttended = false
            pane.controller.paneDidLoseAttention()
        }
        pane.controller.paneWillClose()
        pane.context.runtime = nil
        signals?.paneClosed(id)
        // Gone for good: its owner is told so, everyone else nothing. (A pane
        // that never opened was never anyone's to remember.)
        if pane.isAttached { ownership.release(id) } else { ownership.forget(id) }
        if pane.isAttached {
            hub.publish(.paneClosed, PaneEvent(paneID: id, windowID: pane.windowID, contentType: pane.contentType))
        }
        if lastActive?.pane == id { lastActive = nil }
    }

    /// The shell's active pane may have changed; publishes only if it did.
    package func activePaneDidChange(to id: PaneID?, in window: WindowID?) {
        guard let id, let window else { return }
        let type = panes[id].flatMap { $0.isAttached ? $0.contentType : nil }
        if let lastActive, lastActive.pane == id, lastActive.type == type { return }
        lastActive = (id, type)
        hub.publish(.activePaneChanged, PaneEvent(paneID: id, windowID: window, contentType: type))
    }

    // MARK: Persistence

    /// The pane as it should be saved. A config the plugin hands back that
    /// can't be written as JSON is replaced by the pane's last good one (and
    /// logged against its owner), so one pane can't stop the layout saving.
    package func snapshot(_ pane: LivePane) -> LayoutLeaf {
        var config = pane.controller.currentConfig()
        if config.isRepresentableInJSON {
            pane.lastGoodConfig = config
        } else {
            Log.plugin(pane.owner).fault(
                "pane \(pane.id.rawValue, privacy: .public) returned a config that is not valid JSON (NaN or infinity); saving its last good config instead"
            )
            config = pane.lastGoodConfig
        }
        return LayoutLeaf(id: pane.id, type: pane.contentType, config: config, title: pane.title)
    }

    package func pane(_ id: PaneID) -> LivePane? { panes[id] }

    // MARK: Callbacks from pane contexts

    fileprivate func titleDidChange(_ id: PaneID) {
        guard panes[id]?.isAttached == true else { return }
        shell?.paneTitleDidChange(id)
    }

    fileprivate func stateDidChange(_ id: PaneID) {
        guard panes[id]?.isAttached == true else { return }
        shell?.paneStateDidChange(id)
    }

    fileprivate func offer<Value>(_ capability: PaneCapability<Value>, _ value: Value?, from context: PaneContextImpl) {
        guard declaredCapabilities.contains(capability.id) else {
            Log.core.fault(
                "pane \(context.paneID.rawValue, privacy: .public) offered \(capability.id, privacy: .public), which core doesn't declare")
            return
        }
        guard context.offered[capability.id] as? Value != value else { return }
        context.offered[capability.id] = value
        // Readers see the value at once; the event comes on the next turn, so
        // no other plugin runs inside this one's offer() (and a burst of
        // changes is one event).
        let key = "\(context.paneID.rawValue)\u{1}\(capability.id)"
        guard unannounced.insert(key).inserted else { return }
        Task { @MainActor [weak self, weak context] in
            guard let self else { return }
            self.unannounced.remove(key)
            guard let context, let pane = self.panes[context.paneID], pane.context === context, pane.isAttached else { return }
            self.hub.publish(
                .capabilityChanged(capability), PaneEvent(paneID: pane.id, windowID: pane.windowID, contentType: pane.contentType))
        }
    }

    /// A pane raised or withdrew one of its plugin's signals.
    fileprivate func signal(_ signal: PaneSignal, raise: Bool, from context: PaneContextImpl) {
        guard let signals else { return }
        if raise {
            signals.raise(signal, on: context.paneID, by: context.owner)
        } else {
            signals.withdraw(signal, from: context.paneID, by: context.owner)
        }
    }

    fileprivate func isAppShortcut(_ event: NSEvent, in pane: PaneID) -> Bool {
        guard let chord = KeyChord(event: event), let shortcuts else { return false }
        return shortcuts.command(for: chord, activeType: panes[pane]?.contentType) != nil
    }

    fileprivate func showContextMenu(_ items: [PaneMenuItem], at point: NSPoint, in view: NSView, from pane: PaneID) {
        guard !items.isEmpty, panes[pane] != nil else { return }
        shell?.paneShowContextMenu(items, at: point, in: view, for: pane)
    }

    /// Asks a pane's question. A pane that's gone (or never was) gets the
    /// dismissed answer, and so does one that closes while the card is up.
    fileprivate func ask(_ dialog: PaneDialog, from pane: PaneID) async -> PaneDialog.Answer {
        guard panes[pane] != nil, let shell else { return dialog.dismissedAnswer }
        return await withCheckedContinuation { continuation in
            shell.paneShowDialog(dialog, for: pane) { continuation.resume(returning: $0) }
        }
    }

    fileprivate func pick(_ picker: PanePicker, from pane: PaneID) async -> URL? {
        guard panes[pane] != nil, let shell else { return nil }
        return await withCheckedContinuation { continuation in
            shell.paneShowPicker(picker, for: pane) { continuation.resume(returning: $0) }
        }
    }

    fileprivate func childEnvironment(for pane: PaneID) -> [String: String] {
        var environment = baseEnvironment.filter { !Self.launchSettings.contains($0.key) }
        environment["TABS_PANE_ID"] = pane.rawValue
        environment["TABS_CONTROL_SOCKET"] = controlSocketPath
        return environment
    }

    /// Deferred to the next turn of the main actor, so a plugin's
    /// `paneWillClose` never runs inside its own `requestClose()` call.
    fileprivate func requestClose(_ id: PaneID) {
        // No check yet: a pane asking from inside makePane isn't registered
        // until makePane returns, and the next turn is after that.
        Task { @MainActor [weak self] in
            guard let self, self.panes[id] != nil else { return }
            self.shell?.requestClose(id)
        }
    }

    // MARK: Workspace

    package var activePaneID: PaneID? { shell?.activePaneID }

    package func contentType(of pane: PaneID) -> ContentTypeID? {
        panes[pane].flatMap { $0.isAttached ? $0.contentType : nil }
    }

    package func panes(ofType type: ContentTypeID) -> [PaneID] {
        order.filter { panes[$0]?.isAttached == true && panes[$0]?.contentType == type }
    }

    package func openPane(_ request: PaneRequest) -> PaneID? { openPane(request, by: nil) }

    /// `openPane`, for `plugin` (nil: core, which may name any controller).
    /// A plugin may name a controller only while one of its own control verbs
    /// is answering that very caller; anything else refuses the pane, so a
    /// plugin can never claim a pane for a caller that didn't ask it to.
    package func openPane(_ request: PaneRequest, by plugin: PluginID?) -> PaneID? {
        guard let shell else { return nil }
        if let controller = request.controlledBy, let plugin, !ownership.isRunning(plugin, for: controller) {
            Log.plugin(plugin).fault(
                "refused to open a \(request.type.rawValue, privacy: .public) pane controlled by \(controller.rawValue, privacy: .public): no control verb of this plugin is answering that pane"
            )
            return nil
        }
        // Provisional: the shell may open a window for it; attach records where it landed.
        let window = placementWindow(for: request.placement) ?? shell.frontmostWindowID ?? WindowID("unplaced")
        // Owned from the instant it exists — before its plugin builds it, so
        // before its view and whatever it loads first; the cue goes up on attach.
        let id = PaneID.make()
        if let controller = request.controlledBy { ownership.grant(id, to: controller) }
        guard let pane = create(request, id: id, in: window) else {
            ownership.forget(id)
            return nil
        }
        pane.keyboardExempt = !request.activates
        guard shell.place(pane, placement: request.placement) else {
            // Never shown: let the plugin release what it made, publish nothing.
            detach(pane.id)
            return nil
        }
        return pane.id
    }

    /// Owns `pane` from now on (it is already open): the ledger, and the cue if
    /// it is on screen.
    package func grantOwnership(of pane: PaneID, to owner: PaneID) {
        ownership.grant(pane, to: owner)
        if panes[pane]?.isAttached == true { signals?.raise(ControlledSignal.signal, on: pane, by: nil) }
    }

    package func revealPane(_ pane: PaneID) {
        shell?.reveal(pane)
    }

    /// Every open pane in layout order (creation order without a layout).
    package var openPaneOrder: [PaneID] {
        let laidOut = shell?.layoutPaneOrder() ?? order
        return laidOut.filter { panes[$0]?.isAttached == true }
    }

    /// Closes a pane now — the shell may ask the user first — and says whether
    /// it is gone. Its ownership ends with it (`detach`).
    package func closePane(_ id: PaneID) -> Bool {
        guard panes[id] != nil else { return true }
        shell?.requestClose(id)
        return panes[id] == nil
    }

    /// What `list-panes` answers for `caller`: the panes it owns, in every
    /// window, that their plugin lists — `{paneId, type, title}` with the
    /// pane's own summary merged over it.
    package func controlListing(ownedBy caller: PaneID) -> [JSONValue] {
        openPaneOrder.compactMap { id in
            guard ownership.owner(of: id) == caller, let pane = panes[id], let summary = pane.controller.controlSummary else { return nil }
            var entry: [String: JSONValue] = [
                "paneId": .string(id.rawValue), "type": .string(pane.contentType.rawValue), "title": .string(controlTitle(of: id)),
            ]
            if case .object(let fields) = summary { entry.merge(fields) { _, summarized in summarized } }
            return .object(entry)
        }
    }

    /// The pane's title for control verbs.
    package func controlTitle(of pane: PaneID) -> String {
        shell?.controlTitle(of: pane) ?? panes[pane]?.context.title ?? ""
    }

    package func focusPane(_ pane: PaneID) {
        shell?.focus(pane)
    }

    package func capability<Value>(_ capability: PaneCapability<Value>, of pane: PaneID) -> Value? {
        guard let pane = panes[pane], pane.isAttached else { return nil }
        return pane.context.offered[capability.id] as? Value
    }

    private func placementWindow(for placement: PanePlacement) -> WindowID? {
        switch placement {
        case .tab(near: let pane?), .split(let pane, _), .floating(near: let pane?): panes[pane]?.windowID
        case .automatic, .tab(near: nil), .floating(near: nil), .window: nil
        }
    }
}

/// Core's side of one pane, handed to the plugin's `makePane`.
@MainActor
package final class PaneContextImpl: PaneContext {
    package let paneID: PaneID
    package fileprivate(set) var windowID: WindowID
    package let contentType: ContentTypeID
    /// The plugin that made the pane.
    package let owner: PluginID
    package let initialConfig: JSONValue
    package fileprivate(set) var theme = PaneTheme.dark
    package fileprivate(set) var depth = 0
    /// The plugin's title for the pane, or the saved one until it sets one.
    package private(set) var title: String?
    /// Capability values the pane offers, by capability id. Kept here so an
    /// offer made while the pane is being built isn't lost.
    fileprivate var offered: [String: any Sendable] = [:]
    fileprivate weak var runtime: PaneRuntime?

    fileprivate init(
        paneID: PaneID, windowID: WindowID, contentType: ContentTypeID, owner: PluginID, initialConfig: JSONValue, title: String?
    ) {
        self.paneID = paneID
        self.windowID = windowID
        self.contentType = contentType
        self.owner = owner
        self.initialConfig = initialConfig
        self.title = title
    }

    package var controller: PaneID? { runtime?.ownership.owner(of: paneID) }

    package func setTitle(_ title: String) {
        self.title = title
        runtime?.titleDidChange(paneID)
    }

    package func configDidChange() { runtime?.stateDidChange(paneID) }
    package func requestClose() { runtime?.requestClose(paneID) }
    package func offer<Value>(_ capability: PaneCapability<Value>, _ value: Value?) { runtime?.offer(capability, value, from: self) }
    package func raise(_ signal: PaneSignal) { runtime?.signal(signal, raise: true, from: self) }
    package func withdraw(_ signal: PaneSignal) { runtime?.signal(signal, raise: false, from: self) }
    package var childEnvironment: [String: String] {
        runtime?.childEnvironment(for: paneID)
            ?? ProcessInfo.processInfo.environment.filter { !PaneRuntime.launchSettings.contains($0.key) }
    }
    package func isAppShortcut(_ event: NSEvent) -> Bool { runtime?.isAppShortcut(event, in: paneID) ?? false }
    package func showContextMenu(_ items: [PaneMenuItem], at point: NSPoint, in view: NSView) {
        runtime?.showContextMenu(items, at: point, in: view, from: paneID)
    }

    package func confirm(_ dialog: PaneConfirm) async -> Bool {
        guard let runtime else { return false }
        if case .confirmed(let yes) = await runtime.ask(.confirm(dialog), from: paneID) { return yes }
        return false
    }

    package func choose(_ dialog: PaneChoose) async -> Int? {
        guard let runtime, !dialog.options.isEmpty else { return nil }
        if case .chose(let index) = await runtime.ask(.choose(dialog), from: paneID), let index, dialog.options.indices.contains(index) {
            return index
        }
        return nil
    }

    package func alert(_ dialog: PaneAlert) async { _ = await runtime?.ask(.alert(dialog), from: paneID) }

    package func pick(_ picker: PanePicker) async -> URL? { await runtime?.pick(picker, from: paneID) }
}
