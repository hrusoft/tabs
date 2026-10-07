import AppKit
import Foundation
import TabsPluginSDK
import Testing

@testable import TabsCore

/// A stub pane that can warn before closing.
@MainActor
final class WarningPane: PaneController {
    let view = NSView()
    var warning: String?
    var config: JSONValue
    init(config: JSONValue) { self.config = config }
    func currentConfig() -> JSONValue { config }
    var closeWarning: String? { warning }
}

/// The layout engine: the model's changes reaching plugins, views and disk,
/// in order, against a fake renderer, unhosted. The layout rules themselves
/// are the model's (Layout/*Tests).
@MainActor
@Suite struct LayoutEngineTests {
    let runtime = TestSupport.runtime()
    let renderer = FakeRenderer()
    final class Log { var lines: [String] = [] }
    let log = Log()

    /// Starts `stub` (and a watcher logging pane events), plus `extra`, and
    /// an engine drawn by the fake renderer.
    private func engine(_ extra: PluginCandidate..., restoring saved: SavedLayout? = nil) -> LayoutEngine {
        let log = log
        runtime.startPlugins(
            from: nil,
            inProcess: [
                TestSupport.candidate(TestSupport.manifest("stub", contentTypes: ["stub"])) { context in
                    context.register(
                        ContentTypeContribution(id: "stub", displayName: "Stub", icon: .symbol("circle")) {
                            WarningPane(config: $0.initialConfig)
                        })
                },
                TestSupport.candidate(TestSupport.manifest("watcher")) { context in
                    for (channel, name) in [
                        (EventChannel<PaneEvent>.paneOpened, "open"), (.paneClosed, "close"), (.activePaneChanged, "active"),
                        (.paneMoved, "moved"),
                    ] {
                        context.events.subscribe(channel) { log.lines.append("\(name) \($0.paneID)") }
                    }
                },
            ] + extra, requiredContentTypes: saved?.contentTypes ?? [])
        let engine = LayoutEngine(runtime: runtime)
        engine.renderer = renderer
        engine.restore(saved)
        return engine
    }

    /// A window whose root group holds one tab per pane (`active` is the shown one).
    private func window(_ ids: PaneID..., active: Int = 0, id: WindowID = "w", type: ContentTypeID? = "stub") -> WindowLayout {
        let tabs = ids.map { Tab(title: "Tab", content: .leaf(LayoutLeaf(id: $0, type: type))) }
        return WindowLayout(id: id, root: .tabs(TabGroup(tabs: tabs, activeTabID: tabs[active].id)), active: ids[active])
    }

    /// The panes of a window's root tabs, in order.
    private func tabs(_ engine: LayoutEngine, _ window: WindowID = "w") -> [PaneID] {
        engine.model.window(window)?.root.tabs.map(\.content.id) ?? []
    }

    private func activeLeaf(_ engine: LayoutEngine, _ window: WindowID = "w") -> PaneID? {
        engine.model.window(window)?.activeLeafID
    }

    /// Clicks a pane's tab: shows it and makes it active.
    private func select(_ engine: LayoutEngine, _ pane: PaneID, in window: WindowID = "w") {
        engine.perform(in: window) { layout, titles in layout.reveal(pane, titles: titles) }
    }

    // MARK: Restoring and saving

    @Test func restoringAnnouncesPanesThenTheActiveOneOnce() {
        let engine = engine(restoring: SavedLayout(windows: [window("a", "b", active: 1)]))
        #expect(log.lines == ["open a", "open b", "active b"])
        engine.frontmostWindowDidChange()
        #expect(log.lines.count == 3, "re-activating the same pane is not a change")
        #expect(renderer.rendered == engine.model, "the renderer drew the model")
    }

    @Test func aPaneWhosePluginIsMissingRoundTripsVerbatim() {
        let orphan = LayoutLeaf(id: "p1", type: "vanished", config: ["deep": ["keep": [1, 2, 3]]], title: "Old")
        let saved = WindowLayout(
            id: "w",
            root: .tabs(
                TabGroup(tabs: [
                    Tab(title: "Old", content: .leaf(orphan)), Tab(title: "Stub", content: .leaf(LayoutLeaf(id: "p2", type: "stub"))),
                ])),
            active: "p2")
        let engine = engine(restoring: SavedLayout(windows: [saved]))
        guard case .unavailable(let reason) = engine.body(of: "p1") else {
            Issue.record("expected a placeholder")
            return
        }
        #expect(reason == "No installed plugin provides it.")
        #expect(engine.snapshot().windows.first?.leaves.first == orphan)
        #expect(activeLeaf(engine) == "p2")
    }

    @Test func savingAsksLivePanesAndLoadingGivesTheSameBack() throws {
        let engine = engine(restoring: SavedLayout(windows: [window("a")]))
        (engine.live("a")?.controller as? WarningPane)?.config = ["n": 2]
        engine.saveNow()
        let reloaded = try #require(LayoutStore(file: runtime.paths.layoutFile).load().document)
        #expect(reloaded == engine.snapshot())
        #expect(reloaded.windows.first?.leaves.first?.config == ["n": 2])
        #expect(reloaded.contentTypes == ["stub"])
    }

    @Test func nothingSavedMeansOneWindowWithAnEmptyTab() {
        let engine = engine()
        #expect(engine.model.windows.count == 1)
        #expect(engine.model.leaves.map(\.type) == [nil])
        #expect(engine.model.windows.first?.root.tabs.map(\.title) == ["Tabs"])
    }

    @Test func duplicatePaneIDsInASavedLayoutGetFreshOnesThatCoreShares() throws {
        let engine = engine(
            restoring: SavedLayout(windows: [
                WindowLayout(id: "w1", root: .leaf(LayoutLeaf(id: "dup", type: "stub", config: ["n": 1]))),
                WindowLayout(
                    id: "w2",
                    root: .tabs(
                        TabGroup(tabs: [
                            Tab(title: "Stub", content: .leaf(LayoutLeaf(id: "dup", type: "stub", config: ["n": 2]))),
                            Tab(title: "Tabs", content: .leaf(LayoutLeaf(id: "dup", type: nil))),
                        ]))),
            ]))
        let ids = engine.model.leaves.map(\.id)
        #expect(Set(ids).count == 3)
        for id in ids where engine.model.leaf(id)?.type != nil { #expect(engine.live(id)?.id == id) }
        let copy = try #require(engine.model.window("w2")?.leaves.first?.id)
        engine.close(copy)
        #expect(runtime.panes.pane("dup") != nil, "the first window's pane is untouched")
        #expect(runtime.panes.panes(ofType: "stub") == ["dup"])
    }

    // MARK: Tabs and panes

    @Test func closingTabsKeepsTheUserWhereTheyAre() {
        let engine = engine(restoring: SavedLayout(windows: [window("a", "b", "c", "d", active: 0)]))
        engine.close("c")
        #expect(activeLeaf(engine) == "a", "a background tab")
        select(engine, "b")
        engine.close("a")
        #expect(activeLeaf(engine) == "b", "indexes shift, the active pane doesn't")
        engine.close("b")
        #expect(activeLeaf(engine) == "d", "the active tab's neighbour")
        #expect(log.lines.suffix(3) == ["close a", "close b", "active d"])
    }

    @Test func closingTheLastPaneLeavesAnEmptyOneAndTheWindow() {
        let engine = engine(restoring: SavedLayout(windows: [window("a")]))
        engine.close("a")
        #expect(engine.model.windows.map(\.id) == ["w"], "the window stays")
        #expect(engine.model.leaves.map(\.type) == [nil], "a fresh empty pane")
        #expect(engine.model.windows.first?.root.tabs.map(\.title) == ["Tabs"])
        #expect(log.lines.last == "active \(engine.activePaneID?.rawValue ?? "")")
        #expect(log.lines.contains("close a"))
    }

    @Test func closingTheDockedRootClosesTheTabItShowsAndAsksOnlyAboutThat() throws {
        let engine = engine(restoring: SavedLayout(windows: [window("a", "b", "c", active: 2)]))
        for id in ["a", "b", "c"] { (engine.live(PaneID(id))?.controller as? WarningPane)?.warning = id.uppercased() }
        let root = try #require(engine.model.window("w")?.root.id)
        renderer.answers = [false]
        engine.close(root)
        #expect(renderer.asked == [["C"]], "asked about the tab it would close, not the whole window")
        #expect(tabs(engine) == ["a", "b", "c"], "declined")
        engine.close(root)
        #expect(tabs(engine) == ["a", "b"])
    }

    @Test func closingATabAsksAboutItsContent() throws {
        let engine = engine(restoring: SavedLayout(windows: [window("a", "b")]))
        (engine.live("b")?.controller as? WarningPane)?.warning = "Unsaved"
        let tab = try #require(engine.model.window("w")?.root.tabs.last?.id)
        renderer.answers = [false]
        engine.closeTab(tab)
        #expect(renderer.asked == [["Unsaved"]])
        #expect(tabs(engine) == ["a", "b"])
        engine.closeTab(tab)
        #expect(tabs(engine) == ["a"])
        #expect(log.lines.contains("close b"))
    }

    @Test func clearingAPaneEndsItAndLeavesAnEmptyOneWithFocus() throws {
        let engine = engine(restoring: SavedLayout(windows: [window("a", "b", active: 1)]))
        engine.clear("b")
        #expect(engine.live("b") == nil)
        #expect(log.lines.contains("close b"))
        let empty = try #require(engine.model.window("w")?.root.tabs.last?.content)
        #expect(empty.isEmpty)
        #expect(engine.activePaneID == empty.id)
        #expect(tabs(engine).first == "a")
    }

    @Test func aPluginChoosingATabWhileAnotherClosesKeepsItsChoice() throws {
        final class Choice { var pane: PaneID? }
        let choice = Choice()
        let engine = engine(
            TestSupport.candidate(TestSupport.manifest("chooser", contentTypes: ["chooser"])) { context in
                context.register(TestSupport.contentType("chooser"))
                let workspace = context.workspace
                context.events.subscribe(.paneClosed) { _ in choice.pane.map(workspace.focusPane) }
            }, restoring: SavedLayout(windows: [window("a", "b", "c", "d", active: 1, type: "chooser")]))
        // Closing a background tab while the plugin focuses the active one: nothing shifts.
        choice.pane = "b"
        engine.close("a")
        #expect(activeLeaf(engine) == "b")
        // Closing the active tab while the plugin chooses another: its choice stands.
        choice.pane = "d"
        engine.close("b")
        #expect(activeLeaf(engine) == "d")
        #expect(renderer.rendered.window("w")?.activeLeafID == "d", "what's drawn is what's active")
    }

    @Test func aNewPaneLikeALiveOneIsAnotherOfItsTypeMadeFromIt() throws {
        let engine = engine(
            TestSupport.candidate(TestSupport.manifest("child", contentTypes: ["child"])) { context in
                context.register(
                    ContentTypeContribution(
                        id: "child", displayName: "Child", icon: .symbol("circle"),
                        initialConfig: { creation in ["from": creation.origin.map { .string($0.rawValue) } ?? nil] }
                    ) { StubPane(config: $0.initialConfig) })
            }, restoring: SavedLayout(windows: [window("a", type: "child")]))
        let tab = try #require(engine.newPane(like: "a", in: "w", placement: .tab))
        #expect(tabs(engine) == ["a", tab])
        #expect(engine.live(tab)?.context.initialConfig == ["from": "a"])
        #expect(engine.activePaneID == tab)

        let split = try #require(engine.newPane(like: tab, in: "w", placement: .split(.vertical)))
        #expect(engine.model.window("w")?.root.tabs.last?.content.splitNode?.children.map(\.id) == [tab, split])
        #expect(engine.activePaneID == split)

        let floating = try #require(
            engine.newPane(like: split, in: "w", placement: .floating(FloatRect(x: 0, y: 0, width: 400, height: 300))))
        #expect(engine.model.window("w")?.floating.map(\.content.id) == [floating])
        #expect(engine.live(floating)?.isAttached == true)
        #expect(engine.newPane(like: "missing", in: "w", placement: .tab) == nil)
        #expect(runtime.panes.panes(ofType: "child").count == 4, "nothing made and left unplaced")
    }

    /// The palette's creation (`createContentFor` + `placeNewPane`): the type is the user's choice, the
    /// origin only what the new pane inherits from.
    @Test func aNewPaneOfAChosenTypeIsMadeFromItsOriginAndPlacedBesideIt() throws {
        let child = TestSupport.candidate(TestSupport.manifest("child", contentTypes: ["child"])) { context in
            context.register(
                ContentTypeContribution(
                    id: "child", displayName: "Child", icon: .symbol("circle"),
                    initialConfig: { creation in ["from": creation.origin.map { .string($0.rawValue) } ?? nil] }
                ) { StubPane(config: $0.initialConfig) })
        }
        let broken = TestSupport.candidate(TestSupport.manifest("broken", contentTypes: ["broken"])) { context in
            context.register(
                ContentTypeContribution(id: "broken", displayName: "Broken", icon: .symbol("circle")) { _ in
                    throw NSError(domain: "test", code: 1)
                })
        }
        let engine = engine(child, broken, restoring: SavedLayout(windows: [window("a")]))
        // "a" is a stub; the new pane is a child, and is made from "a".
        let tab = try #require(engine.newPane(ofType: "child", from: "a", in: "w", placement: .tab))
        #expect(tabs(engine) == ["a", tab])
        #expect(engine.model.leaf(tab)?.type == "child", "the chosen type, not the origin's")
        #expect(engine.live(tab)?.context.initialConfig == ["from": "a"])
        #expect(engine.activePaneID == tab)

        let split = try #require(engine.newPane(ofType: "child", from: tab, in: "w", placement: .split(.horizontal)))
        #expect(engine.model.window("w")?.root.tabs.last?.content.splitNode?.children.map(\.id) == [tab, split])

        let floating = try #require(
            engine.newPane(ofType: "child", from: split, in: "w", placement: .floating(FloatRect(x: 0, y: 0, width: 400, height: 300))))
        #expect(engine.model.window("w")?.floating.map(\.content.id) == [floating])

        // A type nobody can make, a pane its plugin refuses to build (E-1), or an origin that's gone (C-7):
        // nothing is made or placed.
        let before = engine.model
        #expect(engine.newPane(ofType: "vanished", from: "a", in: "w", placement: .tab) == nil)
        #expect(runtime.panes.canCreate("broken"), "creatable: it's the pane its plugin won't build")
        for placement: NewPanePlacement in [.tab, .split(.horizontal), .floating(FloatRect(x: 0, y: 0, width: 400, height: 300))] {
            #expect(engine.newPane(ofType: "broken", from: "a", in: "w", placement: placement) == nil)
        }
        #expect(engine.newPane(ofType: "child", from: "missing", in: "w", placement: .tab) == nil)
        #expect(engine.model == before)
        #expect(runtime.panes.panes(ofType: "child").count == 3, "nothing made and left unplaced")
        #expect(runtime.panes.panes(ofType: "broken").isEmpty)
    }

    @Test func aNewPaneOfAChosenTypeOnAnEmptyOriginFillsItAndInheritsNothing() throws {
        let child = TestSupport.candidate(TestSupport.manifest("child", contentTypes: ["child"])) { context in
            context.register(
                ContentTypeContribution(
                    id: "child", displayName: "Child", icon: .symbol("circle"),
                    initialConfig: { creation in ["from": creation.origin.map { .string($0.rawValue) } ?? nil] }
                ) { StubPane(config: $0.initialConfig) })
        }
        let empty = WindowLayout(id: "w", root: .tabs(TabGroup(tabs: [Tab(title: "Tab", content: .leaf(.empty()))])), active: nil)
        let engine = engine(child, restoring: SavedLayout(windows: [empty]))
        let origin = try #require(engine.model.window("w")?.leaves.first?.id)
        let made = try #require(engine.newPane(ofType: "child", from: origin, in: "w", placement: .tab))
        #expect(tabs(engine) == [made], "the empty pane is replaced, not tabbed beside")
        #expect(engine.live(made)?.context.initialConfig == ["from": nil], "a blank pane offers nothing to inherit")
    }

    @Test func aNewPaneLikeOneThatCantBeMadeIsEmptyAndFillsInPlaceFromIt() throws {
        let engine = engine(
            TestSupport.candidate(TestSupport.manifest("child", contentTypes: ["child"])) { context in
                context.register(
                    ContentTypeContribution(
                        id: "child", displayName: "Child", icon: .symbol("circle"),
                        initialConfig: { creation in ["from": creation.origin.map { .string($0.rawValue) } ?? nil] }
                    ) { StubPane(config: $0.initialConfig) })
            }, restoring: SavedLayout(windows: [window("a")]))
        // Its plugin turned off: open panes keep running, but no more are made.
        runtime.host.setUserEnabled(false, for: "stub")
        let empty = try #require(engine.newPane(like: "a", in: "w", placement: .tab))
        #expect(engine.model.leaf(empty)?.type == nil)
        #expect(tabs(engine) == ["a", empty])
        #expect(engine.activePaneID == empty)
        #expect(engine.fill(empty, with: "child"))
        #expect(engine.live(empty)?.context.initialConfig == ["from": "a"], "created from the pane it was made like")
        #expect(tabs(engine) == ["a", empty], "same place, same id")
        #expect(log.lines.suffix(3) == ["active \(empty)", "open \(empty)", "active \(empty)"])
    }

    // MARK: Windows

    @Test func theLastWindowClosedIsKeptAndReopened() throws {
        let engine = engine(restoring: SavedLayout(windows: [window("keep")]))
        (engine.live("keep")?.controller as? WarningPane)?.config = ["kept": true]
        engine.windowDidClose("w")
        #expect(engine.model.windows.isEmpty)
        #expect(engine.snapshot().windows.map { $0.leaves.map(\.id) } == [["keep"]], "saved, to reopen next launch")
        #expect(log.lines.last == "close keep")
        engine.openWindow()
        #expect(engine.model.leaves.map(\.id) == ["keep"])
        #expect(engine.live("keep")?.context.initialConfig == ["kept": true], "with the state it had when it closed")
    }

    @Test func aPaneOpenedWithNoWindowsBringsBackTheLastClosedOne() throws {
        let engine = engine(restoring: SavedLayout(windows: [window("keep")]))
        engine.windowDidClose("w")
        let id = try #require(runtime.panes.openPane(PaneRequest(type: "stub")))
        #expect(engine.model.windows.count == 1)
        #expect(engine.model.leaves.map(\.id) == ["keep", id])
    }

    @Test func closingAPluginsOwnWindowDoesNotLoseTheLastClosedOne() throws {
        let engine = engine(restoring: SavedLayout(windows: [window("keep")]))
        engine.windowDidClose("w")
        let id = try #require(runtime.panes.openPane(PaneRequest(type: "stub", placement: .window)))
        let own = try #require(engine.model.window(holding: id)?.id)
        engine.windowDidClose(own)
        #expect(engine.snapshot().windows.flatMap(\.leaves).contains { $0.id == "keep" })
    }

    @Test func aPaneOpenedWhileTheLastWindowClosesLeavesNoOrphans() throws {
        final class Once { var armed = false }
        let once = Once()
        let engine = engine(
            TestSupport.candidate(TestSupport.manifest("opener", contentTypes: ["opener"])) { context in
                context.register(TestSupport.contentType("opener"))
                let workspace = context.workspace
                context.events.subscribe(.paneClosed) { _ in
                    guard once.armed else { return }
                    once.armed = false
                    workspace.openPane(ofType: "opener")
                }
            }, restoring: SavedLayout(windows: [window("a", "b")]))
        once.armed = true
        engine.windowDidClose("w")
        // Every live pane is in the layout under the id core knows it by, and vice versa.
        let inLayout = engine.model.leaves.compactMap { engine.live($0.id) }
        for live in inLayout { #expect(runtime.panes.pane(live.id) === live) }
        #expect(Set(runtime.panes.panes(ofType: "stub") + runtime.panes.panes(ofType: "opener")) == Set(inLayout.map(\.id)))
    }

    @Test func backgroundWindowsDoNotReportActivePanes() throws {
        let engine = engine(restoring: SavedLayout(windows: [window("b1", id: "back"), window("f1", id: "front")]))
        #expect(log.lines.filter { $0.hasPrefix("active") } == ["active f1"], "only the frontmost window's active pane")
        _ = runtime.panes.openPane(PaneRequest(type: "stub", placement: .tab(near: "b1")))
        #expect(log.lines.filter { $0.hasPrefix("active") } == ["active f1"], "a pane placed in a background window isn't the active pane")
        renderer.front = "back"
        engine.frontmostWindowDidChange()
        #expect(log.lines.last?.hasPrefix("active ") == true && log.lines.last != "active f1")
        #expect(engine.frontmostWindowID == "back")
    }

    @Test func placementsLandWhereAPluginAsks() throws {
        let engine = engine(restoring: SavedLayout(windows: [window("first")]))
        let split = try #require(runtime.panes.openPane(PaneRequest(type: "stub", placement: .split("first", edge: .trailing))))
        #expect(engine.model.window("w")?.root.tabs.first?.content.splitNode?.children.map(\.id) == ["first", split])
        #expect(engine.model.window("w")?.root.tabs.first?.content.splitNode?.direction == .horizontal)
        let above = try #require(runtime.panes.openPane(PaneRequest(type: "stub", placement: .split("first", edge: .top))))
        guard case .split(let column, let index)? = Tree.findParent(try #require(engine.model.window("w")?.rootNode), "first") else {
            Issue.record("expected the pane to be split")
            return
        }
        #expect(column.direction == .vertical)
        #expect(column.children.map(\.id) == [above, "first"])
        #expect(index == 1)
        let tab = try #require(runtime.panes.openPane(PaneRequest(type: "stub", placement: .tab(near: split))))
        guard case .tab(let group, _)? = Tree.findParent(try #require(engine.model.window("w")?.rootNode), tab) else {
            Issue.record("expected a tab beside the pane")
            return
        }
        #expect(group.tabs.map(\.content.id) == [split, tab])
        let alone = try #require(runtime.panes.openPane(PaneRequest(type: "stub", placement: .window)))
        #expect(engine.model.windows.count == 2)
        #expect(runtime.panes.pane(alone)?.windowID == engine.model.windows.last?.id)
    }

    @Test func pluginsReachTheWorkspaceOnlyOnceAnEngineExists() {
        runtime.startPlugins(
            from: nil,
            inProcess: [
                TestSupport.candidate(TestSupport.manifest("stub", contentTypes: ["stub"])) { $0.register(TestSupport.contentType("stub")) }
            ])
        #expect(runtime.workspace.openPane(ofType: "stub") == nil, "headless: no windows")
        let engine = LayoutEngine(runtime: runtime)
        engine.restore(nil)
        #expect(runtime.workspace.openPane(ofType: "stub") != nil)
    }

    // MARK: Moving, visibility, focus

    @Test func aPaneMovesToAnotherWindowWithItsState() throws {
        let engine = engine(restoring: SavedLayout(windows: [window("a", "b", active: 1, id: "one"), window("c", id: "two")]))
        let live = try #require(engine.live("b"))
        let source = try #require(engine.model.window("one")?.root)
        let destination = try #require(engine.model.window("two")?.root.id)
        let tab = try #require(source.tabs.last?.id)

        #expect(
            engine.move(.tab(tabID: tab, sourceGroupID: source.id), from: "one", to: "two", at: .tabBar(groupID: destination, index: 1)))

        #expect(tabs(engine, "one") == ["a"])
        #expect(tabs(engine, "two") == ["c", "b"])
        #expect(engine.live("b") === live, "the same pane, not a copy")
        #expect(live.context.windowID == "two")
        #expect(log.lines.contains("moved b"))
        #expect(!log.lines.contains("close b"))
    }

    @Test func aMoveTheDestinationCannotTakeChangesNeitherWindow() throws {
        let engine = engine(restoring: SavedLayout(windows: [window("a", "b", id: "one"), window("c", id: "two")]))
        let before = engine.model
        let destination = try #require(engine.model.window("two")?.root.id)

        #expect(
            !engine.move(.pane("a"), from: "one", to: "two", at: .dock(targetID: destination, zone: .left)), "the docked root's own edge")
        #expect(!engine.move(.pane("a"), from: "one", to: "two", at: .dock(targetID: "nowhere", zone: .center)))
        #expect(!engine.move(.pane("a"), from: "one", to: "one", at: .dock(targetID: "b", zone: .left)), "not another window")
        #expect(!engine.move(.pane(try #require(engine.model.window("one")?.root.id)), from: "one", to: "two", at: .emptyPane("c")))
        #expect(engine.model == before)
    }

    @Test func aWindowsOnlyPaneMayLeaveAPlaceholderBehind() throws {
        let engine = engine(restoring: SavedLayout(windows: [window("a", id: "one"), window("c", id: "two")]))
        #expect(engine.move(.pane("a"), from: "one", to: "two", at: .dock(targetID: "c", zone: .right)))
        #expect(engine.model.window("one")?.leaves.map(\.type) == [nil])
        #expect(engine.model.window("two")?.root.tabs.first?.content.splitNode?.children.map(\.id) == ["c", "a"])
        #expect(engine.live("a")?.windowID == "two")
    }

    @Test func panesHearWhenTheyAreTheVisibleTab() throws {
        let engine = engine(restoring: SavedLayout(windows: [window("a", "b", active: 0)]))
        #expect(engine.live("a")?.isVisible == true)
        #expect(engine.live("b")?.isVisible == false)
        select(engine, "b")
        #expect(engine.live("a")?.isVisible == false)
        #expect(engine.live("b")?.isVisible == true)
    }

    @Test func unpinningAPaneKeepsItAliveAndOnScreen() throws {
        let engine = engine(restoring: SavedLayout(windows: [window("a", "b")]))
        renderer.viewports["w"] = Viewport(width: 800, height: 600)
        let lines = log.lines.count
        #expect(
            engine.perform(in: "w") { layout, titles in
                layout.unpinPane(
                    "a", rect: FloatRect(x: 0, y: 0, width: 5000, height: 300), viewport: Viewport(width: 800, height: 600), titles: titles)
            })
        #expect(engine.model.window("w")?.floating.map(\.content.id) == ["a"])
        #expect(engine.live("a")?.isVisible == true, "a floating pane is on screen")
        #expect(!log.lines.dropFirst(lines).contains { $0.hasPrefix("close") })
        #expect(!engine.perform(in: "w") { layout, _ in layout.raiseFloating("missing") }, "an operation that changes nothing reports so")
    }

    @Test func aNewFloatingPaneIsKeptInsideItsWindowsViewport() throws {
        let engine = engine(restoring: SavedLayout(windows: [window("a")]))
        renderer.viewports["w"] = Viewport(width: 500, height: 400)
        let id = try #require(engine.newPane(like: "a", in: "w", placement: .floating(FloatRect(x: 0, y: 0, width: 5000, height: 5000))))
        #expect(engine.model.window("w")?.floatingPane(holding: id)?.rect == FloatRect(x: 0, y: 0, width: 500, height: 400))
    }

    @Test func focusingAPaneRevealsItBringsItsWindowForwardAndGivesItFocus() {
        let engine = engine(restoring: SavedLayout(windows: [window("a", "b", id: "one"), window("c", id: "two")]))
        engine.focus("b")
        #expect(activeLeaf(engine, "one") == "b")
        #expect(engine.model.window("one")?.isShowing("b") == true)
        #expect(renderer.broughtToFront == ["one"])
        engine.focus("b")
        #expect(renderer.focused == ["b", "b"], "even when it's already the shown tab")
    }

    @Test func aPaneOpenedFromAnotherPanesMakePaneWaitsForTheWindowToBeWhole() throws {
        final class Once { var done = false }
        let once = Once()
        let engine = engine(
            TestSupport.candidate(TestSupport.manifest("eager", contentTypes: ["eager"])) { context in
                let workspace = context.workspace
                context.register(
                    ContentTypeContribution(id: "eager", displayName: "Eager", icon: .symbol("circle")) { pane in
                        if pane.paneID == "b", !once.done {
                            once.done = true
                            workspace.openPane(PaneRequest(type: "eager", placement: .tab(near: "a")))
                        }
                        return StubPane(config: pane.initialConfig)
                    })
            }, restoring: SavedLayout(windows: [window("a", "b", type: "eager")]))
        #expect(!log.lines.contains { $0.hasPrefix("close") }, "no pane of the window being built was taken for closed")
        for leaf in engine.model.leaves { #expect(engine.live(leaf.id)?.isAttached == true, "\(leaf.id) is live") }
        #expect(engine.model.leaves.count == 3)
    }

    @Test func aPaneOpenedDuringPaneOpenedNeverSeesAStaleLayout() throws {
        final class Seen { var lines: [String] = [] }
        let seen = Seen()
        let engine = engine(
            TestSupport.candidate(TestSupport.manifest("chain", contentTypes: ["chain"])) { context in
                let workspace = context.workspace
                context.register(
                    ContentTypeContribution(id: "chain", displayName: "Chain", icon: .symbol("circle")) { pane in
                        final class Probe: PaneController {
                            let view = NSView()
                            let id: PaneID
                            let seen: Seen
                            init(id: PaneID, seen: Seen) {
                                self.id = id
                                self.seen = seen
                            }
                            func currentConfig() -> JSONValue { [:] }
                            func paneDidShow() { seen.lines.append("show \(id)") }
                            func paneDidHide() { seen.lines.append("hide \(id)") }
                        }
                        return Probe(id: pane.paneID, seen: seen)
                    })
                context.events.subscribe(.paneOpened) { event in
                    if event.contentType == "chain", event.paneID == "a" {
                        workspace.openPane(PaneRequest(type: "chain", placement: .tab(near: "a")))
                    }
                }
            }, restoring: SavedLayout(windows: [window("a", type: "chain")]))
        let opened = try #require(engine.model.leaves.last?.id)
        #expect(engine.activePaneID == opened)
        #expect(seen.lines == ["show \(opened)"], "a was never told it's showing while hidden")
    }

    @Test func titlesReachTheRenderer() throws {
        let engine = engine(restoring: SavedLayout(windows: [window("a")]))
        #expect(renderer.titles == ["a"], "asked once the pane opened (building its view may have set one)")
        engine.live("a")?.context.setTitle("Renamed")
        #expect(renderer.titles == ["a", "a"])
        #expect(engine.paneTitle(of: PaneID("a")) == "Renamed")
        engine.perform(in: "w") { layout, titles in layout.renamePane("a", "Mine", titles: titles) }
        #expect(engine.paneTitle(of: PaneID("a")) == "Mine", "a title the user set wins over the plugin's")
    }

    // MARK: Robustness

    @Test func pluginsFocusingBackAndForthCantSpinTheLayoutForever() throws {
        func chaser(_ id: String, chasing other: String) -> PluginCandidate {
            TestSupport.candidate(TestSupport.manifest(id, contentTypes: [ContentTypeID(id).rawValue])) { context in
                context.register(TestSupport.contentType(id))
                let workspace = context.workspace
                context.events.subscribe(.activePaneChanged) { event in
                    // Whenever the other's pane is active, focus my own.
                    if event.contentType == ContentTypeID(other) {
                        workspace.panes(ofType: ContentTypeID(id)).first.map(workspace.focusPane)
                    }
                }
            }
        }
        let saved = WindowLayout(
            id: "w",
            root: .tabs(
                TabGroup(tabs: [
                    Tab(title: "Ping", content: .leaf(LayoutLeaf(id: "a", type: "ping"))),
                    Tab(title: "Pong", content: .leaf(LayoutLeaf(id: "b", type: "pong"))),
                ])), active: "a")
        let engine = engine(chaser("ping", chasing: "pong"), chaser("pong", chasing: "ping"), restoring: SavedLayout(windows: [saved]))
        engine.focus("b")  // returns: the passes stop at their cap
        #expect(engine.model.windows.count == 1)
    }

    @Test func aPaneMayAskToCloseWhileItIsBeingMade() async throws {
        let engine = engine(
            TestSupport.candidate(TestSupport.manifest("brief", contentTypes: ["brief"])) { context in
                context.register(
                    ContentTypeContribution(id: "brief", displayName: "Brief", icon: .symbol("circle")) { pane in
                        pane.requestClose()  // e.g. its process had already exited
                        return StubPane(config: pane.initialConfig)
                    })
            }, restoring: SavedLayout(windows: [window("a")]))
        let id = try #require(runtime.panes.openPane(PaneRequest(type: "brief")))
        #expect(engine.model.leaf(id) != nil)
        await Task.yield()
        #expect(engine.model.leaf(id) == nil, "closed once it was made")
    }

    @Test func windowFramesAreKeptWithTheLayout() throws {
        let frame = WindowFrame(x: 100, y: 120, width: 700, height: 500)
        let engine = engine(
            restoring: SavedLayout(windows: [WindowLayout(id: "w", root: .leaf(LayoutLeaf(id: "a", type: "stub")), frame: frame)]))
        #expect(engine.model.window("w")?.frame == frame)
        let moved = WindowFrame(x: 10, y: 20, width: 800, height: 600)
        engine.windowFrameDidChange("w", to: moved)
        #expect(engine.snapshot().windows.first?.frame == moved)
        engine.windowDidClose("w")
        #expect(engine.snapshot().windows.first?.frame == moved, "the last closed window keeps its place too")
    }

    @Test func panesRestoredAtLaunchHandTheSocketToWhatTheySpawn() throws {
        let runtime = CoreRuntime(paths: AppPaths(dataDirectory: TestSupport.temporaryDirectory()), controlSocketPath: "/tmp/tabs.sock")
        final class Seen { var environment: [String: String]? }
        let seen = Seen()
        runtime.startPlugins(
            from: nil,
            inProcess: [
                TestSupport.candidate(TestSupport.manifest("shell", contentTypes: ["shell"])) { context in
                    context.register(
                        ContentTypeContribution(id: "shell", displayName: "Shell", icon: .symbol("circle")) { pane in
                            seen.environment = pane.childEnvironment  // spawning its process right away
                            return StubPane(config: pane.initialConfig)
                        })
                }
            ], requiredContentTypes: ["shell"])
        let engine = LayoutEngine(runtime: runtime)
        engine.restore(SavedLayout(windows: [WindowLayout(id: "w", root: .leaf(LayoutLeaf(id: "s", type: "shell")))]))
        #expect(seen.environment?["TABS_CONTROL_SOCKET"] == "/tmp/tabs.sock")
    }

    // MARK: Asking before losing work

    @Test func closingAPaneThatWouldLoseWorkAsksFirst() throws {
        let engine = engine(restoring: SavedLayout(windows: [window("a", "b")]))
        (engine.live("a")?.controller as? WarningPane)?.warning = "Unsaved"
        renderer.answers = [false]
        engine.close("a")
        #expect(tabs(engine) == ["a", "b"], "declined")
        #expect(renderer.asked == [["Unsaved"]])
        engine.close("a")
        #expect(tabs(engine) == ["b"])
    }

    @Test func closingAWindowAsksAboutEveryPaneThatWouldLoseWork() throws {
        let engine = engine(restoring: SavedLayout(windows: [window("a", "b", "c")]))
        (engine.live("a")?.controller as? WarningPane)?.warning = "A"
        (engine.live("c")?.controller as? WarningPane)?.warning = "C"
        renderer.answers = [false]
        #expect(!engine.shouldClose("w"))
        #expect(engine.shouldClose("w"))
        #expect(renderer.asked == [["A", "C"], ["A", "C"]])
        #expect(engine.shouldQuit())
    }
}
