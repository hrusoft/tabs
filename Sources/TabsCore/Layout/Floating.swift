import Foundation
import TabsPluginSDK

/// Geometry of a floating pane in its window's content, in points from the
/// top-left.
package struct FloatRect: Codable, Equatable, Sendable {
    package var x, y, width, height: Double

    package init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
}

/// A content area's size, in points.
package struct Viewport: Equatable, Sendable {
    package var width, height: Double

    package init(width: Double, height: Double) {
        self.width = width
        self.height = height
    }
}

/// Where a floating pane came from, so pinning it back can put it there:
/// the container it lived in (exact while that survives) and the siblings it
/// sat between (the fallback when its departure collapsed the container).
package indirect enum FloatAnchor: Equatable, Sendable {
    case split(SplitAnchor)
    case tab(TabAnchor)
    /// It was the whole docked layout, or it never had a place (a new unpinned pane).
    case root

    package struct SplitAnchor: Equatable, Sendable {
        package var splitID: NodeID
        package var direction: SplitDirection
        package var index: Int
        package var size: Double
        package var beforeID: NodeID?
        package var afterID: NodeID?
    }

    package struct TabAnchor: Equatable, Sendable {
        package var groupID: NodeID
        package var index: Int
        /// The tab's own title (a user rename can't be derived again).
        package var title: String
        package var beforeTabID: NodeID?
        package var afterTabID: NodeID?
        /// The group's other tabs, in order: what rebuilds a group the departure collapsed.
        package var siblings: [Sibling]
        package var wasActive: Bool
        /// Where the group itself sat, when this was its only tab.
        package var groupAnchor: FloatAnchor?
        /// Whether the group was the docked root (never rebuilt: its collapse is rewrapped).
        package var groupWasRoot: Bool
    }

    package struct Sibling: Equatable, Sendable {
        package var id: NodeID
        package var title: String
        package var contentID: NodeID
    }
}

/// One floating window: a subtree, where it sits, and where it came from.
/// `id` is the window's own identity, never its content's (which changes
/// whenever an operation replaces the subtree's root).
package struct FloatingPane: Equatable, Sendable {
    package var id: NodeID
    package var content: LayoutNode
    package var rect: FloatRect
    package var anchor: FloatAnchor

    package init(id: NodeID = .make(), content: LayoutNode, rect: FloatRect, anchor: FloatAnchor) {
        self.id = id
        self.content = content
        self.rect = rect
        self.anchor = anchor
    }
}

/// Which section of the pane it spawns from a new unpinned pane lands in.
package enum SpawnPosition: String, Codable, Sendable, CaseIterable {
    case topLeft = "top-left", topCenter = "top-center", topRight = "top-right"
    case middleLeft = "middle-left", middleCenter = "middle-center", middleRight = "middle-right"
    case bottomLeft = "bottom-left", bottomCenter = "bottom-center", bottomRight = "bottom-right"

    package static let `default` = SpawnPosition.topRight

    /// 0 against the leading edge, 1 the trailing edge, 0.5 centered.
    var fractions: (column: Double, row: Double) {
        let parts = rawValue.split(separator: "-")
        let row: Double = parts[0] == "top" ? 0 : parts[0] == "middle" ? 0.5 : 1
        let column: Double = parts[1] == "left" ? 0 : parts[1] == "center" ? 0.5 : 1
        return (column, row)
    }
}

/// Floating panes.
package enum Floating {
    /// Smallest a floating pane may be moved or resized to.
    package static let minSize = (width: 240.0, height: 120.0)
    /// How much of a window must stay inside the viewport.
    static let keepOnScreen = 80.0
    package static let defaultRect = FloatRect(x: 48, y: 48, width: 640, height: 400)
    /// Gap kept between a new unpinned pane and the pane it spawns over.
    package static let spawnSpacing = 16.0

    // MARK: Spawning

    /// A new unpinned pane's geometry: `position`'s section of `origin`,
    /// sized off the origin (capped at the default size).
    package static func spawnRect(in origin: FloatRect, at position: SpawnPosition) -> FloatRect {
        let (column, row) = position.fractions
        let width = spawnSize(origin.width, defaultRect.width, minSize.width)
        let height = spawnSize(origin.height, defaultRect.height, minSize.height)
        return FloatRect(
            x: spawnOffset(origin.x, origin.width, width, column), y: spawnOffset(origin.y, origin.height, height, row),
            width: width, height: height)
    }

    private static func spawnSize(_ originSize: Double, _ preferred: Double, _ minimum: Double) -> Double {
        min(preferred, max(minimum, originSize - spawnSpacing * 2))
    }

    private static func spawnOffset(_ start: Double, _ originSize: Double, _ size: Double, _ fraction: Double) -> Double {
        start + spawnSpacing + fraction * (originSize - size - spawnSpacing * 2)
    }

    // MARK: Anchoring

    /// Where `id` sits now, as `restoreAtAnchor` can aim at it later. nil when
    /// `id` isn't in the tree.
    package static func captureAnchor(_ root: LayoutNode, _ id: NodeID) -> FloatAnchor? {
        guard let ref = Tree.findParent(root, id) else { return Tree.contains(root, id) ? .root : nil }
        switch ref {
        case .split(let parent, let index):
            return .split(
                .init(
                    splitID: parent.id, direction: parent.direction, index: index,
                    size: parent.sizes.indices.contains(index) ? parent.sizes[index] : 1 / Double(parent.children.count),
                    beforeID: index > 0 ? parent.children[index - 1].id : nil,
                    afterID: index + 1 < parent.children.count ? parent.children[index + 1].id : nil))
        case .tab(let group, let tab):
            let index = group.tabs.firstIndex { $0.id == tab.id } ?? 0
            let groupAnchor = group.tabs.count == 1 ? captureAnchor(root, group.id) : nil
            return .tab(
                .init(
                    groupID: group.id, index: index, title: tab.title,
                    beforeTabID: index > 0 ? group.tabs[index - 1].id : nil,
                    afterTabID: index + 1 < group.tabs.count ? group.tabs[index + 1].id : nil,
                    siblings: group.tabs.filter { $0.id != tab.id }.map { .init(id: $0.id, title: $0.title, contentID: $0.content.id) },
                    wasActive: group.activeTabID == tab.id, groupAnchor: groupAnchor, groupWasRoot: group.id == root.id))
        }
    }

    // MARK: Detach and restore

    /// Lifts the node `id` out of `root` into a floating pane at `rect`. A
    /// group emptied by the departure goes (a relocation, not a close).
    package static func detachForFloat(_ root: LayoutNode, _ id: NodeID, rect: FloatRect) -> (root: LayoutNode, floating: FloatingPane)? {
        guard let content = Tree.findNode(root, id), let anchor = captureAnchor(root, id) else { return nil }
        let detached = Tree.withPaneDetached(root, id)
        let nextRoot = detached.map(Tree.normalize) ?? .emptyLeaf()
        return (nextRoot, FloatingPane(content: content, rect: rect, anchor: anchor))
    }

    /// Puts a floating pane's content back as close to where it came from as
    /// the layout allows; `fallbackTarget` (re-checked) can't fail, so pinning
    /// back never loses content.
    package static func restoreFloating(_ root: LayoutNode, _ entry: FloatingPane, _ titleOf: TabTitler, fallbackTarget: NodeID)
        -> LayoutNode
    {
        restoreAtAnchor(root, entry.content, entry.anchor, titleOf, fallbackTarget: fallbackTarget)
    }

    package static func restoreAtAnchor(
        _ root: LayoutNode, _ node: LayoutNode, _ anchor: FloatAnchor, _ titleOf: TabTitler, fallbackTarget: NodeID
    ) -> LayoutNode {
        switch anchor {
        case .tab(let tab):
            if let group = Tree.findNode(root, tab.groupID), group.isTabs {
                return Tree.normalize(Tree.addTab(root, tab.groupID, Tab(title: tab.title, content: node), at: tab.index))
            }
            // The group is gone: aim at a neighbouring tab that survived, on its side.
            let before = tab.beforeTabID.flatMap { Tree.findTab(root, $0) }
            let after = tab.afterTabID.flatMap { Tree.findTab(root, $0) }
            if let ref = before ?? after {
                let at = before != nil ? ref.index + 1 : ref.index
                return Tree.normalize(Tree.addTab(root, ref.group.id, Tab(title: tab.title, content: node), at: at))
            }
            if let rebuilt = rebuildGroup(root, node, tab, titleOf, fallbackTarget: fallbackTarget) { return rebuilt }
        case .split(let split):
            if case .split(let parent)? = Tree.findNode(root, split.splitID), parent.direction == split.direction {
                let at = min(max(split.index, 0), parent.children.count - 1)
                let next = Tree.splitContent(
                    root, parent.children[at].id, split.direction, node, before: split.index < parent.children.count)
                return withRestoredSize(next, node.id, split.size)
            }
            // The split collapsed: re-split against a neighbour that's left.
            let before = split.beforeID.flatMap { Tree.contains(root, $0) ? $0 : nil }
            let after = split.afterID.flatMap { Tree.contains(root, $0) ? $0 : nil }
            if let target = before ?? after {
                let next = Tree.splitContent(root, target, split.direction, node, before: before == nil)
                return withRestoredSize(next, node.id, split.size)
            }
        case .root:
            break
        }
        let target = Tree.contains(root, fallbackTarget) ? fallbackTarget : root.id
        return Tree.openContent(root, target, node, titleOf)
    }

    /// The group a tab anchor names, put back around `node` when its
    /// departure took the group with it.
    private static func rebuildGroup(
        _ root: LayoutNode, _ node: LayoutNode, _ anchor: FloatAnchor.TabAnchor, _ titleOf: TabTitler, fallbackTarget: NodeID
    ) -> LayoutNode? {
        let moved = Tab(title: anchor.title, content: node)
        if anchor.groupWasRoot {
            for sibling in anchor.siblings {
                guard case .tab(let parent, _)? = Tree.findParent(root, sibling.contentID) else { continue }
                return Tree.normalize(Tree.addTab(root, parent.id, moved, at: min(anchor.index, parent.tabs.count)))
            }
            return nil
        }
        if anchor.siblings.isEmpty {
            guard let groupAnchor = anchor.groupAnchor else { return nil }
            let group = LayoutNode.tabs(TabGroup(id: anchor.groupID, tabs: [moved]))
            return restoreAtAnchor(root, group, groupAnchor, titleOf, fallbackTarget: fallbackTarget)
        }
        guard anchor.siblings.count == 1, let survivorNode = Tree.findNode(root, anchor.siblings[0].contentID) else { return nil }
        let survivor = anchor.siblings[0]
        let kept = Tab(id: survivor.id, title: survivor.title, content: survivorNode)
        let group = TabGroup(
            id: anchor.groupID, tabs: anchor.index == 0 ? [moved, kept] : [kept, moved],
            activeTabID: anchor.wasActive ? moved.id : kept.id)
        return Tree.replaceNode(root, survivor.contentID) { _ in .tabs(group) }.map(Tree.normalize)
    }

    /// Best-effort return of the fraction the pane used to hold.
    private static func withRestoredSize(_ root: LayoutNode, _ nodeID: NodeID, _ size: Double) -> LayoutNode {
        guard case .split(let parent, let index)? = Tree.findParent(root, nodeID) else { return root }
        let ceiling = max(1 - Tree.minPaneSize * Double(parent.children.count - 1), Tree.minPaneSize)
        let target = min(max(size, Tree.minPaneSize), ceiling)
        let rest = parent.sizes.indices.reduce(0.0) { $1 == index ? $0 : $0 + parent.sizes[$1] }
        let scale = rest > 0 ? (1 - target) / rest : 0
        return Tree.resizeSplit(root, parent.id, parent.sizes.indices.map { $0 == index ? target : parent.sizes[$0] * scale })
    }

    // MARK: The floating list (array order is z-order: last is topmost)

    package static func owning(_ floating: [FloatingPane], _ id: NodeID) -> FloatingPane? {
        floating.first { Tree.contains($0.content, id) }
    }

    /// `floatID`'s pane moved to the top of the stack.
    package static func raise(_ floating: [FloatingPane], _ floatID: NodeID) -> [FloatingPane] {
        guard let index = floating.firstIndex(where: { $0.id == floatID }), index != floating.count - 1 else { return floating }
        var next = floating
        next.append(next.remove(at: index))
        return next
    }

    // MARK: Geometry

    /// Keeps a window no smaller than the minimum and never fully off screen;
    /// the top edge is clamped to 0 (a title bar above the viewport can't be grabbed).
    package static func clamp(_ rect: FloatRect, to viewport: Viewport) -> FloatRect {
        let width = clampSize(rect.width, minSize.width, viewport.width)
        let height = clampSize(rect.height, minSize.height, viewport.height)
        let keep = min(keepOnScreen, width, height)
        let x = rect.x.isFinite ? rect.x : 0
        let y = rect.y.isFinite ? rect.y : 0
        return FloatRect(
            x: min(max(x, keep - width), max(viewport.width - keep, 0)), y: min(max(y, 0), max(viewport.height - keep, 0)),
            width: width, height: height)
    }

    private static func clampSize(_ value: Double, _ minimum: Double, _ maximum: Double) -> Double {
        let size = value.isFinite ? value : minimum
        return max(minimum, min(size, max(maximum, minimum)))
    }

    /// Repairs floating panes off disk: an entry survives only with no node id
    /// already claimed by the docked root or an earlier entry; a duplicated
    /// window id is re-minted.
    package static func sanitize(_ floating: [FloatingPane], against root: LayoutNode) -> [FloatingPane] {
        var claimed = Set(root.nodeIDs)
        var windowIDs: Set<NodeID> = []
        var result: [FloatingPane] = []
        for entry in floating {
            var entry = entry
            entry.content = Tree.normalize(entry.content)
            let ids = entry.content.nodeIDs
            if ids.contains(where: claimed.contains) { continue }
            claimed.formUnion(ids)
            if !windowIDs.insert(entry.id).inserted {
                entry.id = .make()
                windowIDs.insert(entry.id)
            }
            result.append(entry)
        }
        return result
    }
}
