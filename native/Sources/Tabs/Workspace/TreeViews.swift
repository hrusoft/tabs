import AppKit
import TabsCore
import TabsPluginSDK

/// One layout tree on screen — the docked layout, or a floating pane's —
/// with the overlay drawn above all of its panes: the active pane's outline
/// and a drag's dock preview.
@MainActor
final class TreeHostView: FlippedView {
    private(set) var rootView: NodeView?
    let overlay: TreeOverlayView
    /// Hover menus opened from this tree's chrome: above its panes and overlay.
    let menuLayer = PassThroughView()

    override init(frame: NSRect) {
        overlay = TreeOverlayView()
        super.init(frame: frame)
        addSubview(overlay)
        addSubview(menuLayer)
    }

    /// Shows `view` as the tree: one that was a background tab's content comes here still hidden.
    func setRoot(_ view: NodeView) {
        if rootView !== view {
            rootView?.removeFromSuperview()
            addSubview(view, positioned: .below, relativeTo: overlay)
            rootView = view
        }
        view.isHidden = false
        overlay.tree = self
        needsLayout = true
    }

    override func layout() {
        super.layout()
        if let rootView { place(rootView, layoutBounds) }
        place(overlay, layoutBounds)
        place(menuLayer, layoutBounds)
    }

    /// The pane view for `id` in this tree, if it is on screen.
    func paneView(_ id: NodeID) -> PaneView? {
        guard let rootView else { return nil }
        return Self.find(id, in: rootView)
    }

    static func find(_ id: NodeID, in view: NSView) -> PaneView? {
        if let pane = view as? PaneView, pane.nodeID == id { return pane }
        for subview in view.subviews {
            if let found = find(id, in: subview) { return found }
        }
        return nil
    }
}

/// A view that never takes the mouse itself (its subviews may).
@MainActor
class PassThroughView: FlippedView {
    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        return hit === self ? nil : hit
    }
}

/// Draws over a tree: the active pane's 1px accent outline around its
/// content (its chrome bar excluded, broken where its active tab opens onto
/// the content), each signalled pane's outline in the same place, and where a
/// dragged tab or pane would dock.
@MainActor
final class TreeOverlayView: FlippedView {
    weak var host: (any ChromeHost)?
    weak var tree: TreeHostView?
    private let preview = CALayer()
    private var previewPane: NodeID?
    /// Signalled panes' outlines, by pane.
    private(set) var signalOutlines: [NodeID: SignalOutlineView] = [:]
    /// The signal outlines, and over them the dock preview (`.dock-preview`'s
    /// z-index over the cues' `::after`): views, so AppKit keeps their layers
    /// in this order; the preview is a plain layer inside its host, so it
    /// animates between zones.
    let outlineHost = FlippedView()
    let previewHost = FlippedView()

    override init(frame: NSRect) {
        super.init(frame: frame)
        for host in [outlineHost, previewHost] {
            host.frame = bounds
            host.autoresizingMask = [.width, .height]
            addSubview(host)
        }
        previewHost.layer?.addSublayer(preview)
        preview.isHidden = true
        preview.borderWidth = 1
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// Where the dock preview is laid out (content coordinates), if it shows.
    var previewFrame: CGRect? { preview.isHidden ? nil : previewLayout }
    private var previewLayout: CGRect?

    /// The box a pane's outlines take (overlay coordinates): its content,
    /// below its chrome bar, over its own border on three sides (or, where it
    /// has none, over the ancestor's border it sits against).
    func outlineRect(of pane: PaneView) -> CGRect {
        let box = pane.paddingBox
        let chrome = pane.chromeBottom
        return convert(CGRect(x: box.minX - 1, y: box.minY + chrome, width: box.width + 2, height: box.height - chrome + 1), from: pane)
    }

    override func layout() {
        super.layout()
        for host in [outlineHost, previewHost] { host.frame = bounds }
        updateSignals()
    }

    /// Every visible leaf's signal outline, the last signal it shows, in tree
    /// order (later panes' outlines over earlier ones', as `::after`s paint).
    func updateSignals() {
        var next: [NodeID: SignalOutlineView] = [:]
        var order: [SignalOutlineView] = []
        if let host, let tree, let root = tree.rootView {
            let source = host.dragVisuals.sourcePane.flatMap { tree.paneView($0) }
            let theme = host.appearance.theme
            func visit(_ view: NSView) {
                guard !view.isHidden else { return }
                if let pane = view as? PaneView, pane.isLeaf {
                    guard let signal = host.signals(on: pane.nodeID).last else { return }
                    let outline = signalOutlines[pane.nodeID] ?? SignalOutlineView(pane: pane.nodeID)
                    outline.frame = outlineRect(of: pane)
                    outline.show(signal, color: SignalStyle.color(signal.kind, in: theme), radii: pane.cornerRadii)
                    // Part of the pane: a dragged pane's outline dims with it.
                    outline.alphaValue = source.map { pane.isDescendant(of: $0) } == true ? 0.4 : 1
                    next[pane.nodeID] = outline
                    order.append(outline)
                    return
                }
                for subview in view.subviews { visit(subview) }
            }
            visit(root)
        }
        for (id, outline) in signalOutlines where next[id] == nil { outline.removeFromSuperview() }
        for outline in order where outline.superview !== outlineHost { outlineHost.addSubview(outline) }
        if outlineHost.subviews.map(ObjectIdentifier.init) != order.map(ObjectIdentifier.init) {
            for outline in order { outlineHost.addSubview(outline, positioned: .above, relativeTo: nil) }
        }
        signalOutlines = next
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let host, let tree, let pane = tree.paneView(host.layout.activePaneID), !pane.isHiddenOrHasHiddenAncestor else { return }
        // A signal on the active pane outlines it instead (the cue's rule
        // follows the accent's and wins the cascade).
        if pane.isLeaf, !host.signals(on: pane.nodeID).isEmpty { return }
        let rect = outlineRect(of: pane)
        let (left, right) = pane.cornerRadii
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.saveGState()
        // The active tab covers the outline where it opens onto the content.
        if let bar = pane.tabBar, let active = bar.strip.orderedTabs.first(where: \.isActive) {
            let stripClip = bar.strip.convert(bar.strip.bounds, to: self)
            let tabRect = active.convert(active.bounds, to: self).intersection(stripClip)
            if !tabRect.isNull {
                let gap = NSBezierPath(rect: bounds)
                gap.append(NSBezierPath(rect: CGRect(x: tabRect.minX, y: rect.minY, width: tabRect.width, height: 1)).reversed)
                gap.addClip()
            }
        }
        // Part of the pane: a dragged pane's outline dims with it.
        let dimmed = host.dragVisuals.sourcePane.flatMap { tree.paneView($0) }.map { pane.isDescendant(of: $0) } ?? false
        let accent = host.appearance.theme.accent.withAlphaComponent(dimmed ? 0.4 : 1)
        accent.setFill()
        if left == 0 && right == 0 {
            let frame = NSBezierPath(rect: rect)
            frame.append(NSBezierPath(rect: rect.insetBy(dx: 1, dy: 1)).reversed)
            frame.fill()
        } else {
            let path = PaneView.bottomRoundedRect(rect.insetBy(dx: 0.5, dy: 0.5), left: max(left - 0.5, 0), right: max(right - 0.5, 0))
            accent.setStroke()
            path.lineWidth = 1
            path.stroke()
        }
        context.restoreGState()
    }

    /// Where a drag would dock: half the pane (inside its border) for an
    /// edge, all of it for the center. Moves between zones animate.
    func updatePreview() {
        guard let host, case .dock(let targetID, let zone)? = host.dragVisuals.target, let pane = tree?.paneView(targetID) else {
            preview.isHidden = true
            previewPane = nil
            return
        }
        // Laid out on the pane's padding box, unsnapped; painted snapped.
        let insets = pane.borderInsets
        let frame = pane.layoutFrame
        let box = CGRect(
            x: frame.minX + insets.left, y: frame.minY + insets.top, width: frame.width - insets.left - insets.right,
            height: frame.height - insets.top - insets.bottom)
        var layout = box
        switch zone {
        case .left: layout.size.width = box.width / 2
        case .right: layout = CGRect(x: box.minX + box.width / 2, y: box.minY, width: box.width / 2, height: box.height)
        case .top: layout.size.height = box.height / 2
        case .bottom: layout = CGRect(x: box.minX, y: box.minY + box.height / 2, width: box.width, height: box.height / 2)
        case .center: break
        }
        previewLayout = layout
        let origin = layoutFrame.snapped.origin
        let rect = layout.snapped.offsetBy(dx: -origin.x, dy: -origin.y)
        let theme = host.appearance.theme
        CATransaction.begin()
        let animate = previewPane == targetID && !preview.isHidden
        CATransaction.setDisableActions(!animate)
        CATransaction.setAnimationDuration(0.1)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeInEaseOut))
        preview.backgroundColor = theme.accent.mixedWithTransparent(0.16).cgColor
        preview.borderColor = theme.accent.cgColor
        preview.frame = rect
        preview.isHidden = false
        CATransaction.commit()
        previewPane = targetID
    }
}

/// A floating pane: its tree in a rounded window over the docked layout,
/// with a dark ring and a drop shadow, and invisible frame handles.
@MainActor
final class FloatingWindowView: FlippedView {
    let floatID: NodeID
    let tree: TreeHostView
    private let clip = FlippedView()
    private var handles: [ResizeHandle] = []

    init(floatID: NodeID, host: any ChromeHost) {
        self.floatID = floatID
        tree = TreeHostView()
        super.init(frame: .zero)
        tree.overlay.host = host
        layer?.masksToBounds = false
        clip.layer?.masksToBounds = true
        clip.layer?.cornerRadius = Metrics.floatingCornerRadius
        clip.addSubview(tree)
        addSubview(clip)
        for edge in ResizeHandle.Edge.allCases {
            let handle = ResizeHandle(edge: edge, floatID: floatID, host: host)
            handles.append(handle)
            addSubview(handle)
        }
        setAccessibilityIdentifier("floating-\(floatID)")
    }

    func apply(theme: Theme) {
        clip.layer?.backgroundColor = theme.bg.cgColor
        // Ring (0 0 0 1px) and drop shadow (0 14px 36px).
        layer?.shadowColor = theme.shadow.cgColor
        layer?.shadowOpacity = Float(min(0.6 * theme.shadowStrength, 1))
        layer?.shadowRadius = 36
        layer?.shadowOffset = CGSize(width: 0, height: -14)
        clip.layer?.borderWidth = 0
        ring.backgroundColor = theme.shadow(0.55).cgColor
    }

    private lazy var ring: CALayer = {
        let ring = CALayer()
        ring.cornerRadius = Metrics.floatingCornerRadius + 1
        layer?.insertSublayer(ring, at: 0)
        return ring
    }()

    override func layout() {
        super.layout()
        place(clip, layoutBounds)
        clip.place(tree, clip.layoutBounds)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        ring.frame = bounds.insetBy(dx: -1, dy: -1)
        layer?.shadowPath = CGPath(
            roundedRect: bounds, cornerWidth: Metrics.floatingCornerRadius, cornerHeight: Metrics.floatingCornerRadius, transform: nil)
        CATransaction.commit()
        let edge = Metrics.floatingResizeEdge
        let corner = Metrics.floatingResizeCorner
        for handle in handles {
            handle.frame =
                switch handle.edge {
                case .n: CGRect(x: corner, y: 0, width: bounds.width - corner * 2, height: edge)
                case .s: CGRect(x: corner, y: bounds.height - edge, width: bounds.width - corner * 2, height: edge)
                case .w: CGRect(x: 0, y: corner, width: edge, height: bounds.height - corner * 2)
                case .e: CGRect(x: bounds.width - edge, y: corner, width: edge, height: bounds.height - corner * 2)
                case .nw: CGRect(x: 0, y: 0, width: corner, height: corner)
                case .ne: CGRect(x: bounds.width - corner, y: 0, width: corner, height: corner)
                case .sw: CGRect(x: 0, y: bounds.height - corner, width: corner, height: corner)
                case .se: CGRect(x: bounds.width - corner, y: bounds.height - corner, width: corner, height: corner)
                }
        }
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// One of a floating pane's eight invisible frame handles.
@MainActor
final class ResizeHandle: FlippedView {
    enum Edge: CaseIterable {
        case n, ne, e, se, s, sw, w, nw
    }

    let edge: Edge
    let floatID: NodeID
    unowned let host: any ChromeHost

    init(edge: Edge, floatID: NodeID, host: any ChromeHost) {
        self.edge = edge
        self.floatID = floatID
        self.host = host
        super.init(frame: .zero)
    }

    var cursor: NSCursor {
        switch edge {
        case .n, .s: .frameResize(position: edge == .n ? .top : .bottom, directions: .all)
        case .e, .w: .frameResize(position: edge == .e ? .right : .left, directions: .all)
        case .nw: .frameResize(position: .topLeft, directions: .all)
        case .se: .frameResize(position: .bottomRight, directions: .all)
        case .ne: .frameResize(position: .topRight, directions: .all)
        case .sw: .frameResize(position: .bottomLeft, directions: .all)
        }
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: cursor)
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    override func mouseDown(with event: NSEvent) {
        host.resizeFloating(floatID, edge: edge, with: event)
    }
}

/// A window's content: the docked tree, the floating panes over it, and the
/// window-wide overlays (the drag ghost, the navigation flash, menus).
@MainActor
final class WindowRootView: FlippedView {
    let docked: TreeHostView
    let floatingLayer = PassThroughView()
    let overlay = PassThroughView()
    var background: NSColor = .black { didSet { layer?.backgroundColor = background.cgColor } }
    /// Answers whether a point grabs a split separator (the resize owns the press).
    var separatorHit: ((CGPoint) -> Bool)?
    /// Takes a press on a separator.
    var separatorMouseDown: ((NSEvent) -> Void)?

    override init(frame: NSRect) {
        docked = TreeHostView()
        super.init(frame: frame)
        for view in [docked, floatingLayer, overlay] as [NSView] { addSubview(view) }
    }

    override func layout() {
        super.layout()
        layoutFrame = bounds
        place(docked, bounds)
        place(floatingLayer, bounds)
        place(overlay, bounds)
    }

    var floatingViews: [FloatingWindowView] { floatingLayer.subviews.compactMap { $0 as? FloatingWindowView } }

    /// Reports pointer moves (the separators' cursor).
    var mouseMovedHandler: ((CGPoint) -> Void)?
    private var tracking: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseMoved(with event: NSEvent) {
        mouseMovedHandler?(convert(event.locationInWindow, from: nil))
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        if let hit = overlay.hitTest(convert(local, to: overlay.superview)) { return hit }
        if let hit = floatingLayer.hitTest(convert(local, to: floatingLayer.superview)) {
            // A separator inside a floating pane still takes the press; a menu or a frame handle over it doesn't.
            if separatorHit?(local) == true, !(hit is ResizeHandle),
                !hit.isDescendant(of: floatingViews.first { hit.isDescendant(of: $0) }?.tree.menuLayer ?? hit)
            {
                return self
            }
            return hit
        }
        if let hit = docked.menuLayer.hitTest(convert(local, to: docked.menuLayer.superview)) { return hit }
        if separatorHit?(local) == true { return self }
        return super.hitTest(point)
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    override func mouseDown(with event: NSEvent) {
        separatorMouseDown?(event)
    }
}
