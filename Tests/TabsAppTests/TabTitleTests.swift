import AppKit
import SwiftUI
import TabsPluginSDK
import Testing

@testable import Tabs
@testable import TabsCore

extension UITests {
    // MARK: - Tab titles follow panes (docs/TAB-TITLES.md)

    /// What a tab shows, drawn: the title of the pane last active in it (the
    /// text stand-in is titled by its first line), unless the user named it.
    @MainActor
    @Suite struct TabTitles {
        /// Root tabs: "t-s" holds a split of A ("alpha") and B ("beta"), "t-c" holds C ("gamma"); A is active.
        static let twoTabs: SavedLayout = {
            let text = { (id: PaneID, text: String) in Fixture.leaf(id, "text", config: ["text": .string(text)]) }
            let split = Fixture.split("s", .horizontal, [text("a", "alpha"), text("b", "beta")])
            let tabs = [Fixture.tab(split, id: "t-s", title: "Tabs"), Fixture.tab(text("c", "gamma"), title: "Tabs")]
            return Fixture.saved(WindowLayout(id: "w", root: Fixture.tabs("root-w", tabs), active: "a"))
        }()

        /// The layout, a pane's title change shown at once (how long one waits
        /// to show: `aPanesOwnTitleChangeWaitsHalfASecondToShow`).
        static func driver() -> UIDriver {
            let ui = UIDriver(layout: twoTabs)
            ui.engine.titleSettleDelay = .zero
            return ui
        }

        private func text(_ ui: UIDriver, _ pane: PaneID) -> TextPane? {
            ui.renderer.body(for: pane)?.live?.controller as? TextPane
        }

        private func isManual(_ ui: UIDriver, _ tab: NodeID) throws -> Bool? {
            try ui.layout.findTab(tab)?.tab.titleIsManual
        }

        @Test func aTabShowsItsPanesTitleAsItChanges() throws {  // TT-3
            let ui = Self.driver()
            #expect(try ui.tabView("t-s").title == "alpha")
            #expect(try ui.tabView("t-c").title == "gamma", "a tab none of whose panes was active: the pane it shows")

            text(ui, "a")?.insert(" and a longer first line, as a shell's title can be ")
            ui.layoutAll()
            let tab = try ui.tabView("t-s")
            let line = try #require(ui.config(of: "a")?["text"]?.stringValue)
            #expect(line.contains("a longer first line"))
            #expect(tab.title == line.trimmingCharacters(in: .whitespaces), "trimmed, as its header shows it")
            #expect(tab.frame.width == tab.naturalWidth, "the strip laid out again for the new title")
            #expect(try ui.layout.findTab("t-s")?.tab.title == "Tabs", "shown, never stored")
        }

        @Test func aTabSwitchesToThePaneThatBecomesActiveInItAndKeepsItInTheBackground() throws {  // TT-4, TT-5
            let ui = Self.driver()
            try ui.click(body: "b")
            #expect(try ui.tabView("t-s").title == "beta")

            try ui.click(tab: "t-c")
            #expect(ui.activePane == "c")
            #expect(try ui.tabView("t-s").title == "beta", "in the background, still the pane last active in it")
            text(ui, "b")?.insert("zeta ")
            #expect(try ui.tabView("t-s").title.contains("zeta"), "and still following its title")
        }

        @Test func aRenamedTabKeepsTheNameAndAnEmptiedOneFollowsAgain() throws {  // TT-8, TT-9
            let ui = Self.driver()
            try ui.click(tab: "t-s", count: 2)
            let editor = try #require(try ui.tabView("t-s").editor)
            #expect((editor.subviews.first as? NSTextField)?.stringValue == "alpha", "the editor starts from what the tab shows")
            try ui.type("\n")
            #expect(try isManual(ui, "t-s") == false, "Return on the shown title changes nothing")

            try ui.click(tab: "t-s", count: 2)
            try ui.type("Mine\n")
            #expect(try ui.tabView("t-s").title == "Mine")
            #expect(try isManual(ui, "t-s") == true)
            text(ui, "a")?.insert("x")
            try ui.click(body: "b")
            #expect(try ui.tabView("t-s").title == "Mine", "neither a title change nor a pane switch touches it")
            #expect(try ui.tabView("t-c").title == "gamma", "the other tab still follows")

            try ui.click(tab: "t-s", count: 2)
            try ui.type(" \n")
            #expect(try isManual(ui, "t-s") == false)
            #expect(try ui.layout.findTab("t-s")?.tab.title == "Split", "the title a new tab of its content gets")
            #expect(try ui.tabView("t-s").title == "beta", "following its pane again")
        }

        @Test func confirmingAPanesShownTitleKeepsItFollowingItsContent() throws {  // TT-14
            let ui = Self.driver()
            let header = try #require(try ui.paneView("a").header)
            let title = header.titleRect
            try ui.click(at: NSPoint(x: title.minX + min(8, title.width / 2), y: title.midY), in: header, count: 2)
            let editor = try #require(header.editor)
            #expect((editor.subviews.first as? NSTextField)?.stringValue == "alpha", "the editor starts from what the header shows")
            try ui.type("\n")
            #expect(header.editor == nil)
            #expect(ui.engine.model.leaf("a")?.titleIsManual == false, "Return on the shown title changes nothing")

            text(ui, "a")?.insert("zeta ")
            #expect(ui.engine.paneTitle(of: "a").contains("zeta"), "the header still follows the content's title")
            #expect(try ui.tabView("t-s").title.contains("zeta"), "and so does the tab following it")
        }

        @Test func turnedOffATabShowsItsOwnTitle() throws {  // TT-10
            let ui = Self.driver()
            var panes = ui.runtime.settings.panes
            panes.tabTitlesFollowPanes = false
            ui.runtime.settings.setPanes(panes)
            #expect(try ui.tabView("t-s").title == "Tabs")
            #expect(try ui.tabView("t-c").title == "Tabs")

            panes.tabTitlesFollowPanes = true
            ui.runtime.settings.setPanes(panes)
            #expect(try ui.tabView("t-s").title == "alpha", "on again: nothing was lost")
        }

        @Test func aPanesOwnTitleChangeWaitsHalfASecondToShow() async throws {  // TT-13
            let ui = UIDriver(layout: Self.twoTabs)
            #expect(ui.engine.titleSettleDelay == .milliseconds(500), "the app's own wait")
            let context = try #require(ui.engine.live("a")?.context)
            func shown() throws -> [String] {
                [try ui.tabView("t-s").title, ui.engine.paneTitle(of: "a"), try ui.window.window?.title ?? ""]
            }

            // A quick command: its title, then the prompt's again.
            context.setTitle("ls")
            context.setTitle("alpha")
            try await Task.sleep(for: .milliseconds(800))
            #expect(try shown() == ["alpha", "alpha", "alpha"], "never shown")

            context.setTitle("make")
            #expect(try shown() == ["alpha", "alpha", "alpha"], "not yet")
            #expect(ui.engine.controlTitle(of: "a") == "make", "the control plane reads the live title at once")
            #expect(
                try await ui.wait(until: { try shown() == ["make", "make", "make"] }),
                "the tab, the header's title and the window title together")
        }
    }

    // MARK: - Settings ▸ Panes & Tabs ▸ Tabs (docs/TAB-TITLES.md TT-2)

    @MainActor
    @Suite struct TabTitlesSetting {
        @Test func theSwitchIsOnPanesAndTabsUnderTabs() throws {
            let runtime = TestSupport.runtime()
            let controller = makeSettingsWindow(
                pages: [], settings: runtime.settings, signals: [], shortcuts: runtime.shortcuts, themes: runtime.themes)
            defer { controller.close() }
            let tabs = try #require(controller.contentViewController as? NSTabViewController)
            #expect(tabs.tabViewItems.first?.label == "Panes & Tabs")
            let page = try #require(tabs.tabViewItems.first?.view)
            let hosting = try #require(
                page.allSubviews.lazy.compactMap { $0 as? NSHostingView<ThemedRoot<PaneSettingsView>> }.first ?? page
                    as? NSHostingView<ThemedRoot<PaneSettingsView>>)

            // The switch writes the setting, both ways.
            let model = hosting.rootView.content.model
            #expect(model.binding(\.tabTitlesFollowPanes).wrappedValue)
            model.binding(\.tabTitlesFollowPanes).wrappedValue = false
            #expect(runtime.settings.panes.tabTitlesFollowPanes == false)
            model.binding(\.tabTitlesFollowPanes).wrappedValue = true
            #expect(runtime.settings.panes.tabTitlesFollowPanes)
        }
    }
}
