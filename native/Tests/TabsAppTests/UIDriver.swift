import AppKit
import TabsPluginSDK
import Testing

@testable import Tabs
@testable import TabsCore

/// Drives the real AppKit shell with synthesized input, in windows that are
/// never shown: the in-process UI tier. Builds a runtime with the shipped
/// plugins, a workspace and the real main menu (installed as NSApp's for the
/// driver's lifetime, so suites using it live under the serialized `AppUI`).
/// The stand-in plugins (`StandIns`: text and inert panes) run beside them when
/// the layout uses its types or `standIns` asks for it.
///
/// Clicks and drags reach the chrome the way the mouse does: hit-tested at a
/// point, the press delivered to what's there, the rest of a drag queued for
/// the tracking loop that press starts (see `InputSynthesizer`).
@MainActor
final class UIDriver {
    let runtime: CoreRuntime
    let shell: AppShell
    var engine: LayoutEngine { shell.engine }
    var renderer: WorkspaceRenderer { shell.renderer }
    var router: CommandRouter { shell.router }
    private let previousMenu: NSMenu?

    init(
        layout: SavedLayout? = nil, disabled: [PluginID] = [], inProcess: [PluginCandidate] = [],
        panes: SettingsStore.PaneSettings? = nil, requiring: Set<ContentTypeID> = [], standIns: Bool = false
    ) {
        runtime = TestSupport.runtime()
        for id in disabled { runtime.settings.setDisabled(true, for: id) }
        if let panes { runtime.settings.setPanes(panes) }
        if inProcess.isEmpty {
            let types = layout?.contentTypes ?? []
            let stand = standIns || !types.isDisjoint(with: ["text", "inert"])
            runtime.startPlugins(
                from: Bundle.main.builtInPlugInsURL, bundled: BuildStamp(of: .main)?.bundledPlugins ?? [],
                inProcess: stand ? StandIns.candidates() : [], requiredContentTypes: types)
        } else {
            runtime.startPlugins(from: nil, inProcess: inProcess, requiredContentTypes: (layout?.contentTypes ?? []).union(requiring))
        }
        previousMenu = NSApp.mainMenu
        shell = AppShell(runtime: runtime, presentsWindows: false)
        // The harness's look, not the OS's: a square window corner.
        renderer.baseAppearance.cornerRadius = 0
        shell.engine.restore(layout)
        layoutAll()
    }

    isolated deinit {
        if renderer.drag.isDragging { renderer.drag.endSimulation() }
        HeaderMenu.close()
        ChromeTooltip.hide()
        shell.stop()
        NSApp.mainMenu = previousMenu
        for window in renderer.windows {
            window.isClosingForModel = true
            window.window?.close()
            window.dismantle()
        }
        runtime.host.stop()
    }

    // MARK: Where things are

    var window: WorkspaceWindowController {
        get throws { try #require(renderer.frontmostController, "no workspace window") }
    }

    func window(_ id: WindowID) throws -> WorkspaceWindowController {
        try #require(renderer.windowController(id), "no window \(id)")
    }

    /// The frontmost window's layout.
    var layout: WindowLayout {
        get throws {
            let id = try window.windowID
            return try #require(engine.model.window(id))
        }
    }

    /// The leaf with the keyboard in the frontmost window (what the Workspace API calls the active pane).
    var activePane: PaneID? { renderer.frontmostController?.layout.activeLeafID }

    /// The frontmost window's active node (a leaf or a tab group).
    var activeNode: NodeID? { renderer.frontmostController?.layout.activePaneID }

    /// The pane whose body holds the frontmost window's keyboard focus.
    var focusedPane: PaneID? {
        guard let window = renderer.frontmostController?.window else { return nil }
        return focusedPane(in: window)
    }

    func focusedPane(in window: NSWindow) -> PaneID? {
        var view = window.firstResponder as? NSView
        while let current = view {
            if let body = current as? PaneBodyHost { return body.paneID }
            view = current.superview
        }
        return nil
    }

    func body(_ pane: PaneID) throws -> PaneBodyHost {
        try #require(renderer.body(for: pane), "no body for \(pane)")
    }

    func contentType(of pane: PaneID) -> ContentTypeID? { engine.model.leaf(pane)?.type }

    func paneView(_ id: NodeID, in window: WorkspaceWindowController? = nil) throws -> PaneView {
        let controller = try window ?? self.window
        return try #require(controller.paneView(id), "no pane view \(id)")
    }

    func tabView(_ tab: NodeID, in window: WorkspaceWindowController? = nil) throws -> TabView {
        let controller = try window ?? self.window
        let nsWindow = try #require(controller.window)
        let view = try #require(InputSynthesizer.find("tab-\(tab.rawValue)", in: nsWindow), "no tab \(tab)")
        return try #require(view as? TabView)
    }

    func split(_ id: NodeID, in window: WorkspaceWindowController? = nil) throws -> SplitNodeView {
        let controller = try window ?? self.window
        return try #require(controller.splitViews.first { $0.nodeID == id }, "no split \(id)")
    }

    func view(_ identifier: String) throws -> NSView {
        try #require(InputSynthesizer.find(identifier, in: try window.window!), "no view \(identifier)")
    }

    /// The pane's persisted state as core would save it now.
    func config(of pane: PaneID) -> JSONValue? {
        runtime.panes.pane(pane).map(runtime.panes.snapshot)?.config
    }

    /// A point in a view, in the window's content coordinates (top-left origin).
    func contentPoint(_ point: NSPoint, in view: NSView) throws -> NSPoint {
        let controller = try #require(renderer.windows.first { $0.window === view.window })
        return view.convert(point, to: controller.root)
    }

    /// Lays every window out, as a display pass would.
    func layoutAll() {
        for controller in renderer.windows { controller.root.layoutSubtreeIfNeeded() }
    }

    // MARK: Input

    func click(_ identifier: String, in pane: PaneID? = nil) throws {
        layoutAll()
        try InputSynthesizer.click(
            identifier, in: try window.window!, within: pane.flatMap { id in renderer.windows.lazy.compactMap { $0.paneView(id) }.first },
            input: shell.input)
    }

    /// Clicks at `point` in `view` (its own coordinates).
    func click(at point: NSPoint, in view: NSView, count: Int = 1, right: Bool = false) throws {
        layoutAll()
        try InputSynthesizer.click(at: point, in: view, count: count, right: right, input: shell.input)
    }

    /// Clicks `view` at its center.
    func click(_ view: NSView, count: Int = 1, right: Bool = false) throws {
        try click(at: NSPoint(x: view.bounds.midX, y: view.bounds.midY), in: view, count: count, right: right)
    }

    /// Clicks a pane's body near its corner, clear of what it shows (an empty
    /// pane's creation buttons sit at its center): activates it and nothing else.
    func click(body pane: PaneID) throws {
        try click(at: NSPoint(x: 8, y: 8), in: try body(pane))
    }

    /// Clicks a tab (on its title, clear of the close button).
    func click(tab: NodeID, count: Int = 1, right: Bool = false, in window: WorkspaceWindowController? = nil) throws {
        let view = try tabView(tab, in: window)
        let title = view.titleRect
        try click(at: NSPoint(x: title.minX + min(8, title.width / 2), y: title.midY), in: view, count: count, right: right)
    }

    /// Clicks a tab's close button.
    func close(tab: NodeID) throws {
        let view = try tabView(tab)
        try click(at: NSPoint(x: view.closeRect.midX, y: view.closeRect.midY), in: view)
    }

    /// Clicks an empty pane's button for `type` (the active pane's by default).
    func create(_ type: ContentTypeID, in pane: PaneID? = nil) throws {
        layoutAll()
        let id = try #require(pane ?? activePane, "no pane to create in")
        try InputSynthesizer.create(type, in: try body(id), input: shell.input)
    }

    /// A pane's header (a leaf's title bar, or a group's tab bar).
    func chrome(_ pane: NodeID, in window: WorkspaceWindowController? = nil) throws -> NSView {
        let view = try paneView(pane, in: window)
        return try #require(view.header ?? view.tabBar, "\(pane) has no chrome")
    }

    /// A header control of `pane` (`pane-split-horizontal-button`, `pane-close-button`, …).
    func control(_ identifier: String, of pane: NodeID) throws -> MenuGroupButton {
        let chrome = try chrome(pane)
        return try #require(InputSynthesizer.find(identifier, in: try window.window!, within: chrome) as? MenuGroupButton)
    }

    /// Hovers `view` at `point` (its coordinates): chrome under it shows `:hover`.
    func hover(at point: NSPoint, in view: NSView) throws {
        let controller = try #require(renderer.windows.first { $0.window === view.window })
        ChromeHover.update(view.convert(point, to: controller.root), in: controller.root)
        if let event = InputSynthesizer.mouseEvent(.mouseMoved, at: view.convert(point, to: nil), in: controller.window!) {
            HeaderMenu.simulatePointer(event)
        }
    }

    /// The pointer leaves the window: nothing is hovered, and an open header menu starts its close delay.
    func unhover(_ controller: WorkspaceWindowController) {
        ChromeHover.update(nil, in: controller.root)
        if let window = controller.window, let event = InputSynthesizer.mouseEvent(.mouseMoved, at: NSPoint(x: -100, y: -100), in: window) {
            HeaderMenu.simulatePointer(event)
        }
    }

    /// Opens a header control's menu (by hovering it), moves onto the row for
    /// `action` and clicks it, then moves off; returns once the menu has closed
    /// (a disabled row leaves it open until the pointer has been away 0.2s).
    func choose(_ action: HeaderAction, of pane: NodeID) throws {
        let root = try control(action.menuRoot.accessibilityID, of: pane)
        try hover(at: NSPoint(x: root.bounds.midX, y: root.bounds.midY), in: root)
        let dropdown = try #require(HeaderMenu.openDropdown, "the menu didn't open")
        let row = try #require(dropdown.items.firstIndex { $0.action == action })
        let frame = dropdown.rowFrame(row)
        let point = NSPoint(x: frame.midX, y: frame.midY)
        try hover(at: point, in: dropdown)
        try click(at: point, in: dropdown)
        if let controller = renderer.windows.first(where: { $0.window === root.window }) { unhover(controller) }
        let deadline = Date().addingTimeInterval(1)
        while HeaderMenu.openDropdown != nil, Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        layoutAll()
    }

    /// The open context menu's panel (its rows are drawn: 12pt text, 6pt padding, in a 4pt-padded, bordered panel).
    var contextMenu: NSView? {
        guard let controller = renderer.frontmostController, let window = controller.window else { return nil }
        return InputSynthesizer.find("context-menu", in: window, within: controller.root.overlay)
    }

    private var contextRowHeight: CGFloat { ChromeText(size: 12).lineHeight + 12 }

    /// How many items the open context menu has.
    var contextMenuCount: Int {
        guard let panel = contextMenu else { return 0 }
        return Int(((panel.frame.height - 10) / contextRowHeight).rounded())
    }

    /// Chooses the open context menu's item at `index`.
    func chooseContextItem(_ index: Int) throws {
        let panel = try #require(contextMenu, "no context menu")
        let backdrop = try #require(panel.superview)
        let point = NSPoint(x: panel.frame.midX, y: panel.frame.minY + 5 + (CGFloat(index) + 0.5) * contextRowHeight)
        try click(at: point, in: backdrop)
    }

    /// The dialog card a pane's question is showing (needs
    /// `renderer.showsDialogCardsUnattended`: with no window shown a question
    /// answers itself and there is no card).
    var dialog: DialogCard? { renderer.dialogCards.last { !$0.isFinished } }

    /// Waits for a pane's question to show its card.
    func waitForDialog(timeout: TimeInterval = 5) async throws -> DialogCard {
        let deadline = Date().addingTimeInterval(timeout)
        while dialog == nil, Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        layoutAll()
        return try #require(dialog, "no dialog card")
    }

    /// Presses a dialog button as a click does: `dialog-confirm`, `dialog-cancel` or `dialog-ok`.
    func pressDialogButton(_ identifier: String) throws {
        let card = try #require(dialog, "no dialog card")
        let button = try #require(card.buttons.first { $0.accessibilityIdentifier() == identifier }, "no dialog button \(identifier)")
        try click(button)
    }

    /// Picks `index` in the open choose dialog's select, through its menu.
    func chooseDialogOption(_ index: Int) throws {
        let card = try #require(dialog, "no dialog card")
        try click(try #require(card.select, "the dialog has no select"))
        try chooseContextItem(index)
    }

    /// Clicks the dimmed backdrop outside the card: the dialog is dismissed.
    func clickDialogBackdrop() throws {
        let card = try #require(dialog, "no dialog card")
        try click(at: NSPoint(x: 4, y: 4), in: card)
    }

    /// Presses at `start` in `view` and drags through `steps`.
    func drag(from start: NSPoint, in view: NSView, _ steps: [InputSynthesizer.DragStep]) throws {
        layoutAll()
        try InputSynthesizer.drag(from: start, in: view, steps, input: shell.input)
        layoutAll()
    }

    /// A point of another window's content, in `view`'s coordinates (a drag's
    /// path is in the pressed view's terms; the drag follows the screen).
    func point(_ point: NSPoint, of target: NSView, from view: NSView) throws -> NSPoint {
        let targetWindow = try #require(target.window)
        let sourceWindow = try #require(view.window)
        let screen = targetWindow.convertPoint(toScreen: target.convert(point, to: nil))
        return view.convert(sourceWindow.convertPoint(fromScreen: screen), from: nil)
    }

    func type(_ text: String) throws {
        InputSynthesizer.type(text, into: try window.window!)
    }

    func type(_ text: String, in controller: WorkspaceWindowController) throws {
        InputSynthesizer.type(text, into: try #require(controller.window))
    }

    /// One physical key (see `InputSynthesizer.Key`) to the front window's first responder.
    func key(_ keyCode: UInt16, modifiers: NSEvent.ModifierFlags = [], in controller: WorkspaceWindowController? = nil) throws {
        let controller = try controller ?? window
        InputSynthesizer.key(keyCode, modifiers: modifiers, into: try #require(controller.window))
    }

    /// Creates a pane of the type the palette lists as `name`, placed as a new
    /// tab beside the active pane: ⌘P, the type's digit, then 1 (Tab).
    func createViaPalette(_ name: String) throws {
        try press(KeyChord("p", [.command]))
        let palette = try #require(palette, "⌘P opened no palette")
        let row = try #require(
            palette.rows.firstIndex { $0.label == name }, "the palette doesn't list \(name): \(palette.rows.map(\.label))")
        try key(InputSynthesizer.Key.digit(row + 1))
        try key(InputSynthesizer.Key.digit(1))
    }

    /// The command palette open in the front window, if any.
    var palette: PaletteView? { renderer.frontmostController.flatMap { Palette.current(in: $0) } }

    @discardableResult
    func press(_ chord: KeyChord) throws -> Bool {
        InputSynthesizer.press(chord, in: try window.window!, input: shell.input)
    }

    /// Lets timers and deferred work run (a fly-back, a menu's close delay).
    func settle(_ seconds: TimeInterval = 0.3) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
        layoutAll()
    }

    /// Chooses a menu item as a user would: validated first, and only if enabled.
    func choose(_ path: String...) throws {
        struct Disabled: Error, CustomStringConvertible { let description: String }
        let item = try menuItem(path)
        guard item.isEnabled, let menu = item.menu else { throw Disabled(description: "\(path.joined(separator: " ▸ ")) is disabled") }
        menu.performActionForItem(at: menu.index(of: item))
    }

    /// The menu item at `path`, validated the way AppKit does before showing a
    /// menu (current enabled state and checkmark).
    func menuItem(_ path: String...) throws -> NSMenuItem {
        try menuItem(path)
    }
    private func menuItem(_ path: [String]) throws -> NSMenuItem {
        struct Missing: Error, CustomStringConvertible { let description: String }
        var menu: NSMenu? = NSApp.mainMenu
        var item: NSMenuItem?
        for (index, title) in path.enumerated() {
            guard let found = menu?.item(withTitle: title) else {
                throw Missing(description: "no menu item \(path[...index].joined(separator: " ▸ "))")
            }
            found.menu?.update()
            item = found
            menu = found.submenu
        }
        guard let item else { throw Missing(description: "empty menu path") }
        return item
    }
}

extension HeaderAction {
    /// The root button of the menu this action is in.
    var menuRoot: HeaderAction {
        switch self {
        case .close, .clear: .close
        default: .splitHorizontal
        }
    }
}
