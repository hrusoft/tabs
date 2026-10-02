import AppKit
import TabsPluginSDK

/// Where everything in one row goes: `.git-tree-row`'s flex layout (gap 8,
/// padding 0 8 0 6, items centred in 24), in the row's own coordinates.
struct CommitRowLayout {
    struct Pill {
        var rect: CGRect
        var text: String
        var textX: Double
    }

    var gutter: CGRect
    var hash: CGRect
    var hashText: String
    var hashBaseline: Double
    var subject: CGRect
    var subjectBaseline: Double
    var pills: [Pill]
    /// The subject text as drawn (cut with an ellipsis when it doesn't fit),
    /// where it starts, and whether it was cut.
    var subjectText: String
    var subjectTextX: Double
    var truncated: Bool
    var author: CGRect?
    var authorText: String?
    var date: CGRect?
    var dateText: String?
    /// Author and date share the 11px line box.
    var smallBaseline: Double

    static let ellipsis = "…"

    init(row: GraphRow, laneCount: Int, width: Double, showAuthor: Bool, showDate: Bool, isHead: Bool) {
        let height = GitTreeMetrics.rowHeight
        let content = width - GitTreeMetrics.rowPaddingLeft - GitTreeMetrics.rowPaddingRight
        let phantom = row.commit.hash == uncommittedChangesHash
        let subjectFont = phantom ? GitText.italic12 : GitText.ui12
        let mono = GitText.mono11
        let small = GitText.ui11
        let pillFont = GitText.ui10

        let gutterWidth = Double(max(laneCount, 1)) * GitTreeMetrics.laneWidth
        hashText = shortHash(row.commit.hash)
        let hashWidth = mono.width(hashText)
        authorText = showAuthor ? row.commit.author : nil
        dateText = showDate ? formatDate(row.commit.date) : nil
        // `max-width: 20%` of the row's content box.
        let authorWidth = authorText.map { min(small.width($0), 0.2 * content) }
        let dateWidth = dateText.map { small.width($0) }
        let items = 3 + (showAuthor ? 1 : 0) + (showDate ? 1 : 0)
        let fixed = gutterWidth + hashWidth + (authorWidth ?? 0) + (dateWidth ?? 0) + Double(items - 1) * GitTreeMetrics.rowGap
        let subjectWidth = max(content - fixed, 0)

        var x = GitTreeMetrics.rowPaddingLeft
        gutter = CGRect(x: x, y: 0, width: gutterWidth, height: height)
        x += gutterWidth + GitTreeMetrics.rowGap
        // An empty span (the working-tree row's hash) is 0 tall.
        let hashHeight = hashText.isEmpty ? 0 : mono.lineHeight
        hash = CGRect(x: x, y: (height - hashHeight) / 2, width: hashWidth, height: hashHeight)
        hashBaseline = hash.minY + mono.ascent
        x += hashWidth + GitTreeMetrics.rowGap

        // The subject's line box holds its own text and the ref pills: each
        // an inline-block 16 tall (a 14 line box and its border) whose
        // baseline is its text's, raised 1 (`vertical-align: 1px`).
        let strutTop = -subjectFont.ascent
        let strutBottom = subjectFont.descent
        let pillBaselineInside = 1 + pillFont.halfLeading(in: GitTreeMetrics.pillLineHeight) + pillFont.ascent
        let pillTop = -1 - pillBaselineInside
        let pillHeight = GitTreeMetrics.pillLineHeight + 2
        let top = row.commit.refs.isEmpty ? strutTop : min(strutTop, pillTop)
        let bottom = row.commit.refs.isEmpty ? strutBottom : max(strutBottom, pillTop + pillHeight)
        let subjectHeight = bottom - top
        subject = CGRect(x: x, y: (height - subjectHeight) / 2, width: subjectWidth, height: subjectHeight)
        subjectBaseline = subject.minY - top

        // Pills then text, cut as `text-overflow: ellipsis` cuts a line: what
        // doesn't fit before the ellipsis is left out.
        let ellipsisWidth = subjectFont.width(Self.ellipsis)
        var pills: [Pill] = []
        var cursor = x
        let limit = x + subjectWidth
        var cut = false
        let textWidth = subjectFont.width(row.commit.subject)
        let pillWidths = row.commit.refs.map { pillFont.width($0) + 2 * GitTreeMetrics.pillPadding + 2 }
        let natural =
            pillWidths.reduce(0) { $0 + $1 + GitTreeMetrics.pillMarginRight } + textWidth
        if natural > subjectWidth + 0.01 { cut = true }
        for (ref, pillWidth) in zip(row.commit.refs, pillWidths) {
            let end = cursor + pillWidth
            if cut && end > limit - ellipsisWidth + 0.01 { break }
            pills.append(
                Pill(
                    rect: CGRect(x: cursor, y: subjectBaseline - 1 - pillBaselineInside, width: pillWidth, height: pillHeight),
                    text: ref, textX: cursor + 1 + GitTreeMetrics.pillPadding))
            cursor = end + GitTreeMetrics.pillMarginRight
        }
        self.pills = pills
        subjectTextX = cursor
        if cut {
            let room = limit - cursor
            if pills.count < row.commit.refs.count || room < ellipsisWidth {
                subjectText = Self.ellipsis
            } else {
                subjectText = subjectFont.truncated(row.commit.subject, to: room)
            }
        } else {
            subjectText = row.commit.subject
        }
        truncated = cut
        x += subjectWidth + GitTreeMetrics.rowGap

        let smallTop = (height - small.lineHeight) / 2
        smallBaseline = smallTop + small.ascent
        if let authorWidth {
            author = CGRect(x: x, y: smallTop, width: authorWidth, height: small.lineHeight)
            x += authorWidth + GitTreeMetrics.rowGap
        }
        if let dateWidth {
            date = CGRect(x: x, y: smallTop, width: dateWidth, height: small.lineHeight)
        }
    }
}

/// The commit list: one 24pt row per commit with its slice of the lane gutter
/// (`CommitRow.tsx`, `GitGraph.tsx`), and Load more under the rows. The list
/// keeps the keyboard as a whole; the selected row is the pane's selection.
@MainActor
final class CommitListView: GitFlippedView {
    unowned let pane: GitTreePane
    private var hoveredRow: Int?
    private var hoveringLoadMore = false
    private var trackingArea: NSTrackingArea?
    /// Where the rows sit in the pane view's coordinates, before scrolling
    /// (fractional origin for text baselines).
    var theme = PaneTheme.dark { didSet { needsDisplay = true } }
    /// Tells the pane view to redraw its focus ring.
    var onFocusChange: (() -> Void)?

    init(pane: GitTreePane) {
        self.pane = pane
        super.init(frame: .zero)
        setAccessibilityIdentifier("git-tree-list")
        setAccessibilityRole(.list)
        setAccessibilityLabel("Commits")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    var rowCount: Int { pane.graph.rows.count }
    var showsLoadMore: Bool {
        if case .success(let log) = pane.log { log.hasMore } else { false }
    }

    /// The Load more button's box: `display: block`, 100% − 16 wide, margin 6 8,
    /// padding 4, a 1pt border around an 11px line.
    var loadMoreRect: CGRect? {
        guard showsLoadMore else { return nil }
        let height = 2 * GitTreeMetrics.loadMorePadding + 2 + GitText.ui11.lineHeight
        return CGRect(
            x: GitTreeMetrics.loadMoreMargin.horizontal,
            y: Double(rowCount) * GitTreeMetrics.rowHeight + GitTreeMetrics.loadMoreMargin.vertical,
            width: bounds.width - 2 * GitTreeMetrics.loadMoreMargin.horizontal, height: height)
    }

    /// The document's height: the rows, and Load more with its margins.
    var contentHeight: Double {
        let rows = Double(rowCount) * GitTreeMetrics.rowHeight
        guard let loadMore = loadMoreRect else { return rows }
        return loadMore.maxY + GitTreeMetrics.loadMoreMargin.vertical
    }

    func rowRect(_ index: Int) -> CGRect {
        CGRect(x: 0, y: Double(index) * GitTreeMetrics.rowHeight, width: bounds.width, height: GitTreeMetrics.rowHeight)
    }

    func layout(ofRow index: Int) -> CommitRowLayout {
        let row = pane.graph.rows[index]
        return CommitRowLayout(
            row: row, laneCount: pane.graph.laneCount, width: bounds.width, showAuthor: pane.showAuthor, showDate: pane.showDate,
            isHead: row.commit.refs.contains("HEAD"))
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let rows = pane.graph.rows
        let first = max(Int(dirtyRect.minY / GitTreeMetrics.rowHeight), 0)
        let last = min(Int(dirtyRect.maxY / GitTreeMetrics.rowHeight), rows.count - 1)
        if first <= last {
            for index in first...last {
                let rect = rowRect(index)
                context.saveGState()
                context.translateBy(x: 0, y: rect.minY)
                drawRow(index, in: context)
                context.restoreGState()
            }
        }
        if let loadMore = loadMoreRect, loadMore.intersects(dirtyRect) { drawLoadMore(loadMore) }
    }

    private func drawRow(_ index: Int, in context: CGContext) {
        let row = pane.graph.rows[index]
        let phantom = row.commit.hash == uncommittedChangesHash
        let selected = row.commit.hash == pane.selectedHash
        let layout = layout(ofRow: index)
        // The phantom row composites as a group at 0.6, gutter included.
        if phantom {
            context.setAlpha(0.6)
            context.beginTransparencyLayer(auxiliaryInfo: nil)
        }
        let box = CGRect(x: 0, y: 0, width: bounds.width, height: GitTreeMetrics.rowHeight)
        if selected {
            theme.selection.setFill()
            box.fill()
        } else if hoveredRow == index && !phantom {
            theme.hover(0.08).setFill()
            box.fill()
        }
        drawGutter(row, in: layout.gutter, selected: selected, isHead: row.commit.refs.contains("HEAD"), context: context)
        GitText.mono11.draw(layout.hashText, at: CGPoint(x: layout.hash.minX, y: layout.hashBaseline), color: theme.textDim)
        let isHead = row.commit.refs.contains("HEAD")
        for pill in layout.pills {
            let rect = snapped(pill.rect)
            let path = NSBezierPath(
                roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: GitTreeMetrics.pillRadius - 0.5,
                yRadius: GitTreeMetrics.pillRadius - 0.5)
            if isHead {
                theme.accent.setFill()
                NSBezierPath(roundedRect: rect, xRadius: GitTreeMetrics.pillRadius, yRadius: GitTreeMetrics.pillRadius).fill()
            }
            theme.accent.setStroke()
            path.lineWidth = 1
            path.stroke()
            GitText.ui10.draw(
                pill.text, at: CGPoint(x: pill.textX, y: layout.subjectBaseline - 1), color: isHead ? theme.onAccent : theme.accent)
        }
        let subjectFont = phantom ? GitText.italic12 : GitText.ui12
        context.saveGState()
        context.clip(to: CGRect(x: layout.subject.minX, y: 0, width: layout.subject.width, height: GitTreeMetrics.rowHeight))
        subjectFont.draw(layout.subjectText, at: CGPoint(x: layout.subjectTextX, y: layout.subjectBaseline), color: theme.text)
        context.restoreGState()
        if let author = layout.author, let text = layout.authorText {
            GitText.ui11.draw(text, at: CGPoint(x: author.minX, y: layout.smallBaseline), color: theme.textDim, maxWidth: author.width)
        }
        if let date = layout.date, let text = layout.dateText {
            GitText.ui11.draw(text, at: CGPoint(x: date.minX, y: layout.smallBaseline), color: theme.textDim)
        }
        if phantom { context.endTransparencyLayer() }
    }

    /// One row's slice of the gutter: lines passing by first, then the
    /// commit's own edges, then its dot (and HEAD's ring) on top.
    private func drawGutter(_ row: GraphRow, in rect: CGRect, selected: Bool, isHead: Bool, context: CGContext) {
        // An SVG paints at a whole point.
        let origin = CGPoint(x: snap(rect.minX), y: snap(rect.minY))
        let height = GitTreeMetrics.rowHeight
        let centerY = height / 2
        func laneX(_ lane: Int) -> Double { Double(lane) * GitTreeMetrics.laneWidth + GitTreeMetrics.laneWidth / 2 }
        func curve(_ from: Int, _ to: Int, _ fromY: Double, _ toY: Double, color: NSColor) {
            let x1 = laneX(from)
            let x2 = laneX(to)
            let mid = (fromY + toY) / 2
            let path = NSBezierPath()
            path.move(to: CGPoint(x: origin.x + x1, y: origin.y + fromY))
            path.curve(
                to: CGPoint(x: origin.x + x2, y: origin.y + toY), controlPoint1: CGPoint(x: origin.x + x1, y: origin.y + mid),
                controlPoint2: CGPoint(x: origin.x + x2, y: origin.y + mid))
            path.lineWidth = GitTreeMetrics.lineWidth
            color.setStroke()
            path.stroke()
        }
        for lane in row.through { curve(lane, lane, 0, height, color: GitTreeColors.lane(lane)) }
        for from in row.incoming { curve(from, row.lane, 0, centerY, color: GitTreeColors.lane(from)) }
        for to in row.outgoing { curve(row.lane, to, centerY, height, color: GitTreeColors.lane(to)) }
        let color = GitTreeColors.lane(row.lane)
        let center = CGPoint(x: origin.x + laneX(row.lane), y: origin.y + centerY)
        let r = GitTreeMetrics.dotRadius
        let dot = NSBezierPath(ovalIn: CGRect(x: center.x - r, y: center.y - r, width: 2 * r, height: 2 * r))
        (selected ? color : theme.bg).setFill()
        dot.fill()
        dot.lineWidth = GitTreeMetrics.lineWidth
        color.setStroke()
        dot.stroke()
        if isHead {
            let ring = GitTreeMetrics.headRingRadius
            let path = NSBezierPath(ovalIn: CGRect(x: center.x - ring, y: center.y - ring, width: 2 * ring, height: 2 * ring))
            path.lineWidth = GitTreeMetrics.lineWidth
            path.stroke()
        }
    }

    private func drawLoadMore(_ rect: CGRect) {
        let box = snapped(rect)
        if hoveringLoadMore {
            theme.hover(0.12).setFill()
            NSBezierPath(roundedRect: box, xRadius: 3, yRadius: 3).fill()
        }
        theme.border.setStroke()
        let border = NSBezierPath(roundedRect: box.insetBy(dx: 0.5, dy: 0.5), xRadius: 2.5, yRadius: 2.5)
        border.lineWidth = 1
        border.stroke()
        let font = GitText.ui11
        let text = "Load more"
        let x = rect.minX + (rect.width - font.width(text)) / 2
        let baseline = rect.minY + 1 + GitTreeMetrics.loadMorePadding + font.ascent
        font.draw(text, at: CGPoint(x: x, y: baseline), color: hoveringLoadMore ? theme.text : theme.textDim)
    }

    // MARK: Input

    override var acceptsFirstResponder: Bool { true }

    /// Whether the list shows its focus ring (`:focus-visible`): focused
    /// from the keyboard (pane navigation), not by a click.
    private(set) var showsFocusRing = false

    override func becomeFirstResponder() -> Bool {
        showsFocusRing = NSApplication.shared.currentEvent?.type == .keyDown
        onFocusChange?()
        return true
    }

    override func resignFirstResponder() -> Bool {
        onFocusChange?()
        return true
    }

    func rowIndex(at point: CGPoint) -> Int? {
        let index = Int((point.y / GitTreeMetrics.rowHeight).rounded(.down))
        return point.y >= 0 && index < rowCount ? index : nil
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if let loadMore = loadMoreRect, loadMore.contains(point) {
            pane.loadMore()
            return
        }
        window?.makeFirstResponder(self)
        guard let index = rowIndex(at: point) else { return }
        let hash = pane.graph.rows[index].commit.hash
        pane.select(hash)
        // The working-tree row has nothing to check out.
        if event.clickCount == 2 && hash != uncommittedChangesHash {
            Task { await pane.checkout(hash) }
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard let index = rowIndex(at: point) else { return }
        openMenu(forRow: index, at: point)
    }

    /// Right-click: selects the row it opens on (so the details show the commit
    /// the menu acts on), then Checkout and Copy SHA-1, both acting on that row,
    /// never on a selection made since. None on the working-tree row.
    func openMenu(forRow index: Int, at point: CGPoint) {
        let hash = pane.graph.rows[index].commit.hash
        guard hash != uncommittedChangesHash else { return }
        pane.select(hash)
        pane.pane.showContextMenu(commitItems(for: hash), at: point, in: self)
    }

    /// The row menu's items: core draws them.
    func commitItems(for hash: String) -> [PaneMenuItem] {
        [
            PaneMenuItem("Checkout") { [weak pane] in
                guard let pane else { return }
                Task { await pane.checkout(hash) }
            },
            PaneMenuItem("Copy SHA-1") { [weak pane] in pane?.copyHash(hash) },
        ]
    }

    override func keyDown(with event: NSEvent) {
        // Cursor keys by key, not by physical position: the same meaning on
        // every layout. Anything else goes on up (the app's pane navigation).
        let moved: Int?
        switch event.specialKey {
        case .downArrow?: moved = pane.moveSelection(1)
        case .upArrow?: moved = pane.moveSelection(-1)
        case .home?: moved = pane.moveSelection(-pane.commits.count)
        case .end?: moved = pane.moveSelection(pane.commits.count)
        default:
            super.keyDown(with: event)
            return
        }
        if let moved { scrollToVisibleNearest(moved) }
    }

    /// Keeps the moved-to row on screen by the least scroll (`block: 'nearest'`).
    func scrollToVisibleNearest(_ index: Int) {
        scrollToVisible(rowRect(index))
    }

    // MARK: Hover

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseMoved(with event: NSEvent) { hover(at: convert(event.locationInWindow, from: nil)) }
    override func mouseEntered(with event: NSEvent) { hover(at: convert(event.locationInWindow, from: nil)) }
    override func mouseExited(with event: NSEvent) { hover(at: nil) }

    func hover(at point: CGPoint?) {
        let row = point.flatMap(rowIndex(at:))
        let loadMore = point.map { loadMoreRect?.contains($0) ?? false } ?? false
        guard row != hoveredRow || loadMore != hoveringLoadMore else { return }
        hoveredRow = row
        hoveringLoadMore = loadMore
        needsDisplay = true
    }
}
