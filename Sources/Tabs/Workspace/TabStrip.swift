import AppKit
import TabsCore
import TabsPluginSDK

/// A bar's tabs, left to right at their natural widths (capped), then the
/// "+" button. Sits on the bar's bottom edge and reaches one row below it, so
/// the active tab covers the hairline there and opens onto its content.
/// Clips its tabs and scrolls sideways when they overflow.
@MainActor
final class TabStripView: FlippedView {
    unowned let pane: PaneView
    private var tabViews: [NodeID: TabView] = [:]
    private(set) var orderedTabs: [TabView] = []
    let newTabButton = NewTabButton()
    private let dropIndicator = FlippedView()
    /// How far the tabs are scrolled left.
    private(set) var scrollOffset: CGFloat = 0
    private var isRevealed = false

    init(pane: PaneView) {
        self.pane = pane
        super.init(frame: .zero)
        layer?.masksToBounds = true
        addSubview(newTabButton)
        addSubview(dropIndicator)
        dropIndicator.isHidden = true
        newTabButton.alphaValue = 0
        newTabButton.onPress = { [unowned self] in self.pane.host.newTab(in: self.pane.nodeID) }
        setAccessibilityIdentifier("tab-strip-\(pane.nodeID)")
    }

    var group: TabGroup? { pane.node.group }
    var theme: Theme { pane.host.appearance.theme }

    func refresh() {
        guard let group else { return }
        var next: [NodeID: TabView] = [:]
        orderedTabs = group.tabs.map { tab in
            let view = tabViews[tab.id] ?? TabView(strip: self, tabID: tab.id)
            if view.superview !== self { addSubview(view, positioned: .below, relativeTo: newTabButton) }
            view.tab = tab
            view.isActive = tab.id == group.activeTabID
            view.setSignals(pane.host.tabSignals(tab.content))
            view.needsDisplay = true
            next[tab.id] = view
            return view
        }
        for (id, view) in tabViews where next[id] == nil { view.removeFromSuperview() }
        tabViews = next
        // The active tab draws over its neighbours' edges (it's the one raised).
        if let active = orderedTabs.first(where: \.isActive) { addSubview(active, positioned: .below, relativeTo: newTabButton) }
        dropIndicator.layer?.backgroundColor = theme.accent.cgColor
        newTabButton.color = theme.textDim
        newTabButton.hoverColor = theme.text
        newTabButton.theme = theme
        needsLayout = true
    }

    /// The signals of the panes the tabs hold changed (a tab may grow or shrink).
    func refreshSignals() {
        guard let group else { return }
        for tab in group.tabs { tabViews[tab.id]?.setSignals(pane.host.tabSignals(tab.content)) }
        needsLayout = true
    }

    /// Where the drop indicator goes: before the tab at this index of the
    /// bar's own list (the dragged tab counts too).
    var dropIndex: Int? {
        if case .tabBar(let groupID, let index)? = pane.host.dragVisuals.target, groupID == pane.nodeID { return index }
        return nil
    }

    /// The width of everything laid out, scrolled or not.
    private(set) var contentWidth: CGFloat = 0

    override func layout() {
        super.layout()
        let height = layoutSize.height
        var x = -scrollOffset
        let dropIndex = dropIndex
        dropIndicator.isHidden = dropIndex == nil
        for (index, view) in orderedTabs.enumerated() {
            if index == dropIndex {
                placeDropIndicator(at: x)
                x += Metrics.dropIndicatorSize.width + Metrics.tabGap
            }
            let width = view.naturalWidth
            place(view, CGRect(x: x, y: 0, width: width, height: height))
            x += width + Metrics.tabGap
        }
        if dropIndex == orderedTabs.count {
            placeDropIndicator(at: x)
            x += Metrics.dropIndicatorSize.width + Metrics.tabGap
        }
        let size = Metrics.newTabButtonSize
        place(newTabButton, CGRect(x: x, y: (height - size.height) / 2, width: size.width, height: size.height))
        contentWidth = x + size.width + scrollOffset
    }

    /// The drop indicator's layout rect (content coordinates) while it shows.
    var dropIndicatorFrame: CGRect? { dropIndicator.isHidden ? nil : dropIndicator.layoutFrame }

    private func placeDropIndicator(at x: CGFloat) {
        let size = Metrics.dropIndicatorSize
        place(dropIndicator, CGRect(x: x, y: (layoutSize.height - size.height) / 2, width: size.width, height: size.height))
    }

    func setRevealed(_ revealed: Bool) {
        guard revealed != isRevealed else { return }
        isRevealed = revealed
        ChromeFade.fade(newTabButton, to: revealed ? 1 : 0)
    }

    func isOverTab(_ point: CGPoint) -> Bool {
        orderedTabs.contains { $0.frame.contains(point) && $0.hitTest(convert(point, to: $0.superview)) != nil }
            || newTabButton.frame.contains(point)
    }

    func tabView(_ id: NodeID) -> TabView? { tabViews[id] }

    override func scrollWheel(with event: NSEvent) {
        let delta = abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) ? event.scrollingDeltaX : event.scrollingDeltaY
        let maximum = max(contentWidth - bounds.width, 0)
        let next = min(max(scrollOffset - delta, 0), maximum)
        guard next != scrollOffset else { return super.scrollWheel(with: event) }
        scrollOffset = next
        needsLayout = true
        pane.host.chromeDidScroll()
    }
}

/// One tab: the signals of the panes it holds, its title (ellipsized) and a
/// close button revealed on hover. The active tab is painted in the shade of
/// the level it reveals, framed on three sides, and covers the seam into its
/// content.
@MainActor
final class TabView: FlippedView, PointerHover, NSViewToolTipOwner {
    unowned let strip: TabStripView
    let tabID: NodeID
    var tab: Tab?
    var isActive = false
    private var isHovered = false
    private var isCloseHovered = false
    private var tracking: NSTrackingArea?
    private var pressedClose = false
    /// While the title is being edited, its editor.
    var editor: NSView?
    /// The signals of the panes it holds, before the title.
    private var signalRow = SignalIconRow()
    var signalIcons: [SignalIconView] { signalRow.icons }

    static let text = ChromeText(size: Metrics.chromeFontSize)
    /// The close glyph: "×" in 12pt Arial.
    static let closeFont = NSFont(name: "Arial", size: Metrics.tabCloseFontSize) ?? .systemFont(ofSize: Metrics.tabCloseFontSize)
    static let closeGlyphWidth: CGFloat = {
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: "×", attributes: [.font: closeFont]))
        return CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
    }()
    static var closeWidth: CGFloat { closeGlyphWidth + Metrics.tabCloseHorizontalPadding * 2 }
    /// Borders, paddings, the gap and the close button: a tab minus its title.
    static var chromeWidth: CGFloat { 1 + Metrics.tabPaddingLeft + Metrics.tabInnerGap + closeWidth + Metrics.tabPaddingRight + 1 }

    init(strip: TabStripView, tabID: NodeID) {
        self.strip = strip
        self.tabID = tabID
        super.init(frame: .zero)
        setAccessibilityIdentifier("tab-\(tabID)")
    }

    var host: any ChromeHost { strip.pane.host }
    var theme: Theme { host.appearance.theme }
    var depth: Int { strip.pane.depth }
    var title: String { tab?.title ?? "" }

    /// From the tab's left border to its title: the padding, or — while it
    /// shows signals — 2pt, then each 16pt icon and the tab's 2pt gap.
    var leadingWidth: CGFloat {
        signalIcons.isEmpty
            ? Metrics.tabPaddingLeft
            : SignalStyle.tabPaddingLeft + CGFloat(signalIcons.count) * (SignalStyle.iconSize + SignalStyle.tabGap)
    }

    /// Everything but the title.
    var fixedWidth: CGFloat { Self.chromeWidth - Metrics.tabPaddingLeft + leadingWidth }

    var naturalWidth: CGFloat { min(fixedWidth + Self.text.width(title), Metrics.tabMaxWidth) }

    /// The tab's own box inside its strip-tall view, as laid out.
    var layoutBox: CGRect {
        let top = isActive ? Metrics.tabActiveMarginTop : Metrics.tabMarginTop
        return CGRect(x: 0, y: top, width: layoutSize.width, height: layoutSize.height - top)
    }

    /// The box as painted (drawing coordinates).
    var boxRect: CGRect { painted(layoutBox) }

    var titleRect: CGRect {
        drawn(
            CGRect(
                x: 1 + leadingWidth, y: Metrics.tabMarginTop, width: max(layoutSize.width - fixedWidth, 0),
                height: layoutSize.height - Metrics.tabMarginTop))
    }

    /// Each icon's box (layout coordinates), centered in the tab's content.
    private func iconLayoutRect(_ index: Int) -> CGRect {
        let size = SignalStyle.iconSize
        let contentHeight = layoutSize.height - Metrics.tabMarginTop
        return CGRect(
            x: 1 + SignalStyle.tabPaddingLeft + CGFloat(index) * (size + SignalStyle.tabGap),
            y: Metrics.tabMarginTop + (contentHeight - size) / 2, width: size, height: size)
    }

    /// Shows the signals of the panes the tab holds; the title moves over for
    /// their icons.
    func setSignals(_ shown: [ShownSignal]) {
        if signalRow.show(shown, in: self, theme: theme, placement: "tab") {
            needsLayout = true
            needsDisplay = true
        }
        // A dragged tab dims as a whole.
        for icon in signalIcons { icon.alphaValue = isDragSource ? 0.4 : 1 }
    }

    override func layout() {
        super.layout()
        for (index, icon) in signalIcons.enumerated() { place(icon, iconLayoutRect(index)) }
        // After the signals': installing theirs removes the view's others.
        signalRow.installTooltips(in: self)
        addToolTip(closeRect, owner: self, userData: nil)
    }

    /// The close button's tool tip, asked for as it shows: a renamed tab's is current.
    func view(_ view: NSView, stringForToolTip tag: NSView.ToolTipTag, point: NSPoint, userData data: UnsafeMutableRawPointer?) -> String {
        "Close \(title)"
    }

    var closeRect: CGRect {
        let height = Metrics.tabCloseFontSize + Metrics.tabCloseVerticalPadding * 2
        let contentTop = Metrics.tabMarginTop
        let contentHeight = layoutSize.height - contentTop
        return drawn(
            CGRect(
                x: layoutSize.width - 1 - Metrics.tabPaddingRight - Self.closeWidth, y: contentTop + (contentHeight - height) / 2,
                width: Self.closeWidth, height: height))
    }

    var isDragSource: Bool { host.dragVisuals.sourceTab == tabID }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        if isDragSource { context.setAlpha(0.4) }
        context.beginTransparencyLayer(auxiliaryInfo: nil)
        defer { context.endTransparencyLayer() }
        let box = boxRect
        let radius = Metrics.tabCornerRadius
        if isActive {
            let shape = Self.topRoundedRect(box, radius: radius)
            // A soft shadow cast downward (7pt down, a 10pt blur), clipped by the strip.
            //
            // Not `setShadow`'s own offset: that is in a space whose y runs up the screen in some of
            // the contexts this view is drawn in and down it in others (a window's, a layer render's;
            // the transform's sign doesn't say which), so a positive offset cast the shadow up over the
            // tab's top edge in the app and down in the capture. Instead the shadow has no offset at
            // all and is cast by a copy of the tab moved 7pt down in this view's own coordinates,
            // which is down wherever it is drawn. The copy's body is never seen: it is clipped to
            // everything but the tab itself, which is painted over it anyway, so only the blur
            // outside the tab shows.
            context.saveGState()
            let outside = NSBezierPath(rect: box.insetBy(dx: -4 * Metrics.tabMaxWidth, dy: -4 * Metrics.tabMaxWidth))
            outside.append(shape)
            outside.windingRule = .evenOdd
            outside.addClip()
            let scale = abs(context.userSpaceToDeviceSpaceTransform.d)
            context.setShadow(offset: .zero, blur: 10 * scale, color: theme.shadow(0.45).cgColor)
            context.translateBy(x: 0, y: 7)
            NSColor.black.setFill()
            shape.fill()
            context.restoreGState()
            theme.surfaceNext(depth: depth).setFill()
            shape.fill()
            // Top, left and right borders; the bottom opens onto the content.
            theme.border.setFill()
            let frame = Self.topRoundedRect(box, radius: radius)
            let inner = Self.topRoundedRect(
                CGRect(x: box.minX + 1, y: box.minY + 1, width: box.width - 2, height: box.height - 1), radius: max(radius - 1, 0))
            frame.append(inner.reversed)
            frame.fill()
        } else if isHovered {
            theme.hover(0.05).setFill()
            Self.topRoundedRect(box, radius: radius).fill()
        }
        let color = isActive ? theme.text : theme.textDim
        if editor == nil {
            let title = titleRect
            // The title sits a point above its line box's center.
            Self.text.draw(
                self.title, at: CGPoint(x: title.minX, y: Self.text.baseline(centeredIn: title.height, top: title.minY) - 1), color: color,
                maxWidth: title.width)
        }
        if isHovered {
            let close = closeRect
            if isCloseHovered {
                theme.hover(0.12).setFill()
                NSBezierPath(roundedRect: close.snapped, xRadius: 4, yRadius: 4).fill()
            }
            // A 12pt line box around the font: the half-leading is negative.
            let ascent = CGFloat(CTFontGetAscent(Self.closeFont).rounded())
            let descent = CGFloat(CTFontGetDescent(Self.closeFont).rounded())
            let baseline = close.minY + Metrics.tabCloseVerticalPadding + (Metrics.tabCloseFontSize - ascent - descent) / 2 + ascent
            let line = CTLineCreateWithAttributedString(
                NSAttributedString(string: "×", attributes: [.font: Self.closeFont, .foregroundColor: color]))
            context.saveGState()
            context.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
            context.textPosition = CGPoint(x: close.minX + Metrics.tabCloseHorizontalPadding, y: baseline)
            CTLineDraw(line, context)
            context.restoreGState()
        }
    }

    /// A rect with its top corners rounded (flipped coordinates).
    static func topRoundedRect(_ rect: CGRect, radius: CGFloat) -> NSBezierPath {
        let path = NSBezierPath()
        path.move(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.line(to: CGPoint(x: rect.minX, y: rect.minY + radius))
        path.appendArc(
            withCenter: CGPoint(x: rect.minX + radius, y: rect.minY + radius), radius: radius, startAngle: 180, endAngle: 270,
            clockwise: false)
        path.line(to: CGPoint(x: rect.maxX - radius, y: rect.minY))
        path.appendArc(
            withCenter: CGPoint(x: rect.maxX - radius, y: rect.minY + radius), radius: radius, startAngle: 270, endAngle: 360,
            clockwise: false)
        path.line(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.close()
        return path
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        return boxRect.contains(local) ? self : nil
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(
            rect: .zero, options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) { pointerHover(at: convert(event.locationInWindow, from: nil)) }
    override func mouseMoved(with event: NSEvent) { pointerHover(at: convert(event.locationInWindow, from: nil)) }
    override func mouseExited(with event: NSEvent) { pointerHover(at: nil) }

    func pointerHover(at point: CGPoint?) {
        let hovered = point.map { boxRect.contains($0) } ?? false
        let closeHovered = hovered && point.map { closeRect.contains($0) } == true
        guard hovered != isHovered || closeHovered != isCloseHovered else { return }
        isHovered = hovered
        isCloseHovered = closeHovered
        needsDisplay = true
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    override func mouseDown(with event: NSEvent) {
        guard editor == nil, let group = strip.group else { return }
        let point = convert(event.locationInWindow, from: nil)
        if closeRect.contains(point) {
            pressedClose = true
            return
        }
        if event.clickCount == 2, titleRect.contains(point) {
            host.rename(tab: tabID, pane: nil, from: self)
            return
        }
        host.tabMouseDown(event, tab: tabID, group: group.id, in: self)
    }

    override func mouseUp(with event: NSEvent) {
        defer { pressedClose = false }
        guard pressedClose, closeRect.contains(convert(event.locationInWindow, from: nil)) else { return }
        host.closeTab(tabID)
    }

    override func rightMouseDown(with event: NSEvent) {
        guard editor == nil, let group = strip.group else { return }
        host.chromeMenu(event, for: tab?.content.id ?? tabID, tab: tabID, group: group.id, in: self)
    }
}

/// The "+" after the last tab: a new tab in this group. Revealed with the bar's other controls.
@MainActor
final class NewTabButton: FlippedView, PointerHover {
    var color: NSColor = .gray { didSet { needsDisplay = true } }
    var hoverColor: NSColor = .white
    var theme: Theme = .dark
    var onPress: (() -> Void)?
    private var tracking: NSTrackingArea?
    private var isHovered = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityIdentifier("tab-strip-new-tab-button")
        toolTip = "New tab"
    }

    override func draw(_ dirtyRect: NSRect) {
        if isHovered {
            theme.hover(0.12).setFill()
            NSBezierPath(roundedRect: bounds, xRadius: 3, yRadius: 3).fill()
        }
        ChromeIcon.plus.draw(in: drawn(CGRect(x: 5, y: 2, width: 10, height: 10)), color: isHovered ? hoverColor : color)
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
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    override func mouseDown(with event: NSEvent) {}

    override func mouseUp(with event: NSEvent) {
        guard bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        onPress?()
    }
}
