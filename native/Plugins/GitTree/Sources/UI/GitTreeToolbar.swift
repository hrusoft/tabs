import AppKit
import TabsPluginSDK

/// The git tree's toolbar: the path bar, the folder button, the HEAD label and
/// the branch-scope select (`GitTreeHeaderTitle.tsx`). Like the Electron app's
/// `HeaderTitle`, the pane offers it as its header's title (`headerTitle`):
/// core gives it the slot after the grip and before the header's controls, and
/// the header paints the bar behind it.
@MainActor
final class GitTreeToolbar: GitFlippedView, NSTextFieldDelegate, PaneHeaderTitleView {
    unowned let pane: GitTreePane
    /// The app's color tokens, as core last told the pane.
    var theme: PaneTheme {
        didSet {
            needsDisplay = true
            pathBox.needsDisplay = true
            select.needsDisplay = true
            browse.needsDisplay = true
            pathField.textColor = theme.textDim
        }
    }
    let pathBox = GitFlippedView()
    let pathField = PathTextField()
    let select: BranchScopeSelect
    let browse: BrowseButton
    /// What the path bar shows: the configured directory, or what's being typed.
    private(set) var pathValue: String
    /// Where core put this view in the header, once it has.
    private var slot: PaneHeaderSlot?

    /// The branch-scope options, narrowest first.
    static let scopeOptions: [(GitBranchScope, String)] = [
        (.current, "Current branch"), (.local, "All local branches"), (.all, "All branches"),
    ]

    init(pane: GitTreePane) {
        self.pane = pane
        theme = pane.pane.theme
        pathValue = pane.configuredDir ?? ""
        select = BranchScopeSelect(pane: pane)
        browse = BrowseButton(pane: pane)
        super.init(frame: .zero)
        addSubview(pathBox)
        addSubview(browse)
        addSubview(select)
        pathField.isBordered = false
        pathField.drawsBackground = false
        pathField.focusRingType = .none
        pathField.font = GitText.ui12.font
        pathField.textColor = theme.textDim
        pathField.lineBreakMode = .byClipping
        pathField.cell?.isScrollable = true
        pathField.cell?.wraps = false
        pathField.delegate = self
        pathField.setAccessibilityIdentifier("git-tree-path-input")
        pathField.setAccessibilityLabel("Repository directory")
        pathField.stringValue = pathValue
        pathField.onFocusChange = { [weak self] in self?.needsDisplay = true }
        pathBox.addSubview(pathField)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    var isEditingPath: Bool { pathField.currentEditor() != nil }

    /// Follows the configured directory when it changes from elsewhere (the
    /// default adopted), never while the user is typing in the path bar.
    func refresh() {
        if !isEditingPath {
            pathValue = pane.configuredDir ?? ""
            if pathField.stringValue != pathValue { pathField.stringValue = pathValue }
        }
        select.needsDisplay = true
        needsLayout = true
        needsDisplay = true
    }

    func paneHeaderSlotDidChange(_ slot: PaneHeaderSlot) {
        self.slot = slot
        needsLayout = true
        needsDisplay = true
    }

    // MARK: Layout (the children of `.pane-header`: 24 tall, gap 8)

    struct Layout {
        var path: CGRect
        var browse: CGRect
        var head: CGRect?
        var headText: String?
        var select: CGRect
    }

    func headLabel() -> String? {
        switch pane.head {
        case .branch(let name)?: name
        case .detached(let hash)?: "detached at \(shortHash(hash))"
        case nil: nil
        }
    }

    /// The items laid out in `width` (the slot's), in layout coordinates: the
    /// slot's true origin is the offset of the first, since the view's frame
    /// is on whole points and the header's layout is not.
    func computeLayout(width: Double) -> Layout {
        let origin = slot?.fractionalOffset ?? .zero
        let centerHeight = GitTreeMetrics.toolbarHeight
        let selectSize = BranchScopeSelect.size
        let text = headLabel()
        // `max-width: 40%` of the header's content box (the bar less its padding), padding 0 4.
        let headWidth = text.map { min(GitText.ui11.width($0) + 8, 0.4 * (slot?.barContentWidth ?? width)) }
        let browseSize = BrowseButton.size
        let items = 3 + (text == nil ? 0 : 1)
        let pathWidth = max(
            width - browseSize.width - selectSize.width - (headWidth ?? 0) - Double(items - 1) * GitTreeMetrics.toolbarGap, 0)
        var x = origin.x
        let top = origin.y
        let path = CGRect(
            x: x, y: top + (centerHeight - GitTreeMetrics.fieldHeight) / 2, width: pathWidth, height: GitTreeMetrics.fieldHeight)
        x += pathWidth + GitTreeMetrics.toolbarGap
        let browse = CGRect(
            x: x, y: top + (centerHeight - browseSize.height) / 2, width: browseSize.width, height: browseSize.height)
        x += browseSize.width + GitTreeMetrics.toolbarGap
        var head: CGRect?
        if let headWidth {
            let height = GitText.ui11.lineHeight
            head = CGRect(x: x, y: top + (centerHeight - height) / 2, width: headWidth, height: height)
            x += headWidth + GitTreeMetrics.toolbarGap
        }
        let select = CGRect(
            x: x, y: top + (centerHeight - selectSize.height) / 2, width: selectSize.width, height: selectSize.height)
        return Layout(path: path, browse: browse, head: head, headText: text, select: select)
    }

    /// The path bar's text: 12px in a 20-tall box with padding 2 6 and a 1pt
    /// border, the line centred in the 14pt content box.
    static func pathTextOrigin(in box: CGRect) -> CGPoint {
        let font = GitText.ui12
        let contentTop = box.minY + 1 + 2
        let contentHeight = box.height - 2 - 4
        return CGPoint(x: box.minX + 1 + 6, y: contentTop + (contentHeight - font.lineHeight) / 2 + font.ascent)
    }

    override func layout() {
        super.layout()
        let layout = computeLayout(width: bounds.width)
        pathBox.frame = snapped(layout.path)
        browse.frame = snapped(layout.browse)
        select.frame = snapped(layout.select)
        // The editable text sits where the drawn one does.
        let font = GitText.ui12
        let origin = Self.pathTextOrigin(in: CGRect(origin: .zero, size: pathBox.frame.size))
        pathField.frame = CGRect(
            x: origin.x - 2, y: origin.y.rounded() - font.ascent - 1, width: pathBox.frame.width - origin.x - 5, height: font.lineHeight + 2
        )
    }

    override func draw(_ dirtyRect: NSRect) {
        let layout = computeLayout(width: bounds.width)
        // The path bar's box.
        let box = snapped(layout.path)
        theme.bg.setFill()
        NSBezierPath(roundedRect: box, xRadius: 3, yRadius: 3).fill()
        (pathField.hasFocus ? theme.accent : theme.border).setStroke()
        let border = NSBezierPath(roundedRect: box.insetBy(dx: 0.5, dy: 0.5), xRadius: 2.5, yRadius: 2.5)
        border.lineWidth = 1
        border.stroke()
        // The field shows only while editing; otherwise the text is drawn
        // where Chromium puts an input's line (the field's own inset is off).
        pathField.alphaValue = pathField.hasFocus ? 1 : 0
        if !pathField.hasFocus, let context = NSGraphicsContext.current?.cgContext {
            context.saveGState()
            context.clip(to: box.insetBy(dx: 7, dy: 1))
            GitText.ui12.draw(pathValue, at: Self.pathTextOrigin(in: box), color: theme.textDim)
            context.restoreGState()
        }
        if let head = layout.head, let text = layout.headText {
            GitText.ui11.draw(
                text, at: CGPoint(x: head.minX + 4, y: head.minY + GitText.ui11.ascent), color: theme.textDim, maxWidth: head.width - 8)
        }
    }

    // MARK: The path bar

    func controlTextDidChange(_ notification: Notification) {
        pathValue = pathField.stringValue
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            pane.applyPath(pathField.stringValue)
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            pathValue = pane.configuredDir ?? ""
            pathField.stringValue = pathValue
            return true
        default:
            return false
        }
    }

    /// Leaving the path bar commits it, like `onBlur`.
    func controlTextDidEndEditing(_ notification: Notification) {
        pane.applyPath(pathField.stringValue)
        pathBox.needsDisplay = true
        needsDisplay = true
    }
}

/// The path bar's text field: borderless, drawn over the toolbar's box.
@MainActor
final class PathTextField: NSTextField {
    var onFocusChange: (() -> Void)?

    var hasFocus: Bool { currentEditor() != nil }

    /// A press (an accessibility press, a synthesized click) starts editing,
    /// as a click in the field does.
    override func performClick(_ sender: Any?) {
        window?.makeFirstResponder(self)
    }

    override func becomeFirstResponder() -> Bool {
        let became = super.becomeFirstResponder()
        onFocusChange?()
        superview?.superview?.needsDisplay = true
        return became
    }

    override func textDidEndEditing(_ notification: Notification) {
        super.textDidEndEditing(notification)
        onFocusChange?()
    }
}

/// The folder button (`HeaderButton` with `FolderIcon`, title "Choose a
/// repository"): a `.pane-header-button`, a 13pt icon in 2 5 padding, washed
/// with the hover color under the pointer. Pressing it opens the system's
/// picker on the current directory.
@MainActor
final class BrowseButton: GitFlippedView {
    unowned let pane: GitTreePane
    var theme: PaneTheme { (superview as? GitTreeToolbar)?.theme ?? .dark }

    static let icon = 13.0
    static let size = CGSize(width: 23, height: 17)
    static let title = "Choose a repository"

    private var hovered = false { didSet { needsDisplay = true } }
    private var tracking: NSTrackingArea?

    init(pane: GitTreePane) {
        self.pane = pane
        super.init(frame: .zero)
        setAccessibilityIdentifier("git-tree-browse-button")
        setAccessibilityRole(.button)
        setAccessibilityLabel(Self.title)
        toolTip = Self.title
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func draw(_ dirtyRect: NSRect) {
        if hovered {
            theme.hover(0.12).setFill()
            NSBezierPath(roundedRect: bounds, xRadius: 3, yRadius: 3).fill()
        }
        GitTreeGlyphs.drawFolder(in: CGRect(x: 5, y: 2, width: Self.icon, height: Self.icon), color: theme.textDim)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) { hovered = true }
    override func mouseExited(with event: NSEvent) { hovered = false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    override func mouseDown(with event: NSEvent) {}

    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { press() }
    }

    override func accessibilityPerformPress() -> Bool {
        press()
        return true
    }

    /// The picker is asynchronous to the user: the pane goes on meanwhile.
    func press() {
        Task { [pane] in await pane.browse() }
    }
}

/// The branch-scope `<select>`: 11px text in a 20-tall box (padding 1 4, a
/// 1pt border, radius 3) with Chromium's menu-list arrow; choosing pops up
/// the three filters.
@MainActor
final class BranchScopeSelect: GitFlippedView {
    unowned let pane: GitTreePane
    var theme: PaneTheme { (superview as? GitTreeToolbar)?.theme ?? .dark }

    /// Chromium sizes a select to its widest option.
    static var size: CGSize {
        let widest = GitTreeToolbar.scopeOptions.map { GitText.ui11.width($0.1) }.max() ?? 0
        return CGSize(width: (widest + arrowArea + 2 * 4 + 2).rounded(.up), height: GitTreeMetrics.fieldHeight)
    }

    /// The room the arrow takes after the text.
    static let arrowArea = 20.0

    init(pane: GitTreePane) {
        self.pane = pane
        super.init(frame: .zero)
        setAccessibilityIdentifier("git-tree-branch-scope")
        setAccessibilityRole(.popUpButton)
        setAccessibilityLabel("Branches shown")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    var label: String { GitTreeToolbar.scopeOptions.first { $0.0 == pane.branchScope }?.1 ?? "" }

    override func draw(_ dirtyRect: NSRect) {
        let box = bounds
        theme.bg.setFill()
        NSBezierPath(roundedRect: box, xRadius: 3, yRadius: 3).fill()
        theme.border.setStroke()
        let border = NSBezierPath(roundedRect: box.insetBy(dx: 0.5, dy: 0.5), xRadius: 2.5, yRadius: 2.5)
        border.lineWidth = 1
        border.stroke()
        let font = GitText.ui11
        let baseline = (box.height - font.lineHeight) / 2 + font.ascent
        // Chromium's menu list keeps 4 more inside the author padding.
        font.draw(label, at: CGPoint(x: 1 + 4 + 4, y: baseline), color: theme.textDim)
        // The arrow: Chromium's bold chevron, 9×5.5 of ink, 4.5 from the right.
        let arrow = NSBezierPath()
        arrow.move(to: CGPoint(x: box.maxX - 12.5, y: 8.5))
        arrow.line(to: CGPoint(x: box.maxX - 9, y: 12))
        arrow.line(to: CGPoint(x: box.maxX - 5.5, y: 8.5))
        arrow.lineWidth = 2
        arrow.lineCapStyle = .round
        arrow.lineJoinStyle = .round
        theme.textDim.setStroke()
        arrow.stroke()
    }

    override func mouseDown(with event: NSEvent) {
        pane.pane.showContextMenu(scopeItems(), at: CGPoint(x: 0, y: bounds.height), in: self)
    }

    /// The three filters, as core's menu rows.
    func scopeItems() -> [PaneMenuItem] {
        GitTreeToolbar.scopeOptions.map { scope, title in
            PaneMenuItem(title) { [weak pane] in pane?.chooseBranchScope(scope) }
        }
    }
}
