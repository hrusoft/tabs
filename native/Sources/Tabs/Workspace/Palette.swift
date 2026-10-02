import AppKit
import TabsCore
import TabsPluginSDK

// MARK: - The ⌘P command palette

/// Where the palette puts the content it makes: the four ways to place new
/// content, in the File menu's order (`PLACEMENT_STRATEGY_IDS`).
enum PalettePlacement: CaseIterable {
    case tab, splitHorizontal, splitVertical, unpinned

    /// The command whose title (minus its "New ") labels the row, so the
    /// palette and the File menu can't disagree.
    var command: CoreCommand {
        switch self {
        case .tab: CoreCommands.newTab
        case .splitHorizontal: CoreCommands.splitHorizontal
        case .splitVertical: CoreCommands.splitVertical
        case .unpinned: CoreCommands.newUnpinnedPane
        }
    }

    /// "New Horizontal Split" → "Horizontal Split" (`label.replace(/^New /, '')`).
    var label: String {
        let title = command.title
        return title.hasPrefix("New ") ? String(title.dropFirst(4)) : title
    }

    var icon: ChromeIcon {
        switch self {
        case .tab: .newTab
        case .splitHorizontal: .splitHorizontal
        case .splitVertical: .splitVertical
        case .unpinned: .newUnpinnedTab
        }
    }

    var identifier: String {
        switch self {
        case .tab: "new-tab"
        case .splitHorizontal: "split-horizontal"
        case .splitVertical: "split-vertical"
        case .unpinned: "new-unpinned-pane"
        }
    }
}

/// The palette overlay (`CommandPalette.tsx`): pick a content type, then where
/// to put it. One per window, in the window's overlay, aimed at the pane that
/// was active when it opened.
@MainActor
enum Palette {
    /// Opens the palette in `controller` aimed at its active pane — or, when
    /// one is already open, aims that one afresh (the chord pressed again).
    /// Nothing when the window has no active pane in any tree.
    @discardableResult
    static func open(in controller: WorkspaceWindowController) -> PaletteView? {
        let target = controller.layout.activePaneID
        guard controller.layout.findNode(target) != nil else { return nil }
        if let open = controller.root.overlay.subviews.compactMap({ $0 as? PaletteView }).first {
            open.reopen(target: target)
            return open
        }
        let view = PaletteView(controller: controller, target: target)
        view.frame = controller.root.overlay.bounds
        view.autoresizingMask = [.width, .height]
        controller.root.overlay.addSubview(view)
        view.layoutSubtreeIfNeeded()
        controller.window?.makeFirstResponder(view)
        return view
    }

    /// The palette open in `controller`, if any.
    static func current(in controller: WorkspaceWindowController) -> PaletteView? {
        controller.root.overlay.subviews.compactMap { $0 as? PaletteView }.first
    }
}

/// One row: what it says, its icon, and what choosing it does.
struct PaletteRow {
    enum Icon {
        /// A content type's own icon.
        case type(EmptyPaneView.Icon)
        /// One of the chrome's (a placement's).
        case chrome(ChromeIcon)
    }

    var key: String
    var label: String
    var icon: Icon
}

/// The backdrop (`.command-palette-backdrop`): dims the whole window, centers
/// the panel, takes the keyboard, and swallows every pointer event.
@MainActor
final class PaletteView: FlippedView {
    enum Step: Equatable {
        case type
        case placement(ContentTypeID)

        /// The step's kind, which is what resets the highlight
        /// (`useEffect([step.kind])`): choosing another type of the same kind
        /// of step doesn't exist, but opening again on the type step doesn't count.
        var kind: Int {
            switch self {
            case .type: 0
            case .placement: 1
            }
        }
    }

    private(set) weak var controller: WorkspaceWindowController?
    /// The pane that was active when the palette opened: where the content goes.
    private(set) var target: NodeID
    private(set) var step: Step = .type
    private(set) var highlighted = 0
    private(set) var scrollOffset: CGFloat = 0
    private let theme: Theme
    private let panel = PalettePanel()
    private var types: [EmptyPaneView.Action]
    /// The row the pointer last entered (`onMouseEnter` fires on entry only).
    private var hoverRow: Int?
    private var lastPointer: CGPoint?
    private var pressed: Pressed?
    private var tracking: NSTrackingArea?

    private enum Pressed: Equatable {
        case row(Int)
        case backdrop
        case panel
    }

    static let text = ChromeText(size: 13)
    static let badgeText = ChromeText(size: 10, tabularNumbers: true)
    static let emptyText = ChromeText(size: 12)
    static let panelWidth: CGFloat = 320
    static let panelPadding: CGFloat = 4
    static let border: CGFloat = 1
    static let rowPadding = CGSize(width: 10, height: 7)
    static let gap: CGFloat = 8
    static let iconSize: CGFloat = 16
    static let badgeMinWidth: CGFloat = 16
    static let badgeHeight: CGFloat = 16
    static let badgePadding: CGFloat = 4

    init(controller: WorkspaceWindowController, target: NodeID) {
        self.controller = controller
        self.target = target
        theme = controller.appearance.theme
        types = controller.renderer.creationActions()
        super.init(frame: .zero)
        layer?.backgroundColor = theme.bg.mixedWithTransparent(0.4).cgColor
        setAccessibilityIdentifier("command-palette-backdrop")
        panel.layer?.backgroundColor = theme.bgElevated.cgColor
        panel.layer?.borderColor = theme.border.cgColor
        panel.layer?.borderWidth = Self.border
        panel.layer?.cornerRadius = 8
        panel.layer?.masksToBounds = false
        panel.setAccessibilityIdentifier("command-palette")
        panel.setAccessibilityRole(.menu)
        panel.drawContent = { [unowned self] in self.drawPanel() }
        addSubview(panel)
    }

    // MARK: What it lists

    /// The rows of the step showing: the enabled types (registration order),
    /// then the four placements. Empty when nothing can be created.
    var rows: [PaletteRow] {
        switch step {
        case .type:
            types.map { PaletteRow(key: $0.type.rawValue, label: $0.displayName, icon: .type($0.icon)) }
        case .placement:
            PalettePlacement.allCases.map { PaletteRow(key: $0.identifier, label: $0.label, icon: .chrome($0.icon)) }
        }
    }

    /// Re-reads the creatable types (one was enabled or disabled while open).
    /// The highlight is not clamped (`items[highlighted]` may be gone).
    func refreshTypes() {
        types = controller?.renderer.creationActions() ?? types
        needsLayout = true
        panel.needsDisplay = true
    }

    /// The chord again: aimed afresh at the active pane and back on the type
    /// step. The highlight resets only if the step's kind changed.
    func reopen(target: NodeID) {
        self.target = target
        setStep(.type)
        controller?.window?.makeFirstResponder(self)
    }

    private func setStep(_ next: Step) {
        let changed = next.kind != step.kind
        step = next
        if changed {
            highlighted = 0
            scrollOffset = 0
        }
        // The rows moved under a resting pointer: Chromium re-hovers after layout.
        hoverRow = nil
        needsLayout = true
        panel.needsDisplay = true
        if let lastPointer { updateHover(at: lastPointer) }
    }

    // MARK: Layout (`.command-palette`: 320 wide, padding 4, border 1, max 70vh)

    static var contentHeight: CGFloat { max(iconSize, text.lineHeight) }
    static var rowHeight: CGFloat { contentHeight + 2 * rowPadding.height }

    /// The empty state's sentence, wrapped to the panel (`.command-palette-empty`: padding 10).
    var emptyLines: [String] {
        Self.emptyText.wrap(NoContentTypes.message, width: Self.panelWidth - 2 * (Self.border + Self.panelPadding + 10))
    }
    private var emptyHeight: CGFloat { CGFloat(emptyLines.count) * Self.emptyText.lineHeight + 20 }

    /// The list's natural height (0 with nothing to list).
    private var listHeight: CGFloat { CGFloat(rows.count) * Self.rowHeight }

    /// The panel's box (window content coordinates, unsnapped): centered.
    var panelLayout: CGRect {
        let chrome = 2 * (Self.border + Self.panelPadding)
        let natural = chrome + (rows.isEmpty ? emptyHeight : listHeight)
        let height = min(natural, bounds.height * 0.7)
        return CGRect(x: (bounds.width - Self.panelWidth) / 2, y: (bounds.height - height) / 2, width: Self.panelWidth, height: height)
    }

    /// The visible part of the list, in panel coordinates.
    private var listArea: CGRect {
        let inset = Self.border + Self.panelPadding
        return CGRect(x: inset, y: inset, width: Self.panelWidth - 2 * inset, height: panelLayout.height - 2 * inset)
    }

    private var maxScroll: CGFloat { max(0, listHeight - listArea.height) }

    /// Row `index`'s box, in panel coordinates.
    func rowRect(_ index: Int) -> CGRect {
        let area = listArea
        return CGRect(
            x: area.minX, y: area.minY + CGFloat(index) * Self.rowHeight - scrollOffset, width: area.width, height: Self.rowHeight)
    }

    /// What one row is made of, in panel coordinates.
    struct RowParts {
        var row: CGRect
        var badge: CGRect?
        var badgeText: CGPoint?
        var icon: CGRect
        var label: CGRect
        var labelBaseline: CGFloat
    }

    func parts(_ index: Int) -> RowParts {
        let row = rowRect(index)
        var x = row.minX + Self.rowPadding.width
        let middle = row.minY + Self.rowPadding.height
        var badge: CGRect?
        var badgeText: CGPoint?
        if index < 9 {
            let digit = String(index + 1)
            let width = max(Self.badgeMinWidth, Self.badgeText.width(digit) + 2 * Self.badgePadding)
            let box = CGRect(x: x, y: middle + (Self.contentHeight - Self.badgeHeight) / 2, width: width, height: Self.badgeHeight)
            badge = box
            badgeText = CGPoint(
                x: box.minX + (width - Self.badgeText.width(digit)) / 2,
                y: Self.badgeText.baseline(centeredIn: Self.badgeHeight, top: box.minY))
            x = box.maxX + Self.gap
        }
        let iconWidth = iconWidth(of: rows[index])
        let icon = CGRect(x: x, y: middle + (Self.contentHeight - Self.iconSize) / 2, width: iconWidth, height: Self.iconSize)
        x = icon.maxX + Self.gap
        let label = CGRect(
            x: x, y: middle + (Self.contentHeight - Self.text.lineHeight) / 2, width: row.maxX - Self.rowPadding.width - x,
            height: Self.text.lineHeight)
        return RowParts(
            row: row, badge: badge, badgeText: badgeText, icon: icon, label: label, labelBaseline: label.minY + Self.text.ascent)
    }

    /// The icon's slot: 16 wide, except text standing in for one (the visual
    /// comparison's "▣"), which is as wide as its glyph.
    private func iconWidth(of row: PaletteRow) -> CGFloat {
        if case .type(.glyph(let glyph)) = row.icon { return Self.text.width(glyph) }
        return Self.iconSize
    }

    override func layout() {
        super.layout()
        layoutFrame = bounds
        scrollOffset = min(scrollOffset, maxScroll)
        place(panel, panelLayout)
        // `0 16px 40px`: a layer's shadow radius is the CSS blur.
        panel.layer?.shadowColor = theme.shadow(0.5).cgColor
        panel.layer?.shadowOpacity = 1
        panel.layer?.shadowRadius = 40
        panel.layer?.shadowOffset = CGSize(width: 0, height: -16)
        panel.needsDisplay = true
    }

    // MARK: Drawing

    /// The backdrop holds the keyboard by a programmatic `focus()`, and
    /// Chromium answers with its `outline: auto 1px` focus ring around it —
    /// the outermost pixel of the window, in the platform's ring colors
    /// (measured: #99c8ff over the dark theme, #005fcc over the light).
    override func draw(_ dirtyRect: NSRect) {
        (theme.isDark
            ? NSColor(srgbRed: 0x99 / 255, green: 0xc8 / 255, blue: 1, alpha: 1)
            : NSColor(srgbRed: 0, green: 0x5f / 255, blue: 0xcc / 255, alpha: 1)).setStroke()
        let ring = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 2, yRadius: 2)
        ring.lineWidth = 1
        ring.stroke()
    }

    private func drawPanel() {
        let rows = rows
        guard !rows.isEmpty else {
            let text = Self.emptyText
            let inset = Self.border + Self.panelPadding + 10
            for (index, line) in emptyLines.enumerated() {
                text.draw(
                    line, at: panel.drawn(CGPoint(x: inset, y: inset + CGFloat(index) * text.lineHeight + text.ascent)),
                    color: theme.text.mixedWithTransparent(0.65))
            }
            return
        }
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: panel.painted(listArea)).addClip()
        for (index, row) in rows.enumerated() {
            let parts = parts(index)
            guard parts.row.maxY > listArea.minY, parts.row.minY < listArea.maxY else { continue }
            let isHighlighted = index == highlighted
            let color = isHighlighted ? theme.onAccent : theme.text
            if isHighlighted {
                theme.accent.setFill()
                NSBezierPath(roundedRect: panel.painted(parts.row), xRadius: 4, yRadius: 4).fill()
            }
            if let badge = parts.badge, let origin = parts.badgeText {
                color.mixedWithTransparent(0.14).setFill()
                NSBezierPath(roundedRect: panel.painted(badge), xRadius: 4, yRadius: 4).fill()
                Self.badgeText.draw(String(index + 1), at: panel.drawn(CGPoint(x: origin.x, y: origin.y)), color: color)
            }
            drawIcon(row.icon, in: parts.icon, color: color)
            Self.text.draw(
                row.label, at: panel.drawn(CGPoint(x: parts.label.minX, y: parts.labelBaseline)), color: color,
                maxWidth: parts.label.width)
        }
        NSGraphicsContext.restoreGraphicsState()
    }

    private func drawIcon(_ icon: PaletteRow.Icon, in rect: CGRect, color: NSColor) {
        let box = panel.drawn(rect)
        switch icon {
        case .chrome(let chrome):
            chrome.draw(in: box, color: color)
        case .type(.symbol(let name)):
            guard
                let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
                    .withSymbolConfiguration(.init(pointSize: 13, weight: .regular).applying(.init(paletteColors: [color])))
            else { return }
            image.draw(
                in: CGRect(
                    x: box.midX - image.size.width / 2, y: box.midY - image.size.height / 2, width: image.size.width,
                    height: image.size.height),
                from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        case .type(.image(let template)):
            EmptyPaneView.tinted(template, color: color).draw(
                in: box, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        case .type(.glyph(let glyph)):
            Self.text.draw(glyph, at: CGPoint(x: box.minX, y: box.midY - Self.text.lineHeight / 2 + Self.text.ascent), color: color)
        }
    }

    // MARK: Choosing

    /// Chooses row `index` — by Return, by digit, by click: a type advances
    /// to the placement step; a placement creates and places, and closes.
    func choose(_ index: Int) {
        let rows = rows
        guard rows.indices.contains(index) else { return }
        switch step {
        case .type:
            setStep(.placement(types[index].type))
        case .placement(let type):
            commit(PalettePlacement.allCases[index], type: type)
        }
    }

    /// Closes first, then makes and places the content (`commit`): the target
    /// is looked up now, and if it's gone nothing is made.
    private func commit(_ placement: PalettePlacement, type: ContentTypeID) {
        guard let controller else { return }
        let target = target
        removeFromSuperview()
        guard controller.layout.findNode(target) != nil else { return }
        controller.newPane(ofType: type, from: target, placement: placement)
    }

    /// Closes and hands the keyboard back to the pane it was opened on
    /// (Escape, or a click on the backdrop).
    func dismiss() {
        let controller = controller
        let target = target
        removeFromSuperview()
        controller?.renderer.focus(target)
    }

    // MARK: Input

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    /// `Digit1`…`Digit9` by physical key (the main row, not the keypad).
    private static let digitKeyCodes: [UInt16: Int] = [18: 0, 19: 1, 20: 2, 21: 3, 23: 4, 22: 5, 26: 6, 28: 7, 25: 8]

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {
            dismiss()
            return
        }
        let count = rows.count
        guard count > 0 else { return }
        switch event.keyCode {
        case 125: highlighted = (highlighted + 1) % count
        case 126: highlighted = (highlighted - 1 + count) % count
        case 36, 76: choose(highlighted)
        default:
            if let index = Self.digitKeyCodes[event.keyCode], index < count { choose(index) }
            return
        }
        panel.needsDisplay = true
    }

    private func row(at point: CGPoint) -> Int? {
        let local = CGPoint(x: point.x - panelLayout.minX, y: point.y - panelLayout.minY)
        guard listArea.contains(local) else { return nil }
        return rows.indices.first { rowRect($0).contains(local) }
    }

    private func pressTarget(at point: CGPoint) -> Pressed {
        if let row = row(at: point) { return .row(row) }
        return panelLayout.contains(point) ? .panel : .backdrop
    }

    override func mouseDown(with event: NSEvent) {
        pressed = pressTarget(at: convert(event.locationInWindow, from: nil))
    }

    override func mouseUp(with event: NSEvent) {
        let released = pressTarget(at: convert(event.locationInWindow, from: nil))
        defer { pressed = nil }
        guard pressed == released else { return }
        switch released {
        case .row(let index): choose(index)
        case .backdrop: dismiss()
        case .panel: break
        }
    }

    /// A right-click lands on the backdrop and is swallowed: only the primary
    /// button clicks.
    override func rightMouseDown(with event: NSEvent) {}
    override func otherMouseDown(with event: NSEvent) {}

    override func scrollWheel(with event: NSEvent) {
        guard maxScroll > 0 else { return }
        scrollOffset = min(max(scrollOffset - event.scrollingDeltaY, 0), maxScroll)
        panel.needsDisplay = true
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        lastPointer = point
        updateHover(at: point)
    }

    /// Entering a row highlights it; moving within it changes nothing.
    private func updateHover(at point: CGPoint) {
        let row = row(at: point)
        guard row != hoverRow else { return }
        hoverRow = row
        if let row, row != highlighted {
            highlighted = row
            panel.needsDisplay = true
        }
    }

    /// Moves the highlight as the arrow keys would (the capture).
    func setHighlight(_ index: Int) {
        highlighted = index
        panel.needsDisplay = true
    }

    /// Where the pointer is, as a synthesized move (tests, the capture).
    func simulatePointer(at point: CGPoint) {
        lastPointer = point
        updateHover(at: point)
    }
}

/// The panel's own box: its background, border and shadow are its layer's;
/// the rows are drawn over them. Clicks fall through to the backdrop.
@MainActor
final class PalettePanel: FlippedView {
    var drawContent: (() -> Void)?

    override func draw(_ dirtyRect: NSRect) { drawContent?() }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// What the empty pane and the palette say when nothing can be created.
enum NoContentTypes {
    static let message = "No content types are enabled — turn one on in Settings → General → Content types."
}
