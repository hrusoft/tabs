import AppKit
import TabsPluginSDK

/// A git tree pane's whole view (its toolbar is the header's title): one of
/// three states: "Reading history…", the branches sidebar and the list beside
/// it with the details below both (a divider between each), or a failure's
/// notice.
@MainActor
final class GitTreeView: GitFlippedView {
    unowned let pane: GitTreePane
    var toolbar: GitTreeToolbar { pane.toolbar }
    let listScroll = NSScrollView()
    let list: CommitListView
    let detailScroll = NSScrollView()
    let detail: CommitDetailView
    let divider: PanelDivider
    let sidebar: BranchSidebarView
    let sidebarDivider: PanelDivider
    let notice = GitTreeNoticeView()
    /// The app's color tokens, as core last told the pane.
    var theme: PaneTheme { didSet { if theme != oldValue { applyTheme() } } }

    init(pane: GitTreePane) {
        self.pane = pane
        theme = pane.pane.theme
        list = CommitListView(pane: pane)
        detail = CommitDetailView(pane: pane)
        divider = PanelDivider(pane: pane, panel: .details)
        sidebar = BranchSidebarView(pane: pane)
        sidebarDivider = PanelDivider(pane: pane, panel: .branches)
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
        addSubview(listScroll)
        addSubview(detailScroll)
        addSubview(sidebar)
        addSubview(notice)
        // The details' divider runs the body's width, over the sidebar's end.
        addSubview(sidebarDivider)
        addSubview(divider)
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
        let collapsed = pane.split.collapsed
        detailScroll.isHidden = state != .list || collapsed
        divider.isHidden = state != .list
        sidebar.isHidden = state != .list || pane.sidebar.collapsed
        sidebarDivider.isHidden = state != .list
        switch pane.log {
        case nil: notice.content = .loading
        case .failure(let error): notice.content = .failure(failureMessage(error.reason))
        case .success: break
        }
        sidebar.refresh()
        needsLayout = true
        list.needsDisplay = true
        detail.needsDisplay = true
        divider.needsDisplay = true
        sidebarDivider.needsDisplay = true
        notice.needsDisplay = true
        needsDisplay = true
    }

    private func applyTheme() {
        list.theme = theme
        detail.theme = theme
        divider.theme = theme
        sidebar.theme = theme
        sidebarDivider.theme = theme
        notice.theme = theme
        needsDisplay = true
    }

    // MARK: Focus

    var toolbarHasFocus: Bool { toolbar.isEditingPath }
    var sidebarHasFocus: Bool { sidebar.hasFocus }

    /// The list takes the keyboard whatever the pane shows: a pane activated
    /// while it's still reading (a new or restored one is, since git runs
    /// after it opens) has it when the rows land. Until then the list has no
    /// rows, and its keys move nothing.
    func focusList() {
        window?.makeFirstResponder(list)
    }

    // MARK: Layout

    /// Where the parts go, in this view's coordinates (fractional).
    struct Layout {
        var content: CGRect
        var list: CGRect?
        var divider: CGRect?
        var dividerCollapsed = false
        var detail: CGRect?
        /// The open sidebar's box (its right border included), beside the
        /// list and as tall; its divider (0 wide while open, the collapsed bar).
        var sidebar: CGRect?
        var sidebarDivider: CGRect?
        var sidebarCollapsed = false
    }

    func computeLayout() -> Layout {
        let width = bounds.width
        let content = CGRect(x: 0, y: 0, width: width, height: bounds.height)
        var layout = Layout(content: content)
        guard state == .list else { return layout }
        // The details take the bottom; the sidebar and the list share the rest.
        let split = pane.split
        let bandHeight: Double
        if split.collapsed {
            let dividerHeight = GitTreeMetrics.collapsedDividerThickness
            bandHeight = max(content.height - dividerHeight, 0)
            layout.divider = CGRect(x: 0, y: content.maxY - dividerHeight, width: width, height: dividerHeight)
            layout.dividerCollapsed = true
        } else {
            let detailHeight = split.fraction * content.height
            let detailTop = content.maxY - detailHeight
            bandHeight = detailTop
            layout.divider = CGRect(x: 0, y: detailTop, width: width, height: 0)
            layout.detail = CGRect(x: 0, y: detailTop, width: width, height: detailHeight)
        }
        let sidebar = pane.sidebar
        let listX: Double
        if sidebar.collapsed {
            listX = GitTreeMetrics.collapsedDividerThickness
            layout.sidebarDivider = CGRect(x: 0, y: 0, width: listX, height: bandHeight)
            layout.sidebarCollapsed = true
        } else {
            listX = shownSidebarWidth(sidebar, bodyWidth: width)
            layout.sidebar = CGRect(x: 0, y: 0, width: listX, height: bandHeight)
            layout.sidebarDivider = CGRect(x: listX, y: 0, width: 0, height: bandHeight)
        }
        layout.list = CGRect(x: listX, y: 0, width: max(width - listX, 0), height: bandHeight)
        return layout
    }

    override func layout() {
        super.layout()
        let layout = computeLayout()
        notice.frame = snapped(layout.content)
        if let listRect = layout.list {
            // The list clips at the whole point where the details' border starts.
            let bottom = layout.detail.map { snap($0.minY) } ?? snap(listRect.maxY)
            let x = snap(listRect.minX)
            let frame = CGRect(x: x, y: snap(listRect.minY), width: max(bounds.width - x, 0), height: max(bottom - snap(listRect.minY), 0))
            listScroll.frame = frame
            list.frame = CGRect(x: 0, y: 0, width: frame.width, height: max(list.contentHeight, frame.height))
            // The sidebar's rows end at the whole point where its right border starts.
            if let sidebarRect = layout.sidebar {
                sidebar.frame = CGRect(x: 0, y: frame.minY, width: max(snap(sidebarRect.maxX) - 1, 0), height: frame.height)
            }
        }
        if let dividerRect = layout.sidebarDivider {
            sidebarDivider.collapsed = layout.sidebarCollapsed
            sidebarDivider.layoutRect = dividerRect
            sidebarDivider.bodyRect = layout.content
            // The hit strip: 4 inside the sidebar (its border included) and 3
            // into the list; from a collapsed bar's left to 4 past its right.
            let thickness = GitTreeMetrics.collapsedDividerThickness
            sidebarDivider.frame =
                layout.sidebarCollapsed
                ? CGRect(x: 0, y: snap(dividerRect.minY), width: thickness + 4, height: listScroll.frame.height)
                : CGRect(x: snap(dividerRect.minX) - 4, y: snap(dividerRect.minY), width: 7, height: listScroll.frame.height)
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
                ? CGRect(x: 0, y: snap(dividerRect.minY) - 4, width: bounds.width, height: GitTreeMetrics.collapsedDividerThickness + 4)
                : CGRect(x: 0, y: snap(dividerRect.minY) - 3, width: bounds.width, height: 7)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        // The details' top border and the sidebar's right one (each the
        // divider's line while open).
        let layout = computeLayout()
        theme.border.setFill()
        if let detailRect = layout.detail {
            CGRect(x: 0, y: snap(detailRect.minY), width: bounds.width, height: 1).fill()
        }
        if let sidebarRect = layout.sidebar {
            CGRect(x: snap(sidebarRect.maxX) - 1, y: listScroll.frame.minY, width: 1, height: listScroll.frame.height).fill()
        }
    }
}

/// The notice in place of the list: "Reading history…", or a failure as a
/// sentence with the hint under it (padding 16, 12pt, paragraphs 6 apart).
@MainActor
final class GitTreeNoticeView: GitFlippedView {
    enum Content: Equatable {
        case loading
        case failure(String)
    }

    var content = Content.loading { didSet { needsDisplay = true } }
    var theme = PaneTheme.placeholder { didSet { needsDisplay = true } }

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
