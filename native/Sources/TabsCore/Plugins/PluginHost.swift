import Foundation
import TabsPluginSDK

/// Runs the plugin lifecycle: resolve → load → activate (transactionally) →
/// deactivate at quit. Owns the records the Plugins window and the report show.
@MainActor
package final class PluginHost {
    package struct Dependencies {
        package let registry: ContributionRegistry
        package let hub: EventHub
        package let settings: SettingsStore
        package let paths: AppPaths
        package let workspace: WorkspaceProxy
        /// A secret of this data directory's, mixed into plugins' web data identity.
        package let webDataSalt: @MainActor () -> String
    }

    private let deps: Dependencies
    /// What start() decided; `records` adds what changes while running.
    private var baseRecords: [PluginRecord] = []
    /// More notes per plugin, from other parts of core (unbound shortcuts).
    package var notesProvider: (@MainActor (PluginID) -> [String])?
    private var active: [(plugin: any TabsPlugin, context: PluginContextImpl)] = []
    private var contexts: [PluginID: PluginContextImpl] = [:]
    private var ranks: [PluginID: (Int, String)] = [:]
    private var changeObservers: [(token: Int, handler: @MainActor () -> Void)] = []
    private var nextObserverToken = 0
    package private(set) var hasStarted = false

    package init(_ deps: Dependencies) {
        self.deps = deps
    }

    /// Resolves, loads and activates `candidates`. Call once.
    package func start(candidates: [PluginCandidate], rejected: [PluginRecord], requiredContentTypes: Set<ContentTypeID>) {
        precondition(!hasStarted, "PluginHost.start called twice")
        hasStarted = true

        let disabled = deps.settings.disabledPlugins
        for candidate in candidates { ranks[candidate.manifest.id] = (candidate.manifest.sortOrder, candidate.manifest.id.rawValue) }
        var recordsByID: [PluginID: PluginRecord] = [:]
        func record(_ candidate: PluginCandidate, _ state: PluginState) {
            let manifest = candidate.manifest
            recordsByID[manifest.id] = PluginRecord(
                id: manifest.id, displayName: manifest.displayName, summary: manifest.summary,
                location: candidate.location, canDisable: manifest.canDisable,
                declaredContentTypes: manifest.contentTypes, state: state,
                userEnabled: !(manifest.canDisable && disabled.contains(manifest.id))
            )
        }

        let resolution = PluginResolver.resolve(
            .init(manifests: candidates.map(\.manifest), disabled: disabled, requiredContentTypes: requiredContentTypes))
        let byID = Dictionary(candidates.map { ($0.manifest.id, $0) }, uniquingKeysWith: { first, _ in first })
        for id in resolution.disabled { if let candidate = byID[id] { record(candidate, .disabled) } }

        for id in resolution.activationOrder {
            guard let candidate = byID[id] else { continue }
            let clock = ContinuousClock()
            let started = clock.now
            record(candidate, activate(candidate))
            recordsByID[id]?.activationTime = clock.now - started
            recordsByID[id]?.contributionCounts = deps.registry.counts(for: id)
            if let why = resolution.loadedWhileDisabled[id] {
                recordsByID[id]?.notes.append("disabled, but loaded because \(why)")
            }
        }

        baseRecords = (Array(recordsByID.values) + rejected).sorted { rank(of: $0.id) < rank(of: $1.id) }
        Log.plugins.info("plugins: \(self.records.map { "\($0.id)=\($0.state.label)" }.joined(separator: " "), privacy: .public)")
    }

    private func activate(_ candidate: PluginCandidate) -> PluginState {
        let manifest = candidate.manifest
        let plugin: any TabsPlugin
        switch candidate.source {
        case .bundle(let bundle):
            do {
                plugin = try PluginLoader.load(bundle)
            } catch {
                return .failed(error.description)
            }
        case .inProcess(_, let make):
            plugin = make()
        }

        let context = PluginContextImpl(
            manifest: manifest, bundle: candidate.bundle, registry: deps.registry, hub: deps.hub,
            settings: deps.settings, paths: deps.paths, workspace: deps.workspace, webDataSalt: deps.webDataSalt
        )
        contexts[manifest.id] = context
        do {
            try plugin.activate(context)
        } catch {
            _ = context.finishActivation(succeeded: false)
            Log.plugins.error("\(manifest.id, privacy: .public) threw from activate: \(String(describing: error), privacy: .public)")
            return .failed("activate() threw: \(error)")
        }
        let problems = context.finishActivation(succeeded: true)
        guard problems.isEmpty else {
            // activate() returned, so the plugin may have started things: the
            // contract promises it a deactivate() to stop them — while its
            // context still works, exactly as at quit — and only then the kill.
            plugin.deactivate()
            context.kill()
            Log.plugins.error(
                "\(manifest.id, privacy: .public) contributions rejected: \(problems.joined(separator: "; "), privacy: .public)")
            return .failed(problems.joined(separator: "; "))
        }
        active.append((plugin, context))
        return .active
    }

    /// Deactivates in reverse activation order, then kills each context
    /// (cancelling its tasks and subscriptions). Call once, at quit.
    package func stop() {
        for (plugin, context) in active.reversed() {
            plugin.deactivate()
            context.kill()
        }
        active.removeAll()
    }

    // MARK: Queries

    /// Every plugin's record, in UI order, with its calls ignored so far and
    /// core's current notes about it.
    package var records: [PluginRecord] {
        baseRecords.map { base in
            var record = base
            if let context = contexts[record.id] { record.ignoredCalls = context.ignoredCalls }
            record.notes += notesProvider?(record.id) ?? []
            return record
        }
    }

    package func record(for id: PluginID) -> PluginRecord? {
        records.first { $0.id == id }
    }

    /// UI order: (manifest sortOrder, id). Unknown plugins sort last.
    package func rank(of id: PluginID) -> (Int, String) { ranks[id] ?? (Int.max, id.rawValue) }

    package func offersCreation(_ plugin: PluginID) -> Bool { baseRecords.first { $0.id == plugin }?.offersCreation ?? false }

    /// The Plugins window's switch. Creation actions and settings pages follow
    /// immediately; what gets loaded follows at the next launch (a loaded
    /// plugin can't be unloaded).
    package func setUserEnabled(_ enabled: Bool, for id: PluginID) {
        guard let index = baseRecords.firstIndex(where: { $0.id == id }), baseRecords[index].canDisable,
            baseRecords[index].userEnabled != enabled
        else { return }
        baseRecords[index].userEnabled = enabled
        deps.settings.setDisabled(!enabled, for: id)
        for observer in changeObservers { observer.handler() }
    }

    /// Called whenever what plugins offer changes (enablement today).
    package func observeChanges(_ handler: @escaping @MainActor () -> Void) -> Subscription {
        nextObserverToken += 1
        let token = nextObserverToken
        changeObservers.append((token, handler))
        return Subscription { [weak self] in self?.changeObservers.removeAll { $0.token == token } }
    }

    package func report(sharedFingerprint: String?) -> JSONValue {
        [
            "sharedFingerprint": sharedFingerprint.map(JSONValue.string) ?? .null,
            "plugins": .array(records.map { $0.reportValue() }),
        ]
    }
}
