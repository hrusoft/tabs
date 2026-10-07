import AppKit
import TabsPluginSDK

/// The browser's header: Back, Forward and Refresh, then the address bar
/// filling what is left, with the page's live title as a segment at its left.
/// The pane offers it as its header's title (`headerTitle`): core gives it the
/// slot after the grip and before the header's controls, and the header paints
/// the bar behind it. The children sit in one row, 8 apart.
@MainActor
final class BrowserToolbar: BrowserFlippedView, PaneHeaderTitleView {
    unowned let pane: BrowserPane
    /// The app's color tokens, as core last told the pane.
    var theme: PaneTheme {
        didSet {
            needsDisplay = true
            for button in buttons { button.needsDisplay = true }
            bar.needsDisplay = true
            bar.field.textColor = theme.textDim
        }
    }
    let back: NavButton
    let forward: NavButton
    let refresh: NavButton
    let bar = AddressBar()
    private var buttons: [NavButton] { [back, forward, refresh] }
    /// Where core put this view in the header, once it has.
    private var slot: PaneHeaderSlot?
    #if DEBUG
    /// A title and an address to show whatever the page says (the visual
    /// comparison's states that no fixture page reaches); nil follows the page.
    var titleOverride: String?
    var addressOverride: String?
    #endif

    init(pane: BrowserPane) {
        self.pane = pane
        theme = pane.pane.theme
        back = NavButton(glyph: .back, label: "Back", identifier: "browser-back-button")
        forward = NavButton(glyph: .forward, label: "Forward", identifier: "browser-forward-button")
        refresh = NavButton(glyph: .refresh, label: "Refresh", identifier: "browser-refresh-button")
        super.init(frame: .zero)
        back.onPress = { [weak pane] in pane?.page.goBack() }
        forward.onPress = { [weak pane] in pane?.page.goForward() }
        refresh.onPress = { [weak pane] in pane?.page.reload() }
        for button in buttons { addSubview(button) }
        addSubview(bar)
        bar.toolbar = self
        bar.field.stringValue = pane.page.url
        bar.address = pane.page.url
        bar.title = pane.page.title
        sync()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Whether the address field has the keyboard (typing there is never
    /// replaced by a navigation that happens in the background).
    var isEditingAddress: Bool { bar.field.hasFocus }

    /// Follows the page: the buttons' enabled state, the URL (unless it is being
    /// typed over), the live title.
    func sync() {
        let page = pane.page
        back.isEnabled = page.canGoBack
        forward.isEnabled = page.canGoForward
        #if DEBUG
        let address = addressOverride ?? page.url
        let title = titleOverride ?? page.title
        #else
        let address = page.url
        let title = page.title
        #endif
        if !isEditingAddress {
            bar.address = address
            if bar.field.stringValue != address { bar.field.stringValue = address }
        }
        if bar.title != title { bar.title = title }
        needsLayout = true
        bar.needsDisplay = true
    }

    func paneHeaderSlotDidChange(_ slot: PaneHeaderSlot) {
        self.slot = slot
        needsLayout = true
        needsDisplay = true
    }

    // MARK: Layout (one row: 24 tall, gap 8)

    struct Layout {
        var back: CGRect
        var forward: CGRect
        var refresh: CGRect
        var bar: CGRect
    }

    /// The items laid out in `width` (the slot's), in layout coordinates: the
    /// slot's true origin is the offset of the first, since the view's frame is
    /// on whole points and the header's layout is not.
    func computeLayout(width: Double) -> Layout {
        let origin = slot?.fractionalOffset ?? .zero
        let size = BrowserMetrics.buttonSize
        let buttonY = origin.y + (BrowserMetrics.barHeight - size.height) / 2
        var x = origin.x
        var rects: [CGRect] = []
        for _ in 0..<3 {
            rects.append(CGRect(x: x, y: buttonY, width: size.width, height: size.height))
            x += size.width + BrowserMetrics.gap
        }
        let barWidth = max(width - (x - origin.x), 0)
        let bar = CGRect(
            x: x, y: origin.y + (BrowserMetrics.barHeight - BrowserMetrics.barFieldHeight) / 2, width: barWidth,
            height: BrowserMetrics.barFieldHeight)
        return Layout(back: rects[0], forward: rects[1], refresh: rects[2], bar: bar)
    }

    override func layout() {
        super.layout()
        let layout = computeLayout(width: bounds.width)
        back.frame = snapped(layout.back)
        forward.frame = snapped(layout.forward)
        refresh.frame = snapped(layout.refresh)
        bar.frame = snapped(layout.bar)
    }
}

/// A nav button: a 13pt icon padded 2 above and below and 5 either side,
/// washed with the hover color under the pointer, dimmed and inert
/// while disabled. Its label is its tooltip and accessibility label, a
/// disabled button's too: a fresh pane's Back is exactly the one worth naming.
@MainActor
final class NavButton: BrowserFlippedView {
    let glyph: BrowserGlyphs.Nav
    let label: String
    var onPress: (() -> Void)?
    var isEnabled = true {
        didSet {
            guard isEnabled != oldValue else { return }
            if !isEnabled { hovered = false }
            setAccessibilityEnabled(isEnabled)
            window?.invalidateCursorRects(for: self)
            needsDisplay = true
        }
    }

    private var theme: PaneTheme { (superview as? BrowserToolbar)?.theme ?? .dark }
    private(set) var hovered = false { didSet { needsDisplay = true } }
    private var tracking: NSTrackingArea?

    init(glyph: BrowserGlyphs.Nav, label: String, identifier: String) {
        self.glyph = glyph
        self.label = label
        super.init(frame: .zero)
        setAccessibilityIdentifier(identifier)
        setAccessibilityRole(.button)
        setAccessibilityLabel(label)
        toolTip = label
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func draw(_ dirtyRect: NSRect) {
        if hovered, isEnabled {
            theme.hover(0.12).setFill()
            NSBezierPath(roundedRect: bounds, xRadius: BrowserMetrics.radius, yRadius: BrowserMetrics.radius).fill()
        }
        let color =
            isEnabled ? theme.textDim : theme.textDim.withAlphaComponent(theme.textDim.alphaComponent * BrowserMetrics.disabledOpacity)
        BrowserGlyphs.draw(
            glyph, in: CGRect(x: 5, y: 2, width: BrowserMetrics.iconSize, height: BrowserMetrics.iconSize), color: color)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(area)
        tracking = area
    }

    /// `cursor: pointer` while enabled, `default` while disabled.
    override func resetCursorRects() {
        if isEnabled { addCursorRect(bounds, cursor: .pointingHand) }
    }

    override func mouseEntered(with event: NSEvent) { hovered = isEnabled }
    override func mouseExited(with event: NSEvent) { hovered = false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    /// A press on the button is the button's: it activates the pane but never
    /// starts a pane drag.
    override func mouseDown(with event: NSEvent) {}

    override func mouseUp(with event: NSEvent) {
        if isEnabled, bounds.contains(convert(event.locationInWindow, from: nil)) { onPress?() }
    }

    override func accessibilityPerformPress() -> Bool {
        guard isEnabled else { return false }
        onPress?()
        return true
    }
}

/// The address bar: one bordered, rounded box shared by the title segment and
/// the address input, so the pair reads as a single control rather than two
/// glued together. The border and radius live on the box, since clipping is
/// what rounds the segment's shade at the shared corner.
/// The border turns accent while the field has the keyboard.
///
/// It paints the segment and the input's background itself and the unfocused
/// text, centered in the input's content box; the field draws only while it
/// is being edited.
@MainActor
final class AddressBar: BrowserFlippedView, NSTextFieldDelegate {
    weak var toolbar: BrowserToolbar?
    let field = AddressField()
    /// The overlay that gives the segment its tooltip; it takes no presses, so a
    /// press on the segment drags the pane as the rest of the bar does.
    let segmentView = SegmentView()
    /// What the input shows: the page's URL, or what's being typed.
    var address = ""
    /// The page's live title; the segment is absent without one.
    var title = "" {
        didSet {
            guard title != oldValue else { return }
            segmentView.toolTip = title.isEmpty ? nil : title
            needsLayout = true
            needsDisplay = true
        }
    }

    private var theme: PaneTheme { toolbar?.theme ?? .dark }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityIdentifier("browser-address-bar")
        addSubview(segmentView)
        addSubview(field)
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = BrowserText.ui12.font
        field.textColor = PaneTheme.dark.textDim
        field.lineBreakMode = .byClipping
        field.cell?.isScrollable = true
        field.cell?.wraps = false
        field.delegate = self
        field.setAccessibilityIdentifier("browser-address-input")
        field.setAccessibilityLabel("Address")
        field.onFocusChange = { [weak self] in self?.needsDisplay = true }
    }

    convenience init() { self.init(frame: .zero) }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    // MARK: Geometry

    struct Layout {
        /// The content box inside the border.
        var content: CGRect
        var segment: CGRect?
        var input: CGRect
    }

    /// The segment is its own width (the title, padding both sides and its right
    /// border), at most 30% of the box's content.
    func computeLayout() -> Layout {
        let content = CGRect(
            x: BrowserMetrics.borderWidth, y: BrowserMetrics.borderWidth, width: max(bounds.width - 2 * BrowserMetrics.borderWidth, 0),
            height: max(bounds.height - 2 * BrowserMetrics.borderWidth, 0))
        guard !title.isEmpty else { return Layout(content: content, segment: nil, input: content) }
        let natural = BrowserText.ui12.width(title) + 2 * BrowserMetrics.segmentPaddingX + 1
        let width = min(natural, BrowserMetrics.segmentMaxFraction * content.width)
        let segment = CGRect(x: content.minX, y: content.minY, width: width, height: content.height)
        let input = CGRect(x: segment.maxX, y: content.minY, width: content.width - width, height: content.height)
        return Layout(content: content, segment: segment, input: input)
    }

    /// The input's text: 12pt in a box padded 2 by 6, the line centred in the
    /// content.
    static func inputTextOrigin(in input: CGRect) -> CGPoint {
        let font = BrowserText.ui12
        let contentTop = input.minY + BrowserMetrics.inputPaddingY
        let contentHeight = input.height - 2 * BrowserMetrics.inputPaddingY
        return CGPoint(x: input.minX + BrowserMetrics.inputPaddingX, y: contentTop + (contentHeight - font.lineHeight) / 2 + font.ascent)
    }

    override func layout() {
        super.layout()
        let layout = computeLayout()
        segmentView.frame = layout.segment.map(snapped) ?? .zero
        segmentView.isHidden = layout.segment == nil
        let input = snapped(layout.input)
        // The editable text sits where the drawn one does.
        let font = BrowserText.ui12
        let origin = Self.inputTextOrigin(in: input)
        field.frame = CGRect(
            x: origin.x - 2, y: origin.y.rounded() - font.ascent,
            width: max(input.maxX - origin.x - BrowserMetrics.inputPaddingX + 2, 0),
            height: font.lineHeight + 2)
    }

    override func draw(_ dirtyRect: NSRect) {
        let layout = computeLayout()
        let box = bounds
        let radius = BrowserMetrics.radius
        // Clipped to the padding box, whose corners are the border's less its width.
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.saveGState()
        NSBezierPath(roundedRect: layout.content, xRadius: radius - 1, yRadius: radius - 1).addClip()
        theme.bg.setFill()
        layout.content.fill()
        if let segment = layout.segment {
            let snappedSegment = snapped(segment)
            theme.bgElevated.setFill()
            snappedSegment.fill()
            theme.border.setFill()
            CGRect(x: snappedSegment.maxX - 1, y: snappedSegment.minY, width: 1, height: snappedSegment.height).fill()
            let font = BrowserText.ui12
            let baseline =
                snappedSegment.minY + BrowserMetrics.segmentPaddingY + font.halfLeading(in: BrowserMetrics.segmentLineHeight) + font.ascent
            font.draw(
                title, at: CGPoint(x: snappedSegment.minX + BrowserMetrics.segmentPaddingX, y: baseline), color: theme.textDim,
                maxWidth: snappedSegment.width - 2 * BrowserMetrics.segmentPaddingX - 1)
        }
        // The text is drawn centered in the input's content box (the field's own
        // inset is off); the field shows only while it is being edited.
        field.alphaValue = field.hasFocus ? 1 : 0
        if !field.hasFocus {
            let input = snapped(layout.input)
            context.saveGState()
            context.clip(to: input.insetBy(dx: BrowserMetrics.inputPaddingX, dy: 0))
            BrowserText.ui12.draw(address, at: Self.inputTextOrigin(in: input), color: theme.textDim)
            context.restoreGState()
        }
        context.restoreGState()
        (field.hasFocus ? theme.accent : theme.border).setStroke()
        let border = NSBezierPath(roundedRect: box.insetBy(dx: 0.5, dy: 0.5), xRadius: radius - 0.5, yRadius: radius - 0.5)
        border.lineWidth = 1
        border.stroke()
    }

    // MARK: Typing

    func controlTextDidChange(_ notification: Notification) {
        address = field.stringValue
    }

    /// Return navigates to what was typed, then the field gives up focus; a
    /// blank field does nothing (`resolveAddressInput`).
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard selector == #selector(NSResponder.insertNewline(_:)) else { return false }
        toolbar?.pane.navigate(toAddress: field.stringValue)
        field.window?.makeFirstResponder(nil)
        return true
    }

    /// What was typed and not sent stays until the next navigation puts the page's
    /// URL back.
    func controlTextDidEndEditing(_ notification: Notification) {
        needsDisplay = true
    }
}

/// The transparent view over the title segment: it carries the segment's
/// identifier and its tooltip (the full title) and takes no press.
@MainActor
final class SegmentView: BrowserFlippedView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityIdentifier("browser-title-segment")
        setAccessibilityRole(.staticText)
    }

    convenience init() { self.init(frame: .zero) }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var toolTip: String? {
        didSet { setAccessibilityLabel(toolTip) }
    }
}

/// The address input: borderless, drawn over the bar's box.
@MainActor
final class AddressField: NSTextField {
    var onFocusChange: (() -> Void)?

    var hasFocus: Bool { currentEditor() != nil }

    /// A press (an accessibility press, a synthesized click) starts editing, as a
    /// click in the field does.
    override func performClick(_ sender: Any?) {
        window?.makeFirstResponder(self)
    }

    override func becomeFirstResponder() -> Bool {
        let became = super.becomeFirstResponder()
        onFocusChange?()
        return became
    }

    override func textDidEndEditing(_ notification: Notification) {
        super.textDidEndEditing(notification)
        onFocusChange?()
    }
}
