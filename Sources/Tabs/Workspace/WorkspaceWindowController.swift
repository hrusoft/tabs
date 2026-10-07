import AppKit
import TabsCore
import TabsPluginSDK

/// One workspace window: draws its `WindowLayout` — the docked tree under a
/// root tab bar that doubles as the title bar, floating panes over it — and
/// forwards what the user does to the layout engine. It decides nothing about
/// the layout.
@MainActor
final class WorkspaceWindowController: NSWindowController, NSWindowDelegate, ChromeHost {
    let windowID: WindowID
    unowned let renderer: WorkspaceRenderer
    private(set) var layout: WindowLayout
    let root: WindowRootView
    private var nodeViews: [NodeID: NodeView] = [:]
    private var floatingViews: [NodeID: FloatingWindowView] = [:]
    /// What had the keyboard last: the active leaf and the body it showed.
    private var focused: (pane: NodeID, body: String?)?
    /// Set when the renderer closes the window (the model no longer has it),
    /// so the close isn't reported back as the user's.
    var isClosingForModel = false
    /// Called when the user closes the window, before the engine is told.
    var willClose: (() -> Void)?
    /// Called when the window becomes key, before the engine is told.
    var didBecomeKey: (() -> Void)?
    /// Once placed, moves and resizes are reported to the engine (saved with the layout).
    var tracksFrame = false
    private(set) var isFullScreen = false
    private var reclampTimer: Timer?
    lazy var resizer = SplitResizer(window: self)

    static let defaultSize = NSSize(width: 1200, height: 800)

    init(layout: WindowLayout, renderer: WorkspaceRenderer) {
        windowID = layout.id
        self.layout = layout
        self.renderer = renderer
        let window = WorkspaceWindow(
            contentRect: NSRect(origin: .zero, size: Self.defaultSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        window.titlebarAppearsTransparent = true
        // Only the root bar's background moves the window (`dragWindow`). Left
        // movable, the window server drags it from anywhere in the title-bar
        // strip — tabs included — whatever the content views under it say.
        window.isMovable = false
        window.titleVisibility = .hidden
        window.title = "Tabs"
        window.minSize = NSSize(width: 360, height: 200)
        window.collectionBehavior.insert(.fullScreenPrimary)
        root = WindowRootView()
        super.init(window: window)
        root.docked.overlay.host = self
        window.delegate = self
        window.contentView = root
        root.separatorHit = { [unowned self] point in self.resizer.hitRegions(at: point).isEmpty == false }
        root.separatorMouseDown = { [unowned self] event in self.resizer.mouseDown(event) }
        root.separatorCursorRects = { [unowned self] in self.resizer.cursorRects() }
        root.separatorCursor = { [unowned self] point in self.resizer.cursor(at: point) }
        window.layoutTrafficLights = { [weak window] in window?.placeTrafficLights() }
        window.placeTrafficLights()
        applyAppearance()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    var appearance: PaneAppearance { renderer.appearance(fullScreen: isFullScreen) }
    var dragVisuals: DragVisuals { renderer.drag.visuals(in: windowID) }

    /// The content area's size: where floating panes are kept.
    var viewport: Viewport { Viewport(width: root.bounds.width, height: root.bounds.height) }

    func applyAppearance() {
        let theme = appearance.theme
        root.background = theme.bg
        window?.backgroundColor = theme.bg
        window?.appearance = NSAppearance(named: theme.isDark ? .darkAqua : .aqua)
    }

    // MARK: Drawing the layout

    func show(_ layout: WindowLayout) {
        self.layout = layout
        var used: [NodeID: NodeView] = [:]
        let rootView = build(
            .tabs(layout.root), depth: 0, edges: Edges(cornerLeft: true, cornerRight: true), dockedRoot: true, floatingRoot: nil,
            used: &used)
        root.docked.setRoot(rootView)

        var keptFloating: [NodeID: FloatingWindowView] = [:]
        for entry in layout.floating {
            let view = floatingViews[entry.id] ?? FloatingWindowView(floatID: entry.id, host: self)
            if view.superview !== root.floatingLayer { root.floatingLayer.addSubview(view) }
            let content = build(entry.content, depth: 0, edges: Edges(), dockedRoot: false, floatingRoot: entry.content.id, used: &used)
            view.tree.setRoot(content)
            root.floatingLayer.layoutFrame = root.bounds
            root.floatingLayer.place(view, CGRect(x: entry.rect.x, y: entry.rect.y, width: entry.rect.width, height: entry.rect.height))
            view.apply(theme: appearance.theme)
            keptFloating[entry.id] = view
        }
        for (id, view) in floatingViews where keptFloating[id] == nil { view.removeFromSuperview() }
        floatingViews = keptFloating
        // Array order is z-order: the last is on top.
        let order = Dictionary(uniqueKeysWithValues: layout.floating.enumerated().map { ($0.element.id, $0.offset) })
        root.floatingLayer.subviews.sort { a, b in
            let za = (a as? FloatingWindowView).flatMap { order[$0.floatID] } ?? -1
            let zb = (b as? FloatingWindowView).flatMap { order[$0.floatID] } ?? -1
            return za < zb
        }
        nodeViews = used
        refreshChrome()
        root.needsLayout = true
        root.layoutSubtreeIfNeeded()
        ChromeHover.dropStale(in: root)
        refreshOverlays()
        followActivePane()
        window?.title = engine.paneTitle(of: layout.activeLeafID ?? layout.activePaneID)
    }

    /// The view for `node`, reused while the node lives, and its subtree.
    private func build(
        _ node: LayoutNode, depth: Int, edges: Edges, dockedRoot: Bool, floatingRoot: NodeID?, used: inout [NodeID: NodeView]
    ) -> NodeView {
        switch node {
        case .split(let split):
            let view = (nodeViews[node.id] as? SplitNodeView) ?? SplitNodeView(node: node, host: self)
            view.node = node
            view.depth = depth
            view.edges = edges
            let horizontal = split.direction == .horizontal
            let children = split.children.enumerated().map { index, child in
                let first = index == 0
                let last = index == split.children.count - 1
                let touches = horizontal ? (left: first, right: last, bottom: true) : (left: true, right: true, bottom: last)
                let childEdges = Edges(
                    cornerLeft: touches.left && touches.bottom && edges.cornerLeft,
                    cornerRight: touches.right && touches.bottom && edges.cornerRight,
                    suppressLeft: touches.left && edges.suppressLeft, suppressRight: touches.right && edges.suppressRight,
                    suppressBottom: touches.bottom && edges.suppressBottom)
                return build(child, depth: depth, edges: childEdges, dockedRoot: false, floatingRoot: floatingRoot, used: &used)
            }
            view.setChildren(children)
            used[node.id] = view
            return view
        case .tabs(let group):
            let view = paneView(for: node)
            view.depth = depth
            view.edges = edges
            view.isDockedRoot = dockedRoot
            view.isFloatingRoot = floatingRoot == node.id
            // A tab's content sits flush against this group's border on three sides.
            let contentEdges = Edges(
                cornerLeft: edges.cornerLeft, cornerRight: edges.cornerRight, suppressLeft: true, suppressRight: true, suppressBottom: true)
            let contents = group.tabs.map { tab in
                (
                    tab.id,
                    build(tab.content, depth: depth + 1, edges: contentEdges, dockedRoot: false, floatingRoot: floatingRoot, used: &used)
                )
            }
            view.setTabContents(contents, active: group.activeTabID)
            used[node.id] = view
            return view
        case .leaf(let leaf):
            let view = paneView(for: node)
            view.depth = depth
            view.edges = edges
            view.isDockedRoot = false
            view.isFloatingRoot = floatingRoot == node.id
            view.setBody(renderer.bodyHost(for: leaf))
            used[node.id] = view
            return view
        }
    }

    private func paneView(for node: LayoutNode) -> PaneView {
        if let view = nodeViews[node.id] as? PaneView, view.node.isLeaf == node.isLeaf, view.node.isTabs == node.isTabs {
            view.node = node
            return view
        }
        return PaneView(node: node, host: self)
    }

    /// Chrome drawn from the model and the window's state; bodies shown, dimmed.
    func refreshChrome() {
        let dim = appearance.dim
        for view in nodeViews.values {
            guard let pane = view as? PaneView else {
                view.needsLayout = true
                continue
            }
            pane.refresh()
            pane.needsLayout = true
            if case .leaf(let leaf) = pane.node {
                let body = renderer.bodyHost(for: leaf)
                // Before the view is first built, so it starts with the right look.
                renderer.runtime.panes.appearanceDidChange(leaf.id, theme: appearance.theme, depth: pane.depth)
                body.setShown(layout.isShowing(leaf.id))
                body.setDim(leaf.id == layout.activePaneID ? nil : dim)
                (body.content as? EmptyPaneView)?.theme = appearance.theme
                (body.content as? EmptyPaneView)?.isDropTarget = dragVisuals.target == .emptyPane(leaf.id)
                (body.content as? UnavailablePaneView)?.theme = appearance.theme
                pane.header?.setTitleView(body.headerTitle)
                pane.header?.controls.setAccessory(body.accessory)
                pane.header?.controls.setActions(body.actions, from: body.content)
            }
        }
    }

    func refreshOverlays() {
        for tree in trees {
            tree.overlay.needsDisplay = true
            tree.overlay.updatePreview()
            tree.overlay.updateSignals()
        }
    }

    /// These panes' signals changed: their headers, the tabs holding them and
    /// the outlines follow; nothing else is redrawn.
    func refreshSignals(on panes: Set<PaneID>) {
        for case let view as PaneView in nodeViews.values {
            if view.isLeaf {
                if panes.contains(view.nodeID) { view.header?.refreshSignals() }
            } else if let bar = view.tabBar, view.node.leaves.contains(where: { panes.contains($0.id) }) {
                bar.strip.refreshSignals()
            }
        }
        root.layoutSubtreeIfNeeded()
        refreshOverlays()
    }

    var trees: [TreeHostView] { [root.docked] + root.floatingViews.map(\.tree) }

    /// The keyboard follows the active pane (or new content in it).
    private func followActivePane() {
        guard let active = layout.activeLeafID, layout.isShowing(active), let leaf = layout.findNode(active)?.leaf else { return }
        let host = renderer.bodyHost(for: leaf)
        guard focused?.pane != active || focused?.body != host.bodyKey else { return }
        focused = (active, host.bodyKey)
        // A pane opened without taking the keyboard (an agent's) is active and
        // shown as usual but skips it, once: the user activating it later
        // focuses it as always.
        if engine.live(active)?.consumeKeyboardExemption() == true { return }
        host.focusContent()
    }

    func paneView(_ id: NodeID) -> PaneView? { nodeViews[id] as? PaneView }

    /// Every split view on screen, docked and floating, with the tree it's in.
    var splitViews: [SplitNodeView] { nodeViews.values.compactMap { $0 as? SplitNodeView }.filter { !$0.isHiddenOrHasHiddenAncestor } }

    func tree(containing view: NSView) -> TreeHostView? {
        trees.first { view.isDescendant(of: $0) }
    }

    /// A pane's rect in the content area (top-left origin), if it's on screen.
    func paneRect(_ id: NodeID) -> FloatRect? {
        guard let view = paneView(id), !view.isHiddenOrHasHiddenAncestor, view.window != nil else { return nil }
        let rect = view.convert(view.bounds, to: root)
        return FloatRect(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height)
    }

    // MARK: ChromeHost

    func paneTitle(of node: LayoutNode) -> String { engine.paneTitle(of: node) }

    func bodyHost(for leaf: LayoutLeaf) -> PaneBodyHost { renderer.bodyHost(for: leaf) }

    func activate(_ node: NodeID) {
        engine.perform(in: windowID) { layout, _ in layout.setActivePane(node) }
    }

    func activateTab(_ tab: NodeID, in group: NodeID) {
        engine.perform(in: windowID) { layout, titles in
            guard let ref = layout.trees.lazy.compactMap({ Tree.findTab($0, tab) }).first else { return false }
            if ref.group.activeTabID != tab {
                // Switching moves focus with it, down to the tab's own leaf.
                layout.activateTab(group, tab, titles: titles)
                layout.setActivePane(Navigation.entryPaneID(ref.tab.content))
                return true
            }
            return layout.setActivePane(group)
        }
    }

    func closeTab(_ tab: NodeID) { engine.closeTab(tab) }

    func newTab(in group: NodeID) {
        engine.newPane(like: group, in: windowID, placement: .tab)
    }

    func perform(_ action: HeaderAction, on pane: NodeID) {
        HeaderMenu.close()
        switch action {
        case .splitHorizontal: engine.newPane(like: pane, in: windowID, placement: .split(.horizontal))
        case .splitVertical: engine.newPane(like: pane, in: windowID, placement: .split(.vertical))
        case .newTab: engine.newPane(like: pane, in: windowID, placement: .tab)
        case .newUnpinnedTab: newUnpinnedPane(from: pane)
        case .wrapInTabGroup: engine.perform(in: windowID) { layout, titles in layout.wrapPaneInTabs(pane, titles: titles) }
        case .close: engine.close(pane)
        case .clear: engine.clear(pane)
        }
    }

    /// A new pane like `origin`, floating over the section of it the setting names.
    func newUnpinnedPane(from origin: NodeID) {
        engine.newPane(like: origin, in: windowID, placement: .floating(spawnRect(from: origin)))
    }

    /// Where a new unpinned pane made from `origin` spawns: the section of it
    /// the setting names, or the default rect when it has no measurable box.
    private func spawnRect(from origin: NodeID) -> FloatRect {
        paneRect(origin).map { Floating.spawnRect(in: $0, at: appearance.spawnPosition) } ?? Floating.defaultRect
    }

    /// The palette's commit: a new pane of the chosen `type`, made from and
    /// placed at `origin`.
    func newPane(ofType type: ContentTypeID, from origin: NodeID, placement: PalettePlacement) {
        let placed: NewPanePlacement =
            switch placement {
            case .tab: .tab
            case .splitHorizontal: .split(.horizontal)
            case .splitVertical: .split(.vertical)
            case .unpinned: .floating(spawnRect(from: origin))
            }
        engine.newPane(ofType: type, from: origin, in: windowID, placement: placed)
    }

    func chromeMouseDown(_ event: NSEvent, on node: NodeID, in view: NSView) {
        if let float = layout.floating.first(where: { $0.content.id == node }) {
            activate(node)
            FloatingGesture.move(float.id, in: self, with: event)
            return
        }
        guard node != layout.root.id else { return }
        renderer.drag.press(event, subject: .pane(node), title: engine.paneTitle(of: node), in: self) { [weak self] in
            self?.activate(node)
        }
    }

    func tabMouseDown(_ event: NSEvent, tab: NodeID, group: NodeID, in view: NSView) {
        let title = layout.trees.lazy.compactMap { Tree.findTab($0, tab) }.first?.tab.title ?? ""
        renderer.drag.press(event, subject: .tab(tabID: tab, sourceGroupID: group), title: title, in: self) { [weak self] in
            self?.activateTab(tab, in: group)
        }
    }

    func chromeMenu(_ event: NSEvent, for node: NodeID, tab: NodeID?, group: NodeID?, in view: NSView) {
        var items: [ContextMenu.Item] = []
        let floating = layout.floatingPane(holding: node)
        func pinItem(_ id: NodeID, origin: NodeID? = nil) -> ContextMenu.Item? {
            if let floating {
                guard floating.content.id == id else { return nil }
                return ContextMenu.Item(title: "Pin") { [weak self] in self?.pin(floating.id) }
            }
            return ContextMenu.Item(title: "Unpin") { [weak self] in self?.unpin(id, origin: origin) }
        }
        if let tab, let group {
            items.append(
                ContextMenu.Item(title: "Edit title") { [weak self, weak view] in
                    if let view { self?.rename(tab: tab, pane: nil, from: view) }
                })
            if let unpin = pinItem(node, origin: group) { items.append(unpin) }
        } else if let group {
            let isRoot = group == layout.root.id
            if !isRoot, let pin = pinItem(group) { items.append(pin) }
            if !isRoot, case .tabs(let node)? = layout.findNode(group), node.tabs.count == 1 {
                items.append(
                    ContextMenu.Item(title: "Ungroup") { [weak self] in
                        guard let self else { return }
                        self.engine.perform(in: self.windowID) { layout, titles in layout.ungroupTabs(group, titles: titles) }
                    })
            }
        } else {
            // A pane whose header shows controls in place of a title has none to edit.
            if paneView(node)?.header?.titleView == nil {
                items.append(
                    ContextMenu.Item(title: "Edit title") { [weak self, weak view] in
                        if let view { self?.rename(tab: nil, pane: node, from: view) }
                    })
            }
            if let pin = pinItem(node) { items.append(pin) }
        }
        guard !items.isEmpty else { return }
        ContextMenu.open(items, at: root.convert(event.locationInWindow, from: nil), in: self)
    }

    /// Where each pane's floating window was when it was pinned back: unpinning
    /// it again puts it there (this session only).
    private static var lastRects: [NodeID: FloatRect] = [:]

    func unpin(_ node: NodeID, origin: NodeID? = nil) {
        let rect = Self.lastRects[node] ?? paneRect(node) ?? origin.flatMap(paneRect) ?? Floating.defaultRect
        let viewport = viewport
        engine.perform(in: windowID) { layout, titles in layout.unpinPane(node, rect: rect, viewport: viewport, titles: titles) }
    }

    func pin(_ floatID: NodeID) {
        if let entry = layout.floating.first(where: { $0.id == floatID }) {
            if Self.lastRects.count > 200 { Self.lastRects.removeAll() }
            Self.lastRects[entry.content.id] = entry.rect
        }
        engine.perform(in: windowID) { layout, titles in layout.repinPane(floatID, titles: titles) }
    }

    func rename(tab: NodeID?, pane: NodeID?, from view: NSView) {
        TitleEditor.begin(tab: tab, pane: pane, in: self, from: view)
    }

    func dragWindow(with event: NSEvent) {
        window?.performDrag(with: event)
    }

    func stopCaffeinate() {
        renderer.runtime.caffeinate.stop()
    }

    func resizeFloating(_ floatID: NodeID, edge: ResizeHandle.Edge, with event: NSEvent) {
        FloatingGesture.resize(floatID, edge: edge, in: self, with: event)
    }

    func chromeDidScroll() {
        for tree in trees { tree.overlay.needsDisplay = true }
    }

    func signals(on pane: NodeID) -> [ShownSignal] { engine.signals.shown(on: pane) }

    func tabSignals(_ content: LayoutNode) -> [ShownSignal] { engine.signals.tabMarks(for: content.leaves.map(\.id)) }

    /// The window has left the layout: its views and handlers let go of this
    /// controller, so nothing AppKit still does with the closing window (a
    /// last layout pass, a hit test) reaches a controller that's gone.
    func dismantle() {
        root.separatorHit = nil
        root.separatorMouseDown = nil
        root.separatorCursorRects = nil
        root.separatorCursor = nil
        window?.delegate = nil
        window?.contentView = NSView()
    }

    // MARK: NSWindowDelegate

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        engine.shouldClose(windowID)
    }

    func windowWillClose(_ notification: Notification) {
        guard !isClosingForModel else { return }
        willClose?()
        engine.windowDidClose(windowID)
        dismantle()
    }

    func windowDidBecomeKey(_ notification: Notification) {
        didBecomeKey?()
        engine.frontmostWindowDidChange()
        engine.windowDidGainFocus(windowID)
    }

    func windowDidResignKey(_ notification: Notification) {
        engine.windowDidLoseFocus(windowID)
    }

    func windowDidMove(_ notification: Notification) { reportFrame() }

    func windowDidResize(_ notification: Notification) {
        reportFrame()
        (window as? WorkspaceWindow)?.placeTrafficLights()
        // Floating panes are kept inside the window, once a resize settles.
        reclampTimer?.invalidate()
        reclampTimer = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let viewport = self.viewport
                self.engine.perform(in: self.windowID) { layout, _ in layout.reclampFloating(viewport) }
            }
        }
    }

    #if DEBUG
    /// A resize's pending reclamp, done now rather than once the resize settles (the visual
    /// capture, which sizes its window and doesn't wait).
    func reclampNow() {
        if let timer = reclampTimer, timer.isValid { timer.fire() }
        reclampTimer = nil
    }
    #endif

    func windowWillEnterFullScreen(_ notification: Notification) { setFullScreen(true) }
    func windowDidExitFullScreen(_ notification: Notification) { setFullScreen(false) }

    func windowDidEnterFullScreen(_ notification: Notification) { (window as? WorkspaceWindow)?.placeTrafficLights() }

    func windowWillExitFullScreen(_ notification: Notification) { setFullScreen(false) }

    private func setFullScreen(_ fullScreen: Bool) {
        guard fullScreen != isFullScreen else { return }
        isFullScreen = fullScreen
        refreshChrome()
        root.needsLayout = true
        (window as? WorkspaceWindow)?.placeTrafficLights()
        refreshOverlays()
    }

    private func reportFrame() {
        guard tracksFrame, let frame = window?.frame else { return }
        engine.windowFrameDidChange(
            windowID, to: WindowFrame(x: frame.origin.x, y: frame.origin.y, width: frame.width, height: frame.height))
    }
}

/// The workspace's NSWindow: its traffic lights sit at {14, 9}
/// (`Metrics.trafficLightOrigin`), centered in the root bar.
@MainActor
final class WorkspaceWindow: NSWindow {
    var layoutTrafficLights: (() -> Void)?

    override func layoutIfNeeded() {
        super.layoutIfNeeded()
        placeTrafficLights()
    }

    /// The title-bar container is the buttons' height plus twice the y margin,
    /// and the buttons start at the x margin.
    func placeTrafficLights() {
        guard let close = standardWindowButton(.closeButton), let mini = standardWindowButton(.miniaturizeButton),
            let zoom = standardWindowButton(.zoomButton), let container = close.superview?.superview
        else { return }
        let margin = Metrics.trafficLightOrigin
        let height = close.frame.height + margin.y * 2
        var frame = container.frame
        if frame.height != height || frame.origin.y != self.frame.height - height {
            frame.size.height = height
            frame.origin.y = self.frame.height - height
            container.frame = frame
        }
        let spacing = mini.frame.minX - close.frame.maxX
        var x = margin.x
        for button in [close, mini, zoom] {
            let y = (button.superview?.frame.height ?? height) - margin.y - button.frame.height
            if button.frame.origin != CGPoint(x: x, y: y) { button.setFrameOrigin(CGPoint(x: x, y: y)) }
            x += button.frame.width + spacing
        }
    }
}
