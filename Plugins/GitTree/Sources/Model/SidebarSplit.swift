import TabsPluginSDK

// How wide the branches sidebar is, left of the commit list: the model behind
// its divider, pure like `DetailSplit`. A width in points rather than a share
// of the body, as a sidebar keeps its width while the window around it
// resizes. Saved in the pane's config (`branchesWidth`, `branchesCollapsed`).

enum SidebarSplitRules {
    /// The width of a pane whose divider was never dragged.
    static let defaultWidth = 200.0
    /// The sidebar's smallest open width. Dragging below half of it collapses
    /// it; between half and all of it, it holds here.
    static let minWidth = 120.0
    /// The commit list is never dragged narrower than this.
    static let listMinWidth = 200.0
}

struct SidebarSplit: Equatable, Sendable {
    /// The width while open, in points: more than 0.
    var width: Double
    var collapsed: Bool
}

/// The sidebar a pane's config asks for, checked rather than trusted (as
/// `readDetailSplit` does): a width must be finite and more than 0, a collapse
/// a literal `true`.
func readSidebarSplit(_ config: JSONValue) -> SidebarSplit {
    let width = config["branchesWidth"]?.doubleValue
    return SidebarSplit(
        width: width.flatMap { $0.isFinite && $0 > 0 ? $0 : nil } ?? SidebarSplitRules.defaultWidth,
        collapsed: config["branchesCollapsed"] == .bool(true))
}

/// The split for a drag that would make the sidebar `width` points of a
/// `bodyWidth`-point body. Collapsing keeps `previous.width`; a body too
/// narrow for both minimums keeps the sidebar's (the list gives way).
func resolveSidebarDrag(width: Double, bodyWidth: Double, previous: SidebarSplit) -> SidebarSplit {
    if bodyWidth <= 0 { return previous }
    if width < SidebarSplitRules.minWidth / 2 { return SidebarSplit(width: previous.width, collapsed: true) }
    return SidebarSplit(width: min(max(width, SidebarSplitRules.minWidth), sidebarMaxWidth(bodyWidth)), collapsed: false)
}

/// The open sidebar's width in a `bodyWidth`-point body: the saved one, unless
/// the body is now too narrow to leave the list its minimum (the saved width
/// comes back when it widens again). Never wider than the body.
func shownSidebarWidth(_ split: SidebarSplit, bodyWidth: Double) -> Double {
    max(min(split.width, sidebarMaxWidth(bodyWidth), bodyWidth), 0)
}

private func sidebarMaxWidth(_ bodyWidth: Double) -> Double {
    max(SidebarSplitRules.minWidth, bodyWidth - SidebarSplitRules.listMinWidth)
}
