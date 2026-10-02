import Foundation
import TabsPluginSDK

/// Core's composition root: everything except windows. The GUI app, headless
/// mode and the tests all build one of these, so they exercise the same code.
@MainActor
package final class CoreRuntime {
    package let paths: AppPaths
    package let settings: SettingsStore
    /// One instance for load and save: it remembers whether the file on disk
    /// must be preserved before the first save replaces it.
    package let layoutStore: LayoutStore
    package let hub = EventHub()
    package let registry = ContributionRegistry()
    package let workspace = WorkspaceProxy()
    package let host: PluginHost
    /// Live panes and the plugin-facing Workspace; the shell attaches to it.
    package let panes: PaneRuntime
    /// Which panes carry which signals; the layout engine is its host.
    package let signals: PaneSignals
    package let control: ControlDispatcher
    /// Every command's effective shortcut, core's and plugins'.
    package let shortcuts: Shortcuts
    /// Runs plugin commands with the pane-ownership rule.
    package let commands: CommandCenter
    /// The app's one managed caffeinate process (File ▸ Caffeinate…).
    package let caffeinate = Caffeinate()
    /// The loaded SDK's fingerprint: what every plugin must match.
    package let sharedFingerprint: String?
    /// What loading saved state had to recover from, for the user and the report.
    package private(set) var persistenceNotes: [String] = []
    /// Where the control socket listens, once the app has started it.
    package var controlSocketPath: String? {
        get { panes.controlSocketPath }
        set { panes.controlSocketPath = newValue }
    }

    /// - Parameter readOnly: never write, move or copy files (headless modes).
    /// - Parameter controlSocketPath: where the control socket will listen,
    ///   known before anything starts, so every pane — restored ones
    ///   included — hands it to the processes it spawns.
    package init(
        paths: AppPaths, readOnly: Bool = false, controlSocketPath: String? = nil,
        sharedFingerprint: String? = BuildStamp.loadedFingerprint
    ) {
        self.paths = paths
        self.sharedFingerprint = sharedFingerprint
        settings = SettingsStore(file: paths.settingsFile, readOnly: readOnly)
        layoutStore = LayoutStore(file: paths.layoutFile, readOnly: readOnly)
        persistenceNotes = settings.loadNotes.map { "settings.json: \($0)" }
        CoreExtensionPoints.install(into: registry)
        for channel in [EventChannel<PaneEvent>.paneOpened, .paneClosed, .activePaneChanged, .paneMoved] { hub.declare(channel) }
        let salt = WebDataSalt(file: paths.dataDirectory.appending(path: "web-data-salt"), readOnly: readOnly)
        host = PluginHost(
            .init(
                registry: registry, hub: hub, settings: settings, paths: paths, workspace: workspace,
                webDataSalt: { salt.value }))
        panes = PaneRuntime(registry: registry, hub: hub, host: host)
        signals = PaneSignals(registry: registry, plugins: host, settings: settings)
        panes.signals = signals
        // Every capability panes may offer. A new one is a core change.
        panes.declare(PaneCapability.workingDirectory)
        panes.controlSocketPath = controlSocketPath
        workspace.target = panes
        control = ControlDispatcher(registry: registry, panes: panes, plugins: host)
        shortcuts = Shortcuts(registry: registry, settings: settings, host: host)
        commands = CommandCenter(registry: registry, panes: panes)
        panes.shortcuts = shortcuts
        host.notesProvider = { [unowned shortcuts] owner in shortcuts.notes(for: owner) }
        control.addCoreVerb(
            ControlVerbContribution(name: "tabs.info", summary: "This process: pid, data directory, control socket, build") {
                [unowned self] _ in
                let stamp = BuildStamp(of: .main)
                return [
                    "pid": .int(Int64(getpid())),
                    "dataDirectory": .string(self.paths.dataDirectory.path),
                    "controlSocket": self.controlSocketPath.map(JSONValue.string) ?? .null,
                    "configuration": stamp.map { .string($0.configuration) } ?? .null,
                    "sharedFingerprint": self.sharedFingerprint.map(JSONValue.string) ?? .null,
                ]
            })
        control.addCoreVerb(
            ControlVerbContribution(name: "tabs.plugins", summary: "Every discovered plugin and its state") { [unowned self] _ in
                self.report()
            })
        addShortcutVerbs()
    }

    private func addShortcutVerbs() {
        control.addCoreVerb(
            ControlVerbContribution(
                name: "tabs.shortcuts", summary: "Every command's shortcut: default, effective, where it came from, and why if unbound"
            ) { [unowned self] _ in
                .array(
                    self.shortcuts.bindings.map { binding in
                        [
                            "command": .string(binding.command.rawValue), "owner": .string(binding.owner.rawValue),
                            "title": .string(binding.title), "appliesTo": binding.scope.map { .string($0.rawValue) } ?? .null,
                            "default": binding.defaultChord.map { .string($0.stringValue) } ?? .null,
                            "chord": binding.chord.map { .string($0.stringValue) } ?? .null,
                            "source": binding.source.map { .string($0.rawValue) } ?? .null,
                            "fixed": .bool(binding.isFixed),
                            "note": binding.note.map(JSONValue.string) ?? .null,
                        ]
                    })
            })
        control.addCoreVerb(
            ControlVerbContribution(
                name: "tabs.setShortcut", summary: "Rebind a command for the user: a chord (cmd+shift+k), none to unbind, default to reset",
                arguments: [
                    ControlArgument("command", .string, required: true),
                    ControlArgument("chord", .string, required: true, summary: "e.g. cmd+shift+k, ctrl+f5; none; default"),
                ]
            ) { [unowned self] invocation in
                let command = CommandID(invocation["command"]?.stringValue ?? "")
                let chord = invocation["chord"]?.stringValue ?? ""
                do {
                    switch chord {
                    case "default": try self.shortcuts.reset(command)
                    case "none": try self.shortcuts.bind(command, to: nil)
                    default:
                        guard let parsed = KeyChord(string: chord) else { throw Shortcuts.Refusal("\"\(chord)\" is not a shortcut") }
                        try self.shortcuts.bind(command, to: parsed)
                    }
                } catch {
                    throw ControlVerbError(String(describing: error))
                }
                let binding = self.shortcuts.binding(for: command)
                return [
                    "chord": binding?.chord.map { .string($0.stringValue) } ?? .null,
                    "note": binding?.note.map(JSONValue.string) ?? .null,
                ]
            })
    }

    /// Starts the plugins an app bundle ships: its PlugIns directory,
    /// reconciled against its `TabsBundledPlugins` list.
    package func startBundledPlugins(of appBundle: Bundle, requiredContentTypes: Set<ContentTypeID> = []) {
        startPlugins(
            from: appBundle.builtInPlugInsURL, bundled: BuildStamp(of: appBundle)?.bundledPlugins ?? [],
            requiredContentTypes: requiredContentTypes)
    }

    /// Discovers plugins in `directory`, adds `inProcess` ones, and starts them.
    /// `bundled` nil skips the bundled-list reconciliation (fixture directories).
    package func startPlugins(
        from directory: URL?,
        bundled: [PluginID]? = nil,
        inProcess: [PluginCandidate] = [],
        requiredContentTypes: Set<ContentTypeID> = []
    ) {
        var discovered =
            directory.map { PluginDiscovery.discover(in: $0, expectedFingerprint: sharedFingerprint, bundled: bundled) }
            ?? PluginDiscovery.Result()
        PluginDiscovery.add(inProcess: inProcess, to: &discovered)
        PluginDiscovery.rejectDuplicateIDs(&discovered)
        host.start(candidates: discovered.candidates, rejected: discovered.rejected, requiredContentTypes: requiredContentTypes)
        shortcuts.rebuild()
    }

    /// Removes this run's temporary directory (every plugin's scratch space).
    package func removeTemporaryFiles() {
        try? FileManager.default.removeItem(at: paths.temporaryDirectory)
    }

    /// Loads layout.json, recording anything it had to recover from. With
    /// Restore layout on relaunch off, the file isn't read (or moved aside, or
    /// touched in any way): launch starts fresh (Electron's `registerLayoutIpc`).
    package func loadLayout() -> SavedLayout? {
        guard settings.panes.persistLayoutOnExit else { return nil }
        let outcome = layoutStore.load()
        persistenceNotes += outcome.notes.map { "layout.json: \($0)" }
        return outcome.document
    }

    package func report() -> JSONValue {
        guard case .object(var report) = host.report(sharedFingerprint: sharedFingerprint) else { return .null }
        if !persistenceNotes.isEmpty { report["persistence"] = .array(persistenceNotes.map(JSONValue.string)) }
        return .object(report)
    }

    /// Settings pages of enabled plugins, in UI order. Like creation actions,
    /// a disabled plugin's pages go away even while it runs for an open pane.
    package func settingsPages() -> [Owned<SettingsPageContribution>] {
        registry.contributions(to: .settingsPages)
            .filter { host.record(for: $0.owner)?.userEnabled == true }
            .sorted { host.rank(of: $0.owner) < host.rank(of: $1.owner) }
    }
}

/// A random secret kept in the data directory, made the first time none is
/// there (or it's empty). It must never change for a data directory, or every
/// plugin's web data (cookies, logins) is orphaned: a file that exists but
/// can't be read is left alone, and whenever the secret can't be stored, one
/// derived from the directory's path is used, stable from run to run.
@MainActor
private final class WebDataSalt {
    private let file: URL
    private let readOnly: Bool
    private var cached: String?

    init(file: URL, readOnly: Bool) {
        self.file = file
        self.readOnly = readOnly
    }

    var value: String {
        if let cached { return cached }
        let value = load()
        cached = value
        return value
    }

    private func load() -> String {
        let fallback = "path:\(file.path)"
        if FileManager.default.fileExists(atPath: file.path) {
            guard let text = try? String(contentsOf: file, encoding: .utf8) else {
                Log.core.fault("web data salt at \(self.file.path, privacy: .public) can't be read; it's left as it is")
                return fallback
            }
            let stored = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !stored.isEmpty { return stored }
        }
        guard !readOnly else { return fallback }
        let fresh = UUID().uuidString
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(fresh.utf8).write(to: file, options: .atomic)
            return fresh
        } catch {
            Log.core.fault("web data salt can't be stored: \(String(describing: error), privacy: .public)")
            return fallback
        }
    }
}
