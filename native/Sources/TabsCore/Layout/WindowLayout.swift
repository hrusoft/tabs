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
/// and the active pane. A port of the Electron app's `layoutStore`: every
/// operation runs on exactly one tree — the docked root or one floating
/// pane's content — and hands focus to what it created or moved, else keeps
/// it. Each returns whether anything changed.
package struct WindowLayout: Equatable, Sendable {
    package var id: WindowID
    package var root: TabGroup
    package var floating: [FloatingPane]
    /// The pane shown as active (its content outlined); always resolves to a node here.
    package var activePaneID: NodeID
    /// Where the window was on screen (nil: let the shell place it).
    package var frame: WindowFrame?

    /// A window around `root`, repaired: normalized, wrapped in the root group,
    /// floating panes sanitized, `active` kept if it still resolves.
    package init(
        id: WindowID = .make(), root: LayoutNode = .emptyLeaf(), floating: [FloatingPane] = [], active: NodeID? = nil,
        frame: WindowFrame? = nil, titles: LayoutTitles = LayoutTitles()
    ) {
        let normalized = Tree.normalize(root)
        self.id = id
        self.root = Tree.ensureTabsRoot(normalized) { titles.rootTabTitle(for: $0) }
        self.floating = Floating.sanitize(floating, against: .tabs(self.root))
        self.frame = frame
        self.activePaneID = Tree.firstPaneID(normalized)
        if let active { activePaneID = resolveActive(active) }
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

    /// The leaf `entryPaneID` of the active pane: what has keyboard focus.
    package var activeLeafID: NodeID? {
        guard let node = findNode(activePaneID) else { return nil }
        return Navigation.entryPaneID(node)
    }

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

    /// `desired` if it still exists anywhere, else the docked root's first pane.
    private func resolveActive(_ desired: NodeID) -> NodeID {
        if Tree.contains(rootNode, desired) || Floating.owning(floating, desired) != nil { return desired }
        return Tree.firstPaneID(rootNode)
    }

    private func ensureRootGroup(_ node: LayoutNode, titles: LayoutTitles, preferredTitle: () -> String? = { nil }) -> TabGroup {
        Tree.ensureTabsRoot(node) { preferredTitle() ?? titles.rootTabTitle(for: $0) }
    }

    /// The title for a rebuilt root wrapper: whichever of the root's tabs from
    /// before the operation is still found after it (not the one `excluded`
    /// names — that one moved).
    private static func survivorTitle(_ before: TabGroup, _ after: LayoutNode, excluding excluded: NodeID?) -> String? {
        for tab in before.tabs where tab.id != excluded && tab.content.id != excluded {
            if Tree.contains(after, tab.content.id) { return tab.title }
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
            let next = ensureRootGroup(rawNext, titles: titles) { Self.survivorTitle(previous, rawNext, excluding: id) }
            let target = Self.target(desired, in: .tabs(next), keeping: activePaneID)
            root = next
            activePaneID = resolveActive(target)
        case .floating(let index):
            let target = Self.target(desired, in: rawNext, keeping: activePaneID)
            floating[index].content = rawNext
            activePaneID = resolveActive(target)
        }
        return true
    }

    private static func target(_ desired: Desired, in next: LayoutNode, keeping current: NodeID) -> NodeID {
        switch desired {
        case .keep: current
        case .node(let node): node
        case .compute(let compute): compute(next) ?? current
        }
    }

    // MARK: Operations

    /// Makes `id` the active pane; a pane in a floating window raises it.
    @discardableResult
    package mutating func setActivePane(_ id: NodeID) -> Bool {
        let owner = owner(of: id)
        guard Tree.contains(tree(owner), id) else { return false }
        var raised = floating
        if case .floating(let index) = owner { raised = Floating.raise(floating, floating[index].id) }
        if id == activePaneID && raised == floating { return false }
        activePaneID = id
        floating = raised
        return true
    }

    @discardableResult
    package mutating func closeTab(_ tabID: NodeID, titles: LayoutTitles) -> Bool {
        withOwner(tabID, titles: titles) { Tree.closeTab($0, tabID) }
    }

    @discardableResult
    package mutating func activateTab(_ groupID: NodeID, _ tabID: NodeID, titles: LayoutTitles) -> Bool {
        withOwner(groupID, titles: titles) { Tree.activateTab($0, groupID, tabID) }
    }

    @discardableResult
    package mutating func moveTab(_ tabID: NodeID, to groupID: NodeID, at index: Int? = nil, titles: LayoutTitles) -> Bool {
        if withOwner(tabID, titles: titles, desired: .node(groupID), { Tree.moveTab($0, tabID, groupID, at: index) }) { return true }
        // A tab dropped back where it was changes nothing but still focuses
        // its group (the Electron store commits the reorder regardless).
        guard Tree.findTab(ownerTree(of: tabID), tabID)?.group.id == groupID else { return false }
        return setActivePane(groupID)
    }

    @discardableResult
    package mutating func dockTab(_ tabID: NodeID, onto targetID: NodeID, zone: DockZone, titles: LayoutTitles) -> Bool {
        guard !splitsDockedRootOutOfItself(targetID, zone) else { return false }
        let titler = tabTitler(titles)
        return withOwner(tabID, titles: titles, desired: .compute { Tree.findTab($0, tabID)?.group.id }) {
            Tree.dockTab($0, tabID, targetID, zone, titler)
        }
    }

    @discardableResult
    package mutating func renameTab(_ tabID: NodeID, _ title: String, titles: LayoutTitles) -> Bool {
        withOwner(tabID, titles: titles) { Tree.renameTab($0, tabID, title) }
    }

    @discardableResult
    package mutating func renamePane(_ id: NodeID, _ title: String?, titles: LayoutTitles) -> Bool {
        withOwner(id, titles: titles) { Tree.renamePane($0, id, title) }
    }

    @discardableResult
    package mutating func setLiveTitle(_ id: NodeID, _ title: String, titles: LayoutTitles) -> Bool {
        withOwner(id, titles: titles) { Tree.setLiveTitle($0, id, title) }
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
        let wasActive = target == activePaneID
        return withOwner(
            target, titles: titles, desired: .compute { next in wasActive ? Navigation.focusAfterClose(ownerTree, next, target) : nil }
        ) {
            Tree.closePane($0, target)
        }
    }

    /// Replaces a pane's content with a fresh empty pane, which keeps focus.
    @discardableResult
    package mutating func clearPane(_ id: NodeID, titles: LayoutTitles) -> Bool {
        let target = redirectFromDockedRoot(id)
        guard target != root.id, let node = findNode(target), !node.isEmpty else { return false }
        let empty = LayoutNode.emptyLeaf()
        return withOwner(target, titles: titles, desired: .node(empty.id)) { Tree.replaceContent($0, target, empty) }
    }

    /// Wraps a pane into a one-tab group, which becomes active.
    @discardableResult
    package mutating func wrapPaneInTabs(_ id: NodeID, titles: LayoutTitles) -> Bool {
        let target = redirectFromDockedRoot(id)
        let titler = tabTitler(titles)
        return withOwner(
            target, titles: titles,
            desired: .compute { next in
                if case .tab(let parent, _)? = Tree.findParent(next, target) { return parent.id }
                return target
            }
        ) { Tree.wrapInTabs($0, target, titler) }
    }

    /// Collapses a single-tab group to its content (never the docked root).
    @discardableResult
    package mutating func ungroupTabs(_ groupID: NodeID, titles: LayoutTitles) -> Bool {
        guard groupID != root.id else { return false }
        var survivor: LayoutNode?
        if case .tabs(let group)? = findNode(groupID), group.tabs.count == 1 { survivor = group.tabs[0].content }
        let desired: Desired = survivor.map { .node(Navigation.entryPaneID($0)) } ?? .keep
        return withOwner(groupID, titles: titles, desired: desired) { Tree.ungroupTabs($0, groupID) }
    }

    @discardableResult
    package mutating func dockPane(_ paneID: NodeID, onto targetID: NodeID, zone: DockZone, titles: LayoutTitles) -> Bool {
        guard !splitsDockedRootOutOfItself(targetID, zone) else { return false }
        let titler = tabTitler(titles)
        return withOwner(paneID, titles: titles, desired: .node(paneID)) { Tree.dockPane($0, paneID, targetID, zone, titler) }
    }

    @discardableResult
    package mutating func movePaneToTabs(_ paneID: NodeID, to groupID: NodeID, at index: Int? = nil, titles: LayoutTitles) -> Bool {
        let titler = tabTitler(titles)
        return withOwner(paneID, titles: titles, desired: .node(paneID)) { Tree.movePaneToTabs($0, paneID, groupID, titler, at: index) }
    }

    /// Lifts a docked pane into a floating pane at `rect` (clamped). Never the docked root.
    @discardableResult
    package mutating func unpinPane(_ id: NodeID, rect: FloatRect, viewport: Viewport, titles: LayoutTitles) -> Bool {
        guard id != root.id, let result = Floating.detachForFloat(rootNode, id, rect: Floating.clamp(rect, to: viewport)) else {
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
        activePaneID = content.id
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
        root = ensureRootGroup(rawRoot, titles: titles) { Self.survivorTitle(previous, rawRoot, excluding: subject.nodeKey) }
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

    /// Inserts content from another window at `target`, as a drop would; the
    /// moved content becomes active.
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
        activePaneID = resolveActive(content.node.id)
        return true
    }
}
