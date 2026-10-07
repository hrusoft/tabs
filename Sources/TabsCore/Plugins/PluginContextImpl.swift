import CryptoKit
import Foundation
import TabsPluginSDK
import os

/// One plugin's view of core. Bound to the plugin's id at creation, so every
/// namespace rule is enforced here rather than trusted.
///
/// Lifecycle: `activating` (contributions accepted into the transaction) →
/// `active` → `dead`. A context dies when its plugin's activation is rolled
/// back or the plugin deactivates; from then on every call is ignored and
/// logged, so a Task or timer the plugin left running can't reach core.
/// Nothing a plugin holds points back at the context strongly or unowned —
/// the facades it hands out (`events`, `workspace`) hold it weakly.
///
/// Isolation is enforced here too: a plugin contributes only to core's points,
/// only listens to core's events, and its workspace handle acts only on its
/// own content types.
@MainActor
package final class PluginContextImpl: PluginContext {
    package enum Phase: Equatable { case activating, active, dead }

    package let manifest: PluginManifest
    package let bundle: Bundle
    package let log: Logger

    package let registry: ContributionRegistry
    package let hub: EventHub
    private let settingsBackend: SettingsStore
    private let paths: AppPaths
    private let workspaceProxy: WorkspaceProxy
    private let webDataSalt: @MainActor () -> String

    package private(set) var phase: Phase = .activating
    private var transaction: ContributionTransaction?
    private var subscriptions: [Subscription] = []
    /// Running spawned tasks; each removes itself when it finishes.
    private var tasks: [UUID: Task<Void, Never>] = [:]
    private var settingsObject: (AnyObject & Invalidatable)?
    /// Calls that arrived outside the phase that allows them; surfaced in the report.
    package private(set) var ignoredCalls: [String] = []

    package init(
        manifest: PluginManifest, bundle: Bundle, registry: ContributionRegistry, hub: EventHub,
        settings: SettingsStore, paths: AppPaths, workspace: WorkspaceProxy, webDataSalt: @escaping @MainActor () -> String
    ) {
        self.webDataSalt = webDataSalt
        self.manifest = manifest
        self.bundle = bundle
        self.log = Log.plugin(manifest.id)
        self.registry = registry
        self.hub = hub
        self.settingsBackend = settings
        self.paths = paths
        self.workspaceProxy = workspace
        self.transaction = registry.begin(for: manifest)
    }

    // MARK: Lifecycle (driven by PluginHost)

    /// Ends activation. On success commits the transaction and returns []. If
    /// the commit finds problems they are returned and nothing is committed —
    /// but the context stays usable until the host has let the plugin
    /// `deactivate()` and then calls `kill()`. On failure (activate threw)
    /// discards everything and kills the context at once.
    package func finishActivation(succeeded: Bool) -> [String] {
        guard phase == .activating, let transaction else { return [] }
        self.transaction = nil
        if succeeded {
            let problems = registry.commit(transaction)
            // Active either way: after rejected contributions the plugin still
            // gets its deactivate() with a working context, then the kill.
            phase = .active
            return problems
        }
        registry.discard(transaction)
        kill()
        return []
    }

    /// Cancels everything the plugin set up through this context and refuses
    /// all later calls. Idempotent.
    package func kill() {
        guard phase != .dead else { return }
        phase = .dead
        transaction.map(registry.discard)
        transaction = nil
        for subscription in subscriptions { subscription.cancel() }
        subscriptions.removeAll()
        for task in tasks.values { task.cancel() }
        tasks.removeAll()
        settingsObject?.invalidate()
    }

    /// Whether `operation` may run now; records and logs it if not.
    fileprivate func allows(_ operation: String, during allowed: Set<Phase>) -> Bool {
        guard allowed.contains(phase) else {
            recordIgnored("\(operation) while \(phase)")
            return false
        }
        return true
    }

    /// The first `ignoredCallLimit` are kept verbatim; after that only counted,
    /// so a runaway timer in a dead plugin can't grow the report without bound.
    fileprivate func recordIgnored(_ note: String) {
        log.fault("ignored \(note, privacy: .public)")
        if ignoredCalls.count < Self.ignoredCallLimit {
            ignoredCalls.append(note)
        } else {
            droppedIgnoredCalls += 1
            ignoredCalls[Self.ignoredCallLimit - 1] = "… and \(droppedIgnoredCalls + 1) more"
        }
    }

    private static let ignoredCallLimit = 50
    private var droppedIgnoredCalls = 0

    fileprivate func track(_ subscription: Subscription) {
        subscriptions.removeAll(where: \.isCancelled)
        subscriptions.append(subscription)
    }

    // MARK: PluginContext

    package var dataDirectory: URL { Self.created(paths.pluginData(manifest.id)) }
    package var cacheDirectory: URL { Self.created(paths.pluginCache(manifest.id)) }
    package var temporaryDirectory: URL { Self.created(paths.pluginTemporary(manifest.id)) }

    /// A name-based UUID from the plugin id and a secret of the data
    /// directory's: stable across launches, different for every data
    /// directory (tests never touch the user's web data), and not derivable
    /// by another plugin from the id alone.
    package var webDataStoreIdentifier: UUID {
        var bytes = Array(SHA256.hash(data: Data("tabs.webDataStore.\(webDataSalt()).\(manifest.id)".utf8)).prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x50  // version 5 (name-based, SHA)
        bytes[8] = (bytes[8] & 0x3F) | 0x80  // RFC 4122 variant
        return UUID(
            uuid: (
                bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]
            ))
    }

    private static func created(_ url: URL) -> URL {
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    package func contribute<C: Contribution>(_ contribution: C, to point: ExtensionPoint<C>) {
        guard allows("contribute \(point.id) \"\(contribution.contributionID)\"", during: [.activating]),
            let transaction
        else { return }
        registry.stage(contribution, to: point, in: transaction)
    }

    package func settings<Value: PluginSettingsValue>(_ type: Value.Type) -> PluginSettings<Value> {
        if let existing = settingsObject {
            if let typed = existing as? PluginSettings<Value> { return typed }
            // A plugin bug, but only the plugin's: it gets defaults it can't
            // change, and the report says why.
            recordIgnored("settings(\(Value.self)): this plugin already uses another settings type; one per plugin")
            let refused = PluginSettings<Value>(pluginID: manifest.id, backend: DetachedSettings(), log: log)
            refused.invalidate()
            return refused
        }
        let settings = PluginSettings<Value>(pluginID: manifest.id, backend: settingsBackend, log: log)
        if phase == .dead { settings.invalidate() }
        settingsObject = settings
        return settings
    }

    package func spawn(priority: TaskPriority?, _ operation: @escaping @Sendable () async -> Void) -> Task<Void, Never> {
        guard allows("spawn", during: [.activating, .active]) else {
            let task = Task<Void, Never> {}
            task.cancel()
            return task
        }
        let id = UUID()
        let task = Task(priority: priority) { [weak self] in
            await operation()
            self?.taskFinished(id)
        }
        tasks[id] = task
        return task
    }

    private func taskFinished(_ id: UUID) {
        tasks[id] = nil
    }

    package lazy var events: any EventBus = PluginEvents(context: self)
    package lazy var workspace: any Workspace = PluginWorkspace(context: self, proxy: workspaceProxy)
}

/// Settings that read nothing and store nothing.
@MainActor
private final class DetachedSettings: SettingsBackend {
    var isReadOnly: Bool { false }
    func storedSettings(for plugin: PluginID) -> JSONValue? { nil }
    func store(_ value: JSONValue, for plugin: PluginID) {}
}

/// Lets the context stop a `PluginSettings<Value>` without knowing `Value`.
@MainActor
protocol Invalidatable {
    func invalidate()
}

extension PluginSettings: Invalidatable {}

@MainActor
private final class PluginEvents: EventBus {
    weak var context: PluginContextImpl?

    init(context: PluginContextImpl) { self.context = context }

    func subscribe<Payload>(_ channel: EventChannel<Payload>, _ handler: @escaping @MainActor (Payload) -> Void) -> Subscription {
        guard let context, context.allows("subscribe \(channel.id)", during: [.activating, .active]) else {
            let dead = Subscription {}
            dead.cancel()
            return dead
        }
        guard let subscription = context.hub.subscribe(channel, owner: context.manifest.id, handler) else {
            context.recordIgnored("subscribe \(channel.id): \(context.hub.problem(with: channel) ?? "refused")")
            let refused = Subscription {}
            refused.cancel()
            return refused
        }
        context.track(subscription)
        return subscription
    }
}

/// The plugin's handle on the workspace: its own content types only, and only
/// while the plugin is alive. Other plugins' panes are visible as core facts
/// (the active pane, content types) and through core-defined capabilities.
@MainActor
private final class PluginWorkspace: Workspace {
    weak var context: PluginContextImpl?
    let proxy: WorkspaceProxy

    init(context: PluginContextImpl, proxy: WorkspaceProxy) {
        self.context = context
        self.proxy = proxy
    }

    private var target: WorkspaceProxy? { context?.phase == .dead || context == nil ? nil : proxy }

    /// Whether `type` is one of this plugin's own content types; records the
    /// refusal if not.
    private func owns(_ type: ContentTypeID?, _ operation: String) -> Bool {
        guard let context else { return false }
        guard let type, context.manifest.contentTypes.contains(type) else {
            context.recordIgnored("\(operation): not one of this plugin's content types")
            return false
        }
        return true
    }

    var activePaneID: PaneID? { target?.activePaneID }
    func contentType(of pane: PaneID) -> ContentTypeID? { target?.contentType(of: pane) }

    func panes(ofType type: ContentTypeID) -> [PaneID] {
        guard let target, owns(type, "panes(ofType: \(type))") else { return [] }
        return target.panes(ofType: type)
    }

    func openPane(_ request: PaneRequest) -> PaneID? {
        guard let context, context.allows("openPane \(request.type)", during: [.active]),
            owns(request.type, "openPane \(request.type)")
        else { return nil }
        return proxy.openPane(request, by: context.manifest.id)
    }

    func revealPane(_ pane: PaneID) {
        guard let context, context.allows("revealPane", during: [.active]),
            owns(proxy.contentType(of: pane), "revealPane \(pane)")
        else { return }
        proxy.revealPane(pane)
    }

    func focusPane(_ pane: PaneID) {
        guard let context, context.allows("focusPane", during: [.active]),
            owns(proxy.contentType(of: pane), "focusPane \(pane)")
        else { return }
        proxy.focusPane(pane)
    }

    func capability<Value>(_ capability: PaneCapability<Value>, of pane: PaneID) -> Value? {
        guard let target, let context else { return nil }
        guard target.isDeclared(capability.id) else {
            context.recordIgnored("capability \(capability.id): core declares no such capability")
            return nil
        }
        return target.capability(capability, of: pane)
    }
}

/// The late binding between plugin contexts (created by the host) and the
/// pane runtime (which needs the host): every plugin's workspace handle
/// forwards through it.
@MainActor
package final class WorkspaceProxy: Workspace {
    package weak var target: PaneRuntime?

    package init() {}

    package func isDeclared(_ capabilityID: String) -> Bool { target?.isDeclared(capabilityID) ?? false }

    package var activePaneID: PaneID? { target?.activePaneID }
    package func contentType(of pane: PaneID) -> ContentTypeID? { target?.contentType(of: pane) }
    package func panes(ofType type: ContentTypeID) -> [PaneID] { target?.panes(ofType: type) ?? [] }
    package func openPane(_ request: PaneRequest) -> PaneID? { target?.openPane(request) }
    package func openPane(_ request: PaneRequest, by plugin: PluginID) -> PaneID? { target?.openPane(request, by: plugin) }
    package func focusPane(_ pane: PaneID) { target?.focusPane(pane) }
    package func revealPane(_ pane: PaneID) { target?.revealPane(pane) }
    package func capability<Value>(_ capability: PaneCapability<Value>, of pane: PaneID) -> Value? {
        target?.capability(capability, of: pane)
    }
}
