import AppKit
import TabsPluginSDK

/// The branches sidebar, left of the commit list: every branch and tag as a
/// tree under its source (Local, each remote, Tags), names split at `/` into
/// folders. AppKit's own outline view (rows, disclosure triangles, keys, type
/// select) in the pane's colors. The pane holds what's open and selected; this
/// shows it and reports what the user does.
@MainActor
final class BranchSidebarView: GitFlippedView, NSOutlineViewDataSource, NSOutlineViewDelegate {
    unowned let pane: GitTreePane
    let scroll = NSScrollView()
    let outline = BranchOutlineView()
    var theme = PaneTheme.placeholder {
        didSet {
            guard theme != oldValue else { return }
            reloadRows()
            needsDisplay = true
        }
    }

    private var roots: [BranchItem] = []
    private var items: [String: BranchItem] = [:]
    private var shownRevision: Int?
    /// While the view itself opens, closes or selects rows to show the
    /// pane's state: the outline's notifications are then its own, not the user's.
    private var applying = false

    init(pane: GitTreePane) {
        self.pane = pane
        super.init(frame: .zero)
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("branch"))
        column.resizingMask = .autoresizingMask
        outline.addTableColumn(column)
        outline.outlineTableColumn = column
        outline.headerView = nil
        outline.style = .plain
        outline.rowSizeStyle = .custom
        outline.rowHeight = GitTreeMetrics.branchRowHeight
        outline.intercellSpacing = .zero
        outline.backgroundColor = .clear
        outline.focusRingType = .none
        outline.allowsMultipleSelection = false
        outline.allowsEmptySelection = true
        outline.autoresizesOutlineColumn = false
        outline.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        outline.dataSource = self
        outline.delegate = self
        outline.target = self
        outline.doubleAction = #selector(doubleClicked(_:))
        outline.sidebar = self
        outline.setAccessibilityIdentifier("git-tree-branches")
        outline.setAccessibilityLabel("Branches")
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.scrollerStyle = .overlay
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.contentView.drawsBackground = false
        scroll.documentView = outline
        addSubview(scroll)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    var hasFocus: Bool { window?.firstResponder === outline }

    /// The failed read's sentence, in place of the tree.
    var note: String? {
        if case .failure(let error)? = pane.refs { failureMessage(error.reason) } else { nil }
    }

    // MARK: Showing the pane's state

    func refresh() {
        scroll.isHidden = note != nil
        needsDisplay = true
        if shownRevision != pane.branchRevision {
            reloadRows()
        } else {
            apply()
        }
    }

    /// New rows for the pane's tree (or for new colors), then its state.
    private func reloadRows() {
        shownRevision = pane.branchRevision
        roots = pane.branchTree.map(BranchItem.init)
        items = [:]
        func index(_ level: [BranchItem]) {
            for item in level {
                items[item.node.id] = item
                index(item.children)
            }
        }
        index(roots)
        applying = true
        outline.reloadData()
        applying = false
        apply()
    }

    /// The pane's open rows and selection, onto the outline. A row under a
    /// closed one keeps its own state for when that opens.
    private func apply() {
        applying = true
        defer { applying = false }
        let expansion = pane.branchExpansion
        func open(_ level: [BranchItem]) {
            for item in level where !item.children.isEmpty {
                if expansion.isExpanded(item.node) {
                    if !outline.isItemExpanded(item) { outline.expandItem(item) }
                    open(item.children)
                } else if outline.isItemExpanded(item) {
                    outline.collapseItem(item)
                }
            }
        }
        open(roots)
        let row = pane.selectedBranchID.flatMap { items[$0] }.map { outline.row(forItem: $0) } ?? -1
        if row >= 0 {
            if outline.selectedRow != row { outline.selectRowIndexes([row], byExtendingSelection: false) }
        } else if outline.selectedRow >= 0 {
            outline.deselectAll(nil)
        }
    }

    // MARK: Layout and drawing

    override func layout() {
        super.layout()
        scroll.frame = bounds
        outline.sizeLastColumnToFit()
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let note else { return }
        let font = GitText.ui11
        let padding = GitTreeMetrics.branchNotePadding
        var y = padding
        for line in font.wrap(note, width: max(bounds.width - 2 * padding, 0)) {
            font.draw(line, at: CGPoint(x: padding, y: y + font.ascent), color: theme.textDim)
            y += font.lineHeight
        }
    }

    /// The note's text box, as laid out at this width (the visual geometry).
    var noteRect: CGRect? {
        guard let note else { return nil }
        let font = GitText.ui11
        let padding = GitTreeMetrics.branchNotePadding
        let lines = font.wrap(note, width: max(bounds.width - 2 * padding, 0))
        let width = lines.map(font.width).max() ?? 0
        return CGRect(x: padding, y: padding, width: width, height: Double(lines.count) * font.lineHeight)
    }

    // MARK: The outline's data

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        (item as? BranchItem)?.children.count ?? roots.count
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        (item as? BranchItem)?.children[index] ?? roots[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        (item as? BranchItem)?.children.isEmpty == false
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let item = item as? BranchItem else { return nil }
        let cell = outlineView.makeView(withIdentifier: BranchCellView.identifier, owner: nil) as? BranchCellView ?? BranchCellView()
        cell.show(item.node, current: item.node.ref.map(pane.isHeadBranch) ?? false, theme: theme)
        return cell
    }

    func outlineView(_ outlineView: NSOutlineView, rowViewForItem item: Any) -> NSTableRowView? {
        BranchRowView(theme: theme)
    }

    // MARK: What the user does

    func outlineViewSelectionDidChange(_ notification: Notification) {
        guard !applying else { return }
        let item = outline.selectedRow >= 0 ? outline.item(atRow: outline.selectedRow) as? BranchItem : nil
        pane.selectBranch(item?.node.id)
    }

    func outlineViewItemDidExpand(_ notification: Notification) { toggled(notification, expanded: true) }

    func outlineViewItemDidCollapse(_ notification: Notification) { toggled(notification, expanded: false) }

    private func toggled(_ notification: Notification, expanded: Bool) {
        guard !applying, let item = notification.userInfo?["NSObject"] as? BranchItem else { return }
        pane.setBranchExpanded(item.node.id, expanded)
    }

    /// The outline's double action: on the row double-clicked, or, sent
    /// without a click, the selected one.
    @objc private func doubleClicked(_ sender: Any?) {
        activate(row: outline.clickedRow >= 0 ? outline.clickedRow : outline.selectedRow)
    }

    /// A double-click on a row: a branch or tag is checked out, a folder or
    /// source opens or closes.
    func activate(row: Int) {
        guard row >= 0, let item = outline.item(atRow: row) as? BranchItem else { return }
        if item.node.ref != nil {
            let id = item.node.id
            Task { [weak pane] in await pane?.checkoutBranch(id) }
        } else if outline.isItemExpanded(item) {
            outline.collapseItem(item)
        } else {
            outline.expandItem(item)
        }
    }

    /// Right-click on a branch or tag: selects it (as a click does), then
    /// core's menu, acting on that row. None on a folder or source.
    func openMenu(atRow row: Int, at point: CGPoint) {
        guard row >= 0, let item = outline.item(atRow: row) as? BranchItem, let ref = item.node.ref else { return }
        pane.selectBranch(item.node.id)
        pane.pane.showContextMenu(menuItems(for: ref, id: item.node.id), at: point, in: outline)
    }

    /// Checkout (nothing to do on HEAD's own branch), then Copy Branch Name
    /// or Copy Tag Name.
    func menuItems(for ref: GitRef, id: String) -> [PaneMenuItem] {
        [
            PaneMenuItem("Checkout", isEnabled: !pane.isHeadBranch(ref)) { [weak pane] in
                guard let pane else { return }
                Task { await pane.checkoutBranch(id) }
            },
            PaneMenuItem(ref.kind == .tag ? "Copy Tag Name" : "Copy Branch Name") { [weak pane] in pane?.copyName(ref) },
        ]
    }

    /// The rows as shown, with what the outline knows of each (state verb,
    /// visual geometry).
    var shownRows: [(row: Int, item: BranchItem, level: Int)] {
        (0..<outline.numberOfRows).compactMap { row in
            (outline.item(atRow: row) as? BranchItem).map { (row, $0, outline.level(forRow: row)) }
        }
    }

    func isExpanded(_ item: BranchItem) -> Bool { outline.isItemExpanded(item) }
}

/// One row as the outline holds it: an object, since `NSOutlineView` keeps
/// its rows by identity.
@MainActor
final class BranchItem: NSObject {
    let node: BranchNode
    let children: [BranchItem]

    init(_ node: BranchNode) {
        self.node = node
        children = node.children.map(BranchItem.init)
        super.init()
    }
}

/// The outline: AppKit's, but its right-click opens core's menu (as the
/// commit list's does), not a menu of AppKit's own.
@MainActor
final class BranchOutlineView: NSOutlineView {
    weak var sidebar: BranchSidebarView?

    override func rightMouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        sidebar?.openMenu(atRow: row(at: point), at: point)
    }

    override func menu(for event: NSEvent) -> NSMenu? { nil }
}

/// A row's background: the selected row in the accent at 18% (as a commit
/// row), however the outline is focused; its text keeps its colors.
@MainActor
final class BranchRowView: NSTableRowView {
    let theme: PaneTheme

    init(theme: PaneTheme) {
        self.theme = theme
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func drawSelection(in dirtyRect: NSRect) {
        theme.selection.setFill()
        bounds.fill()
    }

    override var interiorBackgroundStyle: NSView.BackgroundStyle { .normal }
}

/// A row's content: its icon, then its name, cut with an ellipsis. HEAD's
/// branch is semibold, its icon in the accent.
@MainActor
final class BranchCellView: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("git-tree-branch")
    static let font = NSFont.systemFont(ofSize: 12)
    static let currentFont = NSFont.systemFont(ofSize: 12, weight: .semibold)
    /// The label's height: one line at 12pt.
    static let nameHeight = NSTextField(labelWithString: "Ag").intrinsicContentSize.height.rounded(.up)

    let icon = NSImageView()
    let label = NSTextField(labelWithString: "")

    init() {
        super.init(frame: .zero)
        identifier = Self.identifier
        icon.imageScaling = .scaleNone
        icon.imageAlignment = .alignCenter
        label.lineBreakMode = .byTruncatingTail
        label.font = Self.font
        addSubview(icon)
        addSubview(label)
        imageView = icon
        textField = label
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func show(_ node: BranchNode, current: Bool, theme: PaneTheme) {
        label.stringValue = node.title
        label.font = current ? Self.currentFont : Self.font
        label.textColor = theme.text
        icon.image = Self.image(for: node)
        icon.contentTintColor = current ? theme.accent : theme.textDim
        toolTip = node.ref?.shortName
    }

    /// Top-down, as the outline is: `parts` places from the top.
    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        let parts = Self.parts(in: bounds)
        icon.frame = parts.icon
        label.frame = parts.name
    }

    /// Where the icon and the name go in a cell's bounds: a 16pt icon at its
    /// start, the name 4 after it to the end, both centred.
    static func parts(in bounds: CGRect) -> (icon: CGRect, name: CGRect) {
        let size = GitTreeMetrics.branchIconSize
        let icon = CGRect(x: bounds.minX, y: bounds.minY + ((bounds.height - size) / 2).rounded(.down), width: size, height: size)
        let x = icon.maxX + GitTreeMetrics.branchIconGap
        let name = CGRect(
            x: x, y: bounds.minY + ((bounds.height - nameHeight) / 2).rounded(.down), width: max(bounds.maxX - x, 0), height: nameHeight)
        return (icon, name)
    }

    /// The SF Symbol for a row: the source's (a computer, a cloud, a tag), a
    /// folder, a branch, a tag.
    static func image(for node: BranchNode) -> NSImage? {
        let name: String
        switch node.kind {
        case .source(.local): name = "laptopcomputer"
        case .source(.remote): name = "cloud"
        case .source(.tags): name = "tag"
        case .folder: name = "folder"
        case .ref(let ref): name = ref.kind == .tag ? "tag" : "arrow.triangle.branch"
        }
        return images[name]
    }

    private static let images: [String: NSImage] = {
        var images: [String: NSImage] = [:]
        let configuration = NSImage.SymbolConfiguration(pointSize: 12, weight: .regular)
        for name in ["laptopcomputer", "cloud", "tag", "folder", "arrow.triangle.branch"] {
            images[name] = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(configuration)
        }
        return images
    }()
}
