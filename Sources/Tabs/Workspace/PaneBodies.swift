import AppKit
import TabsCore
import TabsPluginSDK

/// A leaf's content area: the body core says it has (`LayoutEngine.body(of:)`)
/// — a plugin's view, the empty pane's creation buttons, or why a pane is
/// unavailable. It lives as long as the leaf is in the layout — across tab
/// switches, fills, moves and windows — so a plugin's view does too; its
/// content is built only once the pane is first on screen.
@MainActor
final class PaneBodyHost: FlippedView {
    let paneID: PaneID
    private(set) var body: PaneBody = .empty
    /// Which body is showing, so an unchanged one isn't rebuilt.
    private(set) var bodyKey: String?
    private(set) var contentType: ContentTypeID?
    private(set) var content: NSView?
    /// The plugin's header accessory and header actions, once its view is built.
    private(set) var accessory: NSView?
    /// The plugin's header title, which replaces the pane's own.
    private(set) var headerTitle: NSView?
    private(set) var actions: [PaneHeaderAction] = []
    private var pending: (@MainActor () -> Content)?

    /// What a body shows: its view, and what it adds to the pane's header.
    struct Content {
        var view: NSView
        var accessory: NSView? = nil
        var headerTitle: NSView? = nil
        var actions: [PaneHeaderAction] = []
    }
    /// Whether the pane is on screen (every tab above it active).
    private(set) var isShown = false
    /// How this pane's content is dimmed while inactive, or nil.
    private var dim: (grayscale: Double, brightness: Double)?

    init(paneID: PaneID) {
        self.paneID = paneID
        super.init(frame: .zero)
        setAccessibilityIdentifier("body-\(paneID)")
    }

    var live: LivePane? { if case .live(let pane) = body { pane } else { nil } }

    /// Shows `body` unless it is already showing (same `key`); its view is
    /// built — for a live pane, asked of the plugin — once the pane is shown.
    func show(
        _ body: PaneBody, key: String, contentType: ContentTypeID?,
        content build: @escaping @MainActor () -> Content
    ) {
        guard key != bodyKey else { return }
        bodyKey = key
        self.body = body
        self.contentType = contentType
        content?.removeFromSuperview()
        content = nil
        accessory = nil
        headerTitle = nil
        actions = []
        pending = build
        if isShown { installContent() }
    }

    /// Forgets which body is showing, so the next `show` rebuilds it.
    func invalidateBody() { bodyKey = nil }

    func setShown(_ shown: Bool) {
        guard shown != isShown else { return }
        isShown = shown
        if shown { installContent() }
    }

    override func layout() {
        super.layout()
        for view in subviews {
            if let child = view as? FlippedView { place(child, layoutBounds) } else { view.frame = bounds }
        }
    }

    private func installContent() {
        guard let build = pending else { return }
        pending = nil
        let built = build()
        let view = built.view
        view.frame = bounds
        view.autoresizingMask = [.width, .height]
        addSubview(view)
        needsLayout = true
        content = view
        accessory = built.accessory
        headerTitle = built.headerTitle
        actions = built.actions
        applyDim()
    }

    /// Dims an inactive pane's content: an empty pane recolors itself;
    /// anything else gets the same filter as a Core Image color matrix.
    func setDim(_ dim: (grayscale: Double, brightness: Double)?) {
        guard dim?.grayscale != self.dim?.grayscale || dim?.brightness != self.dim?.brightness else { return }
        self.dim = dim
        applyDim()
    }

    private func applyDim() {
        if let empty = content as? EmptyPaneView {
            empty.dim = dim
            return
        }
        guard let content else { return }
        content.wantsLayer = true
        guard let dim else {
            content.layer?.filters = nil
            return
        }
        layerUsesCoreImageFilters = true
        let k = 1 - dim.grayscale
        let b = dim.brightness
        let filter = CIFilter(name: "CIColorMatrix")
        filter?.setValue(
            CIVector(x: (0.2126 + 0.7874 * k) * b, y: (0.7152 - 0.7152 * k) * b, z: (0.0722 - 0.0722 * k) * b, w: 0), forKey: "inputRVector"
        )
        filter?.setValue(
            CIVector(x: (0.2126 - 0.2126 * k) * b, y: (0.7152 + 0.2848 * k) * b, z: (0.0722 - 0.0722 * k) * b, w: 0), forKey: "inputGVector"
        )
        filter?.setValue(
            CIVector(x: (0.2126 - 0.2126 * k) * b, y: (0.7152 - 0.7152 * k) * b, z: (0.0722 + 0.9278 * k) * b, w: 0), forKey: "inputBVector"
        )
        content.layer?.filters = filter.map { [$0] }
    }

    func focusContent() {
        if let live {
            live.controller.focus()
        } else {
            window?.makeFirstResponder(content ?? self)
        }
    }

    override var acceptsFirstResponder: Bool { live == nil }
}

/// An empty pane: one square button per content type the user may create,
/// joined into a single segmented control, centered.
@MainActor
final class EmptyPaneView: FlippedView, PointerHover, NSViewToolTipOwner {
    struct Action {
        var type: ContentTypeID
        /// The button's tooltip and label ("New terminal").
        var label: String
        /// The type's plain name ("Terminal"), which the palette lists.
        var displayName: String
        var icon: Icon
    }

    enum Icon {
        case symbol(String)
        /// A template image a plugin drew (only its alpha counts).
        case image(NSImage)
        /// Text standing in for an icon (the visual capture's stub type).
        case glyph(String)

        init(_ icon: PaneIcon) {
            switch icon {
            case .symbol(let name): self = .symbol(name)
            case .image(let image): self = .image(image)
            }
        }
    }

    let paneID: PaneID
    var actions: [Action] {
        didSet {
            needsDisplay = true
            needsLayout = true
        }
    }
    var theme: Theme { didSet { needsDisplay = true } }
    var dim: (grayscale: Double, brightness: Double)? { didSet { needsDisplay = true } }
    /// A drag hovering with this pane as its drop target.
    var isDropTarget = false { didSet { needsDisplay = oldValue != isDropTarget } }
    private let create: @MainActor (ContentTypeID) -> Void
    private var hovered: Int?
    private var pressed: Int?
    private var tracking: NSTrackingArea?

    static let message = NoContentTypes.message

    init(paneID: PaneID, actions: [Action], theme: Theme, create: @escaping @MainActor (ContentTypeID) -> Void) {
        self.paneID = paneID
        self.actions = actions
        self.theme = theme
        self.create = create
        super.init(frame: .zero)
        setAccessibilityIdentifier("empty-\(paneID)")
    }

    private func color(_ color: NSColor) -> NSColor {
        guard let dim else { return color }
        return color.dimmed(grayscale: dim.grayscale, brightness: dim.brightness)
    }

    /// The toolbar's buttons: 32×32, sharing one hairline between neighbours.
    var buttonLayoutRects: [CGRect] {
        let size = Metrics.emptyButtonSize
        let width = size * CGFloat(actions.count) - CGFloat(max(actions.count - 1, 0))
        let x = (layoutSize.width - width) / 2
        let y = (layoutSize.height - size) / 2
        return actions.indices.map { CGRect(x: x + CGFloat($0) * (size - 1), y: y, width: size, height: size) }
    }

    /// The buttons as painted (drawing coordinates).
    var buttonRects: [CGRect] { buttonLayoutRects.map(painted) }

    /// A tool tip over each button.
    override func layout() {
        super.layout()
        removeAllToolTips()
        for rect in buttonRects { addToolTip(rect, owner: self, userData: nil) }
    }

    /// The tool tip of the button under `point`: its label.
    func view(_ view: NSView, stringForToolTip tag: NSView.ToolTipTag, point: NSPoint, userData data: UnsafeMutableRawPointer?) -> String {
        buttonRects.firstIndex { $0.contains(point) }.map { actions[$0].label } ?? ""
    }

    override func draw(_ dirtyRect: NSRect) {
        if isDropTarget {
            color(theme.accent.mixedWithTransparent(0.08)).setFill()
            bounds.fill()
            // A 2pt dashed outline, 6 to 8pt inside the pane's edge.
            Self.dashedOutline(painted(layoutBounds).insetBy(dx: 6, dy: 6), thickness: 2, color: color(theme.accent))
        }
        guard !actions.isEmpty else {
            let text = ChromeText(size: 13)
            let width = min(text.width(Self.message), bounds.width - 48)
            text.draw(
                Self.message, at: CGPoint(x: (bounds.width - width) / 2, y: text.baseline(centeredIn: bounds.height)),
                color: color(theme.textDim),
                maxWidth: width)
            return
        }
        let rects = buttonRects
        let radius = Metrics.emptyButtonRadius
        // Hovered last, so its accent border isn't broken by a neighbour's.
        let order = rects.indices.filter { $0 != hovered } + (hovered.map { [$0] } ?? [])
        for index in order {
            let rect = rects[index]
            let isFirst = index == 0
            let isLast = index == rects.count - 1
            let shape = Self.segment(rect, left: isFirst ? radius : 0, right: isLast ? radius : 0)
            let isHovered = index == hovered
            let fill = isHovered ? theme.accent.mixed(0.12, with: theme.bgElevated) : theme.bgElevated
            let stroke = isHovered ? theme.accent : theme.border
            color(stroke).setFill()
            shape.fill()
            color(fill).setFill()
            Self.segment(rect.insetBy(dx: 1, dy: 1), left: max((isFirst ? radius : 0) - 1, 0), right: max((isLast ? radius : 0) - 1, 0))
                .fill()
            let iconColor = color(isHovered ? theme.text : theme.textDim)
            switch actions[index].icon {
            case .symbol(let name):
                if let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
                    .withSymbolConfiguration(.init(pointSize: 13, weight: .regular).applying(.init(paletteColors: [iconColor])))
                {
                    let size = image.size
                    image.draw(
                        in: CGRect(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2, width: size.width, height: size.height),
                        from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
                }
            case .image(let template):
                // A 16×16 box, centered, tinted like the symbols.
                let box = CGRect(x: rect.midX - 8, y: rect.midY - 8, width: 16, height: 16)
                Self.tinted(template, color: iconColor).draw(
                    in: box, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            case .glyph(let glyph):
                let text = ChromeText(size: 13.333)
                let width = text.width(glyph)
                text.draw(
                    glyph, at: CGPoint(x: rect.midX - width / 2, y: text.baseline(centeredIn: rect.height - 2, top: rect.minY + 1)),
                    color: iconColor)
            }
        }
    }

    /// `template` filled with `color` (its alpha is the shape), at any scale.
    static func tinted(_ template: NSImage, color: NSColor) -> NSImage {
        NSImage(size: template.size, flipped: false) { rect in
            template.draw(in: rect)
            color.setFill()
            rect.fill(using: .sourceIn)
            return true
        }
    }

    /// A dashed box: each side on its own, dashes of 3× the thickness, the
    /// gaps (about 2×) stretched so every side starts and ends on a dash —
    /// which puts an L on every corner.
    static func dashedOutline(_ outer: CGRect, thickness: CGFloat, color: NSColor) {
        color.setStroke()
        let half = thickness / 2
        let sides: [(CGPoint, CGPoint)] = [
            (CGPoint(x: outer.minX, y: outer.minY + half), CGPoint(x: outer.maxX, y: outer.minY + half)),
            (CGPoint(x: outer.maxX - half, y: outer.minY), CGPoint(x: outer.maxX - half, y: outer.maxY)),
            (CGPoint(x: outer.minX, y: outer.maxY - half), CGPoint(x: outer.maxX, y: outer.maxY - half)),
            (CGPoint(x: outer.minX + half, y: outer.minY), CGPoint(x: outer.minX + half, y: outer.maxY)),
        ]
        let dash = thickness * (thickness >= 3 ? 2 : 3)
        let preferredGap = thickness * (thickness >= 3 ? 1 : 2)
        for (start, end) in sides {
            let length = hypot(end.x - start.x, end.y - start.y)
            let path = NSBezierPath()
            path.move(to: start)
            path.line(to: end)
            path.lineWidth = thickness
            if length > dash * 2 {
                let fewer = ((length + preferredGap) / (dash + preferredGap)).rounded(.down)
                let smallGap = (length - fewer * dash) / (fewer - 1)
                let bigGap = (length - (fewer + 1) * dash) / fewer
                let gap = bigGap <= 0 || abs(smallGap - preferredGap) < abs(bigGap - preferredGap) ? smallGap : bigGap
                path.setLineDash([dash, gap], count: 2, phase: 0)
            }
            path.stroke()
        }
    }

    /// A button's shape: square, but for the toolbar's outer corners.
    static func segment(_ rect: CGRect, left: CGFloat, right: CGFloat) -> NSBezierPath {
        let path = NSBezierPath()
        path.move(to: CGPoint(x: rect.minX + left, y: rect.minY))
        path.line(to: CGPoint(x: rect.maxX - right, y: rect.minY))
        if right > 0 {
            path.appendArc(from: CGPoint(x: rect.maxX, y: rect.minY), to: CGPoint(x: rect.maxX, y: rect.minY + right), radius: right)
        }
        path.line(to: CGPoint(x: rect.maxX, y: rect.maxY - right))
        if right > 0 {
            path.appendArc(from: CGPoint(x: rect.maxX, y: rect.maxY), to: CGPoint(x: rect.maxX - right, y: rect.maxY), radius: right)
        }
        path.line(to: CGPoint(x: rect.minX + left, y: rect.maxY))
        if left > 0 {
            path.appendArc(from: CGPoint(x: rect.minX, y: rect.maxY), to: CGPoint(x: rect.minX, y: rect.maxY - left), radius: left)
        }
        path.line(to: CGPoint(x: rect.minX, y: rect.minY + left))
        if left > 0 {
            path.appendArc(from: CGPoint(x: rect.minX, y: rect.minY), to: CGPoint(x: rect.minX + left, y: rect.minY), radius: left)
        }
        path.close()
        return path
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(area)
        tracking = area
    }

    private func index(at event: NSEvent) -> Int? {
        let point = convert(event.locationInWindow, from: nil)
        return buttonRects.firstIndex { $0.contains(point) }
    }

    override func mouseMoved(with event: NSEvent) { setHovered(index(at: event)) }
    override func mouseEntered(with event: NSEvent) { setHovered(index(at: event)) }
    override func mouseExited(with event: NSEvent) { setHovered(nil) }

    func pointerHover(at point: CGPoint?) {
        setHovered(point.flatMap { point in buttonRects.firstIndex { $0.contains(point) } })
    }

    private func setHovered(_ index: Int?) {
        guard index != hovered else { return }
        hovered = index
        needsDisplay = true
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var acceptsFirstResponder: Bool { true }

    override func mouseDown(with event: NSEvent) {
        pressed = index(at: event)
    }

    override func mouseUp(with event: NSEvent) {
        defer { pressed = nil }
        guard let pressed, pressed == index(at: event), actions.indices.contains(pressed) else { return }
        create(actions[pressed].type)
    }
}

/// A restored pane whose content type no active plugin provides. It keeps the
/// saved leaf verbatim, so the pane comes back when the plugin does.
@MainActor
final class UnavailablePaneView: FlippedView {
    let type: ContentTypeID?
    let reason: String
    var theme: Theme = .dark { didSet { needsDisplay = true } }

    init(type: ContentTypeID?, reason: String) {
        self.type = type
        self.reason = reason
        super.init(frame: .zero)
    }

    override func draw(_ dirtyRect: NSRect) {
        let heading = ChromeText(size: 13, weight: .semibold)
        let detail = ChromeText(size: 12)
        let title = "“\(type?.rawValue ?? "?")” content is unavailable"
        let lines = [reason, "The pane's saved state is kept and comes back when the plugin does."]
        var y = bounds.midY - 30
        let titleWidth = min(heading.width(title), bounds.width - 48)
        heading.draw(title, at: CGPoint(x: (bounds.width - titleWidth) / 2, y: y), color: theme.text, maxWidth: titleWidth)
        for line in lines {
            y += 20
            let width = min(detail.width(line), bounds.width - 48)
            detail.draw(line, at: CGPoint(x: (bounds.width - width) / 2, y: y), color: theme.textDim, maxWidth: width)
        }
    }
}
