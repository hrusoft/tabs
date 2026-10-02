import AppKit
import Foundation
import TabsPluginSDK
import Testing

@testable import TabsCore

/// `paneDidBecomeAttended` / `paneDidLoseAttention`: the active pane of a
/// focused window, told on transitions only (`LayoutEngine.isLookedAt`).
@MainActor
@Suite struct PaneAttentionTests {
    let runtime = TestSupport.runtime()
    let renderer = FakeRenderer()
    private final class Held { var engine: LayoutEngine? }
    private let held = Held()
    private final class Log { var events: [String] = [] }
    private let log = Log()

    private final class Watcher: PaneController {
        let view = NSView()
        let id: PaneID
        let log: Log
        init(id: PaneID, log: Log) {
            self.id = id
            self.log = log
        }
        func currentConfig() -> JSONValue { .emptyObject }
        func paneDidBecomeAttended() { log.events.append("+\(id.rawValue)") }
        func paneDidLoseAttention() { log.events.append("-\(id.rawValue)") }
        func paneWillClose() { log.events.append("x\(id.rawValue)") }
    }

    private func watched(_ id: PaneID) -> LayoutNode { .leaf(LayoutLeaf(id: id, type: "watch")) }

    private func window(_ id: WindowID, _ panes: [PaneID], active: NodeID) -> WindowLayout {
        WindowLayout(
            id: id, root: .split(Split(id: NodeID("s-\(id.rawValue)"), direction: .horizontal, children: panes.map(watched))),
            active: active)
    }

    private func start(_ windows: [WindowLayout]) -> LayoutEngine {
        let log = log
        let plugin = TestSupport.candidate(TestSupport.manifest("watch", contentTypes: ["watch"])) { context in
            context.register(
                ContentTypeContribution(id: "watch", displayName: "Watch", icon: .symbol("eye")) { Watcher(id: $0.paneID, log: log) })
        }
        runtime.startPlugins(from: nil, inProcess: [plugin])
        let engine = LayoutEngine(runtime: runtime)
        engine.renderer = renderer
        engine.restore(SavedLayout(windows: windows))
        held.engine = engine
        return engine
    }

    private func take() -> [String] {
        defer { log.events = [] }
        return log.events
    }

    @Test func nobodyIsAttendedInAnUnfocusedWindow() {
        _ = start([window("w", ["a", "b"], active: "a")])
        #expect(take().isEmpty)
    }

    @Test func aWindowGainingAndLosingFocusToldItsActivePaneOnce() {
        let engine = start([window("w", ["a", "b"], active: "a")])
        renderer.focusedWindows = ["w"]
        engine.windowDidGainFocus("w")
        #expect(take() == ["+a"])
        engine.windowDidGainFocus("w")
        #expect(take().isEmpty, "not told twice")
        renderer.focusedWindows = []
        engine.windowDidLoseFocus("w")
        #expect(take() == ["-a"])
        engine.windowDidLoseFocus("w")
        #expect(take().isEmpty)
    }

    @Test func switchingTheActivePaneHandsAttentionOver() {
        let engine = start([window("w", ["a", "b"], active: "a")])
        renderer.focusedWindows = ["w"]
        engine.windowDidGainFocus("w")
        _ = take()
        engine.perform(in: "w") { layout, _ in layout.setActivePane("b") }
        #expect(Set(take()) == ["-a", "+b"])
        engine.perform(in: "w") { layout, _ in layout.setActivePane("b") }
        #expect(take().isEmpty)
    }

    @Test func aSwitchInAnUnfocusedWindowTellsNobody() {
        let engine = start([window("w", ["a", "b"], active: "a")])
        engine.perform(in: "w") { layout, _ in layout.setActivePane("b") }
        #expect(take().isEmpty)
    }

    @Test func closingTheAttendedPaneLosesAttentionBeforeItCloses() throws {
        let engine = start([window("w", ["a", "b"], active: "a")])
        renderer.focusedWindows = ["w"]
        engine.windowDidGainFocus("w")
        _ = take()
        engine.perform(in: "w") { layout, titles in layout.closePane("a", titles: titles) }
        let events = take()
        #expect(events.prefix(2) == ["-a", "xa"], "\(events)")
    }

    @Test func aPaneCreatedActiveInAFocusedWindowIsAttended() throws {
        let engine = start([window("w", ["a"], active: "a")])
        renderer.focusedWindows = ["w"]
        engine.windowDidGainFocus("w")
        _ = take()
        let id = try #require(runtime.panes.openPane(PaneRequest(type: "watch", placement: .split("a", edge: .trailing))))
        let events = take()
        #expect(events.contains("+\(id.rawValue)") == (engine.activePaneID == id), "\(events)")
    }

    @Test func aSecondWindowsFocusMovesAttentionBetweenWindows() {
        let engine = start([window("w", ["a"], active: "a"), window("v", ["b"], active: "b")])
        renderer.focusedWindows = ["w"]
        engine.windowDidGainFocus("w")
        #expect(take() == ["+a"])
        renderer.focusedWindows = ["v"]
        engine.windowDidLoseFocus("w")
        engine.windowDidGainFocus("v")
        #expect(Set(take()) == ["-a", "+b"])
    }

    @Test func movingAPaneToAnUnfocusedWindowLosesItsAttention() {
        let engine = start([window("w", ["a", "b"], active: "a"), window("v", ["c"], active: "c")])
        renderer.focusedWindows = ["w"]
        engine.windowDidGainFocus("w")
        _ = take()
        let moved = engine.move(.pane("a"), from: "w", to: "v", at: .dock(targetID: "c", zone: .right))
        #expect(moved)
        #expect(take() == ["-a"])
    }
}
