import AppKit
import TabsCore
import TabsPluginSDK

/// The AppKit shell around a `CoreRuntime`: core's layout engine drawn by the
/// AppKit renderer, the command router and the main menu, kept in step with
/// plugins and shortcuts. The app and the in-process UI tests build the same one.
@MainActor
final class AppShell {
    let runtime: CoreRuntime
    let engine: LayoutEngine
    let renderer: WorkspaceRenderer
    let router: CommandRouter
    let input: WorkspaceInput
    /// File ▸ Caffeinate…'s dialog.
    let caffeinateDialog: CaffeinateDialogPresenter
    /// Beyond the menu and empty panes: the app refreshes its Settings window.
    var pluginsDidChange: (@MainActor () -> Void)?
    private var subscriptions: [Subscription] = []
    private var keyWindowObservers: [any NSObjectProtocol] = []
    private var appearanceObservation: NSKeyValueObservation?

    init(runtime: CoreRuntime, presentsWindows: Bool) {
        self.runtime = runtime
        engine = LayoutEngine(runtime: runtime)
        renderer = WorkspaceRenderer(runtime: runtime, engine: engine, presentsWindows: presentsWindows)
        router = CommandRouter(runtime: runtime, engine: engine)
        input = WorkspaceInput(renderer: renderer, runtime: runtime)
        caffeinateDialog = CaffeinateDialogPresenter(caffeinate: runtime.caffeinate, presentsWindows: presentsWindows)
        router.showCaffeinateDialog = { [weak caffeinateDialog] in caffeinateDialog?.show() }
        router.isWorkspaceWindow = { [weak renderer] window in renderer?.isWorkspaceWindow(window) ?? false }
        router.windowController = { [weak renderer] id in renderer?.windowController(id) }
        applyPaneSettings(runtime.settings.panes)
        subscriptions.append(runtime.settings.observePanes { [weak self] settings in self?.applyPaneSettings(settings) })
        // Every window's root bar shows the cup while caffeinate runs; the menu
        // item relabels itself (Caffeinate… / Decaf) when validated.
        renderer.baseAppearance.caffeinateRunning = runtime.caffeinate.isRunning
        subscriptions.append(
            runtime.caffeinate.observe { [weak self] running in self?.renderer.baseAppearance.caffeinateRunning = running })
        // `system` follows the OS appearance while running.
        appearanceObservation = NSApp?.observe(\.effectiveAppearance) { [weak self] _, _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.applyPaneSettings(self.runtime.settings.panes)
            }
        }
        installMenu()
        engine.activeContentTypeDidChange = { [weak self] _ in self?.armShortcuts() }
        // Scoped chords are the active pane's; with another window key (Settings,
        // Plugins) they'd take keys typed there, so they're disarmed.
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification] {
            keyWindowObservers.append(
                NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.armShortcuts() }
                })
        }
        // Coming back to the app is looking at the key window's active pane again.
        keyWindowObservers.append(
            NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) {
                [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, let key = NSApp.keyWindow, let controller = self.renderer.windows.first(where: { $0.window === key })
                    else { return }
                    self.engine.windowDidGainFocus(controller.windowID)
                }
            })
        // Leaving the app is looking away from every window's active pane.
        keyWindowObservers.append(
            NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) {
                [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    for controller in self.renderer.windows { self.engine.windowDidLoseFocus(controller.windowID) }
                }
            })
        // Enabling or disabling a plugin changes what may be created and which
        // settings pages exist; rebinding a shortcut changes the menu.
        subscriptions.append(
            runtime.host.observeChanges { [weak self] in
                self?.installMenu()
                self?.renderer.refreshEmptyPanes()
                self?.pluginsDidChange?()
            })
        subscriptions.append(runtime.shortcuts.observeChanges { [weak self] in self?.installMenu() })
    }

    /// The chrome's look from the pane settings, and the appearance of everything else the app shows.
    func applyPaneSettings(_ settings: SettingsStore.PaneSettings) {
        // The app's own appearance first: `system` is read from the OS, which a pinned one hides.
        let pinned = NSAppearance.pinned(by: settings.colorTheme)
        if NSApp?.appearance?.name != pinned?.name { NSApp?.appearance = pinned }
        let systemIsDark = NSApp?.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        var appearance = renderer.baseAppearance
        appearance.theme = Theme.resolve(settings.colorTheme, systemIsDark: systemIsDark)
        appearance.dimInactivePanes = settings.dimInactivePanes
        appearance.dimIntensity = settings.dimInactivePanesIntensity
        appearance.showNavFlash = settings.showNavFlash
        appearance.snapResizeSeparators = settings.snapResizeSeparators
        appearance.spawnPosition = settings.spawnPosition
        renderer.baseAppearance = appearance
    }

    func installMenu() {
        NSApp.mainMenu = MainMenu.build(runtime: runtime, router: router)
        armShortcuts()
    }

    /// Arms the active pane type's scoped chords — unless a window other than
    /// a workspace window is key (nil: none is, as under tests).
    func armShortcuts(keyWindow: NSWindow? = NSApp.keyWindow) {
        guard let menu = NSApp.mainMenu else { return }
        let elsewhere = keyWindow.map { key in !renderer.windows.contains { $0.window === key } } ?? false
        MainMenu.arm(menu, for: elsewhere ? nil : engine.activeContentType, runtime: runtime)
    }

    func stop() {
        input.stop()
        caffeinateDialog.dismiss()
        appearanceObservation = nil
        NSApp?.appearance = nil
        for subscription in subscriptions { subscription.cancel() }
        subscriptions.removeAll()
        for observer in keyWindowObservers { NotificationCenter.default.removeObserver(observer) }
        keyWindowObservers.removeAll()
    }
}
