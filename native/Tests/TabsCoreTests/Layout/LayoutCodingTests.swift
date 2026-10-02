import Foundation
import TabsPluginSDK
import Testing

@testable import TabsCore

/// The layout's saved form: each window in the Electron app's snapshot shape,
/// read tolerantly. Ports the file-facing cases of the Electron tests —
/// tree.test.ts's hollow-node repairs, floating.test.ts's `sanitizeFloating`
/// shape repairs, and main's layout.test.ts `loadLayoutFile`/`saveLayoutFile`
/// cases that apply to one window's snapshot — plus the native saved form's
/// own round trips and id repairs.
@Suite struct LayoutCodingTests {
    /// Decodes `json` as core's store does, collecting what had to be dropped.
    static func decode<T: Decodable>(_ json: JSONValue, as type: T.Type = T.self) throws -> (value: T, dropped: [String]) {
        let diagnostics = DecodingDiagnostics()
        let decoder = JSONDecoder()
        decoder.userInfo[DecodingDiagnostics.key] = diagnostics
        return (try decoder.decode(T.self, from: json.encodedData(pretty: false)), diagnostics.dropped)
    }

    static func leafJSON(_ id: String, _ type: String = "terminal") -> JSONValue {
        ["id": .string(id), "type": .string(type), "config": [:]]
    }

    static let rectJSON: JSONValue = ["x": 40, "y": 60, "width": 500, "height": 300]

    /// A saved window: `root` and `floating` as given.
    static func windowJSON(_ root: JSONValue, active: JSONValue = nil, floating: JSONValue? = nil, id: String = "w") -> JSONValue {
        var window: [String: JSONValue] = ["id": .string(id), "root": root, "activePaneId": active]
        if let floating { window["floating"] = floating }
        return .object(window)
    }

    @Suite struct Nodes {
        @Test("repairs hollow nodes off disk away instead of throwing")
        func hollowNodes() throws {
            let root: JSONValue = [
                "id": "root", "type": "tabs", "activeTabId": "ta",
                "tabs": [
                    ["id": "ta", "title": "A", "content": leafJSON("wa", "welcome")],
                    ["id": "bad-tab", "title": "bad", "content": nil],
                    [
                        "id": "tb", "title": "B",
                        "content": [
                            "id": "s", "type": "split", "direction": "vertical",
                            "children": [leafJSON("good", "welcome"), ["id": "hs", "type": "split", "direction": "horizontal"], 42],
                            "sizes": [0.3, 0.3, 0.4],
                        ],
                    ],
                    ["id": "tc", "title": "C", "content": ["id": "ht", "type": "tabs"]],
                ],
            ]

            let next = Tree.normalize(try decode(root, as: LayoutNode.self).value)

            #expect(next.titles == ["A", "B", "C"])
            // The split lost both malformed children and unwrapped to its survivor.
            #expect(next.tabItems[safe: 1]?.content == createLeaf("welcome", id: "good"))
            // A tabs group with no tabs array reverts to an empty pane, like one whose last tab closed.
            #expect(next.tabItems[safe: 2]?.content.kind == "empty")
        }

        @Test("treats a split with no sizes array as evenly sized")
        func noSizes() throws {
            let split: JSONValue = [
                "id": "s", "type": "split", "direction": "horizontal", "children": [leafJSON("a", "welcome"), leafJSON("b", "welcome")],
            ]
            #expect(Tree.normalize(try decode(split, as: LayoutNode.self).value).sizes == [0.5, 0.5])
        }

        @Test("a tree round-trips through its saved form, in the Electron snapshot shape")
        func roundTrip() throws {
            let root = createTabs(
                [
                    createTab("Empty", createLeaf("empty", id: "a")),
                    createTab(
                        "Pair",
                        createSplit(
                            .vertical,
                            [
                                createLeaf("t", ["k": [1, 2]], id: "x", title: "X"),
                                createLeaf("t", id: "y", title: "Mine", titleIsManual: true),
                            ], id: "s", sizes: [0.25, 0.75]), id: "tp"),
                ], id: "g", active: "tp")

            let json = try JSONValue(encoding: root)

            #expect(try decode(json, as: LayoutNode.self).value == root)
            #expect(json["type"] == "tabs")
            #expect(json["activeTabId"] == "tp")
            #expect(json["tabs"]?[0]?["content"] == ["id": "a", "type": "empty", "config": [:]])
            #expect(json["tabs"]?[1]?["title"] == "Pair")
            let split = json["tabs"]?[1]?["content"]
            #expect(split?["type"] == "split")
            #expect(split?["direction"] == "vertical")
            #expect(split?["sizes"] == [0.25, 0.75])
            #expect(split?["children"]?[0] == ["id": "x", "type": "t", "config": ["k": [1, 2]], "title": "X"])
            #expect(split?["children"]?[1] == ["id": "y", "type": "t", "config": [:], "title": "Mine", "titleIsManual": true])
        }
    }

    @Suite struct Windows {
        @Test("a bare snapshot becomes one window, its root wrapped as a top-level tab")
        func bareSnapshot() throws {
            let root = createLeaf("terminal", ["cwd": "~/code"], id: "leaf")
            let json: JSONValue = ["version": 1, "root": try JSONValue(encoding: root), "activePaneId": "leaf"]

            let window = try decode(json, as: LayoutSnapshot.self).value.window

            // The docked root is always a tab group — a bare leaf saved directly
            // comes back wrapped as the sole tab of a fresh group, the leaf
            // itself untouched and still the active pane.
            #expect(window.root.tabs.map(\.content) == [root])
            #expect(window.activePaneID == root.id)
            #expect(window.floating.isEmpty)
        }

        @Test("is dropped when its root is not a plausible node")
        func implausibleRoot() throws {
            let json: JSONValue = [
                "windows": [
                    windowJSON(nil, active: "x", id: "bad"),
                    windowJSON(["id": "g", "type": "tabs", "tabs": [["id": "t", "title": "T", "content": leafJSON("a")]]], id: "good"),
                ]
            ]

            let (layout, dropped) = try decode(json, as: SavedLayout.self)

            #expect(layout.windows.map(\.id) == ["good"])
            #expect(dropped.count == 1)
        }

        @Test("keeps a good docked root when a floating window is structurally hollow")
        func hollowFloating() throws {
            let root = createTabs([createTab("Shell", createLeaf("terminal"))])
            let json = windowJSON(
                try JSONValue(encoding: root), active: .string(root.id.rawValue),
                floating: [["id": "f", "content": ["id": "hollow", "type": "tabs"]]])

            let window = try decode(json, as: WindowLayout.self).value

            #expect(window.rootNode == root)
        }

        @Test("keeps a floating pane, normalizing its content")
        func floatingNormalized() throws {
            let tab = createTab("Shell", createLeaf("terminal"))
            let stale = try JSONValue(encoding: createTabs([tab], active: "stale-id"))
            let json = windowJSON(
                leafJSON("root", "empty"),
                floating: [
                    [
                        "id": "float-1", "content": stale, "rect": ["x": 10, "y": 20, "width": 400, "height": 300],
                        "anchor": ["kind": "root"],
                    ]
                ])

            let floating = try decode(json, as: WindowLayout.self).value.floating

            #expect(floating.count == 1)
            #expect(floating[safe: 0]?.content.activeTabID == tab.id)
            #expect(floating[safe: 0]?.rect == FloatRect(x: 10, y: 20, width: 400, height: 300))
        }

        @Test("drops a floating entry whose content is not a plausible node (null rect and anchor too)")
        func floatingWithoutContent() throws {
            let json = windowJSON(leafJSON("root", "empty"), floating: [["id": "float-1", "content": nil, "rect": nil, "anchor": nil]])
            #expect(try decode(json, as: WindowLayout.self).value.floating.isEmpty)
        }

        @Test("normalizes a tree with a dangling activeTabId")
        func danglingActiveTab() throws {
            let tab = createTab("Shell", createLeaf("terminal"))
            let group = createTabs([tab], active: "stale-id")
            let json = windowJSON(try JSONValue(encoding: group), active: .string(group.id.rawValue))

            #expect(try decode(json, as: WindowLayout.self).value.root.activeTabID == tab.id)
        }

        @Test("keeps every window, its id and its order")
        func everyWindow() throws {
            let a = createLeaf("terminal")
            let b = createLeaf("browser")
            let json: JSONValue = [
                "windows": [
                    windowJSON(try JSONValue(encoding: a), active: .string(a.id.rawValue), id: "w-a"),
                    windowJSON(try JSONValue(encoding: b), active: .string(b.id.rawValue), id: "w-b"),
                ]
            ]

            let windows = try decode(json, as: SavedLayout.self).value.windows

            #expect(windows.map(\.id) == ["w-a", "w-b"])
            #expect(windows[safe: 0]?.root.tabs.first?.content == a)
            #expect(windows[safe: 1]?.root.tabs.first?.content == b)
        }

        @Test("reads an empty window list as nothing to restore")
        func noWindows() throws {
            #expect(try decode(["windows": []], as: SavedLayout.self).value.windows.isEmpty)
        }

        @Test("round-trips a custom tab title and pane title override untouched")
        func customTitles() throws {
            let leaf = createLeaf("terminal", ["cwd": "~"], title: "My server")
            let saved = SavedLayout(windows: [WindowLayout(id: "w-1", root: createTabs([createTab("Deploy", leaf)]), active: leaf.id)])

            let loaded = try decode(try JSONValue(encoding: saved), as: SavedLayout.self).value

            #expect(loaded == saved)
            #expect(loaded.windows.first?.root.tabs.first?.title == "Deploy")
            #expect(loaded.windows.first?.root.tabs.first?.content == leaf)
        }

        @Test("keeps the saved active pane while it resolves, docked or floating, else the docked root's")
        func activePane() throws {
            let docked = createTabs([createTab("A", createLeaf("terminal", id: "a"))], id: "g")
            let floating: JSONValue = [["id": "f", "content": leafJSON("b"), "rect": rectJSON, "anchor": ["kind": "root"]]]
            func active(_ id: JSONValue) throws -> NodeID {
                try decode(windowJSON(try JSONValue(encoding: docked), active: id, floating: floating), as: WindowLayout.self).value
                    .activePaneID
            }

            #expect(try active("a") == "a")
            #expect(try active("b") == "b", "a floating pane can be the active one")
            #expect(try active("gone") == "g")
            // No saved active pane: the tree's own first pane, which for a group is the group itself.
            #expect(try active(nil) == "g")
        }

        @Test("a window's frame round-trips")
        func frame() throws {
            let saved = SavedLayout(windows: [
                WindowLayout(id: "w", root: createLeaf("t", id: "a"), frame: WindowFrame(x: 1, y: 2, width: 300, height: 400))
            ])
            #expect(try decode(try JSONValue(encoding: saved), as: SavedLayout.self).value == saved)
        }
    }

    @Suite struct FloatingEntries {
        let root = leafJSON("root", "empty")

        func floating(_ entries: JSONValue) throws -> [FloatingPane] {
            try decode(windowJSON(root, floating: entries), as: WindowLayout.self).value.floating
        }

        @Test("returns an empty list for anything that is not an array")
        func notAnArray() throws {
            let (window, _) = try decode(windowJSON(root, floating: ["nope": true]), as: WindowLayout.self)
            #expect(window.floating.isEmpty)
            #expect(window.rootNode.leaves.map(\.id) == ["root"], "the window itself survives")
            #expect(try decode(windowJSON(root), as: WindowLayout.self).value.floating.isEmpty)
        }

        @Test("drops an entry whose content is not a plausible node")
        func implausibleContent() throws {
            #expect(try floating([["id": "a", "content": nil, "rect": rectJSON]]).isEmpty)
        }

        @Test("drops an entry holding a node id the docked root already claims")
        func claimed() throws {
            #expect(try floating([["id": "a", "content": leafJSON("root", "terminal"), "rect": rectJSON]]).isEmpty)
        }

        @Test("repairs an unusable rect rather than losing the pane")
        func unusableRect() throws {
            let result = try floating([["id": "a", "content": leafJSON("t"), "rect": ["x": nil, "y": 0], "anchor": ["kind": "root"]]])

            #expect(result.count == 1)
            let rect = try #require(result.first?.rect)
            #expect([rect.x, rect.y, rect.width, rect.height].allSatisfy { $0.isFinite })
            #expect(rect == Floating.defaultRect)
        }

        @Test("repairs an unrecognized anchor to the root anchor")
        func unknownAnchor() throws {
            #expect(
                try floating([["id": "a", "content": leafJSON("t"), "rect": rectJSON, "anchor": ["kind": "huh"]]]).first?.anchor == .root)
        }

        @Test("mints an id for an entry that lost its own")
        func mintsID() throws {
            let id = try #require(try floating([["content": leafJSON("t"), "rect": rectJSON, "anchor": ["kind": "root"]]]).first?.id)
            #expect(!id.rawValue.isEmpty)
        }

        @Test("rebuilds an anchor field-by-field, dropping unknown keys and mistyped neighbours")
        func anchorFields() throws {
            let anchor = try #require(
                try floating([
                    [
                        "id": "a", "content": leafJSON("t"), "rect": rectJSON,
                        "anchor": ["kind": "tab", "groupId": "g", "index": 1, "title": "T", "beforeTabId": 42, "extra": true],
                    ]
                ]).first?.anchor)

            #expect(
                anchor
                    == .tab(
                        .init(
                            groupID: "g", index: 1, title: "T", beforeTabID: nil, afterTabID: nil, siblings: [], wasActive: false,
                            groupAnchor: nil, groupWasRoot: false)))
            #expect(
                try JSONValue(encoding: FloatingPane(content: createLeaf("t"), rect: Floating.defaultRect, anchor: anchor))["anchor"]?[
                    "extra"] == nil)
        }

        @Test("an anchor round-trips, a nested group anchor included")
        func anchorRoundTrip() throws {
            let (left, x) = (createLeaf("terminal"), createLeaf("browser"))
            let root = createSplit(.horizontal, [left, createTabs([createTab("Only", x)])])
            let anchor = try #require(Floating.captureAnchor(root, x.id))
            let pane = FloatingPane(id: "f", content: x, rect: FloatRect(x: 1, y: 2, width: 300, height: 200), anchor: anchor)

            #expect(try decode(try JSONValue(encoding: pane), as: FloatingPane.self).value == pane)
        }
    }

    @Suite struct UniqueIDs {
        @Test("repeated pane and window ids get fresh ones, avoiding ids in use elsewhere")
        func uniqueIDs() {
            var model = LayoutModel(windows: [
                WindowLayout(
                    id: "w", root: createTabs([createTab("A", createLeaf("t", id: "dup")), createTab("B", createLeaf("t", id: "x"))])),
                WindowLayout(
                    id: "w", root: createTabs([createTab("C", createLeaf("t", id: "dup")), createTab("D", createLeaf("t", id: "live"))]),
                    active: "live"),
            ])

            let notes = model.makeLeafIDsUnique(avoiding: ["live"])

            #expect(model.windows[0].id == "w")
            #expect(model.windows[1].id != "w", "window ids are unique too")
            #expect(model.windows[0].leaves.map(\.id) == ["dup", "x"], "the first of a repeated id keeps it")
            let second = model.windows[1].leaves.map(\.id)
            #expect(second.count == 2 && !second.contains("dup") && !second.contains("live"), "ids in use elsewhere are avoided")
            #expect(Set(model.leaves.map(\.id)).count == 4)
            #expect(model.windows[1].holds(model.windows[1].activePaneID), "an active pane that was renamed falls back to one that exists")
            #expect(notes.count == 3)
        }

        @Test("unique ids leave a layout that has none repeated as it was")
        func alreadyUnique() {
            let window = WindowLayout(id: "w", root: createTabs([createTab("A", createLeaf("t", id: "a"))]), active: "a")
            var model = LayoutModel(windows: [window], lastClosed: WindowLayout(id: "v", root: createLeaf("t", id: "b")))
            let before = model

            #expect(model.makeLeafIDsUnique().isEmpty)
            #expect(model == before)
        }
    }
}
