import AppKit
import TabsCore
import TabsPluginSDK

/// Draws core's layout model in AppKit windows (`LayoutRenderer`). Windows
/// and pane bodies are reconciled with the model by id: a pane's body — and
/// so its content view — lives as long as the pane is in the layout,
/// wherever it moves.
@MainActor
final class WorkspaceRenderer: LayoutRenderer {
    let engine: LayoutEngine
    let runtime: CoreRuntime
    /// false in tests: windows are built but never ordered on screen.
    let presentsWindows: Bool
    private var controllers: [WindowID: WorkspaceWindowController] = [:]
    private var bodies: [PaneID: PaneBodyHost] = [:]
    /// The workspace window that was last key: still the one the user is in
    /// while the app is hidden or every window is minimized.
    private var lastKey: WindowID?
    /// Dragging tabs and panes, within and between windows.
    private(set) lazy var drag = DragController(renderer: self)
    /// What the chrome looks like (theme and pane settings).
    var baseAppearance = PaneAppearance() {
        didSet { if oldValue != baseAppearance { refreshAll() } }
    }
    /// What an empty pane offers, when not the plugins' types (the visual capture).
    var creationActionsOverride: [EmptyPaneView.Action]?
    /// Which windows have the focus, when a test decides (never-shown windows
    /// are never key).
    var focusOverride: ((WindowID) -> Bool)?
    /// Whether a pane's question shows its card even where no window is shown
    /// (tests, to answer real cards); off, it is answered at once with its default.
    var showsDialogCardsUnattended = false
    /// What a test answers the file and directory pickers with, in place of the
    /// system's open panel (which can't be driven): nil for cancelled.
    var pickerOverride: ((PanePicker) -> URL?)?
    /// The cards up now, oldest first.
    var dialogCards: [DialogCard] = []
    /// How many times a signal asked the Dock icon to bounce.
    private(set) var attentionRequests = 0

    init(runtime: CoreRuntime, engine: LayoutEngine, presentsWindows: Bool = true) {
        self.runtime = runtime
        self.engine = engine
        self.presentsWindows = presentsWindows
        engine.renderer = self
    }

    /// The windows, in the model's order.
    var windows: [WorkspaceWindowController] { engine.model.windows.compactMap { controllers[$0.id] } }

    func windowController(_ id: WindowID) -> WorkspaceWindowController? { controllers[id] }

    var frontmostController: WorkspaceWindowController? { engine.frontmostWindowID.flatMap { controllers[$0] } }

    func body(for pane: PaneID) -> PaneBodyHost? { bodies[pane] }

    func appearance(fullScreen: Bool) -> PaneAppearance {
        var appearance = baseAppearance
        if fullScreen { appearance.cornerRadius = 0 }
        return appearance
    }

    // MARK: LayoutRenderer

    func render(_ model: LayoutModel) {
        for (id, controller) in controllers where model.window(id) == nil {
            for card in dialogCards where card.window != nil && card.window === controller.window { card.dismiss() }
            controllers[id] = nil
            controller.isClosingForModel = true
            controller.window?.close()
            controller.dismantle()
        }
        let inModel = Set(model.leaves.map(\.id))
        dismissDialogs(except: inModel)
        for (id, body) in bodies where !inModel.contains(id) {
            body.removeFromSuperview()
            bodies[id] = nil
        }
        for window in model.windows {
            let controller = controllers[window.id] ?? makeWindow(window)
            controller.show(window)
        }
    }

    /// z-order of the visible windows; with none visible, the one that was
    /// last key; else nil.
    var frontmostWindowID: WindowID? {
        for window in NSApp?.orderedWindows ?? [] where window.isVisible {
            if let controller = controllers.values.first(where: { $0.window === window }) { return controller.windowID }
        }
        return lastKey.flatMap { controllers[$0] != nil ? $0 : nil }
    }

    /// Workspace windows front to back (visible ones by z-order first).
    var windowsFrontToBack: [WorkspaceWindowController] {
        var ordered: [WorkspaceWindowController] = []
        for window in NSApp?.orderedWindows ?? [] {
            if let controller = controllers.values.first(where: { $0.window === window }) { ordered.append(controller) }
        }
        for controller in windows where !ordered.contains(where: { $0 === controller }) { ordered.append(controller) }
        return ordered
    }

    /// Whether `window` is one of the workspace's (not Settings, Plugins).
    func isWorkspaceWindow(_ window: NSWindow) -> Bool {
        controllers.values.contains { $0.window === window }
    }

    func bringToFront(_ window: WindowID) {
        if presentsWindows { controllers[window]?.window?.makeKeyAndOrderFront(nil) }
    }

    func confirmClose(_ warnings: [String], quitting: Bool) -> Bool {
        guard presentsWindows, !warnings.isEmpty else { return true }
        return closeConfirmation(warnings, quitting: quitting).runModal() == .alertSecondButtonReturn
    }

    /// The alert `confirmClose` runs.
    func closeConfirmation(_ warnings: [String], quitting: Bool) -> NSAlert {
        let copy = CloseConfirmation(warnings: warnings, quitting: quitting)
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = copy.message
        alert.informativeText = copy.detail
        // Cancel first: the default (Return) and the escape route.
        alert.addButton(withTitle: CloseConfirmation.cancel)
        alert.addButton(withTitle: copy.proceed)
        return alert
    }

    func titleDidChange(_ pane: PaneID) {
        guard let window = engine.model.window(holding: pane), let controller = controllers[window.id] else { return }
        controller.refreshChrome()
        controller.window?.title = engine.paneTitle(of: window.activeLeafID ?? window.activePaneID)
    }

    func focus(_ pane: PaneID) {
        guard let body = bodies[pane], body.isShown else { return }
        body.focusContent()
    }

    func viewport(of window: WindowID) -> Viewport? { controllers[window]?.viewport }

    func paneRect(_ pane: PaneID) -> FloatRect? {
        guard let window = engine.model.window(holding: pane) else { return nil }
        return controllers[window.id]?.paneRect(pane)
    }

    func isFocused(_ window: WindowID) -> Bool {
        if let focusOverride { return focusOverride(window) }
        guard let window = controllers[window]?.window else { return false }
        return NSApp.isActive && window.isKeyWindow
    }

    func signalsDidChange(on panes: Set<PaneID>) {
        var byWindow: [WindowID: Set<PaneID>] = [:]
        for pane in panes {
            if let window = engine.model.window(holding: pane)?.id { byWindow[window, default: []].insert(pane) }
        }
        for (id, panes) in byWindow.sorted(by: { $0.key < $1.key }) { controllers[id]?.refreshSignals(on: panes) }
    }

    /// Bounces the Dock icon once; macOS ignores it while the app is active.
    func requestUserAttention() {
        attentionRequests += 1
        if presentsWindows { NSApp.requestUserAttention(.informationalRequest) }
    }

    /// A pane's context menu, drawn by core: in the overlay of the window the
    /// view is in (the pane's own window if it isn't in one yet).
    func showContextMenu(_ items: [PaneMenuItem], at point: NSPoint, in view: NSView, for pane: PaneID) {
        let controller =
            controllers.values.first { view.window != nil && $0.window === view.window }
            ?? engine.model.window(holding: pane).flatMap { controllers[$0.id] }
        guard let controller else { return }
        let overlay = controller.root.overlay
        let local = view.window == nil ? point : overlay.convert(point, from: view)
        ContextMenu.open(
            items.map { ContextMenu.Item(title: $0.title, isEnabled: $0.isEnabled, action: $0.action) }, at: local, in: controller)
    }

    // MARK: Shell-only

    /// Empty panes rebuild their buttons (what may be created changed).
    func refreshEmptyPanes() {
        for body in bodies.values where body.contentType == nil { body.invalidateBody() }
        render(engine.model)
        // An open palette lists the same types.
        for controller in controllers.values { Palette.current(in: controller)?.refreshTypes() }
    }

    func refreshAll() {
        for controller in controllers.values {
            controller.applyAppearance()
            controller.refreshChrome()
            controller.refreshOverlays()
        }
    }

    // MARK: Building

    private func makeWindow(_ layout: WindowLayout) -> WorkspaceWindowController {
        let id = layout.id
        let controller = WorkspaceWindowController(layout: layout, renderer: self)
        controllers[id] = controller
        controller.didBecomeKey = { [weak self] in self?.lastKey = id }
        // The user closed it: forget it before the engine hears, so a window
        // the engine brings back with this id gets a new NSWindow.
        controller.willClose = { [weak self, unowned controller] in
            if self?.controllers[id] === controller { self?.controllers[id] = nil }
        }
        if let frame = layout.frame {
            controller.window?.setFrame(NSRect(x: frame.x, y: frame.y, width: frame.width, height: frame.height), display: false)
        } else if let anchor = (frontmostController.flatMap { $0 === controller ? nil : $0 } ?? windows.last(where: { $0 !== controller }))?
            .window?.frame
        {
            // Cascaded off the front window, back to the work area's corner if it wouldn't fit.
            let size = WorkspaceWindowController.defaultSize
            let area = (NSScreen.screens.first { $0.frame.intersects(anchor) } ?? NSScreen.main)?.visibleFrame ?? anchor
            var origin = CGPoint(x: anchor.minX + 24, y: anchor.maxY - 24 - size.height)
            if origin.x + size.width > area.maxX { origin.x = area.minX }
            if origin.y < area.minY { origin.y = area.maxY - size.height }
            controller.window?.setFrame(NSRect(origin: origin, size: size), display: false)
        } else {
            controller.window?.center()
        }
        controller.tracksFrame = true
        if presentsWindows { controller.showWindow(nil) }
        return controller
    }

    /// What the user may create now: one action per creatable type, in UI
    /// order — the empty pane's buttons and the palette's rows.
    func creationActions() -> [EmptyPaneView.Action] {
        creationActionsOverride
            ?? runtime.panes.creatableTypes().map {
                EmptyPaneView.Action(
                    type: $0.value.id, label: $0.value.resolvedCreationLabel, displayName: $0.value.displayName,
                    icon: EmptyPaneView.Icon($0.value.icon))
            }
    }

    /// The leaf's body, showing what core says it has.
    func bodyHost(for leaf: LayoutLeaf) -> PaneBodyHost {
        let host = bodies[leaf.id] ?? PaneBodyHost(paneID: leaf.id)
        bodies[leaf.id] = host
        let engine = engine
        let id = leaf.id
        switch engine.body(of: id) {
        case .empty:
            let actions = creationActions()
            let theme = baseAppearance.theme
            host.show(.empty, key: "empty", contentType: nil) {
                .init(view: EmptyPaneView(paneID: id, actions: actions, theme: theme) { type in engine.fill(id, with: type) })
            }
        case .live(let live):
            host.show(.live(live), key: "live-\(ObjectIdentifier(live))", contentType: live.contentType) {
                .init(
                    view: live.controller.view, accessory: live.controller.headerAccessory, headerTitle: live.controller.headerTitle,
                    actions: live.controller.headerActions)
            }
        case .unavailable(let reason):
            host.show(.unavailable(reason: reason), key: "unavailable-\(reason)", contentType: leaf.type) {
                .init(view: UnavailablePaneView(type: leaf.type, reason: reason))
            }
        }
        return host
    }
}
