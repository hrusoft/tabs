import AppKit
import TabsPluginSDK

/// The terminal plugin: interactive login shells in panes — the Electron
/// app's `packages/plugin-terminal` (docs/TERMINAL.md lists every case).
///
/// It contributes the `terminal` content type ("New terminal", seeded to
/// start at `~`, or in the directory of the pane it's made from), the bell as
/// a pane signal, Edit ▸ Clear Buffer (⌘K), and Settings ▸ Terminal. Every
/// shell ends when its pane closes, and all of them when the app quits.
@MainActor
final class TerminalPlugin: NSObject, TabsPlugin {
    private(set) var services: TerminalServices?
    private(set) var settings: PluginSettings<TerminalSettings>?

    func activate(_ context: any PluginContext) throws {
        let settings = context.settings(TerminalSettings.self)
        let services = TerminalServices(appVersion: context.bundle.infoDictionary?["CFBundleShortVersionString"] as? String ?? "")
        self.services = services
        self.settings = settings
        // The workspace handle, not the context: a contribution holding its
        // own plugin's context keeps it alive.
        let workspace = context.workspace

        context.register(
            ContentTypeContribution(
                id: "terminal", displayName: "Terminal", icon: .image(TerminalGlyphs.terminal), creationLabel: "New terminal",
                initialConfig: { creation in
                    .object(["cwd": .string(services.startDirectory(from: creation.origin, settings: settings.value, workspace: workspace))]
                    )
                },
                makePane: { pane in
                    let terminal = try TerminalPane(pane: pane, settings: settings, services: services)
                    services.remember(terminal, as: pane.paneID)
                    return terminal
                }))

        context.register(TerminalSignals.bell)

        context.register(
            CommandContribution(
                id: "terminal.clearBuffer", title: "Clear Buffer", summary: "Clear the active terminal, scrollback included.", menu: .edit,
                defaultChord: KeyChord("k", [.command]),
                appliesTo: "terminal"
            ) { invocation in
                invocation.pane(as: TerminalPane.self)?.clear()
            })

        context.register(
            SettingsPageContribution(id: "terminal", title: "Terminal", symbolName: "terminal") {
                TerminalSettingsPage(settings: settings)
            })

        #if DEBUG
        TerminalTestVerbs.register(in: context)
        #endif
    }

    /// Quitting ends every shell (a closed pane's already ended with it).
    func deactivate() {
        services?.endAll()
    }
}

/// What the plugin's panes share: the shell to run, how to build its
/// environment, where a new one starts, links, and the plugin's own live
/// panes (for a new pane's origin and for ending every shell at quit).
@MainActor
final class TerminalServices {
    let appVersion: String
    let shell: String
    let home: String
    let locale: String
    private var panes: [PaneID: WeakPane] = [:]

    private struct WeakPane {
        weak var pane: TerminalPane?
    }

    init(appVersion: String) {
        self.appVersion = appVersion
        let environment = ProcessInfo.processInfo.environment
        shell = Shell.resolveShell(environment: environment) { FileManager.default.isExecutableFile(atPath: $0) }
        home = NSHomeDirectory()
        locale = Shell.utf8Locale(
            language: Locale.current.language.languageCode?.identifier, region: Locale.current.region?.identifier
        ) { FileManager.default.fileExists(atPath: "/usr/share/locale/\($0)") }
    }

    nonisolated func isDirectory(_ path: String) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    func environment(_ base: [String: String]) -> [String: String] {
        Shell.environment(base: base, appVersion: appVersion, locale: locale)
    }

    /// Where a new terminal made from `origin` starts: with inheritance on,
    /// that pane's live directory — a terminal's own, fresh, or what any
    /// other pane offers — else home.
    func startDirectory(from origin: PaneID?, settings: TerminalSettings, workspace: any Workspace) -> String {
        guard settings.inheritCwdOnNewPane, let origin else { return "~" }
        if let terminal = panes[origin]?.pane, let directory = terminal.liveDirectory { return directory }
        return workspace.capability(.workingDirectory, of: origin)?.path ?? "~"
    }

    /// Opens a link the user ⌘-clicked, if it's a web or mail link.
    func openLink(_ link: String) {
        guard let url = TerminalLinks.safeURL(link) else { return }
        NSWorkspace.shared.open(url)
    }

    func remember(_ pane: TerminalPane, as id: PaneID) { panes[id] = WeakPane(pane: pane) }
    func forget(_ id: PaneID) { panes[id] = nil }
    func pane(_ id: PaneID) -> TerminalPane? { panes[id]?.pane }

    func endAll() {
        for entry in panes.values { entry.pane?.end() }
        panes.removeAll()
    }
}

/// Which links a terminal opens: `http:`, `https:` and `mailto:` only. What a
/// program prints is anyone's, and the OS would happily open a `file:` path
/// or a custom scheme (`isSafeExternalUrl`).
enum TerminalLinks {
    static let schemes: Set<String> = ["http", "https", "mailto"]

    static func safeURL(_ link: String) -> URL? {
        guard let url = URL(string: link), let scheme = url.scheme?.lowercased(), schemes.contains(scheme) else { return nil }
        return url
    }
}

/// The terminal's pane signal.
@MainActor
enum TerminalSignals {
    /// BEL in a pane the user isn't looking at: the Electron app's bell — a
    /// pulsing bell icon and outline in the alert color, on every tab holding
    /// the pane, the Dock bouncing, until the user looks at it.
    static let bell = PaneSignalContribution(
        id: "terminal.bell", label: "Bell", icon: .image(TerminalGlyphs.bell), color: .alert, pulse: 3, marksTabs: true,
        lifetime: .untilSeen, requestsAttention: true,
        setting: .init(title: "Bell indicator", detail: "Pulse a bell icon and bounce the Dock icon when a terminal rings its bell."))
}
