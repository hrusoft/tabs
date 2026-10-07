import Foundation
import TabsPluginSDK

/// Every window's layout: the single source of truth for where panes are.
/// Pure data with pure operations — no views, no plugins — so it is tested
/// without a window, and the AppKit shell only draws it.
package struct LayoutModel: Equatable, Sendable {
    /// In the order they were opened.
    package var windows: [WindowLayout]
    /// The last window closed while it was the only one: what reopening the
    /// app (or a pane opened with no window) brings back.
    package var lastClosed: WindowLayout?

    package init(windows: [WindowLayout] = [], lastClosed: WindowLayout? = nil) {
        self.windows = windows
        self.lastClosed = lastClosed
    }

    package func window(_ id: WindowID) -> WindowLayout? { windows.first { $0.id == id } }

    package func index(of window: WindowID) -> Int? { windows.firstIndex { $0.id == window } }

    /// The window holding the node (or tab) `id`, docked or floating.
    package func window(holding id: NodeID) -> WindowLayout? {
        windows.first { window in window.trees.contains { Tree.contains($0, id) || Tree.findTab($0, id) != nil } }
    }

    package func leaf(_ pane: PaneID) -> LayoutLeaf? {
        for window in windows {
            if case .leaf(let leaf)? = window.findNode(pane) { return leaf }
        }
        return nil
    }

    /// Every leaf in every window, in order.
    package var leaves: [LayoutLeaf] { windows.flatMap(\.leaves) }

    /// Makes every leaf id unique (a hand-edited file, a window reopened
    /// while its panes are still closing): a repeated one gets a new id.
    /// `taken` are ids in use elsewhere. Returns what it changed, for the user.
    @discardableResult
    package mutating func makeLeafIDsUnique(avoiding taken: Set<PaneID> = []) -> [String] {
        var seen = taken
        var notes: [String] = []
        var seenWindows: Set<WindowID> = []
        func unique(_ window: inout WindowLayout) {
            if !seenWindows.insert(window.id).inserted {
                window.id = .make()
                notes.append("a window id appeared twice; the second got a new one")
            }
            func fix(_ node: LayoutNode) -> LayoutNode {
                Tree.mapLeaves(node) { leaf in
                    guard !seen.insert(leaf.id).inserted else { return leaf }
                    var copy = leaf
                    copy.id = .make()
                    seen.insert(copy.id)
                    notes.append("pane id appeared twice; the copy got a new one")
                    return copy
                }
            }
            let wasActive = window.activePaneID
            if case .tabs(let root) = fix(window.rootNode) { window.root = root }
            for index in window.floating.indices { window.floating[index].content = fix(window.floating[index].content) }
            if !window.holds(wasActive) { window.activePaneID = Tree.firstPaneID(window.rootNode) }
        }
        for index in windows.indices { unique(&windows[index]) }
        if var lastClosed {
            unique(&lastClosed)
            self.lastClosed = lastClosed
        }
        return notes
    }
}

// MARK: - Saved form

/// layout.json: every window as `{id, root, activePaneId, floating, frame}`,
/// where a leaf is `{id, type, config, title?, titleIsManual?}` (`type: "empty"`
/// for an empty pane), a group `{id, type: "tabs", tabs: [{id, title, content}],
/// activeTabId}`, a split `{id, type: "split", direction, children, sizes}`.
///
/// A pane whose plugin is unavailable round-trips byte-for-byte, so a missing
/// plugin never costs the user their pane; a malformed node or window is
/// dropped (and the original file kept) rather than costing the rest.
package struct SavedLayout: PersistedDocument, Equatable {
    package static let currentVersion = 1
    package var windows: [WindowLayout]

    package init(windows: [WindowLayout]) {
        self.windows = windows
    }

    package init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        windows = try container.decodeLossy(WindowLayout.self, forKey: .windows, what: "window", diagnostics: decoder.diagnostics)
    }

    private enum CodingKeys: String, CodingKey { case windows }

    /// Every content type a restored pane needs — read before any plugin loads.
    package var contentTypes: Set<ContentTypeID> {
        Set(windows.flatMap(\.leaves).compactMap(\.type))
    }
}

package typealias LayoutStore = DocumentStore<SavedLayout>

/// One window's layout as the visual scenarios are written: `{version, root,
/// activePaneId, floating}`.
package struct LayoutSnapshot: Decodable {
    package var window: WindowLayout

    package init(from decoder: any Decoder) throws {
        window = try WindowLayout(from: decoder)
    }
}

extension WindowLayout: Codable {
    private enum CodingKeys: String, CodingKey { case id, root, activePaneId, floating, frame }

    package init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // Floating panes that aren't a list are none: they cost only
        // themselves, never the docked layout.
        var floating: [FloatingPane] = []
        do {
            floating = try container.decodeLossy(
                FloatingPane.self, forKey: .floating, what: "floating pane", diagnostics: decoder.diagnostics)
        } catch {
            if (try? container.decodeNil(forKey: .floating)) != true { decoder.diagnostics?.drop("dropped floating panes: not a list") }
        }
        self.init(
            id: (try? container.decodeIfPresent(WindowID.self, forKey: .id)) ?? .make(),
            root: try container.decode(LayoutNode.self, forKey: .root), floating: floating,
            active: try? container.decodeIfPresent(NodeID.self, forKey: .activePaneId),
            frame: try? container.decodeIfPresent(WindowFrame.self, forKey: .frame))
    }

    package func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(rootNode, forKey: .root)
        try container.encode(activePaneID, forKey: .activePaneId)
        try container.encode(floating, forKey: .floating)
        try container.encodeIfPresent(frame, forKey: .frame)
    }
}

extension LayoutNode: Codable {
    private enum CodingKeys: String, CodingKey {
        case id, type, config, title, titleIsManual, tabs, activeTabId, direction, children, sizes
    }

    private enum TabKeys: String, CodingKey { case id, title, content }

    package static let emptyTypeName = "empty"

    package init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let id = try container.decode(NodeID.self, forKey: .id)
        let type = try container.decode(String.self, forKey: .type)
        switch type {
        case "tabs":
            // A group with no list of tabs is an empty pane, like one whose last tab closed.
            guard var array = try? container.nestedUnkeyedContainer(forKey: .tabs) else {
                if container.contains(.tabs), (try? container.decodeNil(forKey: .tabs)) != true {
                    decoder.diagnostics?.drop("dropped the tabs of group \(id): not a list")
                }
                self = .emptyLeaf()
                return
            }
            var tabs: [Tab] = []
            var index = 0
            while !array.isAtEnd {
                if let tab = try? array.decode(DecodedTab.self) {
                    tabs.append(tab.tab)
                } else {
                    _ = try? array.decode(JSONValue.self)
                    decoder.diagnostics?.drop("dropped malformed tab #\(index)")
                }
                index += 1
            }
            let active = try? container.decodeIfPresent(NodeID.self, forKey: .activeTabId)
            self = .tabs(TabGroup(id: id, tabs: tabs, activeTabID: .some(active ?? nil)))
        case "split":
            let direction = try container.decode(SplitDirection.self, forKey: .direction)
            let rawSizes = (try? container.decodeIfPresent([JSONValue].self, forKey: .sizes)) ?? []
            var children: [LayoutNode] = []
            var sizes: [Double] = []
            if container.contains(.children) {
                var array = try container.nestedUnkeyedContainer(forKey: .children)
                var index = 0
                while !array.isAtEnd {
                    if let child = try? array.decode(LayoutNode.self) {
                        children.append(child)
                        // Each kept child keeps its own size; a missing one is 0 (repaired by normalize).
                        sizes.append(rawSizes.indices.contains(index) ? rawSizes[index].doubleValue ?? 0 : 0)
                    } else {
                        _ = try? array.decode(JSONValue.self)
                        decoder.diagnostics?.drop("dropped malformed pane #\(index) of children")
                    }
                    index += 1
                }
            }
            self = .split(Split(id: id, direction: direction, children: children, sizes: sizes))
        default:
            self = .leaf(
                LayoutLeaf(
                    id: id, type: type == Self.emptyTypeName ? nil : ContentTypeID(type),
                    config: (try? container.decodeIfPresent(JSONValue.self, forKey: .config)) ?? .emptyObject,
                    title: try? container.decodeIfPresent(String.self, forKey: .title),
                    titleIsManual: (try? container.decodeIfPresent(Bool.self, forKey: .titleIsManual)) ?? false))
        }
    }

    /// A tab, decoded on its own so one malformed tab costs only itself.
    private struct DecodedTab: Decodable {
        var tab: Tab

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: TabKeys.self)
            tab = Tab(
                id: try container.decode(NodeID.self, forKey: .id), title: (try? container.decode(String.self, forKey: .title)) ?? "",
                content: try container.decode(LayoutNode.self, forKey: .content))
        }
    }

    package func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        switch self {
        case .leaf(let leaf):
            try container.encode(leaf.type?.rawValue ?? Self.emptyTypeName, forKey: .type)
            try container.encode(leaf.config, forKey: .config)
            try container.encodeIfPresent(leaf.title, forKey: .title)
            if leaf.titleIsManual { try container.encode(true, forKey: .titleIsManual) }
        case .tabs(let group):
            try container.encode("tabs", forKey: .type)
            var tabs = container.nestedUnkeyedContainer(forKey: .tabs)
            for tab in group.tabs {
                var entry = tabs.nestedContainer(keyedBy: TabKeys.self)
                try entry.encode(tab.id, forKey: .id)
                try entry.encode(tab.title, forKey: .title)
                try entry.encode(tab.content, forKey: .content)
            }
            try container.encode(group.activeTabID, forKey: .activeTabId)
        case .split(let split):
            try container.encode("split", forKey: .type)
            try container.encode(split.direction, forKey: .direction)
            try container.encode(split.children, forKey: .children)
            try container.encode(split.sizes, forKey: .sizes)
        }
    }
}

extension FloatingPane: Codable {
    private enum CodingKeys: String, CodingKey { case id, content, rect, anchor }

    package init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let rect = (try? container.decodeIfPresent(FloatRect.self, forKey: .rect)).flatMap { $0 }
        self.init(
            id: (try? container.decodeIfPresent(NodeID.self, forKey: .id)).flatMap { $0 } ?? .make(),
            content: try container.decode(LayoutNode.self, forKey: .content),
            rect: rect.flatMap { [$0.x, $0.y, $0.width, $0.height].allSatisfy(\.isFinite) ? $0 : nil } ?? Floating.defaultRect,
            anchor: (try? container.decodeIfPresent(FloatAnchor.self, forKey: .anchor)).flatMap { $0 } ?? .root)
    }

    package func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(content, forKey: .content)
        try container.encode(rect, forKey: .rect)
        try container.encode(anchor, forKey: .anchor)
    }
}

extension FloatAnchor: Codable {
    private enum CodingKeys: String, CodingKey {
        case kind, splitId, direction, index, size, beforeId, afterId
        case groupId, title, beforeTabId, afterTabId, siblings, wasActive, groupAnchor, groupWasRoot
    }

    private struct SiblingForm: Codable {
        var id: NodeID
        var title: String?
        var contentId: NodeID
    }

    /// Anything malformed is `.root` (pin back beside the active pane): losing
    /// where a window sat is a nuisance, losing its pane is not.
    package init(from decoder: any Decoder) throws {
        guard let container = try? decoder.container(keyedBy: CodingKeys.self) else {
            self = .root
            return
        }
        let kind = try? container.decode(String.self, forKey: .kind)
        let index = (try? container.decode(Double.self, forKey: .index)).flatMap { $0.isFinite ? Int($0) : nil } ?? 0
        if kind == "tab", let groupID = try? container.decode(NodeID.self, forKey: .groupId) {
            let siblings = (try? container.decode([SiblingForm].self, forKey: .siblings)) ?? []
            self = .tab(
                .init(
                    groupID: groupID, index: index, title: (try? container.decode(String.self, forKey: .title)) ?? "",
                    beforeTabID: try? container.decode(NodeID.self, forKey: .beforeTabId),
                    afterTabID: try? container.decode(NodeID.self, forKey: .afterTabId),
                    siblings: siblings.map { .init(id: $0.id, title: $0.title ?? "", contentID: $0.contentId) },
                    wasActive: (try? container.decode(Bool.self, forKey: .wasActive)) ?? false,
                    groupAnchor: try? container.decode(FloatAnchor.self, forKey: .groupAnchor),
                    groupWasRoot: (try? container.decode(Bool.self, forKey: .groupWasRoot)) ?? false))
        } else if kind == "split", let splitID = try? container.decode(NodeID.self, forKey: .splitId),
            let direction = try? container.decode(SplitDirection.self, forKey: .direction)
        {
            let size = (try? container.decode(Double.self, forKey: .size)).flatMap { $0.isFinite ? $0 : nil } ?? Tree.minPaneSize
            self = .split(
                .init(
                    splitID: splitID, direction: direction, index: index, size: size,
                    beforeID: try? container.decode(NodeID.self, forKey: .beforeId),
                    afterID: try? container.decode(NodeID.self, forKey: .afterId)))
        } else {
            self = .root
        }
    }

    package func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .root:
            try container.encode("root", forKey: .kind)
        case .split(let split):
            try container.encode("split", forKey: .kind)
            try container.encode(split.splitID, forKey: .splitId)
            try container.encode(split.direction, forKey: .direction)
            try container.encode(split.index, forKey: .index)
            try container.encode(split.size, forKey: .size)
            try container.encodeIfPresent(split.beforeID, forKey: .beforeId)
            try container.encodeIfPresent(split.afterID, forKey: .afterId)
        case .tab(let tab):
            try container.encode("tab", forKey: .kind)
            try container.encode(tab.groupID, forKey: .groupId)
            try container.encode(tab.index, forKey: .index)
            try container.encode(tab.title, forKey: .title)
            try container.encodeIfPresent(tab.beforeTabID, forKey: .beforeTabId)
            try container.encodeIfPresent(tab.afterTabID, forKey: .afterTabId)
            try container.encode(tab.siblings.map { SiblingForm(id: $0.id, title: $0.title, contentId: $0.contentID) }, forKey: .siblings)
            try container.encode(tab.wasActive, forKey: .wasActive)
            try container.encodeIfPresent(tab.groupAnchor, forKey: .groupAnchor)
            try container.encode(tab.groupWasRoot, forKey: .groupWasRoot)
        }
    }
}

extension KeyedDecodingContainer {
    /// Decodes an array element by element, dropping (and reporting) the ones
    /// that don't decode. A missing key is an empty array.
    func decodeLossy<T: Decodable>(_ type: T.Type, forKey key: Key, what: String, diagnostics: DecodingDiagnostics?) throws -> [T] {
        guard contains(key) else { return [] }
        var array = try nestedUnkeyedContainer(forKey: key)
        var result: [T] = []
        var index = 0
        while !array.isAtEnd {
            if let element = try? array.decode(T.self) {
                result.append(element)
            } else {
                _ = try? array.decode(JSONValue.self)
                diagnostics?.drop("dropped malformed \(what) #\(index) of \(key.stringValue)")
            }
            index += 1
        }
        return result
    }
}
