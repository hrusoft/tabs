import Foundation
import TabsPluginSDK

/// Any node of a layout tree: a leaf pane, a tab group, a split. One id space
/// for all of them (and for tabs), as in the Electron app's model.
package typealias NodeID = PaneID

package enum SplitDirection: String, Codable, Sendable {
    /// Children side by side.
    case horizontal
    /// Children stacked.
    case vertical
}

/// Where a dragged tab or pane docks relative to a pane: an edge splits the
/// pane and the dragged thing lands in the new half; `center` merges it into
/// the pane's tabs.
package enum DockZone: String, Codable, Sendable, CaseIterable {
    case left, right, top, bottom, center
}

/// A direction pane focus moves in (the navigation shortcuts).
package enum NavDirection: String, Codable, Sendable, CaseIterable {
    case left, right, up, down
}

/// Content: a pane with a content type, or an empty pane (`type == nil`, the
/// placeholder every structural operation collapses to). For a live pane,
/// `title` and `config` are refreshed from the plugin when the layout is
/// saved; for a pane whose plugin is missing they are kept verbatim.
///
/// `title` is the pane header's label override: a title the user set
/// (`titleIsManual`) or one the content reports; nil shows the type's name.
package struct LayoutLeaf: Equatable, Sendable {
    package var id: PaneID
    package var type: ContentTypeID?
    package var config: JSONValue
    package var title: String?
    package var titleIsManual: Bool

    package init(
        id: PaneID = .make(), type: ContentTypeID?, config: JSONValue = .emptyObject, title: String? = nil, titleIsManual: Bool = false
    ) {
        self.id = id
        self.type = type
        self.config = config
        self.title = title
        self.titleIsManual = titleIsManual
    }

    /// A pane holding nothing yet.
    package static func empty(_ id: PaneID = .make()) -> LayoutLeaf { LayoutLeaf(id: id, type: nil) }

    package var isEmpty: Bool { type == nil }
}

/// One tab: a title and the content it shows (any node, a group or a split included).
package struct Tab: Equatable, Sendable {
    package var id: NodeID
    package var title: String
    package var content: LayoutNode

    package init(id: NodeID = .make(), title: String, content: LayoutNode) {
        self.id = id
        self.title = title
        self.content = content
    }
}

/// Tabs, one of them shown.
package struct TabGroup: Equatable, Sendable {
    package var id: NodeID
    package var tabs: [Tab]
    package var activeTabID: NodeID?

    package init(id: NodeID = .make(), tabs: [Tab], activeTabID: NodeID?? = nil) {
        self.id = id
        self.tabs = tabs
        self.activeTabID = activeTabID ?? tabs.first?.id
    }

    package var activeIndex: Int? { tabs.firstIndex { $0.id == activeTabID } }
    package var activeTab: Tab? { tabs.first { $0.id == activeTabID } }
}

/// A container divided into resizable sections. `sizes` are fractions of the
/// container that sum to 1, one per child.
package struct Split: Equatable, Sendable {
    package var id: NodeID
    package var direction: SplitDirection
    package var children: [LayoutNode]
    package var sizes: [Double]

    package init(id: NodeID = .make(), direction: SplitDirection, children: [LayoutNode], sizes: [Double]? = nil) {
        self.id = id
        self.direction = direction
        self.children = children
        self.sizes = sizes ?? Tree.evenSizes(children.count)
    }
}

/// A node of a layout tree. Every node but a split is a pane: it can be
/// active, and it has chrome (a header, or a tab bar).
package indirect enum LayoutNode: Equatable, Sendable {
    case leaf(LayoutLeaf)
    case tabs(TabGroup)
    case split(Split)

    package var id: NodeID {
        switch self {
        case .leaf(let leaf): leaf.id
        case .tabs(let group): group.id
        case .split(let split): split.id
        }
    }

    package var group: TabGroup? { if case .tabs(let group) = self { group } else { nil } }
    package var splitNode: Split? { if case .split(let split) = self { split } else { nil } }
    package var leaf: LayoutLeaf? { if case .leaf(let leaf) = self { leaf } else { nil } }
    package var isTabs: Bool { group != nil }
    package var isSplit: Bool { splitNode != nil }
    package var isLeaf: Bool { leaf != nil }
    /// An empty pane (a leaf with no content type).
    package var isEmpty: Bool { leaf?.isEmpty == true }

    /// Every leaf under this node, depth first.
    package var leaves: [LayoutLeaf] {
        switch self {
        case .leaf(let leaf): [leaf]
        case .tabs(let group): group.tabs.flatMap(\.content.leaves)
        case .split(let split): split.children.flatMap(\.leaves)
        }
    }

    /// Every node id under this node, itself included (splits and groups too).
    package var nodeIDs: [NodeID] {
        switch self {
        case .leaf(let leaf): [leaf.id]
        case .tabs(let group): [group.id] + group.tabs.flatMap(\.content.nodeIDs)
        case .split(let split): [split.id] + split.children.flatMap(\.nodeIDs)
        }
    }

    package static func emptyLeaf(_ id: NodeID = .make()) -> LayoutNode { .leaf(.empty(id)) }
}

/// Names a node for the tab being created to hold it. `destGroup` is the
/// existing group the tab lands in, when there is one (nil when the operation
/// makes a new group around it) — which lets the window title tabs landing in
/// its root group differently.
package typealias TabTitler = (_ node: LayoutNode, _ destGroup: NodeID?) -> String

/// The tree operations — a port of the Electron app's `tree.ts`, kept
/// function-for-function so the two behave alike. Pure: every operation
/// returns a new tree; one that changes nothing returns an equal tree. Nodes
/// move by value but keep their ids, so whatever is keyed by an id (a live
/// pane's view) survives every relocation.
package enum Tree {
    /// Panes are never resized below this fraction of their split.
    package static let minPaneSize = 0.05

    // MARK: Lookup

    static func children(of node: LayoutNode) -> [LayoutNode] {
        switch node {
        case .tabs(let group): group.tabs.map(\.content)
        case .split(let split): split.children
        case .leaf: []
        }
    }

    package static func findNode(_ root: LayoutNode, _ id: NodeID) -> LayoutNode? {
        if root.id == id { return root }
        for child in children(of: root) {
            if let found = findNode(child, id) { return found }
        }
        return nil
    }

    package static func contains(_ root: LayoutNode, _ id: NodeID) -> Bool { findNode(root, id) != nil }

    /// The first pane reachable from `root`: into a split's first child, but
    /// not into a tab group's tabs (a group is itself a pane that can be
    /// active). `Navigation.entryPaneID` descends to the visible leaf.
    package static func firstPaneID(_ root: LayoutNode) -> NodeID {
        if case .split(let split) = root, let first = split.children.first { return firstPaneID(first) }
        return root.id
    }

    package enum ParentRef: Equatable {
        case split(parent: Split, index: Int)
        case tab(parent: TabGroup, tab: Tab)
    }

    /// The node directly containing `id`: a split it is a child of, or the
    /// group whose tab holds it. nil for the root, and for an id not in the tree.
    package static func findParent(_ root: LayoutNode, _ id: NodeID) -> ParentRef? {
        switch root {
        case .tabs(let group):
            for tab in group.tabs {
                if tab.content.id == id { return .tab(parent: group, tab: tab) }
                if let found = findParent(tab.content, id) { return found }
            }
        case .split(let split):
            for (index, child) in split.children.enumerated() {
                if child.id == id { return .split(parent: split, index: index) }
                if let found = findParent(child, id) { return found }
            }
        case .leaf:
            break
        }
        return nil
    }

    package struct TabRef: Equatable {
        package var group: TabGroup
        package var tab: Tab
        package var index: Int
    }

    package static func findTab(_ root: LayoutNode, _ tabID: NodeID) -> TabRef? {
        if case .tabs(let group) = root, let index = group.tabs.firstIndex(where: { $0.id == tabID }) {
            return TabRef(group: group, tab: group.tabs[index], index: index)
        }
        for child in children(of: root) {
            if let found = findTab(child, tabID) { return found }
        }
        return nil
    }

    /// The tree with `transform` applied to every leaf.
    package static func mapLeaves(_ root: LayoutNode, _ transform: (LayoutLeaf) -> LayoutLeaf) -> LayoutNode {
        switch root {
        case .leaf(let leaf):
            return .leaf(transform(leaf))
        case .tabs(var group):
            for index in group.tabs.indices { group.tabs[index].content = mapLeaves(group.tabs[index].content, transform) }
            return .tabs(group)
        case .split(var split):
            for index in split.children.indices { split.children[index] = mapLeaves(split.children[index], transform) }
            return .split(split)
        }
    }

    // MARK: Structural replacement

    /// The tree with `transform` applied to the node `id`. `transform`
    /// returning nil removes the node: a removed split child drops its size
    /// slot, a removed tab content closes its tab. nil only when the root
    /// itself is removed. An absent `id` returns the tree unchanged.
    ///
    /// `redistributeOnRemove` hands a removed split child's size to its
    /// neighbour(s) instead of leaving the shortfall for `normalizeSizes` to
    /// spread over every sibling — only real closes (`removeNode`) want it.
    package static func replaceNode(
        _ root: LayoutNode, _ id: NodeID, redistributeOnRemove: Bool = false, _ transform: (LayoutNode) -> LayoutNode?
    ) -> LayoutNode? {
        if root.id == id { return transform(root) }
        switch root {
        case .leaf:
            return root
        case .tabs(var group):
            guard let index = group.tabs.firstIndex(where: { contains($0.content, id) }) else { return root }
            if let result = replaceNode(group.tabs[index].content, id, redistributeOnRemove: redistributeOnRemove, transform) {
                group.tabs[index].content = result
            } else {
                group.tabs.remove(at: index)
            }
            return .tabs(group)
        case .split(var split):
            guard let index = split.children.firstIndex(where: { contains($0, id) }) else { return root }
            if let result = replaceNode(split.children[index], id, redistributeOnRemove: redistributeOnRemove, transform) {
                split.children[index] = result
            } else {
                if redistributeOnRemove, split.sizes.indices.contains(index) {
                    let freed = split.sizes[index]
                    let hasLeft = index > 0
                    let hasRight = index < split.sizes.count - 1
                    if hasLeft && hasRight {
                        split.sizes[index - 1] += freed / 2
                        split.sizes[index + 1] += freed / 2
                    } else if hasLeft {
                        split.sizes[index - 1] += freed
                    } else if hasRight {
                        split.sizes[index + 1] += freed
                    }
                }
                split.children.remove(at: index)
                if split.sizes.indices.contains(index) { split.sizes.remove(at: index) }
            }
            return .split(split)
        }
    }

    // MARK: Sizes

    package static func evenSizes(_ count: Int) -> [Double] {
        count > 0 ? Array(repeating: 1 / Double(count), count: count) : []
    }

    /// Repairs a sizes array: non-finite or negative entries become 0, the
    /// array is scaled to sum to 1, and every entry is raised to the minimum
    /// pane size (taken proportionally from the larger ones).
    package static func normalizeSizes(_ sizes: [Double]) -> [Double] {
        let count = sizes.count
        if count == 0 { return [] }
        let minimum = min(minPaneSize, 1 / Double(count))
        var values = sizes.map { $0.isFinite && $0 > 0 ? $0 : 0 }
        let total = values.reduce(0, +)
        values = total <= 0 ? evenSizes(count) : values.map { $0 / total }
        for _ in 0..<count {
            let low = Set(values.indices.filter { values[$0] < minimum })
            if low.isEmpty { break }
            if low.count == count { return evenSizes(count) }
            let rest = values.indices.reduce(0.0) { low.contains($1) ? $0 : $0 + values[$1] }
            let scale = (1 - minimum * Double(low.count)) / rest
            values = values.indices.map { low.contains($0) ? minimum : values[$0] * scale }
        }
        return values
    }

    static func sizesEqual(_ a: [Double], _ b: [Double]) -> Bool {
        a.count == b.count && zip(a, b).allSatisfy { abs($0 - $1) < 1e-9 }
    }

    // MARK: Normalization

    /// Bottom-up invariant repair: splits with no children go, single-child
    /// splits unwrap, child splits sharing their parent's direction flatten
    /// into it, sizes are renormalized, a stale active tab falls back to the
    /// first, and a group left without tabs becomes an empty pane in place
    /// (only an explicit `removeNode` removes a slot).
    package static func normalize(_ root: LayoutNode) -> LayoutNode {
        normalizeNode(root) ?? .emptyLeaf()
    }

    private static func normalizeNode(_ node: LayoutNode) -> LayoutNode? {
        switch node {
        case .leaf: node
        case .tabs(let group): normalizeTabs(group)
        case .split(let split): normalizeSplit(split)
        }
    }

    private static func normalizeTabs(_ node: TabGroup) -> LayoutNode {
        var tabs: [Tab] = []
        for tab in node.tabs {
            guard let content = normalizeNode(tab.content) else { continue }
            var kept = tab
            kept.content = content
            tabs.append(kept)
        }
        if tabs.isEmpty { return .emptyLeaf() }
        var group = node
        group.tabs = tabs
        if !tabs.contains(where: { $0.id == group.activeTabID }) { group.activeTabID = tabs[0].id }
        return .tabs(group)
    }

    private static func normalizeSplit(_ node: Split) -> LayoutNode? {
        var children: [LayoutNode] = []
        var sizes: [Double] = []
        for (index, child) in node.children.enumerated() {
            let size = node.sizes.indices.contains(index) ? node.sizes[index] : 0
            guard let result = normalizeNode(child) else { continue }
            if case .split(let inner) = result, inner.direction == node.direction {
                for (innerIndex, grandchild) in inner.children.enumerated() {
                    children.append(grandchild)
                    sizes.append(size * (inner.sizes.indices.contains(innerIndex) ? inner.sizes[innerIndex] : 0))
                }
                continue
            }
            children.append(result)
            sizes.append(size)
        }
        if children.isEmpty { return nil }
        if children.count == 1 { return children[0] }
        var split = node
        split.children = children
        let repaired = normalizeSizes(sizes)
        split.sizes = sizesEqual(repaired, node.sizes) && children.count == node.children.count ? node.sizes : repaired
        return .split(split)
    }

    // MARK: Tab operations

    /// The element that takes over when `index`'s goes away: the right
    /// neighbour, else the left — the one convention every "what survives a
    /// removal" choice follows.
    package static func neighbour<T>(of list: [T], at index: Int) -> T? {
        if list.indices.contains(index + 1) { return list[index + 1] }
        if list.indices.contains(index - 1) { return list[index - 1] }
        return nil
    }

    /// `replaceNode` narrowed to a tab group: `transform` runs only when `id`
    /// names one.
    private static func updateTabsGroup(_ root: LayoutNode, _ id: NodeID, _ transform: (TabGroup) -> LayoutNode) -> LayoutNode {
        replaceNode(root, id) { node in
            if case .tabs(let group) = node { return transform(group) }
            return node
        } ?? root
    }

    /// Inserts `tab` into the group `groupID` (appended, or at `index`) and activates it.
    package static func addTab(_ root: LayoutNode, _ groupID: NodeID, _ tab: Tab, at index: Int? = nil) -> LayoutNode {
        updateTabsGroup(root, groupID) { group in
            var group = group
            let at = index.map { max(0, min($0, group.tabs.count)) } ?? group.tabs.count
            group.tabs.insert(tab, at: at)
            group.activeTabID = tab.id
            return .tabs(group)
        }
    }

    package static func activateTab(_ root: LayoutNode, _ groupID: NodeID, _ tabID: NodeID) -> LayoutNode {
        updateTabsGroup(root, groupID) { group in
            guard group.activeTabID != tabID, group.tabs.contains(where: { $0.id == tabID }) else { return .tabs(group) }
            var group = group
            group.activeTabID = tabID
            return .tabs(group)
        }
    }

    /// Removes a tab from `group`, activating its right neighbour (or left at
    /// the end). A group left with exactly one tab collapses to that tab's
    /// own content, in place.
    private static func withTabRemoved(_ group: TabGroup, _ tabID: NodeID) -> LayoutNode {
        guard let index = group.tabs.firstIndex(where: { $0.id == tabID }) else { return .tabs(group) }
        let tabs = group.tabs.filter { $0.id != tabID }
        if tabs.count == 1 { return tabs[0].content }
        var result = group
        result.tabs = tabs
        if group.activeTabID == tabID { result.activeTabID = neighbour(of: group.tabs, at: index)?.id }
        return .tabs(result)
    }

    /// The tree without `tabID` (collapse rules included); nil when that
    /// consumed the whole tree.
    private static func removeTabFromGroup(_ root: LayoutNode, _ groupID: NodeID, _ tabID: NodeID) -> LayoutNode? {
        replaceNode(root, groupID) { node in
            if case .tabs(let group) = node { return withTabRemoved(group, tabID) }
            return node
        }
    }

    package static func closeTab(_ root: LayoutNode, _ tabID: NodeID) -> LayoutNode {
        guard let ref = findTab(root, tabID) else { return root }
        return normalize(removeTabFromGroup(root, ref.group.id, tabID) ?? root)
    }

    /// Collapses a single-tab group to its tab's content, in place.
    package static func ungroupTabs(_ root: LayoutNode, _ groupID: NodeID) -> LayoutNode {
        normalize(
            updateTabsGroup(root, groupID) { group in
                group.tabs.count == 1 ? group.tabs[0].content : .tabs(group)
            })
    }

    package static func renameTab(_ root: LayoutNode, _ tabID: NodeID, _ title: String) -> LayoutNode {
        guard let ref = findTab(root, tabID), ref.tab.title != title else { return root }
        return updateTabsGroup(root, ref.group.id) { group in
            var group = group
            for index in group.tabs.indices where group.tabs[index].id == tabID { group.tabs[index].title = title }
            return .tabs(group)
        }
    }

    /// Applies `transform` to the leaf `id`, rebuilding only the path to it.
    private static func updateLeaf(_ root: LayoutNode, _ id: NodeID, _ transform: (LayoutLeaf) -> LayoutLeaf) -> LayoutNode {
        guard case .leaf(let leaf)? = findNode(root, id) else { return root }
        let next = transform(leaf)
        if next == leaf { return root }
        return replaceNode(root, id) { _ in .leaf(next) } ?? root
    }

    /// Sets a pane's header title override (nil clears it back to the
    /// content's own name) and marks it manual, so the content's own
    /// reported title no longer replaces it.
    package static func renamePane(_ root: LayoutNode, _ id: NodeID, _ title: String?) -> LayoutNode {
        updateLeaf(root, id) { leaf in
            var leaf = leaf
            leaf.title = title
            leaf.titleIsManual = title != nil
            return leaf
        }
    }

    /// Sets a pane's title from its content — ignored once the user renamed it.
    package static func setLiveTitle(_ root: LayoutNode, _ id: NodeID, _ title: String) -> LayoutNode {
        let next: String? = title.isEmpty ? nil : title
        return updateLeaf(root, id) { leaf in
            guard !leaf.titleIsManual, leaf.title != next else { return leaf }
            var leaf = leaf
            leaf.title = next
            return leaf
        }
    }

    /// Moves a tab within its group (reorder), to another existing group, or
    /// onto an empty pane (which becomes a group holding just that tab).
    package static func moveTab(_ root: LayoutNode, _ tabID: NodeID, _ targetGroupID: NodeID, at index: Int? = nil) -> LayoutNode {
        guard let ref = findTab(root, tabID) else { return root }
        if ref.group.id == targetGroupID {
            return updateTabsGroup(root, targetGroupID) { group in
                var group = group
                guard let from = group.tabs.firstIndex(where: { $0.id == tabID }) else { return .tabs(group) }
                let moved = group.tabs.remove(at: from)
                let at = index.map { max(0, min($0, group.tabs.count)) } ?? group.tabs.count
                group.tabs.insert(moved, at: at)
                group.activeTabID = moved.id
                return .tabs(group)
            }
        }
        guard let target = findNode(root, targetGroupID), target.isTabs || target.isEmpty else { return root }
        let removed = removeTabFromGroup(root, ref.group.id, tabID) ?? root
        // The target vanished with the removal: it lived inside the moved tab.
        guard contains(removed, targetGroupID) else { return root }
        return insertTabIntoGroupOrEmpty(removed, ref.tab, targetGroupID, at: index)
    }

    // MARK: Split operations

    /// Splits `targetID` in `direction`, placing `newNode` beside it. In a
    /// same-direction split the new node is spliced in beside the target,
    /// taking half its share; otherwise the target becomes a 50/50 split.
    package static func splitContent(
        _ root: LayoutNode, _ targetID: NodeID, _ direction: SplitDirection, _ newNode: LayoutNode, before: Bool = false
    ) -> LayoutNode {
        if case .split(let parent, _)? = findParent(root, targetID), parent.direction == direction {
            let next = replaceNode(root, parent.id) { node in
                guard case .split(var split) = node, let at = split.children.firstIndex(where: { $0.id == targetID }) else { return node }
                let half = (split.sizes.indices.contains(at) ? split.sizes[at] : 1 / Double(split.children.count)) / 2
                if split.sizes.indices.contains(at) { split.sizes[at] = half }
                let insertAt = before ? at : at + 1
                split.children.insert(newNode, at: insertAt)
                split.sizes.insert(half, at: min(insertAt, split.sizes.count))
                return .split(split)
            }
            return normalize(next ?? root)
        }
        let next = replaceNode(root, targetID) { node in
            .split(Split(direction: direction, children: before ? [newNode, node] : [node, newNode]))
        }
        return normalize(next ?? root)
    }

    /// Whether docking `tabID` at `zone` of `targetID` would change anything
    /// (the hover check: a declined zone shows no preview).
    package static func canDockTab(_ root: LayoutNode, _ tabID: NodeID, _ targetID: NodeID, _ zone: DockZone) -> Bool {
        guard let ref = findTab(root, tabID), let target = findNode(root, targetID), !target.isSplit else { return false }
        // Onto a pane inside the dragged tab's own content: the tab would nest into itself.
        if contains(ref.tab.content, targetID) { return false }
        if zone == .center { return targetID != ref.group.id }
        // Splitting a group off itself only rearranges when other tabs remain.
        return targetID != ref.group.id || ref.group.tabs.count > 1
    }

    static func edgeZoneToSplit(_ zone: DockZone) -> (direction: SplitDirection, before: Bool) {
        (zone == .left || zone == .right ? .horizontal : .vertical, zone == .left || zone == .top)
    }

    /// The tab wrapping `targetID` when it lives in `groupID` — read before a
    /// removal that can collapse that group (and lose the tab's title).
    private static func wrappingTab(in root: LayoutNode, _ targetID: NodeID, _ groupID: NodeID?) -> Tab? {
        guard let groupID, case .tab(let parent, let tab)? = findParent(root, targetID), parent.id == groupID else { return nil }
        return tab
    }

    /// Promotes the bare content at `targetID` into a two-tab group holding it
    /// and `incoming`. `wrapperTitle` rebuilds the collapsed-root case: when
    /// the removal left the target as the whole tree, the promotion is nested
    /// one level in under the preserved title.
    private static func promoteIntoTabs(
        _ tree: LayoutNode, _ targetID: NodeID, _ incoming: Tab, _ titleOf: TabTitler, _ wrapperTitle: String?
    ) -> LayoutNode {
        func promotion(_ target: LayoutNode) -> LayoutNode {
            .tabs(TabGroup(tabs: [Tab(title: titleOf(target, nil), content: target), incoming], activeTabID: incoming.id))
        }
        if let wrapperTitle, tree.id == targetID {
            return normalize(.tabs(TabGroup(tabs: [Tab(title: wrapperTitle, content: promotion(tree))])))
        }
        return normalize(replaceNode(tree, targetID) { promotion($0) } ?? tree)
    }

    /// A center drop of `tab` onto a group (at `index`, else appended) or an
    /// empty pane (which becomes a group under the pane's own id).
    private static func insertTabIntoGroupOrEmpty(_ root: LayoutNode, _ tab: Tab, _ targetID: NodeID, at index: Int? = nil) -> LayoutNode {
        guard let target = findNode(root, targetID) else { return root }
        if target.isEmpty {
            let converted = replaceNode(root, targetID) { _ in .tabs(TabGroup(id: targetID, tabs: [tab])) }
            return normalize(converted ?? root)
        }
        return normalize(addTab(root, targetID, tab, at: index))
    }

    /// Places `tab` at `targetID`/`zone`, any same-tree removal already done.
    private static func insertTab(
        _ root: LayoutNode, _ tab: Tab, _ targetID: NodeID, _ zone: DockZone, _ titleOf: TabTitler, _ targetOwnTabTitle: String?,
        at index: Int? = nil
    ) -> LayoutNode {
        if zone == .center {
            guard let target = findNode(root, targetID) else { return root }
            if target.isTabs || target.isEmpty { return insertTabIntoGroupOrEmpty(root, tab, targetID, at: index) }
            return promoteIntoTabs(root, targetID, tab, titleOf, targetOwnTabTitle)
        }
        let (direction, before) = edgeZoneToSplit(zone)
        return splitContent(root, targetID, direction, .tabs(TabGroup(tabs: [tab])), before: before)
    }

    /// Docks a dragged tab against `targetID`: an edge splits the pane with
    /// the tab in the new half as a one-tab group; center merges it (appended
    /// to a group, converting an empty pane, promoting a leaf into a group).
    package static func dockTab(_ root: LayoutNode, _ tabID: NodeID, _ targetID: NodeID, _ zone: DockZone, _ titleOf: TabTitler)
        -> LayoutNode
    {
        guard canDockTab(root, tabID, targetID, zone), let ref = findTab(root, tabID) else { return root }
        if zone == .center {
            guard let target = findNode(root, targetID) else { return root }
            if target.isTabs || target.isEmpty { return moveTab(root, tabID, targetID) }
            let targetOwnTab = wrappingTab(in: root, targetID, ref.group.id)
            let removed = removeTabFromGroup(root, ref.group.id, tabID) ?? root
            guard contains(removed, targetID) else { return root }
            return insertTab(removed, ref.tab, targetID, zone, titleOf, targetOwnTab?.title)
        }
        let removed = removeTabFromGroup(root, ref.group.id, tabID) ?? root
        var effectiveTarget = targetID
        if !contains(removed, targetID) {
            // Only the source group itself can vanish, collapsed to its survivor.
            guard targetID == ref.group.id, let survivor = ref.group.tabs.first(where: { $0.id != tabID }) else { return root }
            effectiveTarget = survivor.content.id
        }
        return insertTab(removed, ref.tab, effectiveTarget, zone, titleOf, nil)
    }

    /// Inserts a tab not yet anywhere in `root` (the cross-window counterpart
    /// of `dockTab`).
    package static func insertTabAt(
        _ root: LayoutNode, _ tab: Tab, _ targetID: NodeID, _ zone: DockZone, _ titleOf: TabTitler, at index: Int? = nil
    ) -> LayoutNode {
        guard canDockExternalTarget(root, targetID) else { return root }
        return insertTab(root, tab, targetID, zone, titleOf, nil, at: index)
    }

    package static func resizeSplit(_ root: LayoutNode, _ splitID: NodeID, _ sizes: [Double]) -> LayoutNode {
        replaceNode(root, splitID) { node in
            guard case .split(var split) = node, sizes.count == split.children.count else { return node }
            let repaired = normalizeSizes(sizes)
            if sizesEqual(repaired, split.sizes) { return node }
            split.sizes = repaired
            return .split(split)
        } ?? root
    }

    // MARK: Replacement and removal

    /// Swaps the node `id` for entirely new content.
    package static func replaceContent(_ root: LayoutNode, _ id: NodeID, _ content: LayoutNode) -> LayoutNode {
        normalize(replaceNode(root, id) { _ in content } ?? root)
    }

    /// Removes any node. Removing the root resets it to an empty pane.
    package static func removeNode(_ root: LayoutNode, _ id: NodeID) -> LayoutNode {
        if root.id == id { return .emptyLeaf() }
        return normalize(replaceNode(root, id, redistributeOnRemove: true) { _ in nil } ?? root)
    }

    // MARK: Pane operations

    /// The pane `paneID` if a pane drag may move it: it exists and isn't the root.
    private static func detachablePane(_ root: LayoutNode, _ paneID: NodeID) -> LayoutNode? {
        root.id == paneID ? nil : findNode(root, paneID)
    }

    /// The tree with the pane spliced out, ready to insert elsewhere: a split
    /// child gives up its slot, a pane in a tab closes that tab (collapse
    /// rules included), and a group emptied by the departure goes entirely.
    /// nil when that consumed the whole tree. Not normalized.
    package static func withPaneDetached(_ root: LayoutNode, _ paneID: NodeID) -> LayoutNode? {
        if case .tab(let group, let tab)? = findParent(root, paneID) {
            if group.tabs.count == 1 { return replaceNode(root, group.id) { _ in nil } }
            return removeTabFromGroup(root, group.id, tab.id)
        }
        return replaceNode(root, paneID) { _ in nil }
    }

    /// The tab-side twin of `withPaneDetached`. Not normalized.
    package static func withTabDetached(_ root: LayoutNode, _ tabID: NodeID) -> LayoutNode? {
        guard let ref = findTab(root, tabID) else { return nil }
        return ref.group.tabs.count == 1
            ? replaceNode(root, ref.group.id) { _ in nil }
            : removeTabFromGroup(root, ref.group.id, tabID)
    }

    /// Closes the pane `id` and everything in it. A pane in a tab closes that
    /// tab (neighbour activation and lone-tab collapse included); anything
    /// else is removed (the root resets to an empty pane).
    package static func closePane(_ root: LayoutNode, _ id: NodeID) -> LayoutNode {
        if case .tab(_, let tab)? = findParent(root, id) { return closeTab(root, tab.id) }
        return removeNode(root, id)
    }

    /// Wraps the node `id` into a new group holding it as the only tab.
    package static func wrapInTabs(_ root: LayoutNode, _ id: NodeID, _ titleOf: TabTitler) -> LayoutNode {
        normalize(replaceNode(root, id) { node in .tabs(TabGroup(tabs: [Tab(title: titleOf(node, nil), content: node)])) } ?? root)
    }

    /// The docked root's invariant: always a tab group (its bar is the
    /// window's title bar). Wraps anything else as the only tab.
    package static func ensureTabsRoot(_ node: LayoutNode, _ titleOf: (LayoutNode) -> String) -> TabGroup {
        if case .tabs(let group) = node { return group }
        return TabGroup(tabs: [Tab(title: titleOf(node), content: node)])
    }

    /// Whether docking the pane `paneID` against `targetID` would change anything.
    package static func canDockPane(_ root: LayoutNode, _ paneID: NodeID, _ targetID: NodeID, _ zone: DockZone) -> Bool {
        guard let pane = detachablePane(root, paneID), let target = findNode(root, targetID), !target.isSplit else { return false }
        if contains(pane, targetID) { return false }
        if case .tab(let group, _)? = findParent(root, paneID), targetID == group.id {
            if zone == .center { return false }
            return group.tabs.count >= 2
        }
        return true
    }

    /// Whether `targetID` can take a pane or tab from another tree: it exists
    /// and isn't a split.
    package static func canDockExternalTarget(_ root: LayoutNode, _ targetID: NodeID) -> Bool {
        guard let target = findNode(root, targetID) else { return false }
        return !target.isSplit
    }

    /// Whether dropping the pane on the bar of `targetGroupID` would change anything.
    package static func canMovePaneToTabs(_ root: LayoutNode, _ paneID: NodeID, _ targetGroupID: NodeID) -> Bool {
        guard let pane = detachablePane(root, paneID), let target = findNode(root, targetGroupID), target.isTabs else { return false }
        if contains(pane, targetGroupID) { return false }
        if case .tab(let group, _)? = findParent(root, paneID), targetGroupID == group.id { return group.tabs.count >= 3 }
        return true
    }

    /// Whether dropping the tab on the bar of `targetGroupID` is meaningful
    /// (its own bar is: that's a reorder).
    package static func canMoveTabToTabs(_ root: LayoutNode, _ tabID: NodeID, _ targetGroupID: NodeID) -> Bool {
        guard let ref = findTab(root, tabID), let target = findNode(root, targetGroupID), target.isTabs else { return false }
        return !contains(ref.tab.content, targetGroupID)
    }

    /// Places `pane` at `targetID`/`zone`, any same-tree removal already done.
    private static func insertPane(
        _ root: LayoutNode, _ pane: LayoutNode, _ targetID: NodeID, _ zone: DockZone, _ titleOf: TabTitler, _ targetOwnTabTitle: String?,
        at index: Int? = nil
    ) -> LayoutNode {
        if zone == .center {
            guard let target = findNode(root, targetID) else { return root }
            if target.isTabs {
                return normalize(addTab(root, targetID, Tab(title: titleOf(pane, targetID), content: pane), at: index))
            }
            if target.isEmpty {
                // The pane takes the placeholder's slot under its own id.
                return normalize(replaceNode(root, targetID) { _ in pane } ?? root)
            }
            return promoteIntoTabs(root, targetID, Tab(title: titleOf(pane, nil), content: pane), titleOf, targetOwnTabTitle)
        }
        let (direction, before) = edgeZoneToSplit(zone)
        return splitContent(root, targetID, direction, pane, before: before)
    }

    /// Docks a dragged pane against `targetID` — `dockTab`'s pane mirror. An
    /// edge splits the target with the pane bare in the new half; center
    /// merges (a tab of a group, an empty pane's slot, or a promotion). A tab
    /// that held the pane closes behind it.
    package static func dockPane(_ root: LayoutNode, _ paneID: NodeID, _ targetID: NodeID, _ zone: DockZone, _ titleOf: TabTitler)
        -> LayoutNode
    {
        guard canDockPane(root, paneID, targetID, zone), let pane = findNode(root, paneID) else { return root }
        let parentRef = findParent(root, paneID)
        var sourceGroup: TabGroup?
        var sourceTab: Tab?
        if case .tab(let group, let tab)? = parentRef {
            sourceGroup = group
            sourceTab = tab
        }
        let targetOwnTab = wrappingTab(in: root, targetID, sourceGroup?.id)
        guard let detached = withPaneDetached(root, paneID) else { return root }
        var effectiveTarget = targetID
        if !contains(detached, targetID) {
            // Only the pane's own two-tab group can vanish, collapsed to its survivor.
            guard let sourceGroup, let sourceTab, targetID == sourceGroup.id,
                let survivor = sourceGroup.tabs.first(where: { $0.id != sourceTab.id })
            else { return root }
            effectiveTarget = survivor.content.id
        }
        return insertPane(detached, pane, effectiveTarget, zone, titleOf, targetOwnTab?.title)
    }

    /// Inserts a pane not yet anywhere in `root` (the cross-window counterpart of `dockPane`).
    package static func insertPaneAt(
        _ root: LayoutNode, _ pane: LayoutNode, _ targetID: NodeID, _ zone: DockZone, _ titleOf: TabTitler, at index: Int? = nil
    ) -> LayoutNode {
        guard canDockExternalTarget(root, targetID) else { return root }
        return insertPane(root, pane, targetID, zone, titleOf, nil, at: index)
    }

    /// Moves a pane into the group `targetGroupID` as a new tab at `index`.
    package static func movePaneToTabs(
        _ root: LayoutNode, _ paneID: NodeID, _ targetGroupID: NodeID, _ titleOf: TabTitler, at index: Int? = nil
    ) -> LayoutNode {
        guard canMovePaneToTabs(root, paneID, targetGroupID), let pane = findNode(root, paneID),
            let detached = withPaneDetached(root, paneID), contains(detached, targetGroupID)
        else { return root }
        return normalize(addTab(detached, targetGroupID, Tab(title: titleOf(pane, targetGroupID), content: pane), at: index))
    }

    // MARK: Content placement

    /// Opens `content` at `targetID` without destroying what's there: a group
    /// gets a new tab; an empty pane is replaced (unless `content` is empty
    /// too); a tab's content gets a sibling tab in its group; anything else is
    /// promoted into the first tab of a new group with `content` second.
    package static func openContent(_ root: LayoutNode, _ targetID: NodeID, _ content: LayoutNode, _ titleOf: TabTitler) -> LayoutNode {
        guard let target = findNode(root, targetID) else { return root }
        if target.isEmpty && !content.isEmpty { return replaceContent(root, targetID, content) }
        let groupID: NodeID? =
            if target.isTabs {
                target.id
            } else if case .tab(let parent, _)? = findParent(root, targetID) {
                parent.id
            } else {
                nil
            }
        if let groupID { return addTab(root, groupID, Tab(title: titleOf(content, groupID), content: content)) }
        let tab = Tab(title: titleOf(content, nil), content: content)
        let next = replaceNode(root, targetID) { node in
            .tabs(TabGroup(tabs: node.isEmpty ? [tab] : [Tab(title: titleOf(node, nil), content: node), tab], activeTabID: tab.id))
        }
        return normalize(next ?? root)
    }
}
