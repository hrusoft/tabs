import Foundation
import TabsPluginSDK

@testable import TabsCore

// Builders named after the Electron model's factories (`createLeaf`,
// `createTab`, `createTabs`, `createSplit` in packages/plugin-sdk/shared/model/
// factories.ts), so a ported test reads like its original. Ids are fresh unless
// given, as `createId()` makes them.

/// A leaf of `type`; `"empty"` is the empty pane (`type == nil` natively).
func createLeaf(
    _ type: String, _ config: JSONValue = .emptyObject, id: NodeID = .make(), title: String? = nil, titleIsManual: Bool = false
) -> LayoutNode {
    .leaf(
        LayoutLeaf(
            id: id, type: type == LayoutNode.emptyTypeName ? nil : ContentTypeID(type), config: config, title: title,
            titleIsManual: titleIsManual))
}

func createTab(_ title: String, _ content: LayoutNode, id: NodeID = .make()) -> Tab {
    Tab(id: id, title: title, content: content)
}

/// A tab group; the first tab is active unless `active` names another
/// (`.some(nil)` for none, a stale id for a stale one).
func createTabs(_ tabs: [Tab], id: NodeID = .make(), active: NodeID?? = nil) -> LayoutNode {
    .tabs(TabGroup(id: id, tabs: tabs, activeTabID: active))
}

/// A split, evenly sized unless `sizes` says otherwise.
func createSplit(_ direction: SplitDirection, _ children: [LayoutNode], id: NodeID = .make(), sizes: [Double]? = nil) -> LayoutNode {
    .split(Split(id: id, direction: direction, children: children, sizes: sizes))
}

/// The tree tests' stock tab: a "welcome" leaf.
func welcomeTab(_ title: String = "Welcome") -> Tab {
    createTab(title, createLeaf("welcome"))
}

/// Stands in for the real display-name titler, which the model never sees: a
/// node is titled by its kind.
func titleOf(_ node: LayoutNode, _ destGroup: NodeID?) -> String { node.kind }

/// `toBeCloseTo`'s default: equal to two decimal places.
func isClose(_ value: Double?, _ expected: Double, digits: Int = 2) -> Bool {
    guard let value else { return false }
    return abs(value - expected) < pow(10, -Double(digits)) / 2
}

extension Array {
    /// The element at `index`, nil when out of range (so a wrong shape fails an expectation instead of crashing).
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}

extension LayoutNode {
    /// The Electron model's `type`: "tabs", "split", or a leaf's content type ("empty" for an empty pane).
    var kind: String {
        switch self {
        case .leaf(let leaf): leaf.type?.rawValue ?? Self.emptyTypeName
        case .tabs: "tabs"
        case .split: "split"
        }
    }

    /// A group's tabs; empty for anything else.
    var tabItems: [Tab] { group?.tabs ?? [] }
    /// A group's tab titles, in order.
    var titles: [String] { tabItems.map(\.title) }
    var activeTabID: NodeID? { group?.activeTabID }
    /// A split's children; empty for anything else.
    var childNodes: [LayoutNode] { splitNode?.children ?? [] }
    var childIDs: [NodeID] { childNodes.map(\.id) }
    /// A split's sizes; empty for anything else.
    var sizes: [Double] { splitNode?.sizes ?? [] }
    var direction: SplitDirection? { splitNode?.direction }
    /// A leaf's config; nil for anything else.
    var config: JSONValue? { leaf?.config }
}
