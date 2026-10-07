import Foundation
import TabsPluginSDK

@testable import TabsCore

/// Layouts for the app tier, in the model's own shape: every node has an id
/// a test can name, tabs have ids of their own (`t-<content id>` unless given).
@MainActor
enum Fixture {
    static func leaf(_ id: PaneID, _ type: ContentTypeID? = nil, config: JSONValue = .emptyObject, title: String? = nil) -> LayoutNode {
        .leaf(LayoutLeaf(id: id, type: type, config: config, title: title))
    }

    static func tab(_ content: LayoutNode, id: NodeID? = nil, title: String = "New Tab") -> Tab {
        Tab(id: id ?? NodeID("t-\(content.id.rawValue)"), title: title, content: content)
    }

    static func tabs(_ id: NodeID, _ tabs: [Tab], active: NodeID? = nil) -> LayoutNode {
        .tabs(TabGroup(id: id, tabs: tabs, activeTabID: .some(active ?? tabs.first?.id)))
    }

    static func split(_ id: NodeID, _ direction: SplitDirection, _ children: [LayoutNode], sizes: [Double]? = nil) -> LayoutNode {
        .split(Split(id: id, direction: direction, children: children, sizes: sizes))
    }

    /// A window whose root group ("root-<id>") shows `root` as its one tab ("t-<id>").
    static func window(
        _ id: WindowID, _ content: LayoutNode, active: NodeID? = nil, floating: [FloatingPane] = [], frame: WindowFrame? = nil
    ) -> WindowLayout {
        let root = tabs(NodeID("root-\(id.rawValue)"), [tab(content, id: NodeID("t-\(id.rawValue)"), title: "Tabs")])
        return WindowLayout(id: id, root: root, floating: floating, active: active ?? Navigation.entryPaneID(content), frame: frame)
    }

    /// A window whose root group ("root-<id>") holds one tab per leaf
    /// ("t-<leaf id>"), the one at `active` shown and active.
    static func tabsWindow(_ id: WindowID, _ leaves: [LayoutNode], active: Int = 0, frame: WindowFrame? = nil) -> WindowLayout {
        let tabs = leaves.map { tab($0, title: "Tabs") }
        let root = self.tabs(NodeID("root-\(id.rawValue)"), tabs, active: tabs[active].id)
        return WindowLayout(id: id, root: root, active: leaves[active].id, frame: frame)
    }

    static func saved(_ windows: WindowLayout...) -> SavedLayout { SavedLayout(windows: windows) }

    /// One window ("w") showing a side-by-side split ("s") of `children`.
    static func sideBySide(_ children: LayoutNode..., active: NodeID? = nil) -> SavedLayout {
        saved(window("w", split("s", .horizontal, children), active: active))
    }

    /// A floating pane around `content` at `rect`, with no anchor (pinning it back docks it beside the active pane).
    static func floating(_ id: NodeID, _ content: LayoutNode, _ rect: FloatRect) -> FloatingPane {
        FloatingPane(id: id, content: content, rect: rect, anchor: .root)
    }
}

extension WindowLayout {
    /// The node `id` wherever it is in this window.
    func node(_ id: NodeID) -> LayoutNode? { findNode(id) }

    /// The group `id`'s tab ids, in order.
    func tabIDs(_ group: NodeID) -> [NodeID] { findNode(group)?.group?.tabs.map(\.id) ?? [] }

    /// The group `id`'s tab titles, in order.
    func tabTitles(_ group: NodeID) -> [String] { findNode(group)?.group?.tabs.map(\.title) ?? [] }

    /// The group `id`'s tab contents' ids, in order.
    func tabContents(_ group: NodeID) -> [NodeID] { findNode(group)?.group?.tabs.map(\.content.id) ?? [] }

    /// The tab `id` wherever it is in this window.
    func findTab(_ id: NodeID) -> Tree.TabRef? { trees.lazy.compactMap { Tree.findTab($0, id) }.first }

    /// The docked root's shown tab's content.
    var shownContent: LayoutNode? { root.activeTab?.content }
}
