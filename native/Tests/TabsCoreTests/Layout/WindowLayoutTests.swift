import Foundation
import TabsPluginSDK
import Testing

@testable import TabsCore

/// One window's layout — the actions of the Electron app's `layoutStore.ts`.
/// There is no layoutStore unit test file there: these are derived from its
/// documented rules and from the outcomes its UI-level tests pin
/// (src/renderer/src/__tests__/*.test.tsx, e2e/browser/*.spec.ts,
/// src/renderer/src/content/__tests__/crossWindowDrag.test.tsx), named after
/// the test they come from where there is one.
///
/// Not ported, because nothing natively corresponds: `reinsertAtAnchor` and
/// its `wholeWindowDetach`/`rebaseRootAnchor` rollback (a native cross-window
/// move is all-or-nothing on copies — see LayoutEngineTests), `setLeafConfig`
/// (configs are read from live panes at save), transfer state and
/// `setReportingCommit` (no IPC, no subscribers that can throw).
@Suite struct WindowLayoutTests {
    static let titles = LayoutTitles(displayNames: ["stub": "Stub", "terminal": "Terminal"])
    static let viewport = Viewport(width: 1200, height: 800)
    static let rect = FloatRect(x: 40, y: 60, width: 500, height: 300)

    /// A window around `root` (wrapped in the root group, as every window is).
    static func window(_ root: LayoutNode = createLeaf("empty"), floating: [FloatingPane] = [], active: NodeID? = nil) -> WindowLayout {
        WindowLayout(id: "w", root: root, floating: floating, active: active, titles: titles)
    }

    static func float(_ content: LayoutNode, _ id: NodeID = .make(), anchor: FloatAnchor = .root) -> FloatingPane {
        FloatingPane(id: id, content: content, rect: rect, anchor: anchor)
    }

    @Suite struct RootGroup {
        @Test("starts with a single top-level tab wrapping one empty pane, the pane active")
        func fresh() throws {
            let window = WindowLayout(titles: titles)

            #expect(window.root.tabs.count == 1)
            let tab = try #require(window.root.tabs.first)
            #expect(tab.title == "Tabs")
            #expect(tab.content.kind == "empty")
            // Resolved against the pre-wrap tree: the leaf, not the wrapper's chrome.
            #expect(window.activePaneID == tab.content.id)
        }

        @Test("a bare tree is wrapped as the root's only tab, titled by what it is")
        func wrapsBareTree() {
            let (left, right) = (createLeaf("empty"), createLeaf("empty"))
            let split = createSplit(.horizontal, [left, right], id: "row")

            let window = window(split, active: left.id)

            #expect(window.root.tabs.map(\.content) == [split])
            #expect(window.root.tabs.map(\.title) == ["Split"])
            #expect(window.activePaneID == left.id)
            #expect(WindowLayoutTests.window(createLeaf("stub")).root.tabs.map(\.title) == ["Stub"])
        }

        @Test("a tree that is already a group is the root group itself")
        func groupIsRoot() {
            let root = createTabs([createTab("Mine", createLeaf("stub"))], id: "g")
            #expect(window(root).rootNode == root)
        }
    }

    @Suite struct SetActivePane {
        @Test("clicking the root tab strip activates the wrapper pane, not its tab content")
        func rootChrome() {
            var window = window()
            #expect(window.setActivePane(window.root.id) == true)
            #expect(window.activePaneID == window.root.id)
        }

        @Test("activating the active pane again, or an unknown one, changes nothing")
        func noOps() {
            var window = window()
            let before = window
            #expect(window.setActivePane(window.activePaneID) == false)
            #expect(window.setActivePane("missing") == false)
            #expect(window == before)
        }

        @Test("the last activated floating window paints over the others")
        func raisesItsWindow() {
            let (a, b) = (createLeaf("stub"), createLeaf("stub"))
            var window = window(floating: [float(a, "older"), float(b, "newer")])

            #expect(window.setActivePane(a.id) == true)
            #expect(window.floating.map(\.id) == ["newer", "older"])
            #expect(window.activePaneID == a.id)
            // Already active and already on top: nothing churns.
            #expect(window.setActivePane(a.id) == false)
        }
    }

    @Suite struct ActivateTab {
        @Test("switching a tab activates it without moving the active pane")
        func switches() {
            let (one, two) = (createTab("One", createLeaf("stub")), createTab("Two", createLeaf("stub")))
            let group = createTabs([one, two], id: "g")
            var window = window(createSplit(.horizontal, [createLeaf("empty", id: "e"), group]), active: "e")

            #expect(window.activateTab("g", two.id, titles: titles) == true)
            #expect(Tree.findNode(window.rootNode, "g")?.activeTabID == two.id)
            #expect(window.activePaneID == "e")
            #expect(window.activateTab("g", two.id, titles: titles) == false, "already active")
        }
    }

    @Suite struct CloseTab {
        @Test("closing the last tab of a converted pane empties it without collapsing the split")
        func emptiesSlot() {
            let e = createLeaf("empty")
            let only = createTab("New Tab", createLeaf("empty"))
            var window = window(createSplit(.vertical, [e, createTabs([only])]))

            #expect(window.closeTab(only.id, titles: titles) == true)

            let split = window.root.tabs.first?.content
            #expect(split?.childNodes.count == 2)
            #expect(split?.childNodes[safe: 0] == e)
            #expect(split?.childNodes[safe: 1]?.kind == "empty")
        }

        @Test("closing one tab of a two-tab group collapses it back to the remaining pane")
        func collapsesPair() {
            let e = createLeaf("empty")
            let (first, second) = (createTab("A", createLeaf("empty")), createTab("B", createLeaf("empty")))
            var window = window(createSplit(.horizontal, [e, createTabs([first, second], active: second.id)]))

            #expect(window.closeTab(second.id, titles: titles) == true)

            #expect(window.root.tabs.first?.content.childNodes == [e, first.content])
        }

        @Test("closing the root's only tab leaves a fresh empty pane, still wrapped in the root group")
        func onlyRootTab() throws {
            var window = window(createLeaf("stub"))
            let only = try #require(window.root.tabs.first)

            #expect(window.closeTab(only.id, titles: titles) == true)

            #expect(window.root.tabs.count == 1)
            #expect(window.root.tabs.first?.title == "Tabs")
            #expect(window.root.tabs.first?.content.kind == "empty")
            #expect(window.holds(window.activePaneID))
        }

        @Test("a root that collapses to its last tab keeps that tab's title")
        func survivorKeepsTitle() {
            let (a, b) = (createTab("Server (renamed)", createLeaf("stub")), createTab("Other", createLeaf("stub")))
            var window = window(createTabs([a, b], id: "g"))

            #expect(window.closeTab(b.id, titles: titles) == true)

            // The collapse unwraps the root group; the rewrap is named after what stayed.
            #expect(window.root.tabs.map(\.title) == ["Server (renamed)"])
            #expect(window.root.tabs.map(\.content) == [a.content])
        }
    }

    @Suite struct MoveTab {
        @Test("dragging a tab onto another tab bar moves it there, collapsing an emptied source bar")
        func acrossBars() {
            let (moving, staying) = (createTab("A", createLeaf("stub")), createTab("B", createLeaf("stub")))
            let a = createTabs([moving], id: "a")
            let b = createTabs([staying], id: "b")
            var window = window(createSplit(.horizontal, [a, b]))

            #expect(window.moveTab(moving.id, to: "b", at: 1, titles: titles) == true)

            let split = window.root.tabs.first?.content
            #expect(split?.childNodes[safe: 0]?.kind == "empty")
            #expect(split?.childNodes[safe: 1]?.tabItems.map(\.id) == [staying.id, moving.id])
            #expect(split?.childNodes[safe: 1]?.activeTabID == moving.id)
            // Focus goes where the tab went.
            #expect(window.activePaneID == "b")
        }

        @Test("reordering a tab within its own tab bar via drag")
        func reorders() {
            let tabs = ["a", "b", "c"].map { createTab($0, createLeaf("stub")) }
            var window = window(createTabs(tabs, id: "g"))

            #expect(window.moveTab(tabs[0].id, to: "g", at: 2, titles: titles) == true)

            #expect(window.root.tabs.map(\.title) == ["b", "c", "a"])
            #expect(window.root.activeTabID == tabs[0].id)
        }

        @Test("dragging a tab onto an empty pane converts it into a tabs group containing just that tab")
        func ontoEmpty() {
            let moving = createTab("T", createLeaf("stub"))
            var window = window(createSplit(.horizontal, [createLeaf("empty", id: "e"), createTabs([moving])]))

            #expect(window.moveTab(moving.id, to: "e", titles: titles) == true)

            let landed = Tree.findNode(window.rootNode, "e")
            #expect(landed?.tabItems == [moving])
            #expect(window.activePaneID == "e")
        }
    }

    @Suite struct DockTab {
        @Test("docking a tab on a pane edge splits the pane")
        func edge() {
            let (first, second) = (createTab("S1", createLeaf("stub")), createTab("S2", createLeaf("stub")))
            let e = createLeaf("empty")
            var window = window(createSplit(.horizontal, [createTabs([first, second], id: "g"), e]))

            #expect(window.dockTab(first.id, onto: "g", zone: .right, titles: titles) == true)

            // The root strip still has one tab; the tab landed in a bar of its own
            // right of the survivor.
            #expect(window.root.tabs.count == 1)
            let row = window.root.tabs.first?.content
            #expect(row?.childNodes[safe: 0] == second.content)
            #expect(row?.childNodes[safe: 1]?.tabItems == [first])
            #expect(row?.childNodes[safe: 2] == e)
            #expect(window.activePaneID == row?.childNodes[safe: 1]?.id, "focus goes to the group now holding the tab")
        }

        @Test("a tab dropped on the docked root's own edge is declined")
        func rootEdge() {
            let tabs = [createTab("S1", createLeaf("stub")), createTab("S2", createLeaf("stub"))]
            var window = window(createTabs(tabs, id: "g"))
            let before = window

            #expect(window.splitsDockedRootOutOfItself("g", .right))
            #expect(window.dockTab(tabs[0].id, onto: "g", zone: .right, titles: titles) == false)
            #expect(window == before)
        }

        @Test("docking a tab in the center of another pane's content merges into its group")
        func center() {
            let moving = createTab("E", createLeaf("empty"))
            let existing = createTab("S", createLeaf("stub"))
            var window = window(createSplit(.horizontal, [createTabs([moving]), createTabs([existing], id: "b")]))

            #expect(window.dockTab(moving.id, onto: "b", zone: .center, titles: titles) == true)

            let b = Tree.findNode(window.rootNode, "b")
            #expect(b?.tabItems.map(\.id) == [existing.id, moving.id])
            #expect(b?.activeTabID == moving.id)
            #expect(window.activePaneID == "b")
        }

        @Test("a nested dock that collapses the root keeps the surviving tab's title, not \"Split\"")
        func survivorTitle() {
            let (a, b) = (createLeaf("stub", id: "a"), createLeaf("stub", id: "b"))
            let (tabA, tabB) = (createTab("Server", a), createTab("B", b))
            var window = window(createTabs([tabA, tabB], active: tabB.id))

            #expect(window.dockTab(tabB.id, onto: "a", zone: .right, titles: titles) == true)

            #expect(window.root.tabs.map(\.title) == ["Server"])
            let row = window.root.tabs.first?.content
            #expect(row?.childNodes[safe: 0] == a)
            #expect(row?.childNodes[safe: 1]?.tabItems == [tabB])
        }
    }

    @Suite struct DockPane {
        @Test("dragging a pane header over a sibling splits on release")
        func edge() {
            let (e1, e2) = (createLeaf("empty"), createLeaf("empty"))
            var window = window(createSplit(.horizontal, [e1, e2]))

            #expect(window.dockPane(e1.id, onto: e2.id, zone: .right, titles: titles) == true)

            #expect(window.root.tabs.first?.content.childNodes == [e2, e1])
            #expect(window.activePaneID == e1.id, "the pane keeps focus in its new place")
        }

        @Test("dragging a top-level pane to the window edge never splits the docked root out of itself")
        func rootEdge() {
            let tabs = ["S1", "S2", "S3"].map { createTab($0, createLeaf("stub")) }
            var window = window(createTabs(tabs, id: "g"))
            let before = window

            #expect(window.dockPane(tabs[0].content.id, onto: "g", zone: .left, titles: titles) == false)
            #expect(window == before)
        }

        @Test("dropping a pane into an empty pane moves it there bare, collapsing the source split")
        func intoEmpty() {
            let (e, s) = (createLeaf("empty"), createLeaf("stub"))
            var window = window(createSplit(.horizontal, [e, s]))

            #expect(window.dockPane(s.id, onto: e.id, zone: .center, titles: titles) == true)

            #expect(window.root.tabs.map(\.content) == [s])
            #expect(window.activePaneID == s.id)
        }

        @Test("dragging the sole tab's pane out dissolves its group entirely")
        func dissolvesGroup() {
            let (s, e) = (createLeaf("stub"), createLeaf("empty"))
            var window = window(createSplit(.horizontal, [createTabs([createTab("S", s)], id: "g"), e]))

            #expect(window.dockPane(s.id, onto: e.id, zone: .right, titles: titles) == true)

            #expect(window.root.tabs.first?.content.childNodes == [e, s])
            #expect(window.findNode("g") == nil)
        }

        @Test("a docked pane cannot be docked onto a floating window")
        func notOntoFloating() {
            let (a, b, c) = (createLeaf("stub"), createLeaf("stub"), createLeaf("stub"))
            var window = window(createSplit(.horizontal, [a, b]), floating: [float(c)])
            let before = window

            #expect(window.dockPane(a.id, onto: c.id, zone: .center, titles: titles) == false)
            #expect(window == before)
        }

        @Test("a pane that leaves the root names the rewrapped root after the tab that stayed")
        func departingTabDoesNotNameRoot() {
            // The departing pane's own tab is listed first and its content is
            // still in the result (split beside the survivor): it must not win.
            let (p, q) = (createLeaf("stub", id: "p"), createLeaf("stub", id: "q"))
            var window = window(createTabs([createTab("First", p), createTab("Second", q)]))

            #expect(window.dockPane("p", onto: "q", zone: .right, titles: titles) == true)

            #expect(window.root.tabs.map(\.title) == ["Second"])
            #expect(window.root.tabs.first?.content.childNodes == [q, p])
        }
    }

    @Suite struct MovePaneToTabs {
        @Test("dropping a pane onto a tab bar inserts it as a tab at that position")
        func atIndex() {
            let s = createLeaf("stub")
            let group = createTabs([createTab("E1", createLeaf("empty")), createTab("E2", createLeaf("empty"))], id: "a")
            var window = window(createSplit(.horizontal, [group, s]))

            #expect(window.movePaneToTabs(s.id, to: "a", at: 1, titles: titles) == true)

            let a = window.root.tabs.first?.content
            #expect(a?.id == "a", "the vacated split unwrapped down to the group")
            #expect(a?.titles == ["E1", "Stub", "E2"])
            #expect(a?.tabItems[safe: 1]?.content == s)
            #expect(a?.activeTabID == a?.tabItems[safe: 1]?.id)
            #expect(window.activePaneID == s.id)
        }

        @Test("a pane landing directly in the root group is titled for the window's own strip")
        func rootTitles() {
            let (e1, e2, s) = (createLeaf("empty"), createLeaf("empty"), createLeaf("stub"))
            var window = window(createSplit(.horizontal, [e1, e2, s]))

            #expect(window.movePaneToTabs(e2.id, to: window.root.id, titles: titles) == true)
            #expect(window.movePaneToTabs(s.id, to: window.root.id, titles: titles) == true)

            // A placeholder reads "Tabs" there, never "New Tab"; real content keeps its name.
            #expect(window.root.tabs.map(\.title) == ["Split", "Tabs", "Stub"])
        }
    }

    @Suite struct SplitPane {
        @Test("split creates a second pane and activates it")
        func creates() {
            var window = window()
            let first = window.activePaneID
            let added = createLeaf("empty")

            #expect(window.split(first, .horizontal, with: added, titles: titles) == true)

            #expect(window.root.tabs.first?.content.childIDs == [first, added.id])
            #expect(window.activePaneID == added.id)
        }

        @Test("splitting the docked root splits the tab it shows, the root staying one tab")
        func redirectsFromRoot() {
            var window = window()
            let shown = window.activePaneID
            let added = createLeaf("empty")

            #expect(window.split(window.root.id, .vertical, with: added, titles: titles) == true)

            #expect(window.root.tabs.count == 1)
            #expect(window.root.tabs.first?.content.childIDs == [shown, added.id])
        }

        @Test("adding and removing a split child leaves its siblings in place")
        func spliceAndClose() {
            let (left, right) = (createLeaf("empty", id: "left"), createLeaf("empty", id: "right"))
            var window = window(createSplit(.horizontal, [left, right], id: "row"), active: "left")
            let added = createLeaf("empty")

            #expect(window.split("left", .horizontal, with: added, titles: titles) == true)
            #expect(window.root.tabs.first?.content.childIDs == ["left", added.id, "right"], "spliced, not nested")

            #expect(window.closePane(added.id, titles: titles) == true)
            #expect(window.root.tabs.first?.content.childIDs == ["left", "right"])
        }
    }

    @Suite struct ResizeSplit {
        @Test("resizing a split inside a tab group keeps the active pane active")
        func keepsActive() {
            let (a, b) = (createLeaf("empty"), createLeaf("empty"))
            var window = window(
                createTabs([createTab("One", createLeaf("empty")), createTab("Two", createSplit(.horizontal, [a, b], id: "s"))]),
                active: a.id)

            #expect(window.resizeSplit("s", [0.3, 0.7], titles: titles) == true)

            #expect(window.findNode("s")?.sizes == [0.3, 0.7])
            #expect(window.activePaneID == a.id)
            #expect(window.resizeSplit("s", [0.3, 0.7], titles: titles) == false, "the same sizes change nothing")
        }
    }

    @Suite struct OpenContent {
        @Test("New tab on the initial pane adds a sibling top-level tab")
        func siblingTopLevelTab() {
            var window = window()
            let added = createLeaf("empty")

            #expect(window.openContent(at: window.activePaneID, added, titles: titles) == true)

            // A placeholder in the root group reads "Tabs", not "New Tab".
            #expect(window.root.tabs.map(\.title) == ["Tabs", "Tabs"])
            #expect(window.root.activeTab?.content == added)
            #expect(window.activePaneID == added.id)
        }

        @Test("repeated New tab clicks on the initial pane keep adding top-level tabs")
        func repeated() {
            var window = window()
            for _ in 0..<2 { window.openContent(at: window.activePaneID, createLeaf("empty"), titles: titles) }

            #expect(window.root.tabs.count == 3)
            #expect(window.root.activeIndex == 2)
        }

        @Test("New tab on a genuinely ungrouped pane (a split child) wraps it into a nested tab group")
        func splitChild() {
            let (e1, e2) = (createLeaf("empty"), createLeaf("empty"))
            var window = window(createSplit(.horizontal, [e1, e2]), active: e2.id)
            let added = createLeaf("empty")

            #expect(window.openContent(at: e2.id, added, titles: titles) == true)

            let nested = window.root.tabs.first?.content.childNodes[safe: 1]
            // The placeholder is dropped; the new tab is titled as a pane, not the window strip.
            #expect(nested?.titles == ["New Tab"])
            #expect(nested?.tabItems.first?.content == added)
            #expect(window.activePaneID == added.id)
        }

        @Test("selecting a tab's own content adds a sibling tab to its group, not a nested one")
        func siblingInGroup() {
            let (e1, e2) = (createLeaf("empty"), createLeaf("empty"))
            var window = window(createTabs([createTab("One", e1), createTab("Two", e2)]), active: e2.id)

            #expect(window.openContent(at: e2.id, createLeaf("empty"), titles: titles) == true)

            #expect(window.root.tabs.count == 3)
            #expect(!window.root.tabs.contains { $0.content.isTabs })
        }

        @Test("pressing one fills the pane in place rather than opening anything beside it")
        func fills() {
            var window = window()
            let stub = createLeaf("stub")

            #expect(window.openContent(at: window.activePaneID, stub, titles: titles) == true)

            #expect(window.root.tabs.map(\.content) == [stub])
            #expect(window.root.tabs.first?.title == "Tabs", "filling a blank tab never renames it")
            #expect(window.activePaneID == stub.id)
        }

        @Test("a nested group's + button adds a tab to that group only, leaving root's alone")
        func nestedGroup() {
            var window = window(createTabs([createTab("Tabs", createTabs([createTab("New Tab", createLeaf("empty"))], id: "g"))]))

            #expect(window.openContent(at: "g", createLeaf("empty"), titles: titles) == true)

            #expect(window.root.tabs.count == 1)
            #expect(window.findNode("g")?.titles == ["New Tab", "New Tab"])
        }

        @Test("cmd+T opens a new tab inside the focused floating window, not in the docked layout")
        func insideFloating() {
            let inWindow = createLeaf("empty")
            var window = window(floating: [float(inWindow, "f")], active: inWindow.id)
            let docked = window.root
            let added = createLeaf("empty")

            #expect(window.openContent(at: inWindow.id, added, titles: titles) == true)

            #expect(window.root == docked)
            #expect(window.floating.map(\.id) == ["f"], "the window keeps its identity when its content is replaced")
            let content = window.floating.first?.content
            // A floating window's tabs are never the window strip's "Tabs".
            #expect(content?.titles == ["New Tab"])
            #expect(content?.tabItems.first?.content == added)
            #expect(window.activePaneID == added.id)

            #expect(window.openContent(at: content?.id ?? "", createLeaf("empty"), titles: titles) == true)
            #expect(window.floating.first?.content.titles == ["New Tab", "New Tab"])
        }
    }

    @Suite struct ClosePane {
        @Test("an empty split pane can be closed from its title bar, collapsing the split")
        func collapsesSplit() {
            let (e1, e2) = (createLeaf("empty"), createLeaf("empty"))
            var window = window(createSplit(.horizontal, [e1, e2]))

            #expect(window.closePane(e1.id, titles: titles) == true)

            #expect(window.root.tabs.map(\.content) == [e2])
            #expect(window.activePaneID == e2.id)
        }

        @Test("closing the root pane resets it to a fresh empty pane")
        func root() {
            let stub = createLeaf("stub")
            var window = window(stub)

            #expect(window.closePane(window.root.id, titles: titles) == true)

            #expect(window.root.tabs.count == 1)
            #expect(window.root.tabs.first?.content.kind == "empty")
            #expect(window.findNode(stub.id) == nil)
            #expect(window.holds(window.activePaneID))
        }

        @Test("closing a tab's content pane closes the tab itself, collapsing a two-tab group")
        func tabContent() {
            let (e1, e2) = (createLeaf("empty"), createLeaf("empty"))
            let (one, two) = (createTab("One", e1), createTab("Two", e2))
            var window = window(createTabs([one, two], active: two.id), active: e2.id)

            #expect(window.closePane(e2.id, titles: titles) == true)

            #expect(window.root.tabs.map(\.content) == [e1])
            #expect(window.root.tabs.map(\.title) == ["One"])
            #expect(window.activePaneID == e1.id)
        }

        @Test("closing the active pane in a 3-way split focuses its true neighbor, not the leftmost pane")
        func focusesNeighbour() {
            let (a, b, c) = (createLeaf("stub"), createLeaf("stub"), createLeaf("stub"))
            var window = window(createSplit(.horizontal, [a, b, c]), active: c.id)

            #expect(window.closePane(c.id, titles: titles) == true)

            #expect(window.root.tabs.first?.content.childIDs == [a.id, b.id])
            #expect(window.activePaneID == b.id)
        }

        @Test("closing a non-active pane never steals focus from the active one")
        func keepsFocus() {
            let (a, b, c) = (createLeaf("stub"), createLeaf("stub"), createLeaf("stub"))
            var window = window(createSplit(.horizontal, [a, b, c]), active: a.id)

            #expect(window.closePane(b.id, titles: titles) == true)

            #expect(window.activePaneID == a.id)
        }

        @Test("the root bar closes the top-level tab it is showing, not every tab in the window")
        func rootBar() {
            let tabs = ["S1", "S2", "S3"].map { createTab($0, createLeaf("stub")) }
            var window = window(createTabs(tabs, id: "g", active: tabs[2].id), active: "g")

            #expect(window.closeTarget("g") == tabs[2].content, "the close asks about what it will close")
            #expect(window.closePane("g", titles: titles) == true)

            #expect(window.root.id == "g")
            #expect(window.root.tabs.map(\.title) == ["S1", "S2"])
        }

        @Test("closing the last floating pane returns focus to the docked pane, not the root tab group")
        func lastFloating() {
            var window = window()
            let docked = window.activePaneID
            let unpinned = createLeaf("empty")
            window.openFloatingPane(unpinned, rect: rect, viewport: viewport)

            #expect(window.closePane(unpinned.id, titles: titles) == true)

            #expect(window.floating.isEmpty)
            #expect(window.activePaneID == docked)
        }

        @Test("closing one floating window hands focus to the one now on top")
        func anotherFloating() {
            let (a, b) = (createLeaf("stub"), createLeaf("stub"))
            var window = window(floating: [float(a, "under"), float(b, "top")], active: a.id)

            #expect(window.closePane(a.id, titles: titles) == true)

            #expect(window.floating.map(\.id) == ["top"])
            #expect(window.activePaneID == b.id)
        }
    }

    @Suite struct ClearPane {
        @Test("clearing a pane empties it in place, keeping the split")
        func inPlace() throws {
            let (e, s) = (createLeaf("empty"), createLeaf("stub"))
            var window = window(createSplit(.horizontal, [e, s]), active: e.id)

            #expect(window.clearPane(s.id, titles: titles) == true)

            let row = try #require(window.root.tabs.first?.content)
            #expect(row.childNodes.count == 2)
            #expect(row.childNodes[safe: 1]?.kind == "empty")
            #expect(row.childNodes[safe: 1]?.id != s.id)
            // The cleared pane keeps focus under its new identity.
            #expect(window.activePaneID == row.childNodes[safe: 1]?.id)
        }

        @Test("clearing the docked root clears the tab it shows, not the window")
        func root() {
            let tabs = [createTab("S1", createLeaf("stub")), createTab("S2", createLeaf("stub"))]
            var window = window(createTabs(tabs, id: "g", active: tabs[1].id))

            #expect(window.clearPane("g", titles: titles) == true)

            #expect(window.root.id == "g")
            #expect(window.root.tabs.map(\.title) == ["S1", "S2"])
            #expect(window.root.tabs[0].content == tabs[0].content)
            #expect(window.root.tabs[1].content.kind == "empty")
        }

        @Test("clearing a placeholder, or nothing, changes nothing")
        func noOps() {
            var window = window()
            let before = window
            #expect(window.clearPane(window.activePaneID, titles: titles) == false)
            #expect(window.clearPane("missing", titles: titles) == false)
            #expect(window == before)
        }

        @Test("clearing a floating window's own pane keeps the window")
        func floating() {
            let s = createLeaf("stub")
            var window = window(floating: [float(s, "f")], active: s.id)

            #expect(window.clearPane(s.id, titles: titles) == true)

            #expect(window.floating.map(\.id) == ["f"])
            #expect(window.floating.first?.content.kind == "empty")
            #expect(window.activePaneID == window.floating.first?.content.id)
        }
    }

    @Suite struct WrapPaneInTabs {
        @Test("the tab-group control wraps a pane into a group, which becomes active")
        func wraps() {
            let (e, s) = (createLeaf("empty"), createLeaf("stub"))
            var window = window(createSplit(.horizontal, [e, s]))

            #expect(window.wrapPaneInTabs(s.id, titles: titles) == true)

            let group = window.root.tabs.first?.content.childNodes[safe: 1]
            #expect(group?.titles == ["Stub"])
            #expect(group?.tabItems.first?.content == s)
            #expect(window.activePaneID == group?.id)
        }

        @Test("the tab-group control nests an existing group inside a new one")
        func nestsGroup() {
            let inner = createTabs([createTab("E", createLeaf("empty"))], id: "inner")
            var window = window(createSplit(.horizontal, [createLeaf("empty"), inner]))

            #expect(window.wrapPaneInTabs("inner", titles: titles) == true)

            let outer = window.root.tabs.first?.content.childNodes[safe: 1]
            #expect(outer?.titles == ["Tab group"])
            #expect(outer?.tabItems.first?.content == inner)
        }

        @Test("wrapping the docked root wraps the tab it shows")
        func root() {
            let s = createLeaf("stub")
            var window = window(s)
            let rootID = window.root.id

            #expect(window.wrapPaneInTabs(rootID, titles: titles) == true)

            #expect(window.root.id == rootID)
            let group = window.root.tabs.first?.content
            #expect(group?.tabItems.map(\.content) == [s])
            #expect(window.activePaneID == group?.id)
        }
    }

    @Suite struct UngroupTabs {
        @Test("Ungroup collapses a single-tab group back to the pane")
        func collapses() {
            let (e, inner) = (createLeaf("empty"), createLeaf("empty"))
            var window = window(createSplit(.horizontal, [e, createTabs([createTab("E", inner)], id: "g")]))

            #expect(window.ungroupTabs("g", titles: titles) == true)

            #expect(window.root.tabs.first?.content.childNodes == [e, inner])
            #expect(window.activePaneID == inner.id)
        }

        @Test("the docked root, and a group of several tabs, cannot ungroup")
        func refuses() {
            let pair = createTabs([createTab("A", createLeaf("empty")), createTab("B", createLeaf("empty"))], id: "pair")
            var window = window(createSplit(.horizontal, [createLeaf("empty"), pair]))
            let before = window

            #expect(window.ungroupTabs(window.root.id, titles: titles) == false)
            #expect(window.ungroupTabs("pair", titles: titles) == false)
            #expect(window == before)
        }
    }

    @Suite struct FloatingPanes {
        @Test("unpinning a pane from a split lifts it into a floating window and collapses the split")
        func unpins() {
            let (a, b) = (createLeaf("stub"), createLeaf("stub"))
            var window = window(createSplit(.horizontal, [a, b]))

            #expect(
                window.unpinPane(b.id, rect: FloatRect(x: 900, y: -50, width: 500, height: 300), viewport: viewport, titles: titles) == true
            )

            #expect(window.root.tabs.map(\.content) == [a])
            #expect(window.floating.map(\.content) == [b])
            #expect(window.floating.first?.rect == FloatRect(x: 900, y: 0, width: 500, height: 300), "clamped into the viewport")
            #expect(window.activePaneID == b.id)
        }

        @Test("re-pinning a floating pane puts it back beside the sibling it came from")
        func repins() throws {
            let (a, b) = (createLeaf("stub"), createLeaf("stub"))
            var window = window(createSplit(.horizontal, [a, b]))
            window.unpinPane(b.id, rect: rect, viewport: viewport, titles: titles)

            #expect(window.repinPane(try #require(window.floating.first?.id), titles: titles) == true)

            #expect(window.floating.isEmpty)
            #expect(window.root.tabs.first?.content.childIDs == [a.id, b.id])
            #expect(window.activePaneID == b.id)
        }

        @Test("re-pinning restores a pane into the tab group and position it came from")
        func repinsIntoGroup() throws {
            let tabs = ["One", "Two", "Three"].map { createTab($0, createLeaf("stub")) }
            var window = window(createTabs(tabs, id: "g"))

            #expect(window.unpinPane(tabs[1].content.id, rect: rect, viewport: viewport, titles: titles) == true)
            #expect(window.root.tabs.map(\.title) == ["One", "Three"])
            #expect(window.repinPane(try #require(window.floating.first?.id), titles: titles) == true)

            #expect(window.root.id == "g")
            #expect(window.root.tabs.map(\.title) == ["One", "Two", "Three"])
            #expect(window.root.tabs.map(\.content) == tabs.map(\.content))
        }

        @Test("re-pinning after its old neighbours are gone still lands the pane in the layout")
        func repinsWithoutNeighbours() throws {
            let (a, b) = (createLeaf("stub"), createLeaf("stub"))
            var window = window(createSplit(.horizontal, [a, b]))
            window.unpinPane(b.id, rect: rect, viewport: viewport, titles: titles)
            window.closePane(a.id, titles: titles)

            #expect(window.repinPane(try #require(window.floating.first?.id), titles: titles) == true)

            #expect(window.floating.isEmpty)
            #expect(window.rootNode.leaves.filter { $0.id == b.id }.count == 1)
        }

        @Test("a whole tab group can be unpinned and re-pinned, tabs intact")
        func wholeGroup() throws {
            let group = createTabs([createTab("A", createLeaf("stub")), createTab("B", createLeaf("stub"))], id: "g")
            var window = window(createSplit(.horizontal, [createLeaf("empty"), group]))

            #expect(window.unpinPane("g", rect: rect, viewport: viewport, titles: titles) == true)
            #expect(window.floating.first?.content == group)
            #expect(window.repinPane(try #require(window.floating.first?.id), titles: titles) == true)

            #expect(window.findNode("g") == group)
        }

        @Test("unpinning the docked root's own tab bar is declined")
        func notTheRoot() {
            var window = window()
            let before = window
            #expect(window.unpinPane(window.root.id, rect: rect, viewport: viewport, titles: titles) == false)
            #expect(window.unpinPane("missing", rect: rect, viewport: viewport, titles: titles) == false)
            #expect(window == before)
        }

        @Test("New Unpinned Pane opens content straight into a floating window, on top and focused")
        func opensFloating() {
            let old = createLeaf("stub")
            var window = window(floating: [float(old, "old")])
            let added = createLeaf("empty")

            #expect(window.openFloatingPane(added, rect: FloatRect(x: 0, y: 0, width: 9000, height: 9000), viewport: viewport) == true)

            #expect(window.floating.map(\.content) == [old, added])
            #expect(window.floating.last?.anchor == .root)
            #expect(window.floating.last?.rect == FloatRect(x: 0, y: 0, width: viewport.width, height: viewport.height))
            #expect(window.activePaneID == added.id)
        }

        @Test("re-pinning a new unpinned pane docks it beside whatever is active then")
        func repinsNewPane() throws {
            let s = createLeaf("stub")
            var window = window(s)
            let added = createLeaf("terminal")
            window.openFloatingPane(added, rect: rect, viewport: viewport)
            window.setActivePane(s.id)

            #expect(window.repinPane(try #require(window.floating.first?.id), titles: titles) == true)

            #expect(window.root.tabs.map(\.content) == [s, added])
            #expect(window.root.tabs.map(\.title) == ["Stub", "Terminal"])
            #expect(window.activePaneID == added.id)
        }

        @Test("a move or resize commits its clamped geometry; the same geometry changes nothing")
        func setsRect() {
            var window = window(floating: [float(createLeaf("stub"), "f")])

            #expect(window.setFloatingRect("f", FloatRect(x: 100, y: 100, width: 10, height: 10), viewport: viewport) == true)
            #expect(
                window.floating.first?.rect == FloatRect(x: 100, y: 100, width: Floating.minSize.width, height: Floating.minSize.height))
            #expect(window.setFloatingRect("f", FloatRect(x: 100, y: 100, width: 10, height: 10), viewport: viewport) == false)
            #expect(window.setFloatingRect("missing", rect, viewport: viewport) == false)
        }

        @Test("re-clamping pulls every window back inside a smaller viewport, once")
        func reclamps() {
            var window = window(floating: [float(createLeaf("stub"), "a"), float(createLeaf("stub"), "b")])
            let small = Viewport(width: 300, height: 200)

            #expect(window.reclampFloating(small) == true)
            #expect(window.floating.allSatisfy { $0.rect == Floating.clamp($0.rect, to: small) })
            #expect(window.reclampFloating(small) == false)
        }

        @Test("raising a window brings it to the front; the frontmost one changes nothing")
        func raises() {
            var window = window(floating: [float(createLeaf("stub"), "a"), float(createLeaf("stub"), "b")])

            #expect(window.raiseFloating("a") == true)
            #expect(window.floating.map(\.id) == ["b", "a"])
            #expect(window.raiseFloating("a") == false)
            #expect(window.raiseFloating("missing") == false)
        }
    }

    @Suite struct Titles {
        @Test("renaming a tab, a pane, and a pane's live title each edit their own tree")
        func renames() throws {
            let (docked, floating) = (createLeaf("stub"), createLeaf("terminal"))
            var window = window(docked, floating: [float(floating, "f")])
            let tab = try #require(window.root.tabs.first)

            #expect(window.renameTab(tab.id, "Deploy", titles: titles) == true)
            #expect(window.root.tabs.first?.title == "Deploy")

            #expect(window.renamePane(floating.id, "My server", titles: titles) == true)
            #expect(window.floating.first?.content.leaf?.title == "My server")
            #expect(window.setLiveTitle(floating.id, "from the shell", titles: titles) == false, "a manual title sticks")

            #expect(window.setLiveTitle(docked.id, "vim", titles: titles) == true)
            #expect(window.findNode(docked.id)?.leaf?.title == "vim")
            #expect(window.renameTab(tab.id, "Deploy", titles: titles) == false, "the same title changes nothing")
        }

        @Test("a pane header reads its title, else what it is")
        func paneTitles() {
            #expect(titles.paneTitle(for: createLeaf("empty")) == "Empty pane")
            #expect(titles.paneTitle(for: createLeaf("stub")) == "Stub")
            #expect(titles.paneTitle(for: createLeaf("unknown")) == "unknown")
            #expect(titles.paneTitle(for: createLeaf("stub", title: "Scratch")) == "Scratch")
            #expect(titles.paneTitle(for: createTabs([welcomeTab()])) == "Tab group")
            #expect(titles.paneTitle(for: createSplit(.horizontal, [createLeaf("empty"), createLeaf("empty")])) == "Split")
            #expect(titles.tabTitle(for: createLeaf("empty")) == "New Tab")
            #expect(titles.rootTabTitle(for: createLeaf("empty")) == "Tabs")
            #expect(titles.rootTabTitle(for: createLeaf("unknown")) == "Tabs")
            #expect(titles.tabTitle(for: createLeaf("terminal")) == "Terminal")
        }

        @Test("replacing a leaf replaces only a leaf")
        func replacesLeaf() {
            let e = createLeaf("empty")
            var window = window(e)
            let filled = LayoutLeaf(id: e.id, type: "stub")

            #expect(window.replaceLeaf(e.id, with: filled, titles: titles) == true)
            #expect(window.findNode(e.id) == .leaf(filled))
            #expect(window.replaceLeaf(window.root.id, with: filled, titles: titles) == false)
        }
    }

    @Suite struct Visibility {
        @Test("revealing a pane activates every tab above it and makes it active")
        func reveals() {
            let (a, x, y) = (createLeaf("stub"), createLeaf("stub"), createLeaf("stub"))
            let inner = createTabs([createTab("X", x), createTab("Y", y)], id: "inner")
            var window = window(createTabs([createTab("A", a), createTab("B", inner)], id: "g"), active: a.id)
            #expect(!window.isShowing(y.id))

            #expect(window.reveal(y.id, titles: titles) == true)

            #expect(window.isShowing(y.id))
            #expect(!window.isShowing(a.id))
            #expect(!window.isShowing(x.id))
            #expect(window.activePaneID == y.id)
            #expect(window.reveal(y.id, titles: titles) == false, "already revealed")
        }

        @Test("revealing a pane in a floating window raises it; floating panes show over the docked ones")
        func revealsFloating() {
            let (a, b) = (createLeaf("stub"), createLeaf("stub"))
            var window = window(floating: [float(a, "a"), float(b, "b")])

            #expect(window.reveal(a.id, titles: titles) == true)

            #expect(window.floating.map(\.id) == ["b", "a"])
            #expect(window.isShowing(a.id) && window.isShowing(b.id))
        }

        @Test("the active leaf is the pane inside an active group")
        func activeLeaf() {
            let (a, b) = (createLeaf("stub"), createLeaf("stub"))
            var window = window(createTabs([createTab("A", a), createTab("B", b)], id: "g"))
            window.activateTab("g", window.root.tabs[1].id, titles: titles)
            window.setActivePane("g")

            #expect(window.activeLeafID == b.id)
        }
    }

    /// The window's half of a cross-window move (`extractForCrossWindowMove`,
    /// `insertFromCrossWindowMove`, `canLeaveWindow` in layoutStore.ts; the
    /// store-driving cases of crossWindowDrag.test.tsx).
    @Suite struct CrossWindow {
        @Test("lets a window's only tab leave, a fresh placeholder staying behind")
        func onlyTabLeaves() throws {
            let only = createTab("Only", createLeaf("stub"))
            var window = window(createTabs([only]))

            let content = window.extract(.tab(tabID: only.id, sourceGroupID: window.root.id), titles: titles)

            #expect(content == .tab(only))
            #expect(window.rootNode.leaves.map(\.type) == [nil])
            #expect(window.holds(window.activePaneID))
        }

        @Test("keeps the surviving root tab its own title when a tab leaves")
        func survivorTitleForTab() throws {
            let (kept, other) = (createTab("Server (renamed)", createLeaf("stub")), createTab("Other", createLeaf("stub")))
            var window = window(createTabs([kept, other]), active: kept.content.id)

            #expect(window.extract(.tab(tabID: other.id, sourceGroupID: window.root.id), titles: titles) == .tab(other))

            #expect(window.root.tabs.map(\.title) == ["Server (renamed)"])
            #expect(window.activePaneID == kept.content.id)
        }

        @Test("keeps the surviving root tab its own title when a pane leaves")
        func survivorTitleForPane() throws {
            let (kept, other) = (createTab("Server (renamed)", createLeaf("stub")), createTab("Other", createLeaf("stub")))
            var window = window(createTabs([kept, other]), active: kept.content.id)

            #expect(window.extract(.pane(other.content.id), titles: titles) == .pane(other.content))

            #expect(window.root.tabs.map(\.title) == ["Server (renamed)"])
        }

        @Test("detaching a group takes every leaf under it")
        func wholeGroup() throws {
            let group = createTabs([createTab("A", createLeaf("stub")), createTab("B", createLeaf("stub"))], id: "group")
            var window = window(createTabs([createTab("Group", group), createTab("Other", createLeaf("stub", id: "bystander"))]))

            let content = window.extract(.pane("group"), titles: titles)

            #expect(content == .pane(group))

            #expect(window.findNode("group") == nil)
            #expect(window.holds("bystander"))
        }

        @Test("refuses to detach the docked root, or anything in a floating window")
        func refuses() {
            let inWindow = createLeaf("stub")
            var window = window(floating: [float(inWindow, "f")])
            let before = window

            #expect(!window.canLeaveWindow(.pane(window.root.id)))
            #expect(!window.canLeaveWindow(.pane(inWindow.id)))
            #expect(!window.canLeaveWindow(.pane("missing")))
            #expect(window.canLeaveWindow(.tab(tabID: window.root.tabs[0].id, sourceGroupID: window.root.id)))
            #expect(window.extract(.pane(window.root.id), titles: titles) == nil)
            #expect(window == before)
        }

        @Test("refuses an edge dock against the docked root, whatever asked for it")
        func refusesRootEdge() {
            var window = window()
            let before = window
            let incoming = MovingContent.pane(createLeaf("stub"))

            #expect(!window.accepts(.dock(targetID: window.root.id, zone: .left)))
            #expect(window.insert(incoming, at: .dock(targetID: window.root.id, zone: .left), titles: titles) == false)
            #expect(window.insert(incoming, at: .dock(targetID: "missing", zone: .center), titles: titles) == false)
            #expect(window == before)
        }

        @Test("a drop on another window's tab bar lands between its tabs, not appended")
        func tabBarIndex() {
            let tabs = [createTab("A", createLeaf("stub")), createTab("B", createLeaf("stub"))]
            var window = window(createTabs(tabs, id: "g"))
            let incoming = createTab("Moved", createLeaf("terminal"))

            #expect(window.insert(.tab(incoming), at: .tabBar(groupID: "g", index: 0), titles: titles) == true)

            #expect(window.root.tabs.map(\.title) == ["Moved", "A", "B"])
            #expect(window.activePaneID == incoming.content.id, "the moved content becomes active")
        }

        @Test("a drop into an empty tab of a nested group in another window fills that tab")
        func fillsEmptyTab() {
            let group = createTabs([createTab("S", createLeaf("stub")), createTab("E", createLeaf("empty", id: "e"))], id: "g")
            var window = window(createSplit(.horizontal, [createLeaf("stub"), group]))
            let incoming = createLeaf("terminal")

            #expect(window.accepts(.emptyPane("e")))
            #expect(window.insert(.pane(incoming), at: .emptyPane("e"), titles: titles) == true)

            #expect(window.findNode("g")?.tabItems.map(\.content) == [group.tabItems[0].content, incoming])
        }

        @Test("a pane dropped on another window's pane edge splits it there")
        func edgeDock() {
            let target = createLeaf("stub")
            var window = window(target)
            let incoming = createLeaf("terminal")

            #expect(window.insert(.pane(incoming), at: .dock(targetID: target.id, zone: .left), titles: titles) == true)

            #expect(window.root.tabs.count == 1)
            #expect(window.root.tabs.first?.content.childNodes == [incoming, target])
        }
    }
}
