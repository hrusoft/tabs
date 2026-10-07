import AppKit
import TabsPluginSDK

/// The divider between the commit list and the details: drag it to resize
/// them, below the details' minimum to collapse them, and back up from the
/// bottom to reopen them (rules in `DetailSplit.swift`).
///
/// Open, it takes no room: the line is the details' own top border, and this
/// is a 7pt hit strip over it. Collapsed, it's all that's left of the details:
/// an 8pt bar with a grip. Only the release is saved; every frame before it
/// is a preview. Pressing it never takes the keyboard from the list. A press a
/// core split separator claims is core's: core's separators sit above panes.
@MainActor
final class DetailDivider: GitFlippedView {
    unowned let pane: GitTreePane
    var theme = PaneTheme.dark { didSet { needsDisplay = true } }
    var collapsed = false { didSet { needsDisplay = true } }
    /// The divider's own box (0 tall while open), and the body it divides, in
    /// the pane view's coordinates.
    var layoutRect = CGRect.zero
    var bodyRect = CGRect.zero

    private struct Drag {
        var startY: Double
        /// How far the divider's top sat above the body's bottom when the drag
        /// began: the details' height, or the collapsed bar's.
        var startHeight: Double
        var bodyHeight: Double
        var origin: DetailSplit
        var latest: DetailSplit
    }

    private var drag: Drag?

    init(pane: GitTreePane) {
        self.pane = pane
        super.init(frame: .zero)
        setAccessibilityIdentifier("git-tree-divider")
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .resizeUpDown)
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        guard collapsed else { return }
        // The bar starts 4 below this view's top (the hit strip's overhang).
        let top = layoutRect.minY - frame.minY
        theme.border.setFill()
        CGRect(x: 0, y: snap(top + frame.minY) - frame.minY, width: bounds.width, height: 1).fill()
        // The grip: 24×2, centred in the bar's padding box (below the border).
        let grip = GitTreeMetrics.gripSize
        let center = CGPoint(x: layoutRect.midX, y: layoutRect.minY + 1 + (layoutRect.height - 1) / 2)
        let rect = snapped(CGRect(x: center.x - grip.width / 2, y: center.y - grip.height / 2, width: grip.width, height: grip.height))
            .offsetBy(dx: -frame.minX, dy: -frame.minY)
        theme.textDim.withAlphaComponent(0.6).setFill()
        NSBezierPath(roundedRect: rect, xRadius: 1, yRadius: 1).fill()
    }

    // MARK: Dragging

    /// The press: remembers where the gesture began. Returns whether it began.
    @discardableResult
    func begin(atY y: Double) -> Bool {
        guard drag == nil, bodyRect.height > 0 else { return false }
        let split = pane.split
        drag = Drag(startY: y, startHeight: bodyRect.maxY - layoutRect.minY, bodyHeight: bodyRect.height, origin: split, latest: split)
        return true
    }

    /// A move to `y` (pane view coordinates, y down): previews the new split.
    func move(toY y: Double) {
        guard var current = drag else { return }
        let next = resolveDetailDrag(
            detailHeight: current.startHeight + current.startY - y, bodyHeight: current.bodyHeight, previous: current.origin)
        guard next != current.latest else { return }
        current.latest = next
        drag = current
        pane.previewSplit(next)
    }

    /// The release: saves where it was last shown.
    func finish() {
        guard let current = drag else { return }
        drag = nil
        pane.commitSplit(current.latest)
    }

    private func paneY(_ event: NSEvent) -> Double {
        guard let root = superview else { return 0 }
        return root.convert(event.locationInWindow, from: nil).y
    }

    override func mouseDown(with event: NSEvent) {
        begin(atY: paneY(event))
    }

    override func mouseDragged(with event: NSEvent) {
        // A move with the button no longer down (a release this view never
        // saw) ends the drag where it was last shown.
        if NSEvent.pressedMouseButtons & 1 == 0 {
            finish()
            return
        }
        move(toY: paneY(event))
    }

    override func mouseUp(with event: NSEvent) { finish() }
}
