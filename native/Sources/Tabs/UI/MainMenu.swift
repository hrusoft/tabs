import AppKit
import TabsCore
import TabsPluginSDK

/// Performs and validates menu commands. Layout actions go to the layout
/// engine; the rule about whose pane a plugin command may touch is core's
/// (`CommandCenter`). The context is the frontmost window's active pane.
@MainActor
final class CommandRouter: NSObject, NSMenuItemValidation {
    private let runtime: CoreRuntime
    private let engine: LayoutEngine?
    /// Tells workspace windows from the app's others (Settings, Plugins).
    var isWorkspaceWindow: (@MainActor (NSWindow) -> Bool)?

    /// `engine` nil: no windows (a menu built without a shell, in tests).
    init(runtime: CoreRuntime, engine: LayoutEngine? = nil) {
        self.runtime = runtime
        self.engine = engine
    }

    private var context: (window: WindowID?, pane: PaneID?, type: ContentTypeID?) {
        (engine?.frontmostWindowID, engine?.activePaneID, engine?.activeContentType)
    }

    /// What a command of `owner` sees now.
    func invocation(for owner: PluginID) -> CommandInvocation {
        runtime.commands.invocation(for: owner, window: context.window, pane: context.pane, contentType: context.type)
    }

    private func command(for item: NSMenuItem) -> Owned<CommandContribution>? {
        (item.representedObject as? CommandID).flatMap(runtime.commands.command)
    }

    /// Not `perform(_:)`: `#selector(perform(_:))` resolves to NSObject's
    /// `performSelector:`, which then treats the menu item as a selector.
    @objc func performCommand(_ sender: NSMenuItem) {
        guard let command = command(for: sender) else { return }
        runtime.commands.perform(command.value.id, window: context.window, pane: context.pane, contentType: context.type)
    }

    // MARK: Layout actions (explicit menu targets)

    /// The frontmost window's controller and its active pane.
    var frontWindow: (controller: WorkspaceWindowController, active: NodeID)? {
        guard let engine, let id = engine.frontmostWindowID, let controller = windowController?(id),
            let layout = engine.model.window(id)
        else { return nil }
        return (controller, layout.activePaneID)
    }

    /// Finds a workspace window's controller (the shell's renderer).
    var windowController: (@MainActor (WindowID) -> WorkspaceWindowController?)?

    @objc func newWindow(_ sender: Any?) {
        engine?.openWindow()
    }

    /// New Tab, and both splits: new content like the active pane, placed
    /// beside it — the same as its header's buttons.
    @objc func newTab(_ sender: Any?) {
        guard let engine else { return }
        if let (controller, active) = frontWindow {
            engine.newPane(like: active, in: controller.windowID, placement: .tab)
        } else {
            engine.openWindow()
        }
    }

    @objc func splitHorizontal(_ sender: Any?) {
        guard let (controller, active) = frontWindow else { return }
        engine?.newPane(like: active, in: controller.windowID, placement: .split(.horizontal))
    }

    @objc func splitVertical(_ sender: Any?) {
        guard let (controller, active) = frontWindow else { return }
        engine?.newPane(like: active, in: controller.windowID, placement: .split(.vertical))
    }

    @objc func newUnpinnedPane(_ sender: Any?) {
        guard let (controller, active) = frontWindow else { return }
        controller.newUnpinnedPane(from: active)
    }

    /// File ▸ New Content… (⌘P): the palette in the front window, aimed at its
    /// active pane. Nothing while another of the app's windows (Settings,
    /// Plugins) is key: those have no palette to open.
    @objc func showPalette(_ sender: Any?) {
        if let key = NSApp.keyWindow, isWorkspaceWindow?(key) == false { return }
        guard let (controller, _) = frontWindow else { return }
        Palette.open(in: controller)
    }

    /// Opens the Caffeinate dialog (the shell's presenter).
    var showCaffeinateDialog: (@MainActor () -> Void)?

    /// File ▸ Caffeinate… / Decaf: running, it stops the process directly;
    /// not running, it opens the dialog that collects the flags to start one
    /// (Electron's `caffeinateMenuItem`). The dialog is a window of its own, so
    /// it needs no workspace window, whichever window is key.
    @objc func caffeinate(_ sender: Any?) {
        if runtime.caffeinate.isRunning {
            runtime.caffeinate.stop()
            return
        }
        showCaffeinateDialog?()
    }

    @objc func closePane(_ sender: Any?) {
        close(keyWindow: NSApp.keyWindow)
    }

    /// ⌘W closes the active pane — the tab it shows, on the window's own bar —
    /// unless another of the app's windows (Settings, Plugins) is key: then
    /// that window, never a pane behind it.
    func close(keyWindow: NSWindow?) {
        if let keyWindow, isWorkspaceWindow?(keyWindow) == false {
            keyWindow.performClose(nil)
            return
        }
        guard let engine, let (_, active) = frontWindow else { return }
        engine.close(active)
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(newWindow(_:)), #selector(newTab(_:)), #selector(showPalette(_:)): return engine != nil
        case #selector(splitHorizontal(_:)), #selector(splitVertical(_:)), #selector(newUnpinnedPane(_:)): return frontWindow != nil
        case #selector(caffeinate(_:)):
            // Relabeled live: the label is the state, read whenever the menu is.
            item.title = runtime.caffeinate.isRunning ? "Decaf" : CoreCommands.caffeinate.title
            return true
        case #selector(closePane(_:)):
            if let key = NSApp.keyWindow, isWorkspaceWindow?(key) == false { return true }
            return frontWindow != nil
        default: break
        }
        guard let command = command(for: item) else { return false }
        item.state = command.value.isChecked?() == true ? .on : .off
        return runtime.commands.isEnabled(command, invocation(for: command.owner))
    }
}

/// The menu bar: core's items and every plugin command, each with the chord
/// core's shortcut table gives it.
@MainActor
enum MainMenu {
    static func build(runtime: CoreRuntime, router: CommandRouter) -> NSMenu {
        let shortcuts = runtime.shortcuts
        let main = NSMenu()
        var menus: [MenuPlacement: NSMenu] = [:]

        /// A core item, its chord from the table (the user may have rebound it).
        @discardableResult
        func add(_ command: CoreCommand, _ action: Selector, to menu: NSMenu, target: AnyObject? = nil) -> NSMenuItem {
            let item = menu.addItem(withTitle: command.title, action: action, keyEquivalent: "")
            item.target = target
            item.identifier = NSUserInterfaceItemIdentifier(command.id.rawValue)
            setChord(shortcuts.chord(for: command.id), on: item)
            return item
        }

        let app = submenu("Tabs", in: main)
        app.addItem(withTitle: AboutCopy.windowTitle, action: #selector(AppDelegate.showAbout(_:)), keyEquivalent: "")
        app.addItem(.separator())
        add(CoreCommands.settings, #selector(AppDelegate.showSettings(_:)), to: app)
        add(CoreCommands.plugins, #selector(AppDelegate.showPlugins(_:)), to: app)
        app.addItem(.separator())
        add(CoreCommands.hide, #selector(NSApplication.hide(_:)), to: app)
        add(CoreCommands.hideOthers, #selector(NSApplication.hideOtherApplications(_:)), to: app)
        app.addItem(withTitle: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        app.addItem(.separator())
        add(CoreCommands.quit, #selector(NSApplication.terminate(_:)), to: app)

        let file = submenu("File", in: main)
        menus[.file] = file
        // Window actions target the router, which resolves the frontmost
        // workspace window — not the responder chain, which would start at
        // whatever is key (Settings, Plugins) and find no tab to act on.
        add(CoreCommands.newWindow, #selector(CommandRouter.newWindow(_:)), to: file, target: router)
        file.addItem(.separator())
        add(CoreCommands.commandPalette, #selector(CommandRouter.showPalette(_:)), to: file, target: router)
        file.addItem(.separator())
        add(CoreCommands.newTab, #selector(CommandRouter.newTab(_:)), to: file, target: router)
        add(CoreCommands.splitHorizontal, #selector(CommandRouter.splitHorizontal(_:)), to: file, target: router)
        add(CoreCommands.splitVertical, #selector(CommandRouter.splitVertical(_:)), to: file, target: router)
        add(CoreCommands.newUnpinnedPane, #selector(CommandRouter.newUnpinnedPane(_:)), to: file, target: router)
        add(CoreCommands.closePane, #selector(CommandRouter.closePane(_:)), to: file, target: router)
        file.addItem(.separator())
        add(CoreCommands.caffeinate, #selector(CommandRouter.caffeinate(_:)), to: file, target: router)

        let edit = submenu("Edit", in: main)
        menus[.edit] = edit
        add(CoreCommands.undo, Selector(("undo:")), to: edit)
        add(CoreCommands.redo, Selector(("redo:")), to: edit)
        edit.addItem(.separator())
        add(CoreCommands.cut, #selector(NSText.cut(_:)), to: edit)
        add(CoreCommands.copy, #selector(NSText.copy(_:)), to: edit)
        add(CoreCommands.paste, #selector(NSText.paste(_:)), to: edit)
        add(CoreCommands.selectAll, #selector(NSText.selectAll(_:)), to: edit)

        menus[.view] = submenu("View", in: main)

        let window = submenu("Window", in: main)
        menus[.window] = window
        add(CoreCommands.minimize, #selector(NSWindow.performMiniaturize(_:)), to: window)
        window.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        NSApp?.windowsMenu = window

        // Plugin commands, grouped per plugin in UI order. Chords of commands
        // that apply to one content type are armed by `arm(_:for:shortcuts:)`.
        let commands = runtime.registry.contributions(to: .commands)
            .sorted { runtime.host.rank(of: $0.owner) < runtime.host.rank(of: $1.owner) }
        var lastOwner: [MenuPlacement: PluginID] = [:]
        for command in commands {
            guard let menu = menus[command.value.menu] else { continue }
            if lastOwner[command.value.menu] != command.owner, !menu.items.isEmpty { menu.addItem(.separator()) }
            lastOwner[command.value.menu] = command.owner
            let item = menu.addItem(withTitle: command.value.title, action: #selector(CommandRouter.performCommand(_:)), keyEquivalent: "")
            item.target = router
            item.representedObject = command.value.id
            item.identifier = NSUserInterfaceItemIdentifier(command.value.id.rawValue)
            if command.value.appliesTo == nil { setChord(shortcuts.chord(for: command.value.id), on: item) }
        }
        if menus[.view]?.items.isEmpty == true, let view = main.item(withTitle: "View") { main.removeItem(view) }
        return main
    }

    /// Arms the chords of commands that apply to one content type: only those
    /// for `activeType` carry a key equivalent. AppKit stops at the first menu
    /// item whose key equivalent matches — even a disabled one — so this is
    /// what lets commands for different pane types share a chord, and keeps a
    /// pane type's ⌃ chords from shadowing keys typed into any other pane.
    static func arm(_ menu: NSMenu, for activeType: ContentTypeID?, runtime: CoreRuntime) {
        for item in menu.items {
            if let submenu = item.submenu { arm(submenu, for: activeType, runtime: runtime) }
            guard let id = item.representedObject as? CommandID, let binding = runtime.shortcuts.binding(for: id),
                let scope = binding.scope
            else { continue }
            setChord(scope == activeType ? binding.chord : nil, on: item)
        }
    }

    private static func setChord(_ chord: KeyChord?, on item: NSMenuItem) {
        item.keyEquivalent = chord?.menuKeyEquivalent ?? ""
        item.keyEquivalentModifierMask = chord?.eventModifierFlags ?? []
    }

    private static func submenu(_ title: String, in main: NSMenu) -> NSMenu {
        let menu = NSMenu(title: title)
        main.addItem(withTitle: title, action: nil, keyEquivalent: "").submenu = menu
        return menu
    }
}
