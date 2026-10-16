import AppKit
import TabsCore
import TabsPluginSDK

/// Dragging tabs and panes. A press on a tab or on a pane's chrome arms a
/// drag; 5pt of travel engages it: the source dims, a ghost follows the
/// pointer, and the drop target under it previews (a tab-bar slot, an empty
/// pane, or a dock zone). Hovering a tab for 550ms opens it (Finder-style):
/// any of the drag's tree but the one it leaves and those inside what's
/// dragged, other tabs in its own bar included. Releasing on a target moves
/// the tab or pane there — into another window too; anywhere else the ghost
/// flies home. Escape cancels.
@MainActor
final class DragController {
    unowned let renderer: WorkspaceRenderer
    private var engine: LayoutEngine { renderer.engine }

    /// Pointer travel that turns a press into a drag.
    static let threshold: CGFloat = 5
    #if DEBUG
    /// Tests that hold a drag over a tab shorten it.
    static var springLoadDelay: TimeInterval = 0.55
    #else
    static let springLoadDelay: TimeInterval = 0.55
    #endif
    /// Within this fraction of a pane's width/height, hovering docks at that edge.
    static let edgeZoneFraction = 0.25
    /// Within this (thinner) fraction of an enclosing group's own edge, the
    /// whole group docks — splitting it out as a sibling.
    static let groupEdgeZoneFraction = 0.1
    #if DEBUG
    /// Tests that wait for a declined drag to end shorten it.
    static var flyBack: TimeInterval = 0.18
    #else
    static let flyBack: TimeInterval = 0.18
    #endif

    private struct Drag {
        var subject: DragSubject
        var title: String
        let source: WindowID
        /// The window under the pointer and the target there.
        var over: WindowID?
        var target: DropTarget?
    }

    private var drag: Drag?
    private var springTimer: Timer?
    private var springKey: NodeID?
    private var ghosts: [WindowID: DragGhostView] = [:]

    init(renderer: WorkspaceRenderer) {
        self.renderer = renderer
    }

    var isDragging: Bool { drag != nil }

    /// What a window shows of the drag in flight.
    func visuals(in window: WindowID) -> DragVisuals {
        guard let drag else { return DragVisuals() }
        var visuals = DragVisuals()
        if drag.source == window {
            switch drag.subject {
            case .tab(let tabID, _): visuals.sourceTab = tabID
            case .pane(let paneID): visuals.sourcePane = paneID
            }
        }
        if drag.over == window { visuals.target = drag.target }
        return visuals
    }

    // MARK: The gesture

    /// A press on a tab or a pane's chrome: tracks the mouse until release.
    /// A press that never travels far enough is a click (`click`).
    func press(_ event: NSEvent, subject: DragSubject, title: String, in controller: WorkspaceWindowController, click: () -> Void) {
        guard let window = controller.window, event.type == .leftMouseDown, drag == nil else { return }
        let start = window.convertPoint(toScreen: event.locationInWindow)
        var engaged = false
        var cancelled = false
        tracking: while let next = window.nextEvent(
            matching: [.leftMouseDragged, .leftMouseUp, .keyDown], until: .distantFuture, inMode: .eventTracking, dequeue: true)
        {
            switch next.type {
            case .keyDown where next.keyCode == 53:
                cancelled = true
                break tracking
            case .keyDown:
                continue
            case .leftMouseDragged:
                let point = window.convertPoint(toScreen: next.locationInWindow)
                if !engaged {
                    guard hypot(point.x - start.x, point.y - start.y) >= Self.threshold else { continue }
                    engaged = true
                    drag = Drag(subject: subject, title: title, source: controller.windowID)
                }
                update(at: point)
            default:
                break tracking
            }
        }
        guard engaged else {
            if !cancelled { click() }
            return
        }
        if cancelled {
            end()
        } else {
            release()
        }
    }

    /// Re-resolves the window and target under the pointer on every move:
    /// spring loading can reveal new bars and panes mid-drag.
    private func update(at screenPoint: CGPoint) {
        guard var current = drag, let source = renderer.windowController(current.source) else { return }
        let hovered = window(at: screenPoint, source: source, subject: current.subject)
        var target: DropTarget?
        if let hovered {
            let point = hovered.root.convert(hovered.window?.convertPoint(fromScreen: screenPoint) ?? .zero, from: nil)
            if hovered === source {
                target = resolveInWindow(hovered, at: point, subject: current.subject)
            } else {
                clearSpringLoad()
                target = resolveExternal(hovered, at: point, subject: current.subject)
            }
            showGhost(in: hovered, at: point, title: current.title)
            ChromeHover.update(point, in: hovered.root)
        } else {
            clearSpringLoad()
        }
        for (id, ghost) in ghosts where id != hovered?.windowID { ghost.isHidden = true }
        for controller in renderer.windows where controller !== hovered { ChromeHover.update(nil, in: controller.root) }
        let changed = current.over != hovered?.windowID || current.target != target
        current.over = hovered?.windowID
        current.target = target
        drag = current
        if changed { refresh() }
    }

    /// The window the pointer is over: the source for any point inside it;
    /// else, if the subject may leave its window, the frontmost other
    /// workspace window there (unless another of the app's windows covers it).
    private func window(at point: CGPoint, source: WorkspaceWindowController, subject: DragSubject) -> WorkspaceWindowController? {
        if let frame = source.window?.frame, frame.contains(point) { return source }
        guard source.layout.canLeaveWindow(subject) else { return nil }
        // Windows that are never shown (tests, the hidden e2e app) stand in for visible ones.
        for window in NSApp.orderedWindows where (window.isShownOnScreen || !renderer.presentsWindows) && !window.isMiniaturized {
            guard window !== source.window else { continue }
            guard let controller = renderer.windows.first(where: { $0.window === window }) else {
                if window.isShownOnScreen, window.frame.contains(point), window.level == .normal { return nil }
                continue
            }
            if controller.window?.styleMask.contains(.fullScreen) == true, source.window?.styleMask.contains(.fullScreen) != true {
                continue
            }
            if window.contentLayoutRect.offsetBy(dx: window.frame.minX, dy: window.frame.minY).contains(point)
                || window.frame.contains(point)
            {
                return controller
            }
        }
        return nil
    }

    #if DEBUG
    /// A drag pressed at `from` and moved to `to` (content coordinates), left
    /// in flight — the visual capture's drag scenarios. The subject is
    /// what a press at `from` would pick up.
    func simulate(from: CGPoint, to: CGPoint, in controller: WorkspaceWindowController) {
        guard let window = controller.window else { return }
        let element = element(at: from, in: controller)
        let subject: DragSubject
        let title: String
        if let tab = closest(TabView.self, from: element), let group = tab.strip.group {
            subject = .tab(tabID: tab.tabID, sourceGroupID: group.id)
            title = tab.title
        } else if let header = closest(PaneHeaderView.self, from: element) {
            subject = .pane(header.pane.nodeID)
            title = engine.paneTitle(of: header.pane.node)
        } else if let bar = closest(TabBarView.self, from: element), !bar.pane.isDockedRoot {
            subject = .pane(bar.pane.nodeID)
            title = engine.paneTitle(of: bar.pane.node)
        } else {
            return
        }
        drag = Drag(subject: subject, title: title, source: controller.windowID)
        for step in 1...10 {
            let fraction = CGFloat(step) / 10
            let point = CGPoint(x: from.x + (to.x - from.x) * fraction, y: from.y + (to.y - from.y) * fraction)
            update(at: window.convertPoint(toScreen: controller.root.convert(point, to: nil)))
        }
    }

    func endSimulation() { end() }
    #endif

    // MARK: Resolving targets

    /// The deepest chrome or content view at `point` (root coordinates):
    /// floating panes first, front to back, then the docked layout.
    private func element(at point: CGPoint, in controller: WorkspaceWindowController) -> NSView? {
        let root = controller.root
        for floating in root.floatingViews.reversed() where floating.frame.contains(point) {
            return floating.hitTest(root.convert(point, to: floating.superview))
        }
        return root.docked.hitTest(root.convert(point, to: root.docked.superview))
    }

    private func closest<T: NSView>(_ type: T.Type, from view: NSView?) -> T? {
        var view = view
        while let current = view {
            if let match = current as? T { return match }
            view = current.superview
        }
        return nil
    }

    /// In precedence order: a tab bar, an edge dock zone, an empty pane, a
    /// center dock. Edge zones beat the empty pane (an empty tab's content
    /// covers its whole pane, which could never be edge-docked otherwise).
    private func byPrecedence(
        tabBar: () -> DropTarget?, dock: () -> (targetID: NodeID, zone: DockZone)?, emptyPane: () -> DropTarget?
    ) -> DropTarget? {
        if let bar = tabBar() { return bar }
        let dock = dock()
        if let dock, dock.zone != .center { return .dock(targetID: dock.targetID, zone: dock.zone) }
        if let empty = emptyPane() { return empty }
        return dock.map { .dock(targetID: $0.targetID, zone: $0.zone) }
    }

    /// A drop in the subject's own window: what's under the pointer, as core
    /// takes it within the subject's own tree (`WindowLayout.canDrop`).
    private func resolveInWindow(_ controller: WorkspaceWindowController, at point: CGPoint, subject: DragSubject) -> DropTarget? {
        let layout = controller.layout
        let element = element(at: point, in: controller)
        if let tab = closest(TabView.self, from: element) {
            springLoad(tab, in: controller, subject: subject)
        } else {
            clearSpringLoad()
        }
        return resolve(element, at: point, in: controller, subject: subject, tree: layout.ownerTree(of: subject.nodeKey)) {
            layout.canDrop(subject, at: $0)
        }
    }

    /// A drop from another window: the same geometry and precedence, judged
    /// only by whether the target can take content from another tree
    /// (`WindowLayout.accepts`).
    private func resolveExternal(_ controller: WorkspaceWindowController, at point: CGPoint, subject: DragSubject) -> DropTarget? {
        let layout = controller.layout
        return resolve(element(at: point, in: controller), at: point, in: controller, subject: subject, tree: layout.rootNode) {
            layout.accepts($0)
        }
    }

    /// The target under `element`, in precedence order, among those `accepts` takes.
    private func resolve(
        _ element: NSView?, at point: CGPoint, in controller: WorkspaceWindowController, subject: DragSubject, tree: LayoutNode,
        accepts: (DropTarget) -> Bool
    ) -> DropTarget? {
        byPrecedence(
            tabBar: { tabBarTarget(element, at: point, in: controller, subject: subject).flatMap { accepts($0) ? $0 : nil } },
            dock: { dockTarget(element, at: point, in: controller, tree: tree) { accepts(.dock(targetID: $0, zone: $1)) } },
            emptyPane: {
                guard let empty = closest(EmptyPaneView.self, from: element), accepts(.emptyPane(empty.paneID)) else { return nil }
                return .emptyPane(empty.paneID)
            })
    }

    /// The bar under `element`: an insertion beside the hovered tab (before
    /// or after it by which half the pointer is in), or at the end over the
    /// bar's empty stretch, as core counts it (`WindowLayout.tabBarDrop`).
    private func tabBarTarget(_ element: NSView?, at point: CGPoint, in controller: WorkspaceWindowController, subject: DragSubject)
        -> DropTarget?
    {
        guard let bar = closest(TabBarView.self, from: element) else { return nil }
        let tab = closest(TabView.self, from: element)
        let after = tab.map { point.x >= $0.convert($0.bounds, to: controller.root).midX } ?? false
        return controller.layout.tabBarDrop(subject, on: bar.pane.nodeID, beside: tab?.tabID, after: after)
    }

    /// The dock target for the pane under the pointer. Over a tab's own
    /// content it docks relative to that content — except within a thin band
    /// at the enclosing group's true edge, which docks the whole group.
    private func dockTarget(
        _ element: NSView?, at point: CGPoint, in controller: WorkspaceWindowController, tree: LayoutNode,
        allowed: (NodeID, DockZone) -> Bool
    ) -> (targetID: NodeID, zone: DockZone)? {
        guard let inner = closest(PaneView.self, from: element) else { return nil }
        var group: PaneView? = inner
        while let current = group, case .tab? = Tree.findParent(tree, current.nodeID) {
            group = closest(PaneView.self, from: current.superview)
        }
        guard let group else { return nil }
        let dockedRoot = controller.layout.root.id
        func dock(_ pane: PaneView, _ zone: DockZone) -> (NodeID, DockZone)? {
            allowed(pane.nodeID, zone) ? (pane.nodeID, zone) : nil
        }
        func rect(_ pane: PaneView) -> CGRect { pane.convert(pane.bounds, to: controller.root) }
        if group === inner { return dock(inner, zone(in: rect(inner), at: point)) }
        let groupZone = zone(in: rect(group), at: point, fraction: Self.groupEdgeZoneFraction)
        if groupZone != .center { return dock(group, groupZone) }
        let innerZone = zone(in: rect(inner), at: point)
        if innerZone != .center { return dock(inner, innerZone) }
        // The docked root's tabs are already its peers: center there means
        // "nest into the hovered tab's content".
        return dock(group.nodeID == dockedRoot ? inner : group, .center)
    }

    /// The nearest edge when the point is within its band, else center.
    private func zone(in rect: CGRect, at point: CGPoint, fraction: Double = DragController.edgeZoneFraction) -> DockZone {
        guard rect.width > 0, rect.height > 0 else { return .center }
        let rx = (point.x - rect.minX) / rect.width
        let ry = (point.y - rect.minY) / rect.height
        let edges: [(Double, DockZone)] = [(rx, .left), (1 - rx, .right), (ry, .top), (1 - ry, .bottom)]
        let nearest = edges.dropFirst().reduce(edges[0]) { $1.0 < $0.0 ? $1 : $0 }
        return nearest.0 < fraction ? nearest.1 : .center
    }

    // MARK: Spring loading

    /// Holding the drag over a tab opens it, so its content can be docked
    /// into: any tab core lets open (`WindowLayout.canSpringLoad`).
    private func springLoad(_ tab: TabView, in controller: WorkspaceWindowController, subject: DragSubject) {
        let tabID = tab.tabID
        guard springKey != tabID else { return }
        clearSpringLoad()
        springKey = tabID
        guard controller.layout.canSpringLoad(tabID, during: subject) else { return }
        let groupID = tab.strip.pane.nodeID
        let windowID = controller.windowID
        let timer = Timer(timeInterval: Self.springLoadDelay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.springTimer = nil
                self?.engine.perform(in: windowID) { layout, titles in layout.activateTab(groupID, tabID, titles: titles) }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        springTimer = timer
    }

    private func clearSpringLoad() {
        springTimer?.invalidate()
        springTimer = nil
        springKey = nil
    }

    // MARK: Ending

    private func release() {
        guard let current = drag else { return }
        clearSpringLoad()
        guard let over = current.over, let target = current.target else {
            flyHome()
            return
        }
        end()
        if over == current.source {
            engine.drop(current.subject, at: target, in: over)
        } else {
            engine.move(current.subject, from: current.source, to: over, at: target)
        }
    }

    /// Sends the ghost gliding back to the drag's source, then ends the drag.
    private func flyHome() {
        guard let current = drag, let source = renderer.windowController(current.source) else {
            end()
            return
        }
        let origin: NSView? =
            switch current.subject {
            case .tab(let tabID, let group): source.paneView(group)?.tabBar?.strip.tabView(tabID)
            case .pane(let paneID): source.paneView(paneID).flatMap { $0.header ?? $0.tabBar }
            }
        guard let origin, !origin.isHiddenOrHasHiddenAncestor else {
            end()
            return
        }
        let ghost = ghosts[current.source] ?? DragGhostView()
        attach(ghost, to: source)
        ghost.update(title: current.title, theme: source.appearance.theme)
        ghost.isHidden = false
        drag?.over = nil
        drag?.target = nil
        refresh()
        let destination = origin.convert(origin.bounds, to: source.root.overlay).origin
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Self.flyBack
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            ghost.animator().setFrameOrigin(destination)
        }
        Timer.scheduledTimer(withTimeInterval: Self.flyBack + 0.04, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.end() }
        }
    }

    private func end() {
        clearSpringLoad()
        drag = nil
        for ghost in ghosts.values { ghost.removeFromSuperview() }
        ghosts.removeAll()
        refresh()
    }

    // MARK: Visuals

    private func attach(_ ghost: DragGhostView, to controller: WorkspaceWindowController) {
        ghosts[controller.windowID] = ghost
        if ghost.superview !== controller.root.overlay { controller.root.overlay.addSubview(ghost) }
    }

    /// The ghost follows the pointer (12, 16) below-right of it, in the window the pointer is over.
    private func showGhost(in controller: WorkspaceWindowController, at point: CGPoint, title: String) {
        let ghost = ghosts[controller.windowID] ?? DragGhostView()
        attach(ghost, to: controller)
        ghost.update(title: title, theme: controller.appearance.theme)
        ghost.place(at: CGPoint(x: point.x + 12, y: point.y + 16))
        ghost.isHidden = false
    }

    /// Every window redraws what the drag shows in it.
    private func refresh() {
        for controller in renderer.windows {
            controller.refreshChrome()
            controller.refreshOverlays()
        }
    }
}

/// The label following the pointer during a drag.
@MainActor
final class DragGhostView: FlippedView {
    private(set) var title = ""
    private var theme = Theme.placeholder
    private static let text = ChromeText(size: 13)

    override init(frame: NSRect) {
        super.init(frame: frame)
        alphaValue = 0.85
        layer?.cornerRadius = 4
        layer?.borderWidth = 1
        layer?.masksToBounds = false
    }

    override func layout() {
        super.layout()
        layer?.applyOverlayShadow(.ghost, theme: theme)
    }

    func update(title: String, theme: Theme) {
        self.title = title
        self.theme = theme
        layer?.backgroundColor = theme.bgElevated.cgColor
        layer?.borderColor = theme.accent.cgColor
        needsLayout = true
        let text = Self.text
        ghostSize = CGSize(width: text.width(title) + 20 + 2, height: text.lineHeight + 8 + 2)
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let text = Self.text
        text.draw(title, at: CGPoint(x: 11, y: 1 + 4 + text.ascent), color: theme.text)
    }

    /// Its size before snapping: `place(at:)` snaps its edges.
    private var ghostSize = CGSize.zero

    func place(at origin: CGPoint) {
        layoutFrame = CGRect(origin: origin, size: ghostSize)
        frame = layoutFrame.snapped
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
