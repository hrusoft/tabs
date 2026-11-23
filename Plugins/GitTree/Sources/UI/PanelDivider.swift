import AppKit
import TabsPluginSDK

/// A divider beside a panel of the body: the one between the commit list and
/// the details below it, and the one between the branches sidebar and the
/// list right of it. Drag it to resize the panel, below the panel's minimum to
/// collapse it, and back out from the edge to reopen it (rules in
/// `DetailSplit.swift`, `SidebarSplit.swift`; the pane resolves them).
///
/// Open, it takes no room: the line is the panel's own border (the details'
/// top, the sidebar's right), and this is a 7pt hit strip over it. Collapsed,
/// it's all that's left of the panel: an 8pt bar with a grip. Only the release
/// is saved; every frame before it is a preview. Pressing it never takes the
/// keyboard from the list. A press a core split separator claims is core's:
/// core's separators sit above panes.
@MainActor
final class PanelDivider: GitFlippedView {
    unowned let pane: GitTreePane
    let panel: GitTreePanel
    var theme = PaneTheme.placeholder { didSet { needsDisplay = true } }
    var collapsed = false { didSet { needsDisplay = true } }
    /// The divider's own box (0 thick while open), and the body it divides, in
    /// the pane view's coordinates.
    var layoutRect = CGRect.zero
    var bodyRect = CGRect.zero

    private struct Drag {
        /// Where the press was, along the drag.
        var start: Double
        /// The panel's length when the drag began (the details' height, the
        /// sidebar's width, or the collapsed bar's), and the body's.
        var startLength: Double
        var bodyLength: Double
    }

    private var drag: Drag?

    init(pane: GitTreePane, panel: GitTreePanel) {
        self.pane = pane
        self.panel = panel
        super.init(frame: .zero)
        setAccessibilityIdentifier(panel == .details ? "git-tree-divider" : "git-tree-branches-divider")
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: panel == .details ? .resizeUpDown : .resizeLeftRight)
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        guard collapsed else { return }
        // The bar's border faces the list: the details' on its top (4 below
        // this view's top, the hit strip's overhang), the sidebar's on its right.
        let bar = layoutRect
        theme.border.setFill()
        let border =
            panel == .details
            ? CGRect(x: 0, y: snap(bar.minY), width: bounds.width, height: 1)
            : CGRect(x: snap(bar.maxX) - 1, y: snap(bar.minY), width: 1, height: snap(bar.maxY) - snap(bar.minY))
        border.offsetBy(dx: panel == .details ? 0 : -frame.minX, dy: -frame.minY).fill()
        // The grip: 24 long, 2 thick, along the bar, centred in its padding
        // box (inside the border).
        let grip = GitTreeMetrics.gripSize
        let rect: CGRect
        if panel == .details {
            let center = CGPoint(x: bar.midX, y: bar.minY + 1 + (bar.height - 1) / 2)
            rect = CGRect(x: center.x - grip.width / 2, y: center.y - grip.height / 2, width: grip.width, height: grip.height)
        } else {
            let center = CGPoint(x: bar.minX + (bar.width - 1) / 2, y: bar.midY)
            rect = CGRect(x: center.x - grip.height / 2, y: center.y - grip.width / 2, width: grip.height, height: grip.width)
        }
        theme.textDim.withAlphaComponent(0.6).setFill()
        NSBezierPath(roundedRect: snapped(rect).offsetBy(dx: -frame.minX, dy: -frame.minY), xRadius: 1, yRadius: 1).fill()
    }

    // MARK: Dragging

    /// The press at `position` (pane view coordinates, along the drag: y for
    /// the details, x for the sidebar): remembers where the gesture began.
    /// Returns whether it began.
    @discardableResult
    func begin(at position: Double) -> Bool {
        let bodyLength = panel == .details ? bodyRect.height : bodyRect.width
        guard drag == nil, bodyLength > 0 else { return false }
        // How far the divider sat from the panel's far edge: the details grow
        // up from the body's bottom, the sidebar right from its left.
        let startLength = panel == .details ? bodyRect.maxY - layoutRect.minY : layoutRect.maxX - bodyRect.minX
        drag = Drag(start: position, startLength: startLength, bodyLength: bodyLength)
        pane.beginResize(panel)
        return true
    }

    /// A move to `position`: previews the new split.
    func move(to position: Double) {
        guard let drag else { return }
        let moved = position - drag.start
        pane.resize(panel, toLength: drag.startLength + (panel == .details ? -moved : moved), bodyLength: drag.bodyLength)
    }

    /// The release: saves where it was last shown.
    func finish() {
        guard drag != nil else { return }
        drag = nil
        pane.endResize(panel)
    }

    private func position(_ event: NSEvent) -> Double {
        guard let root = superview else { return 0 }
        let point = root.convert(event.locationInWindow, from: nil)
        return panel == .details ? point.y : point.x
    }

    override func mouseDown(with event: NSEvent) {
        begin(at: position(event))
    }

    override func mouseDragged(with event: NSEvent) {
        // A move with the button no longer down (a release this view never
        // saw) ends the drag where it was last shown.
        if NSEvent.pressedMouseButtons & 1 == 0 {
            finish()
            return
        }
        move(to: position(event))
    }

    override func mouseUp(with event: NSEvent) { finish() }
}
