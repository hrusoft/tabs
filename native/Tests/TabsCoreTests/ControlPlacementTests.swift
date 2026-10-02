import Foundation
import TabsPluginSDK
import Testing

@testable import TabsCore

/// The pane requests a control verb makes: an agent's pane that doesn't take
/// the keyboard, one floating over its caller, and `revealPane`.
@MainActor
@Suite struct ControlPlacementTests {
    let fixture = ControlFixture(windows: [
        ControlFixture.terminals("t1", "t2", id: "w"), ControlFixture.terminals("t3", id: "w2"),
    ])
    var panes: PaneRuntime { fixture.runtime.panes }
    var engine: LayoutEngine { fixture.engine }

    private func window(_ id: WindowID = "w") -> WindowLayout { engine.model.window(id)! }

    // MARK: activates

    @Test func aPaneOpenedWithoutTheKeyboardIsPlacedAndActiveAsUsualButSkipsTheKeyboardOnce() throws {
        let pane = try #require(panes.openPane(PaneRequest(type: "web", placement: .tab(near: "t1"), activates: false)))
        #expect(window().isShowing(pane), "placed as a tab, shown")
        #expect(window().activeLeafID == pane, "and the window's active pane, as in the Electron store")
        let live = try #require(engine.live(pane))
        #expect(live.consumeKeyboardExemption(), "the shell's focus-follows-active skips it")
        #expect(!live.consumeKeyboardExemption(), "once: the user activating it later focuses it as always")
    }

    @Test func aPaneThatActivatesIsNotExempt() throws {
        let pane = try #require(panes.openPane(PaneRequest(type: "web", placement: .tab(near: "t1"))))
        #expect(engine.live(pane)?.consumeKeyboardExemption() == false)
    }

    @Test func nothingAsksTheRendererToFocusAPaneOpenedByAVerb() async throws {
        let focusRequests = fixture.renderer.focused
        let pane = try await fixture.createPane(from: "t1")
        #expect(fixture.renderer.focused == focusRequests)
        #expect(engine.live(pane)?.consumeKeyboardExemption() == true, "create-web-pane opens with activates: false")
    }

    // MARK: floating

    @Test func aFloatingPaneOpensOverItsOriginInTheSectionTheSettingNames() throws {
        fixture.renderer.paneRects["t1"] = FloatRect(x: 100, y: 50, width: 800, height: 600)
        let pane = try #require(panes.openPane(PaneRequest(type: "web", placement: .floating(near: "t1"))))
        let float = try #require(window().floatingPane(holding: pane))
        #expect(float.rect == Floating.spawnRect(in: FloatRect(x: 100, y: 50, width: 800, height: 600), at: .topRight))
        #expect(window().activeLeafID == pane, "newest, on top and active")
        #expect(window().isShowing(pane))
        #expect(window().root.tabs.count == 2, "nothing was wrapped into the docked root")
    }

    @Test func theSettingPicksTheSection() throws {
        var settings = fixture.runtime.settings.panes
        settings.newUnpinnedPanePosition = "bottom-left"
        fixture.runtime.settings.setPanes(settings)
        let origin = FloatRect(x: 0, y: 0, width: 900, height: 700)
        fixture.renderer.paneRects["t1"] = origin
        let pane = try #require(panes.openPane(PaneRequest(type: "web", placement: .floating(near: "t1"))))
        #expect(window().floatingPane(holding: pane)?.rect == Floating.spawnRect(in: origin, at: .bottomLeft))
    }

    @Test func aFloatingPaneWithNoMeasurableOriginTakesTheDefaultRect() throws {
        let pane = try #require(panes.openPane(PaneRequest(type: "web", placement: .floating(near: "t1"))))
        #expect(window().floatingPane(holding: pane)?.rect == Floating.defaultRect, "a backgrounded tab has no rect to divide")
    }

    @Test func aFloatingPaneOpensInTheWindowOfItsOrigin() throws {
        let pane = try #require(panes.openPane(PaneRequest(type: "web", placement: .floating(near: "t3"))))
        #expect(engine.model.window("w2")?.floatingPane(holding: pane) != nil)
        #expect(engine.model.window("w")?.holds(pane) == false)
    }

    @Test func aFloatingPaneWithNoOriginOpensOverTheFrontmostWindowsActivePane() throws {
        let pane = try #require(panes.openPane(PaneRequest(type: "web", placement: .floating(near: nil))))
        let front = try #require(engine.frontmostWindowID)
        #expect(engine.model.window(front)?.floatingPane(holding: pane) != nil)
    }

    @Test func aFloatingCallerOwnsAWindowOfItsOwnAndAPaneOpensNextToIt() async throws {
        // The caller floats; a tab-placed pane opens inside its window.
        let floater = try #require(panes.openPane(PaneRequest(type: "term", placement: .floating(near: "t1"))))
        let pane = try #require(
            panes.openPane(PaneRequest(type: "web", placement: .tab(near: floater), controlledBy: floater)))
        let float = try #require(window().floatingPane(holding: floater))
        #expect(float.content.leaves.map(\.id).contains(pane), "the new pane joined the caller's floating window")
    }

    @Test func aVerbCanOpenAPaneFloatingOverItsCaller() async throws {
        let opener = TestSupport.candidate(TestSupport.manifest("float", contentTypes: ["float"])) { context in
            let workspace = context.workspace
            context.register(TestSupport.contentType("float"))
            context.register(ControlCapabilityContribution(id: "float", displayName: "Float"))
            context.register(
                ControlVerbContribution(name: "float.open", summary: "opens", command: "open-float", wireType: "openFloat") { invocation in
                    let pane = workspace.openPane(
                        PaneRequest(
                            type: "float", placement: .floating(near: invocation.callerPane), activates: false,
                            controlledBy: invocation.callerPane))
                    return ["paneId": pane.map { .string($0.rawValue) } ?? nil]
                })
        }
        let fixture = ControlFixture(extra: [opener])
        let response = await fixture.ctl("open-float", from: "t2")
        let pane = PaneID(try #require(response["result"]?["paneId"]?.stringValue, "\(response)"))
        #expect(fixture.engine.model.window("w")?.floatingPane(holding: pane) != nil)
        #expect(fixture.runtime.panes.ownership.owner(of: pane) == "t2")
    }

    // MARK: revealPane

    @Test func revealingAPaneShowsItWithoutActivatingIt() throws {
        let pane = try #require(panes.openPane(PaneRequest(type: "web", placement: .tab(near: "t1"))))
        engine.perform(in: "w") { layout, titles in layout.reveal("t2", titles: titles) }
        #expect(!window().isShowing(pane))
        #expect(window().activeLeafID == "t2")
        panes.revealPane(pane)
        #expect(window().isShowing(pane))
        #expect(window().activeLeafID == "t2", "still the user's")
    }

    @Test func aPluginRevealsOnlyItsOwnPanes() throws {
        let holder = WorkspaceHolder()
        let stranger = TestSupport.candidate(TestSupport.manifest("stranger")) { holder.workspace = $0.workspace }
        let fixture = ControlFixture(extra: [stranger])
        let pane = try #require(fixture.runtime.panes.openPane(PaneRequest(type: "web", placement: .tab(near: "t1"))))
        fixture.engine.perform(in: "w") { layout, titles in layout.reveal("t2", titles: titles) }
        #expect(fixture.engine.model.window("w")?.isShowing(pane) == false)
        holder.workspace?.revealPane(pane)
        #expect(fixture.engine.model.window("w")?.isShowing(pane) == false, "another plugin's pane: refused")
    }

    final class WorkspaceHolder { var workspace: (any Workspace)? }
}
