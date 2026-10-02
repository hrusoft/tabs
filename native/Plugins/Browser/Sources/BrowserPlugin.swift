import AppKit
import TabsPluginSDK

/// The browser plugin: a web page in a pane, with back / forward / refresh and an
/// address bar in the pane's header — the Electron app's `packages/plugin-browser`
/// (docs/BROWSER.md lists every case).
///
/// It contributes the `browser` content type ("New browser", seeded to open on
/// `about:blank`: a browser has no directory, so nothing is inherited when one is
/// made from another pane and a copy of a browser starts where the original is)
/// and Settings ▸ Browser. Its pages live in the plugin's own web data store:
/// cookies and storage persist across launches and are shared with no other plugin.
@MainActor
final class BrowserPlugin: NSObject, TabsPlugin {
    private(set) var services: BrowserServices?

    func activate(_ context: any PluginContext) throws {
        let settings = context.settings(BrowserSettings.self)
        let dataStore = context.webDataStoreIdentifier
        let services = BrowserServices(
            settings: settings, workspace: context.workspace, cacheDirectory: context.cacheDirectory,
            agentFiles: AgentFiles(root: context.cacheDirectory))
        self.services = services
        // Files a previous run left for an agent to read, past their ten minutes.
        services.agentFiles.sweepInBackground()

        context.register(
            ContentTypeContribution(
                id: "browser", displayName: "Browser", icon: .image(BrowserGlyphs.browser), creationLabel: "New browser",
                // A new pane opens blank; one made from a browser (a new tab or split "like" it)
                // is a copy of it, as-is: where it is now. A browser has no directory, so nothing
                // else is inherited, whichever pane it is made from.
                initialConfig: { [weak services] creation in
                    if let origin = creation.origin, let browser = services?.pane(origin) { return browser.currentConfig() }
                    return .object(["url": .string(BrowserPage.blank)])
                },
                makePane: { pane in
                    let browser = try BrowserPane(pane: pane, dataStore: dataStore, openExternal: services.openExternal)
                    services.remember(browser)
                    return browser
                }))

        context.register(
            SettingsPageContribution(id: "browser", title: "Browser", symbolName: "globe") {
                BrowserSettingsPage(settings: settings)
            })

        BrowserVerbs.register(in: context, services: services)

        #if DEBUG
        BrowserTestVerbs.register(in: context, services: services)
        #endif
    }
}

/// What the plugin's panes share: the live panes, and the one process fact a
/// pane needs (handing a URL to the OS's browser).
@MainActor
final class BrowserServices {
    /// The plugin's settings, for what reads them outside a pane (an agent's new
    /// pane is placed by them).
    let settings: PluginSettings<BrowserSettings>
    /// The layout requests the verbs make (`create-browser-pane` opens a pane,
    /// `screenshot` reveals one).
    let workspace: any Workspace
    /// The plugin's own cache: where the files a verb hands back live.
    let cacheDirectory: URL
    /// The sink for what verbs write for an agent to read (saved resources, `--out` results).
    let agentFiles: AgentFiles
    private var panes: [WeakPane] = []

    init(settings: PluginSettings<BrowserSettings>, workspace: any Workspace, cacheDirectory: URL, agentFiles: AgentFiles) {
        self.settings = settings
        self.workspace = workspace
        self.cacheDirectory = cacheDirectory
        self.agentFiles = agentFiles
    }

    private struct WeakPane {
        weak var pane: BrowserPane?
    }

    #if DEBUG
    /// Where a popup's URL went, in tests instead of the OS.
    var openedExternally: [URL] = []
    var capturesExternalOpens = false
    #endif

    func openExternal(_ url: URL) {
        #if DEBUG
        if capturesExternalOpens {
            openedExternally.append(url)
            return
        }
        #endif
        NSWorkspace.shared.open(url)
    }

    func remember(_ pane: BrowserPane) {
        panes.removeAll { $0.pane == nil }
        panes.append(WeakPane(pane: pane))
    }

    var livePanes: [BrowserPane] { panes.compactMap(\.pane) }

    func pane(_ id: PaneID) -> BrowserPane? { livePanes.first { $0.pane.paneID == id } }
}
