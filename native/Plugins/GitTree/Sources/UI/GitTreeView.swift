import AppKit
import TabsPluginSDK

/// A git tree pane's whole view (its toolbar is the header's title): one of three states
/// (`GitTreeRenderer.tsx`): "Reading history…", the list and details with the
/// divider between them, or a failure's notice.
@MainActor
final class GitTreeView: GitFlippedView {
    unowned let pane: GitTreePane
    var toolbar: GitTreeToolbar { pane.toolbar }
    let listScroll = NSScrollView()
    let list: CommitListView
    let focusRing = ListFocusRing()
    let detailScroll = NSScrollView()
    let detail: CommitDetailView
    let divider: DetailDivider
    let notice = GitTreeNoticeView()
    /// The app's color tokens, as core last told the pane.
    var theme: PaneTheme { didSet { if theme != oldValue { applyTheme() } } }

    init(pane: GitTreePane) {
        self.pane = pane
        theme = pane.pane.theme
        list = CommitListView(pane: pane)
        detail = CommitDetailView(pane: pane)
        divider = DetailDivider(pane: pane)
        super.init(frame: .zero)
        setAccessibilityIdentifier("git-tree")
        for scroll in [listScroll, detailScroll] {
            scroll.drawsBackground = false
            scroll.hasVerticalScroller = true
            scroll.hasHorizontalScroller = false
            scroll.scrollerStyle = .overlay
            scroll.autohidesScrollers = true
            scroll.borderType = .noBorder
            scroll.contentView.drawsBackground = false
        }
        listScroll.documentView = list
        detailScroll.documentView = detail
        list.onFocusChange = { [weak self] in self?.focusRing.needsDisplay = true }
        addSubview(focusRing)
        addSubview(listScroll)
        addSubview(detailScroll)
        addSubview(notice)
        addSubview(divider)
        focusRing.list = list
        pane.onChange = { [weak self] in self?.refresh() }
        applyTheme()
        refresh()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    // MARK: State

    enum State { case loading, list, notice }

    var state: State {
        switch pane.log {
        case nil: .loading
        case .success: .list
        case .failure: .notice
        }
    }

    func refresh() {
        toolbar.refresh()
        let state = state
        notice.isHidden = state == .list
        listScroll.isHidden = state != .list
        focusRing.isHidden = state != .list
        let collapsed = pane.split.collapsed
        detailScroll.isHidden = state != .list || collapsed
        divider.isHidden = state != .list
        switch pane.log {
        case nil: notice.content = .loading
        case .failure(let error): notice.content = .failure(failureMessage(error.reason))
        case .success: break
        }
        needsLayout = true
        list.needsDisplay = true
        detail.needsDisplay = true
        divider.needsDisplay = true
        notice.needsDisplay = true
        needsDisplay = true
    }

    private func applyTheme() {
        list.theme = theme
        detail.theme = theme
        divider.theme = theme
        notice.theme = theme
        focusRing.theme = theme
        needsDisplay = true
    }

    // MARK: Focus

    var toolbarHasFocus: Bool { toolbar.isEditingPath }

    func focusList() {
        guard state == .list else { return }
        window?.makeFirstResponder(list)
    }

    // MARK: Layout

    /// Where the parts go, in this view's coordinates (fractional, as the page
    /// lays them out).
    struct Layout {
        var content: CGRect
        var list: CGRect?
        var divider: CGRect?
        var dividerCollapsed = false
        var detail: CGRect?
    }

    func computeLayout() -> Layout {
        let width = bounds.width
        let content = CGRect(x: 0, y: 0, width: width, height: bounds.height)
        var layout = Layout(content: content)
        guard state == .list else { return layout }
        let split = pane.split
        if split.collapsed {
            let dividerHeight = GitTreeMetrics.collapsedDividerHeight
            layout.list = CGRect(x: 0, y: 0, width: width, height: max(content.height - dividerHeight, 0))
            layout.divider = CGRect(x: 0, y: content.maxY - dividerHeight, width: width, height: dividerHeight)
            layout.dividerCollapsed = true
        } else {
            let detailHeight = split.fraction * content.height
            let detailTop = content.maxY - detailHeight
            layout.list = CGRect(x: 0, y: 0, width: width, height: detailTop)
            layout.divider = CGRect(x: 0, y: detailTop, width: width, height: 0)
            layout.detail = CGRect(x: 0, y: detailTop, width: width, height: detailHeight)
        }
        return layout
    }

    override func layout() {
        super.layout()
        let layout = computeLayout()
        notice.frame = snapped(layout.content)
        if let listRect = layout.list {
            // The list clips at the whole point where the details' border starts.
            let bottom = layout.detail.map { snap($0.minY) } ?? snap(listRect.maxY)
            let frame = CGRect(x: 0, y: snap(listRect.minY), width: bounds.width, height: max(bottom - snap(listRect.minY), 0))
            listScroll.frame = frame
            focusRing.frame = frame
            list.frame = CGRect(x: 0, y: 0, width: frame.width, height: max(list.contentHeight, frame.height))
        }
        if let detailRect = layout.detail {
            let borderTop = snap(detailRect.minY)
            detailScroll.frame = CGRect(x: 0, y: borderTop + 1, width: bounds.width, height: max(snap(detailRect.maxY) - borderTop - 1, 0))
            // Detail layout is relative to its border box; the document starts below the border.
            detail.fractionalOffset = (detailRect.minY - borderTop) - 1
            let height = detail.layout(width: bounds.width).height + detail.fractionalOffset
            detail.frame = CGRect(x: 0, y: 0, width: bounds.width, height: max(height, detailScroll.frame.height))
        }
        if let dividerRect = layout.divider {
            divider.collapsed = layout.dividerCollapsed
            divider.layoutRect = dividerRect
            divider.bodyRect = layout.content
            // The hit strip: 3 above and 4 below an open divider's line; from 4
            // above a collapsed one to its bottom.
            divider.frame =
                layout.dividerCollapsed
                ? CGRect(x: 0, y: snap(dividerRect.minY) - 4, width: bounds.width, height: GitTreeMetrics.collapsedDividerHeight + 4)
                : CGRect(x: 0, y: snap(dividerRect.minY) - 3, width: bounds.width, height: 7)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        // The details' top border (the divider's line while open).
        let layout = computeLayout()
        if let detailRect = layout.detail {
            theme.border.setFill()
            CGRect(x: 0, y: snap(detailRect.minY), width: bounds.width, height: 1).fill()
        }
    }
}

/// The list's keyboard-focus ring: an inset 1pt accent line along the list's
/// edge (`.git-tree-list:focus-visible`), under the rows, as a box-shadow is.
@MainActor
final class ListFocusRing: GitFlippedView {
    weak var list: CommitListView?
    var theme = PaneTheme.dark { didSet { needsDisplay = true } }

    override func draw(_ dirtyRect: NSRect) {
        guard let list, list.window?.firstResponder === list, list.showsFocusRing else { return }
        theme.accent.setStroke()
        let path = NSBezierPath(rect: bounds.insetBy(dx: 0.5, dy: 0.5))
        path.lineWidth = 1
        path.stroke()
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// The notice in place of the list: "Reading history…", or a failure as a
/// sentence with the hint under it (`.git-tree-notice`: padding 16, 12px,
/// paragraphs 6 apart).
@MainActor
final class GitTreeNoticeView: GitFlippedView {
    enum Content: Equatable {
        case loading
        case failure(String)
    }

    var content = Content.loading { didSet { needsDisplay = true } }
    var theme = PaneTheme.dark { didSet { needsDisplay = true } }

    /// The hint under a failure (E-6): names the toolbar's folder button.
    static let hint = "Type a directory above, or use the folder button to choose one."

    struct Line {
        var text: String
        var box: CGRect
        var baseline: Double
        var dim: Bool
    }

    /// Each paragraph's lines, as laid out for `width`.
    func lines(width: Double) -> [[Line]] {
        let font = GitText.ui12
        let padding = GitTreeMetrics.noticePadding
        let textWidth = max(width - 2 * padding, 0)
        var y = padding
        func paragraph(_ text: String, dim: Bool, gapAfter: Double) -> [Line] {
            var lines: [Line] = []
            for line in font.wrap(text, width: textWidth) {
                lines.append(
                    Line(
                        text: line, box: CGRect(x: padding, y: y, width: font.width(line), height: font.lineHeight),
                        baseline: y + font.ascent, dim: dim))
                y += font.lineHeight
            }
            y += gapAfter
            return lines
        }
        switch content {
        case .loading: return [paragraph("Reading history…", dim: false, gapAfter: 0)]
        case .failure(let message):
            return [
                paragraph(message, dim: false, gapAfter: GitTreeMetrics.noticeParagraphGap), paragraph(Self.hint, dim: true, gapAfter: 0),
            ]
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        for paragraph in lines(width: bounds.width) {
            for line in paragraph {
                GitText.ui12.draw(
                    line.text, at: CGPoint(x: line.box.minX, y: line.baseline), color: line.dim ? theme.textDim : theme.text)
            }
        }
    }
}
