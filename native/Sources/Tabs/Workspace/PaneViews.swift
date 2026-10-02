import AppKit
import TabsCore
import TabsPluginSDK

/// Which of its tree's outer edges a node sits against (the Electron app's
/// `ContentRendererProps`): whether it owns a rounded bottom corner of the
/// window, and which of its own borders it drops because an ancestor's
/// border is already drawn there.
struct Edges: Equatable {
    var cornerLeft = false
    var cornerRight = false
    var suppressLeft = false
    var suppressRight = false
    var suppressBottom = false
}

/// What the chrome views read and whom they tell: the window they're in.
@MainActor
protocol ChromeHost: AnyObject {
    var appearance: PaneAppearance { get }
    var layout: WindowLayout { get }
    var isFullScreen: Bool { get }
    var dragVisuals: DragVisuals { get }
    func paneTitle(of node: LayoutNode) -> String
    func bodyHost(for leaf: LayoutLeaf) -> PaneBodyHost
    func activate(_ node: NodeID)
    func activateTab(_ tab: NodeID, in group: NodeID)
    func closeTab(_ tab: NodeID)
    func newTab(in group: NodeID)
    func perform(_ action: HeaderAction, on pane: NodeID)
    func chromeMouseDown(_ event: NSEvent, on node: NodeID, in view: NSView)
    func tabMouseDown(_ event: NSEvent, tab: NodeID, group: NodeID, in view: NSView)
    func chromeMenu(_ event: NSEvent, for node: NodeID, tab: NodeID?, group: NodeID?, in view: NSView)
    func rename(tab: NodeID?, pane: NodeID?, from view: NSView)
    /// The docked root's bar is the window's title bar: its background drags the window.
    func dragWindow(with event: NSEvent)
    /// The title bar's cup (Decaf): stops the managed caffeinate process.
    func stopCaffeinate()
    func resizeFloating(_ floatID: NodeID, edge: ResizeHandle.Edge, with event: NSEvent)
    /// A tab strip scrolled: the active tab's gap in the outline moved.
    func chromeDidScroll()
    /// The signals a pane's header shows, in order.
    func signals(on pane: NodeID) -> [ShownSignal]
    /// The signals a tab holding `content` shows (tab-marking kinds on any leaf in it).
    func tabSignals(_ content: LayoutNode) -> [ShownSignal]
}

/// What a drag in flight shows in this window.
struct DragVisuals: Equatable {
    var sourceTab: NodeID?
    var sourcePane: NodeID?
    var target: DropTarget?
}

/// The pane-header controls (the hover toolbar's actions).
enum HeaderAction: Equatable {
    case splitHorizontal, splitVertical, newTab, newUnpinnedTab, wrapInTabGroup, close, clear

    /// The control's identifier: the Electron app's test id for it.
    var accessibilityID: String {
        switch self {
        case .splitHorizontal: "pane-split-horizontal-button"
        case .splitVertical: "pane-split-vertical-button"
        case .newTab: "pane-new-tab-button"
        case .newUnpinnedTab: "pane-new-unpinned-tab-button"
        case .wrapInTabGroup: "pane-tab-group-button"
        case .close: "pane-close-button"
        case .clear: "pane-clear-button"
        }
    }
}

/// One view per node of a layout tree, reused while the node lives.
@MainActor
class NodeView: FlippedView {
    let nodeID: NodeID
    unowned let host: any ChromeHost
    var node: LayoutNode
    var depth = 0
    var edges = Edges()

    init(node: LayoutNode, host: any ChromeHost) {
        nodeID = node.id
        self.node = node
        self.host = host
        super.init(frame: .zero)
    }

    /// Accepts the first click in an inactive window: a click on the chrome
    /// acts, as it does in the Electron app.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

// MARK: - Panes

/// A pane — a leaf or a tab group — dressed like a small window: a 1px
/// border (minus the sides an ancestor already draws), its chrome bar (a
/// header, or the group's tab bar), and its content below. `.pane` in the
/// Electron app.
@MainActor
final class PaneView: NodeView {
    /// The docked root: its bar is the window's title bar.
    var isDockedRoot = false
    /// The pane a floating window is built around: its chrome moves the window.
    var isFloatingRoot = false
    private(set) var header: PaneHeaderView?
    private(set) var tabBar: TabBarView?
    /// The leaf's body, or the group's tab contents.
    let content = FlippedView()
    /// A group's tab contents, by tab id.
    private(set) var tabViews: [NodeID: NodeView] = [:]

    override init(node: LayoutNode, host: any ChromeHost) {
        super.init(node: node, host: host)
        addSubview(content)
        switch node {
        case .leaf:
            let header = PaneHeaderView(pane: self)
            addSubview(header)
            self.header = header
        case .tabs:
            let bar = TabBarView(pane: self)
            addSubview(bar)
            tabBar = bar
        case .split:
            break
        }
        setAccessibilityIdentifier("pane-\(node.id)")
    }

    var isLeaf: Bool { node.isLeaf }
    var isActive: Bool { host.layout.activePaneID == nodeID }

    /// Where this pane's chrome bar ends, below its top border.
    var chromeBottom: CGFloat {
        isDockedRoot && !host.isFullScreen ? Metrics.titlebarHeight : Metrics.chromeBottom
    }

    var borderInsets: NSEdgeInsets {
        NSEdgeInsets(top: 1, left: edges.suppressLeft ? 0 : 1, bottom: edges.suppressBottom ? 0 : 1, right: edges.suppressRight ? 0 : 1)
    }

    /// Inside the border (CSS's padding box).
    var paddingBox: CGRect {
        let insets = borderInsets
        return CGRect(
            x: insets.left, y: insets.top, width: max(bounds.width - insets.left - insets.right, 0),
            height: max(bounds.height - insets.top - insets.bottom, 0))
    }

    /// The window corner radius this pane's bottom-left / bottom-right corner follows.
    var cornerRadii: (left: CGFloat, right: CGFloat) {
        let radius = host.isFullScreen ? 0 : host.appearance.cornerRadius
        return (edges.cornerLeft ? radius : 0, edges.cornerRight ? radius : 0)
    }

    /// Shows the group's tabs: each tab's content view, only the active one visible.
    func setTabContents(_ views: [(tab: NodeID, view: NodeView)], active: NodeID?) {
        var next: [NodeID: NodeView] = [:]
        for (tab, view) in views {
            next[tab] = view
            if view.superview !== content { content.addSubview(view) }
            view.isHidden = tab != active
        }
        for (tab, view) in tabViews where next[tab] !== view && view.superview === content {
            view.removeFromSuperview()
        }
        tabViews = next
        needsLayout = true
    }

    /// Shows the leaf's body.
    func setBody(_ body: PaneBodyHost) {
        if body.superview !== content {
            for view in content.subviews where view !== body { view.removeFromSuperview() }
            content.addSubview(body)
        }
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let size = layoutSize
        let insets = borderInsets
        let box = CGRect(
            x: insets.left, y: insets.top, width: max(size.width - insets.left - insets.right, 0),
            height: max(size.height - insets.top - insets.bottom, 0))
        if let header {
            // The header is its chrome bar plus a 1px bottom border.
            let height = chromeBottom + 1
            place(header, CGRect(x: box.minX, y: box.minY, width: box.width, height: height))
            place(content, CGRect(x: box.minX, y: box.minY + height, width: box.width, height: max(box.height - height, 0)))
        } else if let tabBar {
            // The bar reaches one row past its own box: the active tab covers
            // the hairline under it (the content's top border).
            place(tabBar, CGRect(x: box.minX, y: box.minY, width: box.width, height: chromeBottom + 1))
            place(content, CGRect(x: box.minX, y: box.minY + chromeBottom, width: box.width, height: max(box.height - chromeBottom, 0)))
        }
        for view in content.subviews {
            if let child = view as? FlippedView { content.place(child, content.layoutBounds) } else { view.frame = content.bounds }
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        let theme = host.appearance.theme
        theme.border.setFill()
        let insets = borderInsets
        let (left, right) = cornerRadii
        if left == 0 && right == 0 {
            NSBezierPath(rect: CGRect(x: 0, y: 0, width: bounds.width, height: 1)).fill()
            if insets.left > 0 { NSBezierPath(rect: CGRect(x: 0, y: 0, width: 1, height: bounds.height)).fill() }
            if insets.right > 0 { NSBezierPath(rect: CGRect(x: bounds.width - 1, y: 0, width: 1, height: bounds.height)).fill() }
            if insets.bottom > 0 { NSBezierPath(rect: CGRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1)).fill() }
        } else {
            let path = Self.bottomRoundedRect(bounds.insetBy(dx: 0.5, dy: 0.5), left: max(left - 0.5, 0), right: max(right - 0.5, 0))
            theme.border.setStroke()
            path.lineWidth = 1
            path.stroke()
        }
    }

    /// A rect whose bottom corners are rounded (flipped coordinates).
    static func bottomRoundedRect(_ rect: CGRect, left: CGFloat, right: CGFloat) -> NSBezierPath {
        let path = NSBezierPath()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.line(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.line(to: CGPoint(x: rect.maxX, y: rect.maxY - right))
        if right > 0 {
            path.appendArc(
                withCenter: CGPoint(x: rect.maxX - right, y: rect.maxY - right), radius: right, startAngle: 0, endAngle: 90,
                clockwise: false)
        }
        path.line(to: CGPoint(x: rect.minX + left, y: rect.maxY))
        if left > 0 {
            path.appendArc(
                withCenter: CGPoint(x: rect.minX + left, y: rect.maxY - left), radius: left, startAngle: 90, endAngle: 180, clockwise: false
            )
        }
        path.close()
        return path
    }

    /// Refreshes everything this pane draws from the model and the window's state.
    func refresh() {
        needsDisplay = true
        // The drag's source dims in place while its ghost travels.
        alphaValue = host.dragVisuals.sourcePane == nodeID ? 0.4 : 1
        header?.refresh()
        tabBar?.refresh()
    }
}

/// Chrome that shows the pointer over it (CSS `:hover`): told where the
/// pointer is in its own coordinates, or nil once it has left.
@MainActor
protocol PointerHover: NSView {
    func pointerHover(at point: CGPoint?)
}

/// Keeps `:hover` on the chrome under a point — for the pointer during a
/// drag, when tracking areas don't report, and for synthesized input.
@MainActor
enum ChromeHover {
    private static var hovered: [ObjectIdentifier: WeakHover] = [:]

    private struct WeakHover {
        weak var view: (any PointerHover)?
    }

    /// Hovers the chrome under `point` (root coordinates) in `root`, and un-hovers what was.
    static func update(_ point: CGPoint?, in root: WindowRootView) {
        var chain: [any PointerHover] = []
        if let point {
            var view = root.hitTest(root.convert(point, to: root.superview))
            while let current = view, current.isDescendant(of: root) {
                if let hover = current as? any PointerHover { chain.append(hover) }
                view = current.superview
            }
        }
        let now = Set(chain.map { ObjectIdentifier($0) })
        for (id, box) in hovered where !now.contains(id) {
            if let view = box.view, view.isDescendant(of: root) {
                view.pointerHover(at: nil)
                hovered[id] = nil
            } else if box.view == nil {
                hovered[id] = nil
            }
        }
        for view in chain {
            view.pointerHover(at: point.map { view.convert($0, from: root) })
            hovered[ObjectIdentifier(view)] = WeakHover(view: view)
        }
    }
}

// MARK: - Splits

/// A split: its children side by side (or stacked) at the model's sizes,
/// with no chrome and no gap between them — separators take no space.
@MainActor
final class SplitNodeView: NodeView {
    private(set) var children: [NodeView] = []
    /// Sizes shown instead of the model's while the user drags a separator.
    var liveSizes: [Double]?

    var split: Split? { node.splitNode }
    var direction: SplitDirection { split?.direction ?? .horizontal }
    var sizes: [Double] { liveSizes ?? split?.sizes ?? [] }

    /// Shows every child: one that was a background tab's content comes here still hidden.
    func setChildren(_ views: [NodeView]) {
        for view in children where !views.contains(where: { $0 === view }) && view.superview === self { view.removeFromSuperview() }
        for view in views {
            if view.superview !== self { addSubview(view) }
            view.isHidden = false
        }
        children = views
        needsLayout = true
    }

    /// Where each child is laid out (layout coordinates, unsnapped): each at
    /// its share of the length, flush against its neighbours.
    func childLayoutRects(sizes: [Double]? = nil) -> [CGRect] {
        let sizes = sizes ?? self.sizes
        let horizontal = direction == .horizontal
        let size = layoutSize
        let length = horizontal ? size.width : size.height
        var edges: [CGFloat] = [0]
        var running = 0.0
        for index in children.indices {
            running += index < sizes.count ? sizes[index] : 0
            edges.append(index == children.count - 1 ? length : CGFloat(running) * length)
        }
        return children.indices.map { index in
            let start = edges[index]
            let end = max(edges[index + 1], start)
            return horizontal
                ? CGRect(x: start, y: 0, width: end - start, height: size.height)
                : CGRect(x: 0, y: start, width: size.width, height: end - start)
        }
    }

    /// The children's layout rects in the window's content coordinates.
    var childContentRects: [CGRect] { childLayoutRects().map { $0.offsetBy(dx: layoutFrame.minX, dy: layoutFrame.minY) } }

    override func layout() {
        super.layout()
        for (view, rect) in zip(children, childLayoutRects()) { place(view, rect) }
    }
}

// MARK: - Chrome bars

/// A leaf pane's title bar: grip, the pane's signals, title, and the
/// hover-revealed controls.
@MainActor
final class PaneHeaderView: FlippedView, PointerHover {
    unowned let pane: PaneView
    let grip = GripView()
    let controls: HeaderControlsView
    private var tracking: NSTrackingArea?
    private(set) var isHovered = false
    /// While the title is being edited, its editor.
    var editor: NSView?
    /// The pane's signals' icons, after the grip (`CueIcon` in `Pane.tsx`).
    private var signalRow = SignalIconRow()
    var signalIcons: [SignalIconView] { signalRow.icons }
    /// The pane's plugin's view in the title's slot, in place of the title.
    private(set) var titleView: NSView?
    private var titleSlot: PaneHeaderSlot?

    init(pane: PaneView) {
        self.pane = pane
        controls = HeaderControlsView(pane: pane)
        super.init(frame: .zero)
        addSubview(grip)
        addSubview(controls)
    }

    var theme: Theme { pane.host.appearance.theme }
    var surface: NSColor { theme.surface(depth: pane.depth) }
    private let text = ChromeText(size: Metrics.chromeFontSize)

    /// Puts the plugin's own view in the title's slot (or takes it out).
    func setTitleView(_ view: NSView?) {
        guard view !== titleView else { return }
        titleView?.removeFromSuperview()
        titleView = view
        titleSlot = nil
        if let view { addSubview(view) }
        needsLayout = true
        needsDisplay = true
    }

    /// Where the controls are laid out (layout coordinates).
    private var controlsLayoutRect: CGRect {
        let size = controls.intrinsicSize
        let contentHeight = layoutSize.height - 1
        return CGRect(
            x: layoutSize.width - Metrics.barPaddingRight - size.width, y: (contentHeight - size.height) / 2, width: size.width,
            height: size.height)
    }

    /// Where the first signal icon (or the title) starts: after the grip and the bar's gap.
    private var leadingX: CGFloat { Metrics.depthIndent(pane.depth) + grip.glyphWidth + Metrics.barGap }

    /// Each icon's box (layout coordinates): 16×16, the bar's gap after each,
    /// centered in the bar.
    private func iconLayoutRect(_ index: Int) -> CGRect {
        let size = SignalStyle.iconSize
        return CGRect(
            x: leadingX + CGFloat(index) * (size + SignalStyle.headerGap), y: (layoutSize.height - 1 - size) / 2, width: size, height: size)
    }

    /// The title's box, after the grip and the signals and before the controls (drawing coordinates).
    var titleRect: CGRect { drawn(titleLayoutRect) }

    /// The title slot's box in layout coordinates: `titleRect` before it is drawn.
    private var titleLayoutRect: CGRect {
        let x = leadingX + CGFloat(signalIcons.count) * (SignalStyle.iconSize + SignalStyle.headerGap)
        return CGRect(x: x, y: 0, width: max(controlsLayoutRect.minX - Metrics.barGap - x, 0), height: layoutSize.height - 1)
    }

    /// Lays the plugin's title view out in the slot, its frame on whole points,
    /// and tells it where the slot really is.
    private func placeTitleView(_ view: NSView) {
        let absolute = titleLayoutRect.offsetBy(dx: layoutFrame.minX, dy: layoutFrame.minY)
        let painted = layoutFrame.snapped.origin
        let frame = absolute.snapped.offsetBy(dx: -painted.x, dy: -painted.y)
        if view.frame != frame { view.frame = frame }
        guard let adopter = view as? PaneHeaderTitleView else { return }
        let bar = layoutSize.width - Metrics.depthIndent(pane.depth) - Metrics.barPaddingRight
        let slot = PaneHeaderSlot(
            barContentWidth: max(bar, 0),
            fractionalOffset: CGPoint(x: absolute.minX - absolute.snapped.minX, y: absolute.minY - absolute.snapped.minY))
        if slot != titleSlot {
            titleSlot = slot
            adopter.paneHeaderSlotDidChange(slot)
        }
    }

    override func layout() {
        super.layout()
        place(grip, grip.layoutRect(at: Metrics.depthIndent(pane.depth), centeredIn: layoutSize.height - 1))
        for (index, icon) in signalIcons.enumerated() { place(icon, iconLayoutRect(index)) }
        place(controls, controlsLayoutRect)
        if let titleView { placeTitleView(titleView) }
        editor?.frame = titleRect
        signalRow.installTooltips(in: self)
    }

    /// Shows the pane's signals; the title moves over for their icons.
    func refreshSignals() {
        guard signalRow.show(pane.host.signals(on: pane.nodeID), in: self, theme: theme, placement: "pane") else { return }
        needsLayout = true
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        surface.setFill()
        bounds.fill()
        theme.border.setFill()
        CGRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1).fill()
        guard editor == nil, titleView == nil else { return }
        let title = titleRect
        text.draw(
            pane.host.paneTitle(of: pane.node), at: CGPoint(x: title.minX, y: text.baseline(centeredIn: title.height)),
            color: theme.textDim, maxWidth: title.width)
    }

    func refresh() {
        needsDisplay = true
        grip.color = theme.textDim
        refreshSignals()
        controls.refresh()
        needsLayout = true
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) { pointerHover(at: convert(event.locationInWindow, from: nil)) }
    override func mouseExited(with event: NSEvent) { pointerHover(at: nil) }

    func pointerHover(at point: CGPoint?) {
        isHovered = point != nil
        controls.setRevealed(isHovered)
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2, titleView == nil, titleRect.contains(convert(event.locationInWindow, from: nil)) {
            pane.host.rename(tab: nil, pane: pane.nodeID, from: self)
            return
        }
        pane.host.chromeMouseDown(event, on: pane.nodeID, in: self)
    }

    override func rightMouseDown(with event: NSEvent) {
        pane.host.chromeMenu(event, for: pane.nodeID, tab: nil, group: nil, in: self)
    }
}

/// The always-grabbable spot at a chrome bar's left edge: "⠿" at 10px, 60% opaque.
@MainActor
final class GripView: FlippedView {
    private static let text = ChromeText(size: 10)
    private static let glyph = "⠿"
    var color: NSColor = .gray { didSet { needsDisplay = true } }

    var glyphWidth: CGFloat { Self.text.width(Self.glyph) }

    /// Its box: the glyph's advance wide, one line (`line-height: 1`, 10px) tall.
    func layoutRect(at x: CGFloat, centeredIn height: CGFloat) -> CGRect {
        CGRect(x: x, y: (height - 10) / 2, width: glyphWidth, height: 10)
    }

    override func draw(_ dirtyRect: NSRect) {
        // A 10px line box around a taller font: the half-leading goes negative.
        let text = Self.text
        let baseline = (10 - (text.ascent + text.descent)) / 2 + text.ascent
        text.draw(Self.glyph, at: drawn(CGPoint(x: 0, y: baseline)), color: color.withAlphaComponent(color.alphaComponent * 0.6))
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// A chrome bar's controls: one hover-expanding group per kind of action.
@MainActor
final class HeaderControlsView: FlippedView {
    unowned let pane: PaneView
    private var buttons: [MenuGroupButton] = []
    private let separator = FlippedView()
    var groupButtons: [MenuGroupButton] { buttons }
    var separatorView: NSView { separator }
    private var accessory: NSView?
    /// The pane's plugin's header actions, leftmost.
    private(set) var actionButtons: [PaneActionButton] = []
    private(set) var isRevealed = false

    init(pane: PaneView) {
        self.pane = pane
        super.init(frame: .zero)
        alphaValue = 0
        addSubview(separator)
    }

    /// Split, tab and wrap actions — New tab first on the docked root, which
    /// can't be split or wrapped — then close and clear.
    private var groups: [[(HeaderAction, ChromeIcon, String)]] {
        let creation: [(HeaderAction, ChromeIcon, String)] =
            pane.isDockedRoot
            ? [(.newTab, .newTab, "New tab"), (.newUnpinnedTab, .newUnpinnedTab, "New unpinned tab")]
            : [
                (.splitHorizontal, .splitHorizontal, "Split horizontally"), (.splitVertical, .splitVertical, "Split vertically"),
                (.newTab, .newTab, "New tab"), (.newUnpinnedTab, .newUnpinnedTab, "New unpinned tab"),
                (.wrapInTabGroup, .wrapWindow, "Wrap in tab group"),
            ]
        return [creation, [(.close, .closePane, "Close pane"), (.clear, .clearPane, "Clear pane")]]
    }

    func setAccessory(_ view: NSView?) {
        guard view !== accessory else { return }
        accessory?.removeFromSuperview()
        accessory = view
        if let view { addSubview(view) }
        needsLayout = true
    }

    /// The content the current action buttons came from.
    private weak var actionsOwner: NSView?

    /// Shows the plugin's header actions from `owner`, the pane's content
    /// view: rebuilt when the content or the set of actions changes (a new
    /// controller's actions call into it, even under the same ids).
    func setActions(_ actions: [PaneHeaderAction], from owner: NSView?) {
        guard owner !== actionsOwner || actions.map(\.id) != actionButtons.map(\.action.id) else { return }
        actionsOwner = owner
        for button in actionButtons { button.removeFromSuperview() }
        actionButtons = actions.map { PaneActionButton(action: $0, pane: pane) }
        for button in actionButtons { addSubview(button) }
        needsLayout = true
    }

    var intrinsicSize: CGSize {
        let actionsWidth = CGFloat(actionButtons.count) * (Metrics.headerButtonSize.width + Metrics.headerControlsGap)
        let accessoryWidth = accessory.map { $0.fittingSize.width + Metrics.headerControlsGap } ?? 0
        // Two buttons around a 1px separator with 2px margins, 2px gaps between.
        let width = actionsWidth + accessoryWidth + Metrics.headerButtonSize.width * 2 + 5 + Metrics.headerControlsGap * 2
        return CGSize(width: width, height: Metrics.headerButtonSize.height)
    }

    func refresh() {
        if buttons.isEmpty {
            buttons = groups.map { group in
                MenuGroupButton(items: group.map { item in MenuGroupButton.Item(action: item.0, icon: item.1, label: item.2) }, pane: pane)
            }
            for button in buttons { addSubview(button) }
        } else {
            for (button, group) in zip(buttons, groups) {
                button.items = group.map { MenuGroupButton.Item(action: $0.0, icon: $0.1, label: $0.2) }
            }
        }
        separator.layer?.backgroundColor = pane.host.appearance.theme.textDim.withAlphaComponent(0.25).cgColor
        for button in buttons { button.needsDisplay = true }
        needsLayout = true
    }

    override func layout() {
        super.layout()
        var x: CGFloat = 0
        for button in actionButtons {
            place(button, CGRect(origin: CGPoint(x: x, y: 0), size: Metrics.headerButtonSize))
            x += Metrics.headerButtonSize.width + Metrics.headerControlsGap
        }
        if let accessory {
            let size = accessory.fittingSize
            accessory.frame = CGRect(x: x, y: (bounds.height - size.height) / 2, width: size.width, height: size.height)
            x += size.width + Metrics.headerControlsGap
        }
        let size = Metrics.headerButtonSize
        if buttons.count == 2 {
            place(buttons[0], CGRect(origin: CGPoint(x: x, y: 0), size: size))
            x += size.width + Metrics.headerControlsGap
            place(separator, CGRect(x: x + 2, y: 3, width: 1, height: size.height - 6))
            x += 5 + Metrics.headerControlsGap
            place(buttons[1], CGRect(origin: CGPoint(x: x, y: 0), size: size))
        }
    }

    /// While one of this row's menus is open, the row stays revealed.
    var holdOpen = false

    func setRevealed(_ revealed: Bool) {
        guard revealed != isRevealed, revealed || !holdOpen else { return }
        isRevealed = revealed
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.1
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            animator().alphaValue = revealed ? 1 : 0
        }
    }
}

/// A header button: an icon in a 23×17 box that washes on hover. One root
/// action; hovering it opens its group's menu over it (`PaneHeaderMenuGroup`).
@MainActor
final class MenuGroupButton: FlippedView, PointerHover {
    struct Item: Equatable {
        var action: HeaderAction
        var icon: ChromeIcon
        var label: String
    }

    var items: [Item] { didSet { needsDisplay = true } }
    unowned let pane: PaneView
    private var tracking: NSTrackingArea?
    private var isHovered = false

    init(items: [Item], pane: PaneView) {
        self.items = items
        self.pane = pane
        super.init(frame: .zero)
        setAccessibilityIdentifier(items.first.map { $0.action.accessibilityID } ?? "")
    }

    var theme: Theme { pane.host.appearance.theme }

    override func draw(_ dirtyRect: NSRect) {
        guard let root = items.first else { return }
        if isHovered {
            theme.hover(0.12).setFill()
            NSBezierPath(roundedRect: bounds, xRadius: 3, yRadius: 3).fill()
        }
        let icon = Metrics.headerButtonIcon
        root.icon.draw(in: drawn(CGRect(x: 5, y: 2, width: icon, height: icon)), color: theme.textDim)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) { pointerHover(at: convert(event.locationInWindow, from: nil)) }
    override func mouseExited(with event: NSEvent) { pointerHover(at: nil) }

    func pointerHover(at point: CGPoint?) {
        let hovered = point != nil
        guard hovered != isHovered else { return }
        isHovered = hovered
        needsDisplay = true
        if hovered {
            ChromeTooltip.hover(self, label: items.first?.label)
            if items.count > 1 { HeaderMenu.open(for: self) }
        } else {
            ChromeTooltip.leave(self)
        }
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {}

    override func mouseUp(with event: NSEvent) {
        guard let root = items.first, bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        pane.host.perform(root.action, on: pane.nodeID)
    }
}

/// A plugin's header action (`PaneHeaderAction`, the Electron app's
/// `HeaderControl` drawn as a `HeaderButton`): a header button like the
/// others — 23×17, a 13pt icon in the dim text color, washed on hover — that
/// performs the plugin's action, on its own pane whichever pane is active.
@MainActor
final class PaneActionButton: FlippedView, PointerHover {
    let action: PaneHeaderAction
    unowned let pane: PaneView
    private var tracking: NSTrackingArea?
    private var isHovered = false

    init(action: PaneHeaderAction, pane: PaneView) {
        self.action = action
        self.pane = pane
        super.init(frame: .zero)
        setAccessibilityIdentifier(action.id)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(action.label)
    }

    var theme: Theme { pane.host.appearance.theme }

    override func draw(_ dirtyRect: NSRect) {
        if isHovered {
            theme.hover(0.12).setFill()
            NSBezierPath(roundedRect: bounds, xRadius: 3, yRadius: 3).fill()
        }
        let icon = Metrics.headerButtonIcon
        action.icon.draw(in: drawn(CGRect(x: 5, y: 2, width: icon, height: icon)), color: theme.textDim)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) { pointerHover(at: convert(event.locationInWindow, from: nil)) }
    override func mouseExited(with event: NSEvent) { pointerHover(at: nil) }

    func pointerHover(at point: CGPoint?) {
        let hovered = point != nil
        guard hovered != isHovered else { return }
        isHovered = hovered
        needsDisplay = true
        if hovered { ChromeTooltip.hover(self, label: action.label) } else { ChromeTooltip.leave(self) }
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {}

    override func mouseUp(with event: NSEvent) {
        guard bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        action.perform()
    }

    override func accessibilityPerformPress() -> Bool {
        action.perform()
        return true
    }
}

// MARK: - Tab bars

/// A tab group's bar: grip, the tab strip, the group's controls — and, on the
/// docked root, the window's title bar (traffic-light gutter, the cup while
/// caffeinate runs, Settings button).
@MainActor
final class TabBarView: FlippedView, PointerHover {
    unowned let pane: PaneView
    let grip = GripView()
    let strip: TabStripView
    let controls: HeaderControlsView
    let settingsButton = RootIconButton(icon: .settings, label: "Settings", identifier: "settings-open-button") { _ in
        NSApp.sendAction(#selector(AppDelegate.showSettings(_:)), to: nil, from: nil)
    }
    /// Only while the managed caffeinate process runs, immediately before
    /// Settings: a press does what File ▸ Decaf does (TabBar.tsx's CaffeinateButton).
    let caffeinateButton = RootIconButton(icon: .coffeeCup, label: "Decaf", identifier: "caffeinate-decaf-button") { button in
        button.target?.host.stopCaffeinate()
    }
    private var tracking: NSTrackingArea?
    private(set) var isHovered = false

    init(pane: PaneView) {
        self.pane = pane
        strip = TabStripView(pane: pane)
        controls = HeaderControlsView(pane: pane)
        super.init(frame: .zero)
        for view in [grip, strip, controls, caffeinateButton, settingsButton] as [NSView] { addSubview(view) }
        settingsButton.target = pane
        caffeinateButton.target = pane
    }

    var group: TabGroup? { pane.node.group }
    var theme: Theme { pane.host.appearance.theme }
    /// The bar's own height (its view reaches a row further).
    var barHeight: CGFloat { layoutSize.height - 1 }

    override func layout() {
        super.layout()
        let height = barHeight
        let isRoot = pane.isDockedRoot
        var x: CGFloat
        if isRoot {
            grip.isHidden = true
            x = pane.host.isFullScreen ? Metrics.depthIndent(pane.depth) : Metrics.trafficLightGutter
        } else {
            grip.isHidden = false
            place(grip, grip.layoutRect(at: Metrics.depthIndent(pane.depth), centeredIn: height))
            x = Metrics.depthIndent(pane.depth) + grip.glyphWidth + Metrics.barGap
        }
        var right = layoutSize.width - Metrics.barPaddingRight
        settingsButton.isHidden = !isRoot
        caffeinateButton.isHidden = !(isRoot && pane.host.appearance.caffeinateRunning)
        // Right to left: Settings, then the cup before it; each with its margin and the bar's gap.
        for button in [settingsButton, caffeinateButton] where !button.isHidden {
            let size = Metrics.rootIconButtonSize
            right -= Metrics.rootIconButtonMarginRight
            place(button, CGRect(x: right - size.width, y: (height - size.height) / 2, width: size.width, height: size.height))
            right -= size.width + Metrics.barGap
        }
        let controlsSize = controls.intrinsicSize
        place(
            controls,
            CGRect(
                x: right - controlsSize.width, y: (height - controlsSize.height) / 2, width: controlsSize.width, height: controlsSize.height
            ))
        right -= controlsSize.width + Metrics.barGap
        // The strip sits on the bar's bottom edge and reaches one row past it.
        place(strip, CGRect(x: x, y: height - Metrics.tabStripHeight + 1, width: max(right - x, 0), height: Metrics.tabStripHeight))
    }

    override func draw(_ dirtyRect: NSRect) {
        theme.surface(depth: pane.depth).setFill()
        painted(CGRect(x: 0, y: 0, width: layoutSize.width, height: barHeight)).fill()
    }

    func refresh() {
        needsDisplay = true
        grip.color = theme.textDim
        strip.refresh()
        controls.refresh()
        for button in [settingsButton, caffeinateButton] {
            button.color = theme.textDim
            button.hoverColor = theme.text
        }
        needsLayout = true
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) { pointerHover(at: convert(event.locationInWindow, from: nil)) }
    override func mouseExited(with event: NSEvent) { pointerHover(at: nil) }

    func pointerHover(at point: CGPoint?) {
        isHovered = point != nil
        controls.setRevealed(isHovered)
        strip.setRevealed(isHovered)
    }

    /// Only the bar's own rows: the overhang row below belongs to the content.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        guard local.y < bounds.height - 1 || strip.frame.contains(local) else { return nil }
        let hit = super.hitTest(point)
        if hit === strip, !strip.isOverTab(convert(local, to: strip)) { return self }
        return hit
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    override func mouseDown(with event: NSEvent) {
        if pane.isDockedRoot {
            if event.clickCount == 2 {
                window?.performZoomIfAllowed()
                return
            }
            pane.host.dragWindow(with: event)
            pane.host.activate(pane.nodeID)
            return
        }
        pane.host.chromeMouseDown(event, on: pane.nodeID, in: self)
    }

    override func rightMouseDown(with event: NSEvent) {
        pane.host.chromeMenu(event, for: pane.nodeID, tab: nil, group: pane.nodeID, in: self)
    }
}

/// The docked root bar's own buttons (the cup, Settings): dimmed at rest, a
/// 15px icon (`.tab-bar-icon-button`).
@MainActor
final class RootIconButton: FlippedView, PointerHover {
    let icon: ChromeIcon
    /// Its tooltip and accessibility label.
    let label: String
    var color: NSColor = .gray { didSet { needsDisplay = true } }
    var hoverColor: NSColor = .white
    weak var target: PaneView?
    private let press: @MainActor (RootIconButton) -> Void
    private var tracking: NSTrackingArea?
    private var isHovered = false

    init(icon: ChromeIcon, label: String, identifier: String, press: @escaping @MainActor (RootIconButton) -> Void) {
        self.icon = icon
        self.label = label
        self.press = press
        super.init(frame: .zero)
        setAccessibilityIdentifier(identifier)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(label)
    }

    override func draw(_ dirtyRect: NSRect) {
        if isHovered {
            (target?.host.appearance.theme.hover(0.12) ?? .clear).setFill()
            NSBezierPath(roundedRect: bounds, xRadius: 3, yRadius: 3).fill()
        }
        icon.draw(in: drawn(CGRect(x: 4, y: 4, width: 15, height: 15)), color: isHovered ? hoverColor : color)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) { pointerHover(at: convert(event.locationInWindow, from: nil)) }
    override func mouseExited(with event: NSEvent) { pointerHover(at: nil) }

    func pointerHover(at point: CGPoint?) {
        isHovered = point != nil
        needsDisplay = true
        if isHovered { ChromeTooltip.hover(self, label: label) } else { ChromeTooltip.leave(self) }
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    override func mouseDown(with event: NSEvent) {}

    override func mouseUp(with event: NSEvent) {
        guard bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        press(self)
    }

    override func accessibilityPerformPress() -> Bool {
        press(self)
        return true
    }
}

extension NSWindow {
    /// A double-click on the title bar: what the user set in System Settings.
    func performZoomIfAllowed() {
        switch UserDefaults.standard.string(forKey: "AppleActionOnDoubleClick") {
        case "Minimize": performMiniaturize(nil)
        case "None": break
        default: performZoom(nil)
        }
    }
}
