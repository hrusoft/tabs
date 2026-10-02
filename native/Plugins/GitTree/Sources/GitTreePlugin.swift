import AppKit
import TabsPluginSDK

/// The git tree plugin: a repository's commit graph in a pane, the Electron
/// app's `packages/plugin-gitTree` (docs/GIT-TREE.md lists every case).
///
/// It contributes the `git-tree` content type (opening on the directory of
/// the pane it's made from, else the app's own repository or home), View ▸
/// Refresh (⌘R) for it, and Settings ▸ Git tree. It owns no process past a
/// read and nothing to flush at quit.
@MainActor
final class GitTreePlugin: NSObject, TabsPlugin {
    private(set) var services: GitTreeServices?

    func activate(_ context: any PluginContext) throws {
        let settings = context.settings(GitTreeSettings.self)
        // The workspace handle, not the context: a contribution holding its
        // own plugin's context keeps it alive.
        let workspace = context.workspace
        let services = GitTreeServices()
        self.services = services

        context.register(
            ContentTypeContribution(
                id: "git-tree", displayName: "Git tree", icon: .image(GitTreeGlyphs.gitTree), creationLabel: "New git tree",
                // Open on the repository the origin pane is in: "the history of
                // what this shell is looking at". Ungated (a git tree's
                // directory is its subject); an origin offering nothing falls
                // through to the default directory, adopted on open.
                initialConfig: { creation in
                    guard let origin = creation.origin, let directory = workspace.capability(.workingDirectory, of: origin) else {
                        return .emptyObject
                    }
                    return .object(["cwd": .string(directory.path)])
                },
                makePane: { pane in
                    let gitTree = try GitTreePane(pane: pane, settings: settings, services: services)
                    services.remember(gitTree)
                    return gitTree
                }))

        context.register(
            CommandContribution(
                id: "git-tree.refresh", title: "Refresh", summary: "Re-read the active git tree.", menu: .view,
                defaultChord: KeyChord("r", [.command]), appliesTo: "git-tree"
            ) { invocation in
                invocation.pane(as: GitTreePane.self)?.refresh()
            })

        context.register(
            SettingsPageContribution(id: "git-tree", title: "Git tree", symbolName: "arrow.triangle.branch") {
                GitTreeSettingsPage(settings: settings)
            })

        #if DEBUG
        GitTreeTestVerbs.register(in: context, services: services)
        #endif
    }
}

/// What the plugin's panes share: where git answers come from, the live panes
/// (a checkout refreshes the others on the same directory), and the few
/// process facts a pane needs.
@MainActor
final class GitTreeServices {
    private var panes: [WeakPane] = []

    private struct WeakPane {
        weak var pane: GitTreePane?
    }

    #if DEBUG
    /// Scripted git for tests and the visual capture, used by every pane made
    /// after it's set.
    var sourceOverride: (any GitSource)?
    /// What Copy SHA-1 copied, in tests instead of the pasteboard.
    var copiedOverride: ((String) -> Void)?
    #endif

    func source(for pane: any PaneContext) -> any GitSource {
        #if DEBUG
        if let sourceOverride { return sourceOverride }
        #endif
        let manager = FileManager.default
        let appDirectory = manager.fileExists(atPath: manager.currentDirectoryPath) ? manager.currentDirectoryPath : nil
        return GitRepositorySource(
            environment: pane.childEnvironment, appDirectory: appDirectory, home: manager.homeDirectoryForCurrentUser.path)
    }

    func remember(_ pane: GitTreePane) {
        panes.removeAll { $0.pane == nil }
        panes.append(WeakPane(pane: pane))
    }

    func forget(_ pane: GitTreePane) {
        panes.removeAll { $0.pane == nil || $0.pane === pane }
    }

    var livePanes: [GitTreePane] { panes.compactMap(\.pane) }

    /// After a checkout: this pane, and every other git tree on exactly the
    /// same directory string (not "the same repository": that would take a
    /// `rev-parse` per pane per checkout, for a setup few users have).
    func refreshAfterCheckout(from origin: GitTreePane, dir: String) {
        origin.refresh()
        for pane in livePanes where pane !== origin && pane.configuredDir == dir {
            pane.refresh()
        }
    }

    func copyText(_ text: String) {
        #if DEBUG
        if let copiedOverride {
            copiedOverride(text)
            return
        }
        #endif
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }
}
