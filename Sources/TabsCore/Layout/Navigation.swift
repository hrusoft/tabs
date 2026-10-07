import Foundation
import TabsPluginSDK

/// A rect as navigation compares them (top-left origin, y down).
package struct NavRect: Equatable, Sendable {
    package var left, top, right, bottom: Double

    package init(left: Double, top: Double, right: Double, bottom: Double) {
        self.left = left
        self.top = top
        self.right = right
        self.bottom = bottom
    }
}

/// Keyboard pane navigation and focus choices.
package enum Navigation {
    /// A candidate may sit this far "behind" the current pane's edge.
    static let edgeEpsilon = 2.0
    /// Candidates this close along the axis count as the same column or row.
    static let tieEpsilon = 4.0

    private struct Scored {
        var id: NodeID
        var metric: Double
        var cross: Double
    }

    private static func nearestByCross(
        _ current: NavRect, _ scored: [Scored], _ direction: NavDirection, _ tiebreak: (Scored, Scored) -> Bool
    ) -> NodeID? {
        guard let nearest = scored.map(\.metric).min() else { return nil }
        let currentCross = crossOf(current, direction)
        let sameRank = scored.filter { $0.metric - nearest <= tieEpsilon }
        return sameRank.sorted { a, b in
            let da = abs(a.cross - currentCross)
            let db = abs(b.cross - currentCross)
            return da != db ? da < db : tiebreak(a, b)
        }.first?.id
    }

    /// The nearest candidate in `direction`, and among the nearest column or
    /// row, the one closest to `current` across the axis.
    package static func pickSpatialTarget(_ current: NavRect, _ candidates: [(id: NodeID, rect: NavRect)], _ direction: NavDirection)
        -> NodeID?
    {
        let eligible =
            candidates
            .map { candidate -> Scored in
                let (distance, cross) = score(current, candidate.rect, direction)
                return Scored(id: candidate.id, metric: distance, cross: cross)
            }
            .filter { $0.metric >= -edgeEpsilon }
        return nearestByCross(current, eligible, direction) { $0.metric < $1.metric }
    }

    private static func crossOf(_ rect: NavRect, _ direction: NavDirection) -> Double {
        direction == .left || direction == .right ? rect.top : rect.left
    }

    private static func score(_ current: NavRect, _ rect: NavRect, _ direction: NavDirection) -> (Double, Double) {
        let cross = crossOf(rect, direction)
        switch direction {
        case .right: return (rect.left - current.right, cross)
        case .left: return (current.left - rect.right, cross)
        case .down: return (rect.top - current.bottom, cross)
        case .up: return (current.top - rect.bottom, cross)
        }
    }

    /// The pane focus lands on entering `node` moving in `direction`: the one
    /// nearest the crossed edge (a split along the axis of travel is entered
    /// from its far side moving left/up); groups descend into their visible tab.
    package static func entryPaneID(_ node: LayoutNode, _ direction: NavDirection? = nil) -> NodeID {
        switch node {
        case .split(let split):
            let fromFarSide =
                (direction == .left && split.direction == .horizontal) || (direction == .up && split.direction == .vertical)
            guard let child = fromFarSide ? split.children.last : split.children.first else { return node.id }
            return entryPaneID(child, direction)
        case .tabs(let group):
            guard let active = group.activeTab ?? group.tabs.first else { return node.id }
            return entryPaneID(active.content, direction)
        case .leaf:
            return node.id
        }
    }

    /// Every tab activation needed to reveal `id`, innermost first.
    package static func ancestorTabSteps(_ root: LayoutNode, _ id: NodeID) -> [(groupID: NodeID, tabID: NodeID)] {
        func walk(_ node: LayoutNode) -> [(groupID: NodeID, tabID: NodeID)]? {
            if node.id == id { return [] }
            switch node {
            case .tabs(let group):
                for tab in group.tabs {
                    if let found = walk(tab.content) { return found + [(group.id, tab.id)] }
                }
            case .split(let split):
                for child in split.children {
                    if let found = walk(child) { return found }
                }
            case .leaf:
                break
            }
            return nil
        }
        return walk(root) ?? []
    }

    /// The pane to focus after `closedID` was closed (removed from `oldRoot`,
    /// giving `newRoot`): the closest surviving sibling.
    package static func focusAfterClose(_ oldRoot: LayoutNode, _ newRoot: LayoutNode, _ closedID: NodeID) -> NodeID? {
        guard let ref = Tree.findParent(oldRoot, closedID) else { return nil }
        switch ref {
        case .split(let parent, let index):
            return Tree.neighbour(of: parent.children, at: index).map { entryPaneID($0) }
        case .tab(let group, let tab):
            let index = group.tabs.firstIndex { $0.id == tab.id } ?? 0
            if let neighbour = Tree.neighbour(of: group.tabs, at: index) { return entryPaneID(neighbour.content) }
            // The sole tab: its group collapsed in place; read what now fills its slot.
            guard let outer = Tree.findParent(oldRoot, group.id) else { return newRoot.id }
            switch outer {
            case .split(let parent, let index):
                guard case .split(let now)? = Tree.findNode(newRoot, parent.id), now.children.indices.contains(index) else { return nil }
                return now.children[index].id
            case .tab(_, let outerTab):
                return Tree.findTab(newRoot, outerTab.id)?.tab.content.id
            }
        }
    }

    /// When nothing lies in `direction`: among the panes furthest toward the
    /// opposite edge, the one closest to `current` across the axis.
    package static func pickWrapTarget(_ current: NavRect, _ candidates: [(id: NodeID, rect: NavRect)], _ direction: NavDirection)
        -> NodeID?
    {
        func edge(_ rect: NavRect) -> Double {
            switch direction {
            case .right: rect.left
            case .left: -rect.right
            case .down: rect.top
            case .up: -rect.bottom
            }
        }
        let scored = candidates.map { Scored(id: $0.id, metric: edge($0.rect), cross: crossOf($0.rect, direction)) }
        return nearestByCross(current, scored, direction) { $0.cross < $1.cross }
    }

    /// Where an arrow press sends focus, before the pane inside is resolved.
    package struct Target: Equatable {
        /// The subtree focus moves into (resolve a pane with `entryPaneID`).
        package var node: LayoutNode
        /// Set when reaching `node` means switching tabs first.
        package var tabSwitch: (groupID: NodeID, tabID: NodeID)?
        /// Nothing lay in `direction`: the outermost container wrapped around.
        package var wrapped: Bool

        package static func == (a: Target, b: Target) -> Bool {
            a.node == b.node && a.wrapped == b.wrapped && a.tabSwitch?.groupID == b.tabSwitch?.groupID
                && a.tabSwitch?.tabID == b.tabSwitch?.tabID
        }
    }

    private static func wrapIndex(_ index: Int, _ length: Int) -> Int { ((index % length) + length) % length }

    private static func tabTarget(_ group: TabGroup, _ index: Int, _ step: Int) -> Target? {
        guard group.tabs.count >= 2 else { return nil }
        let next = max(0, index) + step
        let wrapped = next < 0 || next >= group.tabs.count
        let tab = group.tabs[wrapped ? wrapIndex(next, group.tabs.count) : next]
        return Target(node: tab.content, tabSwitch: (group.id, tab.id), wrapped: wrapped)
    }

    /// Where an arrow press moves focus, walking up from `paneID` one ancestor
    /// at a time: a split along the axis hands over its next child; a tab
    /// boundary is one step for left/right (taken before the group's own
    /// sibling) and transparent for up/down; anything else is transparent.
    /// Reaching the root wraps the outermost container along the axis.
    package static func navTarget(_ root: LayoutNode, _ paneID: NodeID, _ direction: NavDirection) -> Target? {
        let axis: SplitDirection = direction == .left || direction == .right ? .horizontal : .vertical
        let step = direction == .right || direction == .down ? 1 : -1
        guard let start = Tree.findNode(root, paneID) else { return nil }
        var wrap: Target?
        if axis == .horizontal, case .tabs(let group) = start {
            wrap = tabTarget(group, group.tabs.firstIndex { $0.id == group.activeTabID } ?? -1, step)
            if let wrap, !wrap.wrapped { return wrap }
        }
        var node = start
        while let ref = Tree.findParent(root, node.id) {
            switch ref {
            case .split(let parent, let index):
                if parent.direction == axis && parent.children.count > 1 {
                    if parent.children.indices.contains(index + step) {
                        return Target(node: parent.children[index + step], tabSwitch: nil, wrapped: false)
                    }
                    wrap = Target(node: parent.children[wrapIndex(index + step, parent.children.count)], tabSwitch: nil, wrapped: true)
                }
                node = .split(parent)
            case .tab(let group, let tab):
                if axis == .horizontal, let found = tabTarget(group, group.tabs.firstIndex { $0.id == tab.id } ?? -1, step) {
                    if !found.wrapped { return found }
                    wrap = found
                }
                node = .tabs(group)
            }
        }
        return wrap
    }
}

/// Separator snapping and alignment.
package enum SeparatorSnap {
    /// Distance within which a dragged separator snaps to another's position.
    package static let snapThreshold = 8.0
    /// Distance within which two separators count as aligned (carried together).
    package static let alignmentThreshold = 5.0

    static func boundaryRatio(_ sizes: [Double], _ index: Int) -> Double { sizes.prefix(index).reduce(0, +) }

    /// Where boundary `index` sits, in points.
    package static func boundaryPosition(sizes: [Double], index: Int, containerStart: Double, containerLength: Double) -> Double {
        containerStart + boundaryRatio(sizes, index) * containerLength
    }

    /// `sizes` with boundary `index` moved to `target`; nil when either
    /// adjacent pane would drop below the minimum.
    package static func applyBoundary(
        sizes: [Double], index: Int, containerStart: Double, containerLength: Double, target: Double
    ) -> [Double]? {
        guard containerLength > 0, index >= 1, index < sizes.count else { return nil }
        let delta = (target - containerStart) / containerLength - boundaryRatio(sizes, index)
        var next = sizes
        next[index - 1] += delta
        next[index] -= delta
        if next[index - 1] < Tree.minPaneSize || next[index] < Tree.minPaneSize { return nil }
        return next
    }

    /// The sizes to apply instead of the live drag's when the boundary lands
    /// within `snapThreshold` of a candidate.
    package static func snappedSizes(
        sizes: [Double], index: Int, containerStart: Double, containerLength: Double, candidates: [Double]
    ) -> [Double]? {
        guard containerLength > 0, index >= 1, index < sizes.count else { return nil }
        let current = boundaryPosition(sizes: sizes, index: index, containerStart: containerStart, containerLength: containerLength)
        var target: Double?
        var best = snapThreshold
        for candidate in candidates {
            let distance = abs(candidate - current)
            if distance <= best {
                best = distance
                target = candidate
            }
        }
        guard let target else { return nil }
        return applyBoundary(sizes: sizes, index: index, containerStart: containerStart, containerLength: containerLength, target: target)
    }
}
