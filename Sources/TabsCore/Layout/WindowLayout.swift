import Foundation
import TabsPluginSDK

/// Names nodes the way the window shows them. Injected so the model stays
/// independent of the plugins that provide content types.
package struct LayoutTitles: Sendable {
    /// Content types' display names, from the plugins that provide them.
    package var displayNames: [ContentTypeID: String]

    package init(displayNames: [ContentTypeID: String] = [:]) {
        self.displayNames = displayNames
    }

    package func displayName(_ type: ContentTypeID) -> String? { displayNames[type] }

    package static let newTab = "New Tab"
    /// A placeholder tab directly in the docked root group: the window's own strip.
    package static let rootTab = "Tabs"

    private func derived(_ node: LayoutNode, fallback: String) -> String {
        switch node {
        case .leaf(let leaf): leaf.type.flatMap(displayName) ?? fallback
        case .tabs: "Tab group"
        case .split: "Split"
        }
    }

    /// The title of a new tab holding `node`: what it is ("New Tab" for an empty pane).
    package func tabTitle(for node: LayoutNode) -> String { derived(node, fallback: Self.newTab) }

    /// `tabTitle`, for a tab landing directly in the docked root group.
    package func rootTabTitle(for node: LayoutNode) -> String { derived(node, fallback: Self.rootTab) }

    /// A pane header's label: its title if set, else what it is ("Empty pane").
    package func paneTitle(for node: LayoutNode) -> String {
        switch node {
        case .leaf(let leaf):
            if let title = leaf.title { return title }
            guard let type = leaf.type else { return "Empty pane" }
            return displayName(type) ?? type.rawValue
        case .tabs: return "Tab group"
        case .split: return "Split"
        }
    }
}

/// What is being dragged: a tab out of its bar, or a whole pane by its chrome.
package enum DragSubject: Equatable, Sendable {
    case tab(tabID: NodeID, sourceGroupID: NodeID)
    case pane(NodeID)

    /// The id the subject is found by in its tree.
    package var nodeKey: NodeID {
        switch self {
        case .tab(let tabID, _): tabID
        case .pane(let paneID): paneID
        }
    }
}

/// Where a drag would land.
package enum DropTarget: Equatable, Sendable {
    case tabBar(groupID: NodeID, index: Int)
    case emptyPane(NodeID)
    case dock(targetID: NodeID, zone: DockZone)
}

/// What a drag carries into another window: a tab (with its title) or a bare pane.
package enum MovingContent: Equatable, Sendable {
    case tab(Tab)
    case pane(LayoutNode)

    package var node: LayoutNode {
        switch self {
        case .tab(let tab): tab.content
        case .pane(let node): node
        }
    }
}

/// A window's position and size on screen, in screen points (bottom-left origin).
package struct WindowFrame: Codable, Equatable, Sendable {
    package var x, y, width, height: Double

    package init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
}

/// One window's layout — the docked tree (always a tab group: its bar is the
/// window's title bar), the floating panes over it (array order is z-order),
/// and the active pane. Every operation runs on exactly one tree — the docked
/// root or one floating pane's content — and hands focus to what it created
/// or moved, else keeps it. Each returns whether anything changed.
///
/// Only a leaf (a pane that can hold content) is ever active. Focus asked to
/// go to a group or a split stays where it is, unless the active pane is gone
/// or hidden behind a tab while that container shows: then the pane the
/// container shows takes it.
package struct WindowLayout: Equatable, Sendable {
    package var id: WindowID
    package var root: TabGroup
    package var floating: [FloatingPane]
    /// The pane shown as active (its content outlined) and holding the
    /// keyboard: always a leaf here. Every operation sets it last, after the
    /// trees, so `recentPanes` follows it here.
    package private(set) var activePaneID: NodeID {
        didSet { recordActivePane() }
    }
    /// The window's panes that have been active, the most recent first (the
    /// active pane leads): the pane each tab follows (`followedPane`).
    package private(set) var recentPanes: [NodeID] = []
    /// Where the window was on screen (nil: let the shell place it).
    package var frame: WindowFrame?

    /// A window around `root`, repaired: normalized, wrapped in the root group,
    /// floating panes sanitized, `active` kept if it still resolves, `recent`
    /// kept where the window still holds its panes.
    package init(
        id: WindowID = .make(), root: LayoutNode = .emptyLeaf(), floating: [FloatingPane] = [], active: NodeID? = nil,
        recent: [NodeID] = [], frame: WindowFrame? = nil, titles: LayoutTitles = LayoutTitles()
    ) {
        let normalized = Tree.normalize(root)
        self.id = id
        self.root = Tree.ensureTabsRoot(normalized) { Tab(title: titles.rootTabTitle(for: $0), content: $0) }
        self.floating = Floating.sanitize(floating, against: .tabs(self.root))
        self.frame = frame
        // Not a leaf: resolving it finds the pane `active` names, else the one the root shows.
        self.activePaneID = self.root.id
        activePaneID = resolveActive(active ?? self.root.id)
        recentPanes = recent
        recordActivePane()
    }

    /// Puts the active pane first in `recentPanes`, dropping panes the window
    /// no longer holds (and any id twice).
    private mutating func recordActivePane() {
        var seen: Set<NodeID> = [activePaneID]
        let rest = recentPanes.filter { id in
            guard seen.insert(id).inserted, let node = findNode(id) else { return false }
            return node.isLeaf
        }
        recentPanes = [activePaneID] + rest
    }

    /// The pane `tab` follows: the one most recently active inside it, else
    /// the one it shows. TT-4, TT-5, TT-6
    package func followedPane(of tab: Tab) -> NodeID {
        recentPanes.first { Tree.contains(tab.content, $0) } ?? Navigation.entryPaneID(tab.content)
    }

    package var rootNode: LayoutNode { .tabs(root) }

    /// Every tree: the docked root first, then each floating pane's content.
    package var trees: [LayoutNode] { [rootNode] + floating.map(\.content) }

    package var leaves: [LayoutLeaf] { trees.flatMap(\.leaves) }

    package func findNode(_ id: NodeID) -> LayoutNode? {
        for tree in trees {
            if let node = Tree.findNode(tree, id) { return node }
        }
        return nil
    }

    package func holds(_ id: NodeID) -> Bool { findNode(id) != nil }

    /// Whether `id` is on screen: every tab above it, in its own tree, is the active one.
    package func isShowing(_ id: NodeID) -> Bool {
        guard let tree = trees.first(where: { Tree.contains($0, id) }) else { return false }
        func visible(_ node: LayoutNode) -> Bool {
            if node.id == id { return true }
            switch node {
            case .leaf: return false
            case .split(let split): return split.children.contains { visible($0) }
            case .tabs(let group):
                guard let active = group.activeTab else { return false }
                return visible(active.content)
            }
        }
        return visible(tree)
    }

    // MARK: Owners

    private enum Owner: Equatable {
        case docked
        case floating(Int)
    }

    private func holds(_ tree: LayoutNode, _ id: NodeID) -> Bool {
        Tree.contains(tree, id) || Tree.findTab(tree, id) != nil
    }

    /// The tree that owns `id` (a node or a tab); the docked root when none does.
    private func owner(of id: NodeID) -> Owner {
        if holds(rootNode, id) { return .docked }
        if let index = floating.firstIndex(where: { holds($0.content, id) }) { return .floating(index) }
        return .docked
    }

    private func tree(_ owner: Owner) -> LayoutNode {
        switch owner {
        case .docked: rootNode
        case .floating(let index): floating[index].content
        }
    }

    /// The tree `id` belongs to (the docked root when none holds it).
    package func ownerTree(of id: NodeID) -> LayoutNode { tree(owner(of: id)) }

    /// The floating pane whose tree holds `id`.
    package func floatingPane(holding id: NodeID) -> FloatingPane? { Floating.owning(floating, id) }

    /// The active pane once focus is asked to go to `desired`: a leaf takes
    /// it; a container leaves it where it is, unless the active pane is gone or
    /// hidden while the container shows, and then the pane the container shows
    /// takes it. Neither found: the pane the docked root shows.
    private func resolveActive(_ desired: NodeID) -> NodeID {
        let node = findNode(desired)
        if node?.isLeaf == true { return desired }
        if findNode(activePaneID)?.isLeaf == true, isShowing(activePaneID) || node.map({ !isShowing($0.id) }) ?? true {
            return activePaneID
        }
        return Navigation.entryPaneID(node ?? rootNode)
    }

    /// Where focus goes into `content` (a tab clicked, content dropped): the
    /// active pane stays if it is inside and on screen, else the pane `content`
    /// shows takes it. `content` may be as it was before a move: a moved split
    /// can flatten into its new parent and lose its id, but its panes keep theirs.
    private func entering(_ content: LayoutNode) -> NodeID {
        Tree.contains(content, activePaneID) && isShowing(activePaneID) ? activePaneID : Navigation.entryPaneID(content)
    }

    /// Resolves the active pane again after the trees were edited directly.
    package mutating func repairActivePane() {
        activePaneID = resolveActive(activePaneID)
    }

    private func ensureRootGroup(_ node: LayoutNode, titles: LayoutTitles, survivor: () -> Tab? = { nil }) -> TabGroup {
        Tree.ensureTabsRoot(node) { content in
            survivor()?.renamed(holding: content) ?? Tab(title: titles.rootTabTitle(for: content), content: content)
        }
    }

    /// The tab whose name a rebuilt root wrapper takes (a user's name stays
    /// theirs): whichever of the root's tabs from before the operation is
    /// still found after it (not the one `excluded` names — that one moved).
    private static func survivor(_ before: TabGroup, _ after: LayoutNode, excluding excluded: NodeID?) -> Tab? {
        for tab in before.tabs where tab.id != excluded && tab.content.id != excluded {
            if Tree.contains(after, tab.content.id) { return tab }
        }
        return nil
    }

    /// Titles new tabs: a tab landing directly in the docked root group gets
    /// the root's placeholder title.
    package func tabTitler(_ titles: LayoutTitles) -> TabTitler {
        let rootID = root.id
        return { node, destGroup in destGroup == rootID ? titles.rootTabTitle(for: node) : titles.tabTitle(for: node) }
    }

    /// Redirects an action aimed at the docked root onto the tab it shows:
    /// splitting, wrapping, closing or clearing the root would act on the
    /// whole window.
    package func redirectFromDockedRoot(_ id: NodeID) -> NodeID {
        guard id == root.id else { return id }
        return root.activeTab?.content.id ?? id
    }

    /// The node a close or clear aimed at `id` would really destroy.
    package func closeTarget(_ id: NodeID) -> LayoutNode? { findNode(redirectFromDockedRoot(id)) }

    /// Whether docking at `zone` of `targetID` would split the docked root out
    /// of itself (it has no parent slot to leave the rest in).
    package func splitsDockedRootOutOfItself(_ targetID: NodeID, _ zone: DockZone) -> Bool {
        zone != .center && targetID == root.id
    }

    private enum Desired {
        case keep
        case node(NodeID)
        case compute((LayoutNode) -> NodeID?)
        /// `entering` this content (as it was before the operation).
        case into(LayoutNode)
    }

    /// Applies a tree operation to whichever tree owns `id`, writes the result
    /// back (the docked root re-wrapped in its group) and moves focus to
    /// `desired`, re-resolved. An operation that changed nothing changes nothing.
    private mutating func withOwner(_ id: NodeID, titles: LayoutTitles, desired: Desired = .keep, _ apply: (LayoutNode) -> LayoutNode)
        -> Bool
    {
        let owner = owner(of: id)
        let before = tree(owner)
        let rawNext = apply(before)
        if rawNext == before { return false }
        switch owner {
        case .docked:
            let previous = root
            root = ensureRootGroup(rawNext, titles: titles) { Self.survivor(previous, rawNext, excluding: id) }
        case .floating(let index):
            floating[index].content = rawNext
        }
        activePaneID = resolveActive(target(desired, in: tree(owner)))
        return true
    }

    private func target(_ desired: Desired, in next: LayoutNode) -> NodeID {
        switch desired {
        case .keep: activePaneID
        case .node(let node): node
        case .compute(let compute): compute(next) ?? activePaneID
        case .into(let content): entering(content)
        }
    }

    // MARK: Operations

    /// Makes `id` the active pane (a container: see `resolveActive`); anything
    /// in a floating window raises it.
    @discardableResult
    package mutating func setActivePane(_ id: NodeID) -> Bool {
        let owner = owner(of: id)
        guard Tree.contains(tree(owner), id) else { return false }
        var raised = floating
        if case .floating(let index) = owner { raised = Floating.raise(floating, floating[index].id) }
        let active = resolveActive(id)
        if active == activePaneID && raised == floating { return false }
        activePaneID = active
        floating = raised
        return true
    }

    /// Moves focus into `id` (a tab clicked): see `entering`.
    @discardableResult
    package mutating func focus(into id: NodeID) -> Bool {
        guard let node = findNode(id) else { return false }
        return setActivePane(entering(node))
    }

    /// Closes a tab; when it held the active pane, the nearest pane left takes it.
    @discardableResult
    package mutating func closeTab(_ tabID: NodeID, titles: LayoutTitles) -> Bool {
        let ownerTree = ownerTree(of: tabID)
        let closed = Tree.findTab(ownerTree, tabID)?.tab.content
        let heldActive = closed.map { Tree.contains($0, activePaneID) } ?? false
        return withOwner(
            tabID, titles: titles,
            desired: .compute { next in heldActive ? closed.flatMap { Navigation.focusAfterClose(ownerTree, next, $0.id) } : nil }
        ) {
            Tree.closeTab($0, tabID)
        }
    }

    @discardableResult
    package mutating func activateTab(_ groupID: NodeID, _ tabID: NodeID, titles: LayoutTitles) -> Bool {
        withOwner(groupID, titles: titles) { Tree.activateTab($0, groupID, tabID) }
    }

    /// A tab clicked: shown, and focus goes into it, down to its leaf, unless
    /// it already holds the active pane (`entering`).
    @discardableResult
    package mutating func selectTab(_ tabID: NodeID, in groupID: NodeID, titles: LayoutTitles) -> Bool {
        guard let ref = trees.lazy.compactMap({ Tree.findTab($0, tabID) }).first else { return false }
        let switched = activateTab(groupID, tabID, titles: titles)
        return focus(into: ref.tab.content.id) || switched
    }

    /// Moves a tab within its tree; focus goes into it (`entering`).
    @discardableResult
    package mutating func moveTab(_ tabID: NodeID, to groupID: NodeID, at index: Int? = nil, titles: LayoutTitles) -> Bool {
        guard let moved = Tree.findTab(ownerTree(of: tabID), tabID)?.tab.content else { return false }
        if withOwner(tabID, titles: titles, desired: .into(moved), { Tree.moveTab($0, tabID, groupID, at: index) }) { return true }
        // A tab dropped back where it was changes nothing but still takes focus.
        guard Tree.findTab(ownerTree(of: tabID), tabID)?.group.id == groupID else { return false }
        return focus(into: moved.id)
    }

    /// Docks a tab at a pane's edge or center; focus goes into it (`entering`).
    @discardableResult
    package mutating func dockTab(_ tabID: NodeID, onto targetID: NodeID, zone: DockZone, titles: LayoutTitles) -> Bool {
        guard !splitsDockedRootOutOfItself(targetID, zone), let moved = Tree.findTab(ownerTree(of: tabID), tabID)?.tab.content
        else { return false }
        let titler = tabTitler(titles)
        return withOwner(tabID, titles: titles, desired: .into(moved)) { Tree.dockTab($0, tabID, targetID, zone, titler) }
    }

    /// Names a tab as the user typed it; nil gives it back its default title
    /// (and it follows its pane again). TT-8, TT-9
    @discardableResult
    package mutating func renameTab(_ tabID: NodeID, _ title: String?, titles: LayoutTitles) -> Bool {
        let titler = tabTitler(titles)
        return withOwner(tabID, titles: titles) { tree in
            title.map { Tree.renameTab(tree, tabID, $0) } ?? Tree.resetTabTitle(tree, tabID, titler)
        }
    }

    @discardableResult
    package mutating func renamePane(_ id: NodeID, _ title: String?, titles: LayoutTitles) -> Bool {
        withOwner(id, titles: titles) { Tree.renamePane($0, id, title) }
    }

    /// Replaces a leaf (a pane filled with content, a live pane's saved state).
    @discardableResult
    package mutating func replaceLeaf(_ id: NodeID, with leaf: LayoutLeaf, titles: LayoutTitles) -> Bool {
        withOwner(id, titles: titles) { tree in
            guard Tree.findNode(tree, id)?.isLeaf == true else { return tree }
            return Tree.replaceNode(tree, id) { _ in .leaf(leaf) } ?? tree
        }
    }

    /// Splits `targetID` (the root redirects to its shown tab), with `content`
    /// the new sibling, which becomes active.
    @discardableResult
    package mutating func split(
        _ targetID: NodeID, _ direction: SplitDirection, with content: LayoutNode, before: Bool = false, titles: LayoutTitles
    )
        -> Bool
    {
        let target = redirectFromDockedRoot(targetID)
        return withOwner(target, titles: titles, desired: .node(content.id)) {
            Tree.splitContent($0, target, direction, content, before: before)
        }
    }

    @discardableResult
    package mutating func resizeSplit(_ splitID: NodeID, _ sizes: [Double], titles: LayoutTitles) -> Bool {
        withOwner(splitID, titles: titles) { Tree.resizeSplit($0, splitID, sizes) }
    }

    /// Opens content at a pane without evicting what it holds; the new content becomes active.
    @discardableResult
    package mutating func openContent(at targetID: NodeID, _ content: LayoutNode, titles: LayoutTitles) -> Bool {
        let titler = tabTitler(titles)
        return withOwner(targetID, titles: titles, desired: .node(content.id)) { Tree.openContent($0, targetID, content, titler) }
    }

    /// Closes a pane and everything in it. The docked root means its shown tab;
    /// a floating window's own pane closes the window.
    @discardableResult
    package mutating func closePane(_ id: NodeID, titles: LayoutTitles) -> Bool {
        if let index = floating.firstIndex(where: { $0.content.id == id }) {
            floating.remove(at: index)
            let desired = Navigation.entryPaneID(floating.last?.content ?? rootNode)
            activePaneID = resolveActive(desired)
            return true
        }
        let target = redirectFromDockedRoot(id)
        if target == root.id { return false }
        let ownerTree = self.ownerTree(of: target)
        let wasActive = findNode(target).map { Tree.contains($0, activePaneID) } ?? false
        return withOwner(
            target, titles: titles, desired: .compute { next in wasActive ? Navigation.focusAfterClose(ownerTree, next, target) : nil }
        ) {
            Tree.closePane($0, target)
        }
    }

    /// Whether Clear pane would do anything: the pane (the docked root: its
    /// shown tab) holds something other than an empty pane.
    package func canClear(_ id: NodeID) -> Bool {
        let target = redirectFromDockedRoot(id)
        guard target != root.id, let node = findNode(target) else { return false }
        return !node.isEmpty
    }

    /// Replaces a pane's content with a fresh empty pane, which keeps focus.
    @discardableResult
    package mutating func clearPane(_ id: NodeID, titles: LayoutTitles) -> Bool {
        guard canClear(id) else { return false }
        let target = redirectFromDockedRoot(id)
        let empty = LayoutNode.emptyLeaf()
        return withOwner(target, titles: titles, desired: .node(empty.id)) { Tree.replaceContent($0, target, empty) }
    }

    /// Wraps a pane into a one-tab group; focus stays where it was.
    @discardableResult
    package mutating func wrapPaneInTabs(_ id: NodeID, titles: LayoutTitles) -> Bool {
        let target = redirectFromDockedRoot(id)
        let titler = tabTitler(titles)
        return withOwner(target, titles: titles) { Tree.wrapInTabs($0, target, titler) }
    }

    /// Whether Ungroup applies: a group of one tab, never the docked root.
    package func canUngroup(_ groupID: NodeID) -> Bool {
        guard groupID != root.id, case .tabs(let group)? = findNode(groupID) else { return false }
        return group.tabs.count == 1
    }

    /// Collapses a single-tab group to its content (never the docked root).
    @discardableResult
    package mutating func ungroupTabs(_ groupID: NodeID, titles: LayoutTitles) -> Bool {
        guard canUngroup(groupID), case .tabs(let group)? = findNode(groupID) else { return false }
        return withOwner(groupID, titles: titles, desired: .into(group.tabs[0].content)) { Tree.ungroupTabs($0, groupID) }
    }

    /// Docks a pane at another's edge or center; focus goes into it (`entering`).
    @discardableResult
    package mutating func dockPane(_ paneID: NodeID, onto targetID: NodeID, zone: DockZone, titles: LayoutTitles) -> Bool {
        guard !splitsDockedRootOutOfItself(targetID, zone), let moved = findNode(paneID) else { return false }
        let titler = tabTitler(titles)
        return withOwner(paneID, titles: titles, desired: .into(moved)) { Tree.dockPane($0, paneID, targetID, zone, titler) }
    }

    /// Moves a pane into a tab bar; focus goes into it (`entering`).
    @discardableResult
    package mutating func movePaneToTabs(_ paneID: NodeID, to groupID: NodeID, at index: Int? = nil, titles: LayoutTitles) -> Bool {
        guard let moved = findNode(paneID) else { return false }
        let titler = tabTitler(titles)
        return withOwner(paneID, titles: titles, desired: .into(moved)) { Tree.movePaneToTabs($0, paneID, groupID, titler, at: index) }
    }

    /// Whether Unpin applies: a docked pane or group, never the docked root
    /// (a floating window's content is pinned back instead).
    package func canUnpin(_ id: NodeID) -> Bool {
        id != root.id && Tree.findNode(rootNode, id) != nil
    }

    /// Lifts a docked pane into a floating pane at `rect` (clamped). Never the docked root.
    @discardableResult
    package mutating func unpinPane(_ id: NodeID, rect: FloatRect, viewport: Viewport, titles: LayoutTitles) -> Bool {
        guard canUnpin(id), let result = Floating.detachForFloat(rootNode, id, rect: Floating.clamp(rect, to: viewport)) else {
            return false
        }
        floating.append(result.floating)
        root = ensureRootGroup(result.root, titles: titles)
        activePaneID = resolveActive(id)
        return true
    }

    /// Opens new content directly as a floating pane (a new unpinned pane).
    @discardableResult
    package mutating func openFloatingPane(_ content: LayoutNode, rect: FloatRect, viewport: Viewport) -> Bool {
        floating.append(FloatingPane(content: content, rect: Floating.clamp(rect, to: viewport), anchor: .root))
        activePaneID = resolveActive(content.id)
        return true
    }

    /// Puts a floating pane back into the docked layout, near where it came from.
    @discardableResult
    package mutating func repinPane(_ floatID: NodeID, titles: LayoutTitles) -> Bool {
        guard let index = floating.firstIndex(where: { $0.id == floatID }) else { return false }
        let entry = floating[index]
        root = ensureRootGroup(Floating.restoreFloating(rootNode, entry, tabTitler(titles), fallbackTarget: activePaneID), titles: titles)
        floating.remove(at: index)
        activePaneID = resolveActive(entry.content.id)
        return true
    }

    @discardableResult
    package mutating func setFloatingRect(_ floatID: NodeID, _ rect: FloatRect, viewport: Viewport) -> Bool {
        guard let index = floating.firstIndex(where: { $0.id == floatID }) else { return false }
        let clamped = Floating.clamp(rect, to: viewport)
        guard floating[index].rect != clamped else { return false }
        floating[index].rect = clamped
        return true
    }

    /// Re-clamps every floating pane into the viewport.
    @discardableResult
    package mutating func reclampFloating(_ viewport: Viewport) -> Bool {
        var changed = false
        for index in floating.indices {
            let clamped = Floating.clamp(floating[index].rect, to: viewport)
            if clamped != floating[index].rect {
                floating[index].rect = clamped
                changed = true
            }
        }
        return changed
    }

    @discardableResult
    package mutating func raiseFloating(_ floatID: NodeID) -> Bool {
        let raised = Floating.raise(floating, floatID)
        guard raised != floating else { return false }
        floating = raised
        return true
    }

    // MARK: Dropping within the window (in the dragged subject's own tree)

    /// What a drag of `subject` carries in its own tree: a tab's content, or the pane.
    private func draggedContent(_ subject: DragSubject) -> LayoutNode? {
        let tree = ownerTree(of: subject.nodeKey)
        return switch subject {
        case .pane(let paneID): Tree.findNode(tree, paneID)
        case .tab(let tabID, _): Tree.findTab(tree, tabID)?.tab.content
        }
    }

    /// The bar a drag of `subject` leaves and its tab there: a tab's own
    /// group, or the group whose tab holds the pane. Nil when the subject
    /// isn't in this window, or a pane isn't a tab's content.
    private func departure(of subject: DragSubject) -> (group: NodeID, tab: NodeID)? {
        let tree = ownerTree(of: subject.nodeKey)
        switch subject {
        case .tab(let tabID, _):
            return Tree.findTab(tree, tabID).map { ($0.group.id, tabID) }
        case .pane(let paneID):
            if case .tab(let group, let tab)? = Tree.findParent(tree, paneID) { return (group.id, tab.id) }
            return nil
        }
    }

    /// A drop on `groupID`'s bar: beside `tabID` (before it, or `after` it),
    /// or at the end with no tab under the pointer. Indices count the tabs
    /// that stay: in its own bar the dragged tab leaves first (hovering it
    /// lands at the end).
    package func tabBarDrop(_ subject: DragSubject, on groupID: NodeID, beside tabID: NodeID?, after: Bool) -> DropTarget {
        let departing = departure(of: subject).flatMap { $0.group == groupID ? $0.tab : nil }
        let remaining = (Tree.findNode(ownerTree(of: groupID), groupID)?.group?.tabs.map(\.id) ?? []).filter { $0 != departing }
        guard let tabID, let at = remaining.firstIndex(of: tabID) else { return .tabBar(groupID: groupID, index: remaining.count) }
        return .tabBar(groupID: groupID, index: after ? at + 1 : at)
    }

    /// Whether dropping `subject` at `target`, in the tree it is dragged from,
    /// would change anything (the hover check: a declined target shows no
    /// preview). A drag stays in its tree: floating content never lands in
    /// the docked layout or another floating pane, and the docked root never
    /// splits out of itself.
    package func canDrop(_ subject: DragSubject, at target: DropTarget) -> Bool {
        let tree = ownerTree(of: subject.nodeKey)
        switch (target, subject) {
        case (.tabBar(let groupID, _), .tab(let tabID, _)): return Tree.canMoveTabToTabs(tree, tabID, groupID)
        case (.tabBar(let groupID, _), .pane(let paneID)): return Tree.canMovePaneToTabs(tree, paneID, groupID)
        case (.dock(let targetID, let zone), _) where splitsDockedRootOutOfItself(targetID, zone): return false
        case (.dock(let targetID, let zone), .tab(let tabID, _)): return Tree.canDockTab(tree, tabID, targetID, zone)
        case (.dock(let targetID, let zone), .pane(let paneID)): return Tree.canDockPane(tree, paneID, targetID, zone)
        case (.emptyPane(let paneID), _):
            // Never into itself: an empty pane inside what is being dragged.
            guard Tree.findNode(tree, paneID)?.isEmpty == true, let moving = draggedContent(subject) else { return false }
            return !Tree.contains(moving, paneID)
        }
    }

    /// Drops `subject` at `target` in the tree it is dragged from, as the
    /// user's release does; focus goes into it.
    @discardableResult
    package mutating func drop(_ subject: DragSubject, at target: DropTarget, titles: LayoutTitles) -> Bool {
        guard canDrop(subject, at: target) else { return false }
        return switch (target, subject) {
        case (.tabBar(let group, let index), .tab(let tabID, _)): moveTab(tabID, to: group, at: index, titles: titles)
        case (.tabBar(let group, let index), .pane(let paneID)): movePaneToTabs(paneID, to: group, at: index, titles: titles)
        case (.emptyPane(let pane), .tab(let tabID, _)): moveTab(tabID, to: pane, titles: titles)
        case (.emptyPane(let pane), .pane(let paneID)): dockPane(paneID, onto: pane, zone: .center, titles: titles)
        case (.dock(let targetID, let zone), .tab(let tabID, _)): dockTab(tabID, onto: targetID, zone: zone, titles: titles)
        case (.dock(let targetID, let zone), .pane(let paneID)): dockPane(paneID, onto: targetID, zone: zone, titles: titles)
        }
    }

    /// Whether hovering the tab `tabID` during a drag of `subject` opens it
    /// (spring loading): a tab in the dragged subject's tree, never the one
    /// the drag leaves from nor one inside what is being dragged.
    package func canSpringLoad(_ tabID: NodeID, during subject: DragSubject) -> Bool {
        guard Tree.findTab(ownerTree(of: subject.nodeKey), tabID) != nil, tabID != departure(of: subject)?.tab else { return false }
        return draggedContent(subject).map { Tree.findTab($0, tabID) == nil } ?? true
    }

    // MARK: Moving content between windows (docked trees only)

    /// What dragging `subject` into another window carries, or nil when it
    /// can't leave: a pane in a floating window stays in it, and the docked
    /// root has no slot to leave behind.
    package func movingContent(_ subject: DragSubject) -> MovingContent? {
        switch subject {
        case .tab(let tabID, _):
            return Tree.findTab(rootNode, tabID).map { .tab($0.tab) }
        case .pane(let paneID):
            guard paneID != root.id, let node = Tree.findNode(rootNode, paneID) else { return nil }
            return .pane(node)
        }
    }

    package func canLeaveWindow(_ subject: DragSubject) -> Bool { movingContent(subject) != nil }

    /// Detaches `subject` from the docked root. When everything the window
    /// held leaves, a fresh empty pane stays behind.
    @discardableResult
    package mutating func extract(_ subject: DragSubject, titles: LayoutTitles) -> MovingContent? {
        guard let content = movingContent(subject) else { return nil }
        let node = content.node
        let rawRoot: LayoutNode
        if root.tabs.flatMap(\.content.leaves).allSatisfy({ Tree.contains(node, $0.id) }) {
            rawRoot = .emptyLeaf()
        } else {
            let detached =
                switch subject {
                case .pane(let paneID): Tree.withPaneDetached(rootNode, paneID)
                case .tab(let tabID, _): Tree.withTabDetached(rootNode, tabID)
                }
            guard let detached else { return nil }
            rawRoot = Tree.normalize(detached)
        }
        let previous = root
        root = ensureRootGroup(rawRoot, titles: titles) { Self.survivor(previous, rawRoot, excluding: subject.nodeKey) }
        activePaneID = resolveActive(activePaneID)
        return content
    }

    /// Whether content from another window could land at `target`.
    package func accepts(_ target: DropTarget) -> Bool {
        let (targetID, zone, _) = Self.placement(of: target)
        return !splitsDockedRootOutOfItself(targetID, zone) && Tree.canDockExternalTarget(rootNode, targetID)
    }

    private static func placement(of target: DropTarget) -> (NodeID, DockZone, Int?) {
        switch target {
        case .tabBar(let groupID, let index): (groupID, .center, index)
        case .emptyPane(let paneID): (paneID, .center, nil)
        case .dock(let targetID, let zone): (targetID, zone, nil)
        }
    }

    /// Inserts content from another window at `target`, as a drop would; focus
    /// goes into it.
    @discardableResult
    package mutating func insert(_ content: MovingContent, at target: DropTarget, titles: LayoutTitles) -> Bool {
        let (targetID, zone, index) = Self.placement(of: target)
        guard !splitsDockedRootOutOfItself(targetID, zone) else { return false }
        let titler = tabTitler(titles)
        let next =
            switch content {
            case .pane(let node): Tree.insertPaneAt(rootNode, node, targetID, zone, titler, at: index)
            case .tab(let tab): Tree.insertTabAt(rootNode, tab, targetID, zone, titler, at: index)
            }
        guard next != rootNode else { return false }
        root = ensureRootGroup(next, titles: titles)
        activePaneID = resolveActive(entering(content.node))
        return true
    }
}
