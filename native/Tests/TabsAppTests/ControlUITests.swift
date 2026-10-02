import AppKit
import TabsPluginSDK
import Testing

@testable import Tabs
@testable import TabsCore

extension UITests {
    // MARK: - Panes an agent controls (docs/PLUGINS.md, Control verbs)

    @MainActor
    @Suite struct ControlledPanes {
        static let pair = Fixture.sideBySide(Fixture.leaf("a", "text"), Fixture.leaf("b", "text"), active: "a")

        @Test func aPaneOpenedWithoutTheKeyboardIsActiveAsUsualButTheKeyboardStaysPut() throws {
            let ui = UIDriver(layout: Fixture.saved(Fixture.tabsWindow("w", [Fixture.leaf("a", "text")])))
            #expect(ui.focusedPane == "a")
            let agent = try #require(ui.runtime.panes.openPane(PaneRequest(type: "text", placement: .tab(near: "a"), activates: false)))
            ui.layoutAll()
            #expect(ui.activePane == agent, "shown and active, as the Electron store makes an agent's pane")
            #expect(ui.focusedPane != agent, "but it did not take the keyboard")

            let user = try #require(ui.runtime.panes.openPane(PaneRequest(type: "text", placement: .tab(near: "a"))))
            ui.layoutAll()
            #expect(ui.activePane == user)
            #expect(ui.focusedPane == user, "a pane that activates takes it, as ever")
        }

        @Test func aFloatingPaneOpenedWithoutTheKeyboardKeepsItOutToo() throws {
            let ui = UIDriver(layout: Self.pair)
            let float = try #require(
                ui.runtime.panes.openPane(PaneRequest(type: "text", placement: .floating(near: "b"), activates: false)))
            ui.layoutAll()
            #expect(try ui.layout.floatingPane(holding: float) != nil)
            #expect(ui.activePane == float)
            #expect(ui.focusedPane != float)
        }

        @Test func theUserActivatingTheExemptPaneLaterFocusesItAsAlways() throws {
            let ui = UIDriver(layout: Fixture.saved(Fixture.tabsWindow("w", [Fixture.leaf("a", "text")])))
            let agent = try #require(ui.runtime.panes.openPane(PaneRequest(type: "text", placement: .tab(near: "a"), activates: false)))
            ui.layoutAll()
            ui.engine.perform(in: "w") { layout, titles in layout.reveal("a", titles: titles) }
            ui.layoutAll()
            #expect(ui.focusedPane == "a")
            ui.engine.perform(in: "w") { layout, titles in layout.reveal(agent, titles: titles) }
            ui.layoutAll()
            #expect(ui.focusedPane == agent, "the exemption was spent once")
        }

        @Test func anOwnedPaneShowsTheRobotAndItsOutlineButNeverOnATab() throws {
            let ui = UIDriver(layout: Self.pair)
            ui.runtime.panes.grantOwnership(of: "b", to: "a")
            ui.layoutAll()
            #expect(try ui.headerSignals("b") == ["controlled"])
            #expect(try ui.headerSignals("a").isEmpty)
            #expect(try ui.outline("b")?.shown?.kind.id == "controlled")
            let window = try #require(try ui.window.window)
            #expect(InputSynthesizer.find("tab-signal-controlled", in: window) == nil, "there is no tab icon for it")
            let robot = try #require(InputSynthesizer.find("pane-signal-controlled", in: window))
            #expect(robot.toolTip == nil || robot.toolTip == "Controlled by another pane")
        }

        @Test func closingTheOwnedPaneEndsItsCue() throws {
            let ui = UIDriver(layout: Self.pair)
            ui.runtime.panes.grantOwnership(of: "b", to: "a")
            ui.engine.close("b")
            ui.layoutAll()
            #expect(ui.runtime.signals.raised(on: "b").isEmpty)
            #expect(!ui.runtime.panes.ownership.isOwned("b"))
        }
    }
}
