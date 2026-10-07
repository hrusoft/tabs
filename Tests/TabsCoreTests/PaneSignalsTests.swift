import AppKit
import Foundation
import TabsPluginSDK
import Testing

@testable import TabsCore

/// Pane signals, core's half (`PaneSignals` with the layout engine as its
/// host), unhosted against a fake renderer — the rules of
/// `docs/PANE-SIGNALS.md`, for any kind. The bell is a stand-in declared as a
/// core kind, as the app's `SignalFixtures` declares it (minus the glyph); the
/// controlled cue is core's own.
@MainActor
@Suite struct PaneSignalsTests {
    let runtime = TestSupport.runtime()
    let renderer = FakeRenderer()
    var signals: PaneSignals { runtime.signals }
    /// The engine lives as long as the test: core holds it (the signals' host) weakly.
    private final class Held { var engine: LayoutEngine? }
    private let held = Held()

    /// The terminal's bell: until seen, marks tabs, bounces the Dock.
    static var bell: PaneSignalContribution {
        PaneSignalContribution(
            id: "bell", label: "Bell", icon: .symbol("bell"), color: .alert, pulse: 3, marksTabs: true, lifetime: .untilSeen,
            requestsAttention: true, setting: .init(title: "Bell indicator", detail: ""))
    }

    /// Starts `plugins`, declares the bell's stand-in (core's own `controlled` is
    /// always there, last), and shows `windows`.
    private func engine(_ plugins: PluginCandidate..., windows: [WindowLayout]) -> LayoutEngine {
        runtime.startPlugins(from: nil, inProcess: plugins)
        signals.declare(Self.bell)
        let engine = LayoutEngine(runtime: runtime)
        engine.renderer = renderer
        engine.restore(SavedLayout(windows: windows))
        held.engine = engine
        return engine
    }

    private func leaf(_ id: PaneID) -> LayoutNode { .leaf(.empty(id)) }

    private func split(_ id: NodeID = .make(), _ children: LayoutNode...) -> LayoutNode {
        .split(Split(id: id, direction: .horizontal, children: children))
    }

    private func group(_ id: NodeID, _ tabs: [(NodeID, LayoutNode)], active: NodeID) -> LayoutNode {
        .tabs(TabGroup(id: id, tabs: tabs.map { Tab(id: $0.0, title: "Tab", content: $0.1) }, activeTabID: .some(active)))
    }

    /// Window "w": a side-by-side split of empty panes a | b | c, `active` active.
    private func threePanes(active: NodeID = "a") -> WindowLayout {
        WindowLayout(id: "w", root: split("s", leaf("a"), leaf("b"), leaf("c")), active: active)
    }

    @discardableResult
    private func raise(_ kind: String, on pane: PaneID) -> Bool { signals.raise(PaneSignal(kind), on: pane, by: nil) }

    private func shown(_ pane: PaneID) -> [String] { signals.shown(on: pane).map(\.kind.id) }
    private func raised(_ pane: PaneID) -> [String] { signals.raised(on: pane).map(\.id) }

    private func activate(_ pane: NodeID, in engine: LayoutEngine, window: WindowID = "w") {
        engine.perform(in: window) { layout, _ in layout.setActivePane(pane) }
    }

    private func switchOff(_ kinds: String...) {
        var panes = runtime.settings.panes
        panes.disabledSignals = kinds.sorted()
        runtime.settings.setPanes(panes)
    }

    // MARK: Raising (S-1 … S-8)

    @Test func aBellOnAPaneThatIsntActiveFlagsIt() {
        _ = engine(windows: [threePanes()])
        #expect(raise("bell", on: "b"))
        #expect(shown("b") == ["bell"])
        #expect(renderer.signalChanges.last == ["b"], "the renderer redraws that pane")
    }

    @Test func aBellInTheActivePaneOfAFocusedWindowIsDropped() {
        _ = engine(windows: [threePanes()])
        renderer.focusedWindows = ["w"]
        #expect(!raise("bell", on: "a"))
        #expect(raised("a").isEmpty, "nothing kept for later")
        #expect(renderer.signalChanges.isEmpty)
        // A status isn't attention: the pane being looked at still carries it.
        #expect(raise("controlled", on: "a"))
        #expect(shown("a") == ["controlled"])
    }

    @Test func aBellInTheActivePaneOfAnUnfocusedWindowFlagsIt() {
        _ = engine(windows: [threePanes()])
        #expect(raise("bell", on: "a"))
        #expect(shown("a") == ["bell"])
    }

    @Test func aTabGroupBeingActiveIsntLookingAtItsPanes() {
        let root = split("s", leaf("a"), group("g", [("t-x", leaf("x"))], active: "t-x"))
        _ = engine(windows: [WindowLayout(id: "w", root: root, active: "g")])
        renderer.focusedWindows = ["w"]
        #expect(raise("bell", on: "x"), "the group is active, not the pane in it")
        #expect(shown("x") == ["bell"])
    }

    @Test func raisingAgainChangesNothing() {
        _ = engine(windows: [threePanes()])
        var now = 10.0
        signals.clock = { now }
        raise("bell", on: "b")
        now = 20
        #expect(raise("bell", on: "b"), "it still carries it")
        #expect(signals.raised(on: "b") == [RaisedSignal(id: "bell", since: 10)], "one signal, its pulse not restarted")
        #expect(renderer.signalChanges.count == 1)
    }

    @Test func aSwitchedOffBellIsDroppedWithoutBouncing() {
        _ = engine(windows: [threePanes()])
        switchOff("bell")
        #expect(!raise("bell", on: "b"))
        #expect(renderer.attentionRequests == 0)
        switchOff()
        #expect(raised("b").isEmpty, "not kept for when it's switched back on")
    }

    @Test func switchingOffHidesWhatsUpAndSwitchingOnShowsItAgain() {
        _ = engine(windows: [threePanes()])
        raise("bell", on: "b")
        raise("controlled", on: "c")
        switchOff("bell", "controlled")
        #expect(shown("b").isEmpty && shown("c").isEmpty)
        #expect(raised("b") == ["bell"] && raised("c") == ["controlled"], "hidden, not cleared")
        #expect(signals.outline(of: "b") == nil && signals.tabMarks(for: ["b"]).isEmpty)
        switchOff()
        #expect(shown("b") == ["bell"] && shown("c") == ["controlled"])
    }

    @Test func flippingASwitchRedrawsThePanesCarryingThatKind() {
        _ = engine(windows: [threePanes()])
        raise("bell", on: "b")
        raise("controlled", on: "c")
        let told = renderer.signalChanges.count
        switchOff("bell")
        #expect(renderer.signalChanges.dropFirst(told) == [["b"]])
        switchOff("bell", "controlled")
        #expect(renderer.signalChanges.last == ["c"])
        switchOff()
        #expect(renderer.signalChanges.last == ["b", "c"])
        var panes = runtime.settings.panes
        panes.dimInactivePanes.toggle()
        runtime.settings.setPanes(panes)
        #expect(renderer.signalChanges.count == told + 3, "another setting redraws no signals")
    }

    @Test func aStatusRaisedWhileSwitchedOffIsKeptHidden() {
        _ = engine(windows: [threePanes()])
        switchOff("controlled")
        #expect(raise("controlled", on: "b"))
        #expect(shown("b").isEmpty)
        switchOff()
        #expect(shown("b") == ["controlled"], "the state shows once switched on")
    }

    @Test func aFlagLastsUntilSeen() {
        let engine = engine(windows: [threePanes()])
        raise("bell", on: "b")
        engine.reconcile()
        engine.windowFrameDidChange("w", to: WindowFrame(x: 0, y: 0, width: 800, height: 600))
        activate("c", in: engine)
        #expect(shown("b") == ["bell"], "nothing but seeing it clears it")
    }

    // MARK: Seeing (S-9 … S-16)

    @Test func becomingTheActivePaneClearsItEvenInAnUnfocusedWindow() {
        let engine = engine(windows: [threePanes()])
        raise("bell", on: "b")
        raise("controlled", on: "b")
        activate("b", in: engine)
        #expect(shown("b") == ["controlled"], "the bell is seen; the status stays")
    }

    @Test func aPassDrawsTheSignalsItClearsWithTheViewsItBuilds() {
        let engine = engine(windows: [threePanes()])
        raise("bell", on: "b")
        let told = renderer.signalChanges.count
        activate("b", in: engine)
        #expect(shown("b").isEmpty)
        #expect(renderer.signalChanges.count == told, "seen mid-pass, while the views were the old layout's: its render draws it")
        #expect(renderer.rendered.window("w")?.activePaneID == "b")
    }

    @Test func aSignalRaisedAfterAPassRendersIsToldOnceThePassIsDone() throws {
        final class RaisesWhenShown: PaneController {
            let view = NSView()
            let pane: any PaneContext
            init(pane: any PaneContext) { self.pane = pane }
            func currentConfig() -> JSONValue { .emptyObject }
            func paneDidShow() { pane.raise(PaneSignal("showy.status")) }
        }
        let plugin = TestSupport.candidate(TestSupport.manifest("showy", contentTypes: ["showy"])) { context in
            context.register(ContentTypeContribution(id: "showy", displayName: "Showy", icon: .symbol("eye")) { RaisesWhenShown(pane: $0) })
            context.register(Self.kind("showy.status"))
        }
        _ = engine(plugin, windows: [threePanes()])
        let told = renderer.signalChanges.count
        let pane = try #require(runtime.panes.openPane(PaneRequest(type: "showy", placement: .split("c", edge: .trailing))))
        #expect(raised(pane) == ["showy.status"])
        #expect(renderer.signalChanges.dropFirst(told) == [[pane]], "once")
        #expect(renderer.signalChangesRendered.last == true, "after the render that drew its pane")
    }

    @Test func windowFocusClearsTheActivePanesBellOnly() {
        let engine = engine(windows: [threePanes()])
        raise("bell", on: "a")
        raise("bell", on: "b")
        raise("controlled", on: "a")
        renderer.focusedWindows = ["w"]
        engine.windowDidGainFocus("w")
        #expect(shown("a") == ["controlled"], "the pane the user lands on is seen")
        #expect(shown("b") == ["bell"], "the others still want a look")
    }

    @Test func showingABackgroundTabWhoseEntryPaneRingsClearsIt() {
        let root = group("root", [("t1", leaf("x")), ("t2", leaf("y"))], active: "t2")
        let engine = engine(windows: [WindowLayout(id: "w", root: root, active: "y")])
        raise("bell", on: "x")
        #expect(signals.tabMarks(for: ["x"]).map(\.kind.id) == ["bell"], "its tab shows it while the pane is hidden")
        engine.perform(in: "w") { layout, titles in
            layout.activateTab("root", "t1", titles: titles)
            return layout.setActivePane("x")
        }
        #expect(shown("x").isEmpty)
        #expect(signals.tabMarks(for: ["x"]).isEmpty)
    }

    @Test func aTabSwitchLandingOnAnotherPaneKeepsTheFlag() {
        let root = group("root", [("t1", split("s", leaf("x"), leaf("z"))), ("t2", leaf("y"))], active: "t2")
        let engine = engine(windows: [WindowLayout(id: "w", root: root, active: "y")])
        raise("bell", on: "z")
        engine.perform(in: "w") { layout, titles in
            layout.activateTab("root", "t1", titles: titles)
            return layout.setActivePane(Navigation.entryPaneID(layout.findNode("s")!))
        }
        #expect(engine.model.window("w")?.activePaneID == "x")
        #expect(shown("z") == ["bell"])
        #expect(signals.tabMarks(for: ["x", "z"]).map(\.kind.id) == ["bell"], "and its tab keeps the icon")
    }

    @Test func closingAPaneEndsItsSignals() throws {
        let plugin = TestSupport.candidate(TestSupport.manifest("stub", contentTypes: ["stub"])) { context in
            context.register(TestSupport.contentType("stub"))
            context.register(
                PaneSignalContribution(
                    id: "stub.busy", label: "Busy", icon: .symbol("gear"), color: .accent, lifetime: .untilWithdrawn,
                    setting: .init(title: "Busy", detail: "")))
        }
        let engine = engine(plugin, windows: [threePanes()])
        let live = try #require(runtime.panes.openPane(PaneRequest(type: "stub", placement: .split("c", edge: .trailing))))
        runtime.panes.pane(live)?.context.raise(PaneSignal("stub.busy"))
        #expect(shown(live) == ["stub.busy"])
        engine.close(live)
        #expect(raised(live).isEmpty, "a live pane's signals end with it")

        raise("controlled", on: "b")
        engine.close("b")
        #expect(raised("b").isEmpty, "an empty pane's too, once it leaves the layout")
        #expect(!signals.panes.contains("b"))
    }

    @Test func movingInsideTheWindowKeepsItUnlessThePaneBecomesActive() {
        let engine = engine(windows: [threePanes()])
        raise("bell", on: "c")
        engine.perform(in: "w") { layout, titles in layout.dockPane("b", onto: "a", zone: .left, titles: titles) }
        #expect(engine.model.window("w")?.activePaneID == "b", "the moved pane took the focus")
        #expect(shown("c") == ["bell"], "another pane moving keeps it")
        engine.perform(in: "w") { layout, titles in layout.dockPane("c", onto: "a", zone: .right, titles: titles) }
        #expect(shown("c").isEmpty, "moving it made it active: seen")
    }

    @Test func aSignalFollowsItsPaneIntoAnotherWindow() {
        let first = WindowLayout(
            id: "w1", root: group("r1", [("tA", split("s", leaf("x"), leaf("y"))), ("tB", leaf("q"))], active: "tA"), active: "x")
        let second = WindowLayout(id: "w2", root: group("r2", [("tC", leaf("z"))], active: "tC"), active: "z")
        let engine = engine(windows: [first, second])
        raise("bell", on: "y")
        raise("controlled", on: "y")
        #expect(engine.move(.tab(tabID: "tA", sourceGroupID: "r1"), from: "w1", to: "w2", at: .tabBar(groupID: "r2", index: 1)))
        #expect(engine.model.window(holding: "y")?.id == "w2")
        #expect(engine.model.window("w2")?.activePaneID != "y")
        #expect(shown("y") == ["bell", "controlled"])
    }

    // MARK: Where it shows (S-18 … S-20)

    @Test func tabsMarkTheirPanesSignalsAtEveryDepthButNotStatuses() {
        let inner = group("g", [("tx", leaf("x")), ("ty", leaf("y"))], active: "ty")
        let root = group("root", [("t1", split("s", leaf("a"), inner)), ("t2", leaf("b"))], active: "t1")
        _ = engine(windows: [WindowLayout(id: "w", root: root, active: "a")])
        raise("bell", on: "x")
        raise("controlled", on: "y")
        #expect(signals.tabMarks(for: ["a", "x", "y"]).map(\.kind.id) == ["bell"], "the root tab holds x, in G's background tab")
        #expect(signals.tabMarks(for: ["x"]).map(\.kind.id) == ["bell"])
        #expect(signals.tabMarks(for: ["y"]).isEmpty, "controlled never marks a tab")
        #expect(shown("y") == ["controlled"], "though its pane shows it")
    }

    @Test func aTabsMarkRunsFromTheEarliestRaise() {
        _ = engine(windows: [threePanes()])
        var now = 10.0
        signals.clock = { now }
        raise("bell", on: "c")
        now = 20
        raise("bell", on: "b")
        let marks = signals.tabMarks(for: ["b", "c"])
        #expect(marks.count == 1)
        #expect(marks.first?.signal.since == 10, "the tab's icon appeared with the first bell")
    }

    @Test func aKindAskingForAttentionBouncesTheDockEveryTimeWhileUnfocused() {
        _ = engine(windows: [threePanes()])
        raise("bell", on: "b")
        raise("bell", on: "b")
        #expect(renderer.attentionRequests == 2, "a repeat bounces again")
        raise("controlled", on: "c")
        #expect(renderer.attentionRequests == 2, "a kind that doesn't ask never does")
        renderer.focusedWindows = ["w"]
        raise("bell", on: "c")
        #expect(shown("c").contains("bell") && renderer.attentionRequests == 2, "flagged, but no bounce in a focused window")
        renderer.focusedWindows = []
        switchOff("bell")
        raise("bell", on: "a")
        #expect(renderer.attentionRequests == 2, "nor while switched off")
    }

    // MARK: Statuses (S-21 … S-26)

    @Test func aStatusStaysUntilWithdrawn() {
        let engine = engine(windows: [threePanes()])
        raise("controlled", on: "b")
        activate("b", in: engine)
        renderer.focusedWindows = ["w"]
        engine.windowDidGainFocus("w")
        #expect(shown("b") == ["controlled"], "activation and focus never clear it")
        signals.withdraw(PaneSignal("controlled"), from: "b", by: nil)
        #expect(shown("b").isEmpty)
        #expect(renderer.signalChanges.last == ["b"])
    }

    // MARK: Several (S-29)

    @Test func severalSignalsShowInKindOrderAndTheLastOutlines() {
        _ = engine(windows: [threePanes()])
        raise("controlled", on: "b")
        raise("bell", on: "b")
        #expect(shown("b") == ["bell", "controlled"], "the bell's icon first, whatever came first")
        #expect(signals.outline(of: "b")?.kind.id == "controlled", "the later kind outlines the pane")
    }

    // MARK: Kinds

    private static func kind(_ id: String, lifetime: PaneSignalContribution.Lifetime = .untilWithdrawn) -> PaneSignalContribution {
        PaneSignalContribution(
            id: id, label: id, icon: .symbol("circle"), color: .accent, lifetime: lifetime, setting: .init(title: id, detail: ""))
    }

    @Test func kindsArePluginsInUIOrderEachInRegistrationOrderThenCores() {
        let later = TestSupport.candidate(TestSupport.manifest("later", sortOrder: 20)) { context in
            context.register(Self.kind("later.b"))
            context.register(Self.kind("later.a"))
        }
        let earlier = TestSupport.candidate(TestSupport.manifest("earlier", sortOrder: 10)) { context in
            context.register(Self.kind("earlier.z"))
        }
        _ = engine(later, earlier, windows: [threePanes()])
        #expect(signals.kinds.map(\.id) == ["earlier.z", "later.b", "later.a", "bell", "controlled"])
        #expect(signals.kind("later.a")?.owner == "later")
        #expect(signals.kind("bell")?.owner == nil)
    }

    @Test func aDisabledPluginsKindsHaveNoSwitch() {
        let plugin = TestSupport.candidate(TestSupport.manifest("quiet")) { context in context.register(Self.kind("quiet.ping")) }
        _ = engine(plugin, windows: [threePanes()])
        #expect(signals.settingKinds.map(\.id) == ["quiet.ping", "bell", "controlled"])
        runtime.host.setUserEnabled(false, for: "quiet")
        #expect(signals.settingKinds.map(\.id) == ["bell", "controlled"], "like its settings pages")
        #expect(signals.kind("quiet.ping") != nil, "it's still loaded, and its panes still signal")
    }

    @Test func aPluginRaisesAndWithdrawsOnlyItsOwnKinds() throws {
        let one = TestSupport.candidate(TestSupport.manifest("one", contentTypes: ["one"])) { context in
            context.register(TestSupport.contentType("one"))
            context.register(Self.kind("one.ping"))
        }
        let two = TestSupport.candidate(TestSupport.manifest("two")) { context in context.register(Self.kind("two.ping")) }
        _ = engine(one, two, windows: [threePanes()])
        let pane = try #require(runtime.panes.openPane(PaneRequest(type: "one", placement: .split("c", edge: .trailing))))
        let context = try #require(runtime.panes.pane(pane)?.context)
        context.raise(PaneSignal("two.ping"))
        context.raise(PaneSignal("controlled"))
        context.raise(PaneSignal("nobody.declared"))
        #expect(raised(pane).isEmpty, "another plugin's, core's and undeclared kinds are refused")
        context.raise(PaneSignal("one.ping"))
        #expect(raised(pane) == ["one.ping"])
        raise("two.ping", on: pane)
        context.withdraw(PaneSignal("two.ping"))
        #expect(raised(pane) == ["one.ping", "two.ping"], "it can't take another plugin's off either")
        context.withdraw(PaneSignal("one.ping"))
        #expect(raised(pane) == ["two.ping"])
    }

    @Test func aPaneMayRaiseFromInsideMakePane() throws {
        let plugin = TestSupport.candidate(TestSupport.manifest("eager", contentTypes: ["eager"])) { context in
            context.register(
                ContentTypeContribution(id: "eager", displayName: "Eager", icon: .symbol("bolt")) { pane in
                    pane.raise(PaneSignal("eager.status"))
                    pane.raise(PaneSignal("eager.ring"))
                    return StubPane(config: pane.initialConfig)
                })
            context.register(Self.kind("eager.status"))
            context.register(Self.kind("eager.ring", lifetime: .untilSeen))
        }
        _ = engine(plugin, windows: [threePanes()])
        let pane = try #require(runtime.panes.openPane(PaneRequest(type: "eager", placement: .split("c", edge: .trailing))))
        #expect(raised(pane) == ["eager.status"], "kept through its placement; the ring was seen as the new pane took the focus")
    }

    /// A declaration broken one way, and what the refusal says.
    private static func broken(_ name: String) -> (kind: PaneSignalContribution, problem: String) {
        let setting = PaneSignalContribution.Setting(title: "T", detail: "")
        func kind(
            id: String = "bad.x", label: String = "L", icon: PaneSignalContribution.Icon = .symbol("circle"), pulse: TimeInterval? = 3,
            tooltip: String? = nil, setting: PaneSignalContribution.Setting = setting
        ) -> PaneSignalContribution {
            PaneSignalContribution(
                id: id, label: label, icon: icon, color: .alert, pulse: pulse, lifetime: .untilSeen, tooltip: tooltip, setting: setting)
        }
        switch name {
        case "empty label": return (kind(label: " "), "label is empty")
        case "empty symbol": return (kind(icon: .symbol("")), "symbol name is empty")
        case "unknown symbol": return (kind(icon: .symbol("alrm")), "no SF Symbol named alrm")
        case "zero pulse": return (kind(pulse: 0), "pulse must be")
        case "infinite pulse": return (kind(pulse: .infinity), "pulse must be")
        case "empty setting": return (kind(setting: .init(title: "", detail: "")), "setting's title is empty")
        case "blank tooltip": return (kind(tooltip: " "), "tooltip is empty")
        default: return (kind(id: "other.x"), "must be \"bad\"")
        }
    }

    @Test(arguments: [
        "empty label", "empty symbol", "unknown symbol", "zero pulse", "infinite pulse", "empty setting", "blank tooltip",
        "foreign namespace",
    ])
    func aKindsDeclarationIsChecked(_ name: String) throws {
        let (kind, problem) = Self.broken(name)
        runtime.startPlugins(from: nil, inProcess: [TestSupport.candidate(TestSupport.manifest("bad")) { $0.register(kind) }])
        guard case .failed(let reason)? = TestSupport.state(runtime, "bad") else {
            Issue.record("\(name): the plugin should fail, is \(String(describing: TestSupport.state(runtime, "bad")))")
            return
        }
        #expect(reason.contains(problem), "\(name): \(reason)")
        #expect(signals.kinds.map(\.id) == ["controlled"], "nothing of it committed: only core's own kind is there")
    }

    // MARK: Settings

    @Test func theSwitchesPersistAndABadValueFallsBackAlone() throws {
        var panes = runtime.settings.panes
        panes.disabledSignals = ["terminal.bell"]
        runtime.settings.setPanes(panes)
        #expect(SettingsStore(file: runtime.paths.settingsFile).panes.disabledSignals == ["terminal.bell"])

        let decoded = try JSONDecoder().decode(
            SettingsStore.PaneSettings.self, from: Data(#"{"disabledSignals": 5, "dimInactivePanes": false}"#.utf8))
        #expect(decoded.disabledSignals.isEmpty, "every kind on")
        #expect(decoded.dimInactivePanes == false, "the other fields keep theirs")
        #expect(SettingsStore.PaneSettings().disabledSignals.isEmpty, "on by default")
    }
}
