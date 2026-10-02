import AppKit
import TabsCore
import TabsPluginSDK

/// The workspace's app-wide input: pane navigation by keyboard (a port of
/// the Electron app's `spatialNav.ts`) and activating a pane by clicking
/// into its content — which is a plugin's view, so the click never reaches
/// the pane's own chrome.
@MainActor
final class WorkspaceInput {
    private unowned let renderer: WorkspaceRenderer
    private let runtime: CoreRuntime
    private var monitors: [Any] = []

    private static let navigation: [(CoreCommand, NavDirection)] = [
        (CoreCommands.navLeft, .left), (CoreCommands.navRight, .right), (CoreCommands.navUp, .up), (CoreCommands.navDown, .down),
    ]

    init(renderer: WorkspaceRenderer, runtime: CoreRuntime) {
        self.renderer = renderer
        self.runtime = runtime
        if let keys = NSEvent.addLocalMonitorForEvents(
            matching: .keyDown,
            handler: { [weak self] event in
                let handled = MainActor.assumeIsolated { self?.handleKeyDown(event) ?? false }
                return handled ? nil : event
            })
        {
            monitors.append(keys)
        }
        if let clicks = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown],
            handler: { [weak self] event in
                guard let self else { return event }
                MainActor.assumeIsolated { self.handleMouseDown(event) }
                return event
            })
        {
            monitors.append(clicks)
        }
    }

    func stop() {
        for monitor in monitors { NSEvent.removeMonitor(monitor) }
        monitors.removeAll()
    }

    // MARK: Navigation

    /// A navigation chord in a workspace window moves pane focus — unless a
    /// text field has the keyboard (the arrows edit there) or a drag is on.
    func handleKeyDown(_ event: NSEvent) -> Bool {
        guard let chord = KeyChord(event: event),
            let direction = Self.navigation.first(where: { runtime.shortcuts.chord(for: $0.0.id) == chord })?.1,
            let window = event.window, let controller = renderer.windows.first(where: { $0.window === window })
        else { return false }
        if renderer.drag.isDragging { return false }
        if let text = window.firstResponder as? NSTextView, text.isEditable { return false }
        if controller.appearance.showNavFlash { NavFlashView.flash(direction, in: controller) }
        navigate(direction, in: controller)
        return true
    }

    /// One step through the layout from the active pane, staying inside its
    /// tree (the docked layout, or one floating pane): a sibling across a
    /// split, the next tab (left/right), or — when nothing lies that way —
    /// around the outermost container, else the pane at the far edge.
    func navigate(_ direction: NavDirection, in controller: WorkspaceWindowController) {
        let layout = controller.layout
        let active = layout.activePaneID
        let tree = layout.ownerTree(of: active)
        let engine = renderer.engine
        guard let target = Navigation.navTarget(tree, active, direction) else {
            if let wrap = Navigation.pickWrapTarget(
                currentRect(active, in: controller), visiblePanes(in: tree, controller, excluding: active), direction)
            {
                engine.perform(in: controller.windowID) { layout, _ in layout.setActivePane(wrap) }
            }
            return
        }
        if let step = target.tabSwitch {
            engine.perform(in: controller.windowID) { layout, titles in
                layout.activateTab(step.groupID, step.tabID, titles: titles)
                // The revealed content is still hidden (unmeasurable): the model decides.
                return layout.setActivePane(Navigation.entryPaneID(target.node, direction)) || true
            }
            return
        }
        let candidates = visiblePanes(in: target.node, controller, excluding: active)
        let picked =
            controller.paneRect(active) == nil
            ? nil
            : target.wrapped
                ? Navigation.pickWrapTarget(currentRect(active, in: controller), candidates, direction)
                : Navigation.pickSpatialTarget(currentRect(active, in: controller), candidates, direction)
        let pane = picked ?? Navigation.entryPaneID(target.node, direction)
        engine.perform(in: controller.windowID) { layout, _ in layout.setActivePane(pane) }
    }

    private func currentRect(_ pane: NodeID, in controller: WorkspaceWindowController) -> NavRect {
        guard let rect = controller.paneRect(pane) else { return NavRect(left: 0, top: 0, right: 0, bottom: 0) }
        return NavRect(left: rect.x, top: rect.y, right: rect.x + rect.width, bottom: rect.y + rect.height)
    }

    /// The innermost panes on screen inside `subtree` (a group yields to the pane it shows).
    private func visiblePanes(in subtree: LayoutNode, _ controller: WorkspaceWindowController, excluding active: NodeID) -> [(
        id: NodeID, rect: NavRect
    )] {
        let ids = Set(subtree.nodeIDs)
        let visible = ids.compactMap { id -> (NodeID, PaneView)? in
            guard let view = controller.paneView(id), !view.isHiddenOrHasHiddenAncestor, view.bounds.width > 0, view.bounds.height > 0
            else {
                return nil
            }
            return (id, view)
        }
        let innermost = visible.filter { candidate in
            !visible.contains { other in other.1 !== candidate.1 && other.1.isDescendant(of: candidate.1) }
        }
        return innermost.compactMap { id, _ in
            guard id != active, let rect = controller.paneRect(id) else { return nil }
            return (id, NavRect(left: rect.x, top: rect.y, right: rect.x + rect.width, bottom: rect.y + rect.height))
        }
        .sorted { $0.id < $1.id }
    }

    // MARK: Activation

    /// A press inside a pane's content (or its header's plugin-provided title) makes that pane active (its chrome
    /// activates on its own click).
    func handleMouseDown(_ event: NSEvent) {
        guard let window = event.window, let controller = renderer.windows.first(where: { $0.window === window }),
            let content = window.contentView,
            let hit = content.hitTest(content.superview?.convert(event.locationInWindow, from: nil) ?? event.locationInWindow)
        else { return }
        var view: NSView? = hit
        var inBody = false
        var below: NSView?
        while let current = view {
            if current is PaneBodyHost { inBody = true }
            // The header's plugin-provided title acts as content: a press on it activates.
            if let header = current as? PaneHeaderView, let title = header.titleView, below === title { inBody = true }
            below = current
            if let pane = current as? PaneView {
                if inBody { controller.activate(pane.nodeID) }
                return
            }
            view = current.superview
        }
    }
}
