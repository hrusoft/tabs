import AppKit
import TabsCore
import TabsPluginSDK

/// Slides an overlay of `size` starting at `start` inside `extent`, 4pt
/// clear of both edges; the near edge wins when it doesn't fit.
func clampOverlay(_ start: CGFloat, _ size: CGFloat, _ extent: CGFloat) -> CGFloat {
    max(4, min(start, extent - size - 4))
}

// MARK: - Floating panes: moving and resizing

/// Moving a floating pane by its chrome, or resizing it by a frame handle.
/// No threshold (a window move has no click to protect); the geometry is
/// live on the view and committed once, on release; Escape puts it back.
@MainActor
enum FloatingGesture {
    static func move(_ floatID: NodeID, in controller: WorkspaceWindowController, with event: NSEvent) {
        track(floatID, in: controller, with: event) { origin, dx, dy in
            FloatRect(x: origin.x + dx, y: origin.y + dy, width: origin.width, height: origin.height)
        }
    }

    static func resize(_ floatID: NodeID, edge: ResizeHandle.Edge, in controller: WorkspaceWindowController, with event: NSEvent) {
        track(floatID, in: controller, with: event) { origin, dx, dy in
            var left = origin.x
            var top = origin.y
            var right = origin.x + origin.width
            var bottom = origin.y + origin.height
            let name = "\(edge)"
            // Each moving edge stops at the minimum against the fixed opposite one.
            if name.contains("w") { left = min(left + dx, right - Floating.minSize.width) }
            if name.contains("e") { right = max(right + dx, left + Floating.minSize.width) }
            if name.contains("n") { top = min(top + dy, bottom - Floating.minSize.height) }
            if name.contains("s") { bottom = max(bottom + dy, top + Floating.minSize.height) }
            return FloatRect(x: left, y: top, width: right - left, height: bottom - top)
        }
    }

    private static func track(
        _ floatID: NodeID, in controller: WorkspaceWindowController, with event: NSEvent,
        next rect: (FloatRect, Double, Double) -> FloatRect
    ) {
        guard let window = controller.window, let view = controller.root.floatingViews.first(where: { $0.floatID == floatID }) else {
            return
        }
        controller.engine.perform(in: controller.windowID) { layout, _ in layout.raiseFloating(floatID) }
        let start = controller.root.convert(event.locationInWindow, from: nil)
        let origin = FloatRect(x: view.frame.minX, y: view.frame.minY, width: view.frame.width, height: view.frame.height)
        var current = origin
        tracking: while let next = window.nextEvent(
            matching: [.leftMouseDragged, .leftMouseUp, .keyDown], until: .distantFuture, inMode: .eventTracking, dequeue: true)
        {
            switch next.type {
            case .leftMouseDragged:
                let point = controller.root.convert(next.locationInWindow, from: nil)
                current = Floating.clamp(rect(origin, point.x - start.x, point.y - start.y), to: controller.viewport)
                view.frame = CGRect(x: current.x, y: current.y, width: current.width, height: current.height)
                view.layoutSubtreeIfNeeded()
            case .keyDown where next.keyCode == 53:
                view.frame = CGRect(x: origin.x, y: origin.y, width: origin.width, height: origin.height)
                return
            case .keyDown:
                continue
            default:
                break tracking
            }
        }
        let viewport = controller.viewport
        controller.engine.perform(in: controller.windowID) { layout, _ in layout.setFloatingRect(floatID, current, viewport: viewport) }
    }
}

extension WorkspaceWindowController {
    var engine: LayoutEngine { renderer.engine }
}

// MARK: - Header hover menus

/// A header button's group, opened over it on hover: the root action again
/// as the first row, then the related ones. It stays while the pointer is on
/// the button or the menu, and closes 0.2s after it leaves both.
@MainActor
enum HeaderMenu {
    private static weak var current: HeaderDropdownView?

    static func open(for button: MenuGroupButton) {
        if current?.button === button {
            current?.cancelClose()
            return
        }
        close()
        guard let tree = sequence(first: button as NSView, next: { $0.superview }).first(where: { $0 is TreeHostView }) as? TreeHostView
        else { return }
        let dropdown = HeaderDropdownView(button: button)
        let origin = button.convert(CGPoint.zero, to: tree.menuLayer)
        let size = dropdown.preferredSize
        let width = button.window?.contentView?.bounds.width ?? tree.bounds.width
        let windowX = button.convert(CGPoint.zero, to: nil).x
        let shift = clampOverlay(windowX, size.width, width) - windowX
        dropdown.frame = CGRect(x: origin.x + shift, y: origin.y, width: size.width, height: size.height)
        let absolute = button.layoutFrame.origin
        dropdown.layoutFrame = CGRect(x: absolute.x + shift, y: absolute.y, width: size.width, height: size.height)
        tree.menuLayer.addSubview(dropdown)
        button.pane.header?.controls.holdOpen = true
        button.pane.tabBar?.controls.holdOpen = true
        current = dropdown
    }

    static func close() {
        guard let current else { return }
        current.dismiss()
        self.current = nil
    }

    /// Closes the menu if it is `button`'s.
    static func close(for button: MenuGroupButton) {
        if current?.button === button { close() }
    }

    /// The menu open now, if any.
    static var openDropdown: HeaderDropdownView? { current }

    /// A pointer move the open menu should see (synthesized input).
    static func simulatePointer(_ event: NSEvent) { current?.pointerMoved(event) }
}

@MainActor
final class HeaderDropdownView: FlippedView, NSViewToolTipOwner {
    unowned let button: MenuGroupButton
    private var hovered: Int?
    private var tracking: NSTrackingArea?
    private var closeTimer: Timer?
    private var watcher: Any?
    /// Closed: fading out, and no longer in the way of clicks.
    private var isDismissed = false

    init(button: MenuGroupButton) {
        self.button = button
        super.init(frame: .zero)
        let theme = button.theme
        layer?.cornerRadius = 6
        layer?.borderWidth = 1
        layer?.borderColor = theme.text.cgColor
        layer?.backgroundColor = surface.cgColor
        layer?.masksToBounds = false
        // A tool tip per row; the rows don't move while the menu is open.
        for row in items.indices { addToolTip(rowFrame(row), owner: self, userData: nil) }
        // Closing follows the pointer leaving both the button and the menu.
        watcher = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged]) { [weak self] event in
            self?.pointerMoved(event)
            return event
        }
    }

    override func layout() {
        super.layout()
        // Set here, not in `init`: AppKit resets a view layer's shadow before the view is shown.
        layer?.shadowColor = button.theme.shadow(0.4).cgColor
        layer?.shadowOpacity = 1
        layer?.shadowRadius = 24
        layer?.shadowOffset = CGSize(width: 0, height: -8)
    }

    var surface: NSColor {
        let pane = button.pane
        return pane.host.appearance.theme.surface(depth: pane.depth)
    }

    var items: [MenuGroupButton.Item] { button.items }

    var preferredSize: CGSize {
        CGSize(width: Metrics.headerButtonSize.width + 2, height: Metrics.headerButtonSize.height * CGFloat(items.count) + 2)
    }

    func rowFrame(_ index: Int) -> CGRect {
        CGRect(
            x: 1, y: 1 + CGFloat(index) * Metrics.headerButtonSize.height, width: Metrics.headerButtonSize.width,
            height: Metrics.headerButtonSize.height)
    }

    private func isDisabled(_ index: Int) -> Bool {
        items[index].action == .clear && button.pane.node.isEmpty
    }

    /// The tool tip of the row under `point`: its label.
    func view(_ view: NSView, stringForToolTip tag: NSView.ToolTipTag, point: NSPoint, userData data: UnsafeMutableRawPointer?) -> String {
        items.indices.first { rowFrame($0).contains(point) }.map { items[$0].label } ?? ""
    }

    override func draw(_ dirtyRect: NSRect) {
        let theme = button.theme
        for index in items.indices {
            let rect = rowFrame(index)
            let disabled = isDisabled(index)
            if index == hovered, !disabled {
                theme.hover(0.12).setFill()
                NSBezierPath(roundedRect: rect, xRadius: 3, yRadius: 3).fill()
            }
            let icon = Metrics.headerButtonIcon
            items[index].icon.draw(
                in: CGRect(x: rect.minX + 5, y: rect.minY + 2, width: icon, height: icon),
                color: theme.text.withAlphaComponent(disabled ? 0.35 : 1))
        }
    }

    func pointerMoved(_ event: NSEvent) {
        guard event.window === window else { return }
        let point = convert(event.locationInWindow, from: nil)
        let inButton = button.bounds.contains(button.convert(event.locationInWindow, from: nil))
        let row = items.indices.first { rowFrame($0).contains(point) }
        if row != hovered {
            hovered = row
            needsDisplay = true
        }
        if bounds.contains(point) || inButton {
            cancelClose()
        } else if closeTimer == nil {
            closeTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: false) { _ in
                MainActor.assumeIsolated { HeaderMenu.close() }
            }
        }
    }

    func cancelClose() {
        closeTimer?.invalidate()
        closeTimer = nil
    }

    func dismiss() {
        isDismissed = true
        cancelClose()
        if let watcher { NSEvent.removeMonitor(watcher) }
        watcher = nil
        let pane = button.pane
        for controls in [pane.header?.controls, pane.tabBar?.controls].compactMap({ $0 }) {
            controls.holdOpen = false
            controls.setRevealed(pane.header?.isHovered == true || pane.tabBar?.isHovered == true)
        }
        NSAnimationContext.runAnimationGroup(
            { context in
                context.duration = 0.1
                animator().alphaValue = 0
            },
            completionHandler: { [weak self] in
                MainActor.assumeIsolated { self?.removeFromSuperview() }
            })
    }

    /// Removed without `dismiss()` (its window closed): the monitor goes with it.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil, let watcher {
            NSEvent.removeMonitor(watcher)
            self.watcher = nil
        }
    }

    override func hitTest(_ point: NSPoint) -> NSView? { isDismissed ? nil : super.hitTest(point) }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    override func mouseDown(with event: NSEvent) {}

    override func mouseUp(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard let row = items.indices.first(where: { rowFrame($0).contains(point) }), !isDisabled(row) else { return }
        let pane = button.pane
        let action = items[row].action
        HeaderMenu.close()
        pane.host.perform(action, on: pane.nodeID)
    }
}

// MARK: - Context menus

/// The chrome's right-click menu: at the pointer, kept in the window; a click
/// outside or Escape closes it.
@MainActor
enum ContextMenu {
    struct Item {
        var title: String
        /// A disabled row is drawn dim and does nothing when clicked.
        var isEnabled = true
        var action: @MainActor () -> Void
    }

    @discardableResult
    static func open(_ items: [Item], at point: CGPoint, in controller: WorkspaceWindowController) -> ContextMenuBackdrop? {
        let backdrop = ContextMenuBackdrop(items: items, theme: controller.appearance.theme)
        backdrop.frame = controller.root.overlay.bounds
        backdrop.autoresizingMask = [.width, .height]
        controller.root.overlay.addSubview(backdrop)
        backdrop.place(at: point)
        controller.window?.makeFirstResponder(backdrop)
        return backdrop
    }
}

@MainActor
final class ContextMenuBackdrop: FlippedView {
    private let items: [ContextMenu.Item]
    private let theme: Theme
    private let panel = ContextMenuPanel()
    /// Runs once when the menu goes away, however it does.
    var onClose: (@MainActor () -> Void)?
    private var hovered: Int? { didSet { panel.needsDisplay = true } }
    private var tracking: NSTrackingArea?
    private static let text = ChromeText(size: 12)
    private static var rowHeight: CGFloat { text.lineHeight + 12 }

    init(items: [ContextMenu.Item], theme: Theme) {
        self.items = items
        self.theme = theme
        super.init(frame: .zero)
        panel.layer?.backgroundColor = theme.bgElevated.cgColor
        panel.layer?.borderColor = theme.border.cgColor
        panel.layer?.borderWidth = 1
        panel.layer?.cornerRadius = 6
        panel.layer?.masksToBounds = false
        addSubview(panel)
        panel.setAccessibilityIdentifier("context-menu")
        panel.drawRows = { [unowned self] in self.drawRows() }
    }

    /// Where the panel is laid out (content coordinates, unsnapped).
    private(set) var panelLayout: CGRect = .zero

    func place(at point: CGPoint) {
        let widest = items.map { Self.text.width($0.title) }.max() ?? 0
        let size = CGSize(width: max(140, widest + 16 + 8 + 2), height: CGFloat(items.count) * Self.rowHeight + 8 + 2)
        panelLayout = CGRect(
            x: clampOverlay(point.x, size.width, bounds.width), y: clampOverlay(point.y, size.height, bounds.height), width: size.width,
            height: size.height)
        panel.frame = panelLayout.snapped
        // Set here, not in `init`: AppKit resets a view layer's shadow before the view is shown.
        panel.layer?.shadowColor = theme.shadow(0.4).cgColor
        panel.layer?.shadowOpacity = 1
        panel.layer?.shadowRadius = 24
        panel.layer?.shadowOffset = CGSize(width: 0, height: -8)
    }

    private func rowRect(_ index: Int) -> CGRect {
        CGRect(
            x: panelLayout.minX + 5, y: panelLayout.minY + 5 + CGFloat(index) * Self.rowHeight, width: panelLayout.width - 10,
            height: Self.rowHeight)
    }

    /// The rows, drawn by the panel over its own background (panel coordinates).
    private func drawRows() {
        let origin = panel.frame.origin
        for (index, item) in items.enumerated() {
            let rect = rowRect(index).offsetBy(dx: -origin.x, dy: -origin.y)
            if index == hovered {
                theme.accent.setFill()
                NSBezierPath(
                    roundedRect: rect.offsetBy(dx: origin.x, dy: origin.y).snapped.offsetBy(dx: -origin.x, dy: -origin.y), xRadius: 3,
                    yRadius: 3
                )
                .fill()
            }
            Self.text.draw(
                item.title, at: CGPoint(x: rect.minX + 8, y: rect.minY + 6 + Self.text.ascent),
                color: !item.isEnabled ? theme.textDim.withAlphaComponent(0.5) : index == hovered ? theme.onAccent : theme.text)
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let row = items.indices.first { rowRect($0).contains(point) }
        if let row, !items[row].isEnabled {
            if hovered != nil { hovered = nil }
        } else if row != hovered {
            hovered = row
        }
    }

    override func removeFromSuperview() {
        super.removeFromSuperview()
        let close = onClose
        onClose = nil
        close?()
    }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    override func mouseDown(with event: NSEvent) {
        if !panel.frame.contains(convert(event.locationInWindow, from: nil)) { removeFromSuperview() }
    }

    override func rightMouseDown(with event: NSEvent) { removeFromSuperview() }

    override func mouseUp(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard let row = items.indices.first(where: { rowRect($0).contains(point) }), items[row].isEnabled else { return }
        let action = items[row].action
        removeFromSuperview()
        action()
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { removeFromSuperview() } else { super.keyDown(with: event) }
    }
}

/// The menu's panel: its background, border and shadow, and the rows over them.
@MainActor
final class ContextMenuPanel: FlippedView {
    var drawRows: (() -> Void)?

    override func draw(_ dirtyRect: NSRect) { drawRows?() }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

// MARK: - Inline title editing

/// Renaming a tab or a pane in place: a field over the title, saved on
/// Return or when it loses focus, abandoned on Escape. A tab's emptied title
/// is refused; a pane's clears its override.
@MainActor
enum TitleEditor {
    static func begin(tab: NodeID?, pane: NodeID?, in controller: WorkspaceWindowController, from view: NSView) {
        let theme = controller.appearance.theme
        let layout = controller.layout
        if let tab, let tabView = view as? TabView, let current = layout.trees.lazy.compactMap({ Tree.findTab($0, tab) }).first {
            let field = TitleField(
                text: current.tab.title, color: theme.text, surface: theme.surfaceNext(depth: tabView.depth), theme: theme
            ) { [weak controller, weak tabView] value in
                tabView?.editor = nil
                tabView?.needsDisplay = true
                guard let value, let controller, !value.isEmpty, value != current.tab.title else { return }
                controller.engine.perform(in: controller.windowID) { layout, titles in layout.renameTab(tab, value, titles: titles) }
            }
            tabView.editor = field
            let title = tabView.titleRect
            field.frame = CGRect(x: title.minX, y: title.minY + (title.height - 15) / 2 - 1, width: max(title.width, 40), height: 15)
            tabView.addSubview(field)
            field.focus()
            tabView.needsDisplay = true
        } else if let pane, let header = controller.paneView(pane)?.header, let node = layout.findNode(pane) {
            let field = TitleField(
                text: controller.paneTitle(of: node), color: theme.textDim, surface: header.surface, theme: theme
            ) { [weak controller, weak header] value in
                header?.editor = nil
                header?.needsDisplay = true
                guard let value, let controller else { return }
                controller.engine.perform(in: controller.windowID) { layout, titles in
                    layout.renamePane(pane, value.isEmpty ? nil : value, titles: titles)
                }
            }
            header.editor = field
            header.addSubview(field)
            header.needsLayout = true
            header.layoutSubtreeIfNeeded()
            let title = header.titleRect
            field.frame = CGRect(x: title.minX, y: (title.height - 15) / 2, width: title.width, height: 15)
            field.focus()
            header.needsDisplay = true
        }
    }
}

/// The editor's field: the chrome's font, a translucent wash, an accent border.
@MainActor
final class TitleField: FlippedView, NSTextFieldDelegate {
    private let field = NSTextField()
    private let done: @MainActor (String?) -> Void
    private var finished = false

    init(text: String, color: NSColor, surface: NSColor, theme: Theme, done: @escaping @MainActor (String?) -> Void) {
        self.done = done
        super.init(frame: .zero)
        layer?.backgroundColor = theme.hover(0.12).cgColor
        layer?.borderColor = theme.accent.cgColor
        layer?.borderWidth = 1
        layer?.cornerRadius = 2
        field.stringValue = text
        field.font = .systemFont(ofSize: Metrics.chromeFontSize)
        field.textColor = color
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.delegate = self
        field.cell?.isScrollable = true
        field.cell?.wraps = false
        addSubview(field)
    }

    // Resizing a field that is being edited ends the edit (AppKit reselects its
    // text through `endEditing(for:)`), so the field is sized before it takes
    // the keyboard and left alone by a pass that doesn't change its size.
    override func layout() {
        super.layout()
        let frame = CGRect(x: 2, y: 0, width: max(bounds.width - 4, 0), height: bounds.height)
        if field.frame != frame { field.frame = frame }
    }

    func focus() {
        layoutSubtreeIfNeeded()
        window?.makeFirstResponder(field)
        field.currentEditor()?.selectAll(nil)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if selector == #selector(NSResponder.insertNewline(_:)) {
            finish(save: true)
            return true
        }
        if selector == #selector(NSResponder.cancelOperation(_:)) {
            finish(save: false)
            return true
        }
        return false
    }

    func controlTextDidEndEditing(_ notification: Notification) { finish(save: true) }

    private func finish(save: Bool) {
        guard !finished else { return }
        finished = true
        let value = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        removeFromSuperview()
        done(save ? value : nil)
    }

    override func hitTest(_ point: NSPoint) -> NSView? { super.hitTest(point) }
}

// MARK: - The navigation flash

/// A brief chevron in the middle of the window showing which way keyboard
/// navigation went: 88pt, fading in and out over 350ms.
@MainActor
final class NavFlashView: FlippedView {
    private let direction: NavDirection
    private let theme: Theme

    init(direction: NavDirection, theme: Theme) {
        self.direction = direction
        self.theme = theme
        super.init(frame: CGRect(x: 0, y: 0, width: 88, height: 88))
        layer?.cornerRadius = 14
        layer?.borderWidth = 1
        layer?.borderColor = theme.border.cgColor
        layer?.backgroundColor = theme.bg.withAlphaComponent(0.78).cgColor
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.saveGState()
        context.translateBy(x: 44, y: 44)
        let angle: CGFloat =
            switch direction {
            case .right: 0
            case .down: 90
            case .left: 180
            case .up: 270
            }
        context.rotate(by: angle * .pi / 180)
        // M9 5l7 7-7 7 in a 24-unit box drawn at 40pt.
        let scale: CGFloat = 40 / 24
        context.scaleBy(x: scale, y: scale)
        context.translateBy(x: -12, y: -12)
        let path = NSBezierPath()
        path.move(to: CGPoint(x: 9, y: 5))
        path.line(to: CGPoint(x: 16, y: 12))
        path.line(to: CGPoint(x: 9, y: 19))
        path.lineWidth = 2.5
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        theme.text.setStroke()
        path.stroke()
        context.restoreGState()
    }

    static func flash(_ direction: NavDirection, in controller: WorkspaceWindowController) {
        for view in controller.root.overlay.subviews where view is NavFlashView { view.removeFromSuperview() }
        let flash = NavFlashView(direction: direction, theme: controller.appearance.theme)
        let bounds = controller.root.overlay.bounds
        flash.setFrameOrigin(CGPoint(x: bounds.midX - 44, y: bounds.midY - 44))
        controller.root.overlay.addSubview(flash)
        let fade = CAKeyframeAnimation(keyPath: "opacity")
        fade.values = [0, 0.9, 0.9, 0]
        fade.keyTimes = [0, 0.25, 0.6, 1]
        fade.duration = 0.35
        fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
        flash.layer?.opacity = 0
        flash.layer?.add(fade, forKey: "flash")
        Timer.scheduledTimer(withTimeInterval: 0.36, repeats: false) { [weak flash] _ in
            MainActor.assumeIsolated { flash?.removeFromSuperview() }
        }
    }
}
