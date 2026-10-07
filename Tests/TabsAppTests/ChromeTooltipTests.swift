import AppKit
import Testing

@testable import Tabs
@testable import TabsCore

extension UITests {
    /// The chrome's tool tips are AppKit's: a whole control's is its `toolTip`; a part's (a tab's
    /// close button, a header menu's rows, an empty pane's buttons) is a tool tip rect whose owner,
    /// the view, names it when AppKit asks. Showing one needs a shown window and a real pointer, so
    /// these pin the text.
    @MainActor
    @Suite struct ChromeTooltips {
        /// What AppKit asks `owner` for over `point` (its coordinates).
        private func toolTip(_ owner: some NSView & NSViewToolTipOwner, at point: CGPoint) -> String {
            owner.view(owner, stringForToolTip: 0, point: point, userData: nil)
        }

        private func center(_ rect: CGRect) -> CGPoint { CGPoint(x: rect.midX, y: rect.midY) }

        @Test func aHeaderButtonIsNamedByItsFirstItem() throws {
            let ui = UIDriver(layout: Fixture.saved(Fixture.window("w", Fixture.leaf("a"))))
            #expect(try ui.control(HeaderAction.splitHorizontal.accessibilityID, of: "a").toolTip == "Split horizontally")
            #expect(try ui.control(HeaderAction.close.accessibilityID, of: "a").toolTip == "Close pane")
            // The docked root's bar leads with New tab instead.
            #expect(try ui.control(HeaderAction.newTab.accessibilityID, of: "root-w").toolTip == "New tab")
        }

        @Test func theRootBarsButtonsAreNamed() throws {
            let ui = UIDriver(layout: Fixture.saved(Fixture.window("w", Fixture.leaf("a"))))
            let bar = try #require(try ui.paneView("root-w").tabBar)
            #expect(bar.strip.newTabButton.toolTip == "New tab")
            #expect(bar.settingsButton.toolTip == "Settings")
        }

        @Test func aTabsCloseButtonNamesTheTabEvenOnceRenamed() throws {
            let ui = UIDriver(layout: Fixture.saved(Fixture.tabsWindow("w", [Fixture.leaf("a"), Fixture.leaf("b")], active: 1)))
            let tab = try ui.tabView("t-b")
            #expect(toolTip(tab, at: center(tab.closeRect)) == "Close Tabs")
            #expect(tab.toolTip == nil, "only the close button has one")

            #expect(ui.engine.perform(in: "w") { layout, titles in layout.renameTab("t-b", "Logs", titles: titles) })
            ui.layoutAll()
            #expect(toolTip(tab, at: center(tab.closeRect)) == "Close Logs")
        }

        @Test func aHeaderMenuNamesEachRow() throws {
            let ui = UIDriver(layout: Fixture.saved(Fixture.window("w", Fixture.leaf("a"))))
            let button = try ui.control(HeaderAction.splitHorizontal.accessibilityID, of: "a")
            try ui.hover(at: NSPoint(x: button.bounds.midX, y: button.bounds.midY), in: button)
            let dropdown = try #require(HeaderMenu.openDropdown, "the menu didn't open")
            let names = dropdown.items.indices.map { toolTip(dropdown, at: center(dropdown.rowFrame($0))) }
            #expect(names == ["Split horizontally", "Split vertically", "New tab", "New unpinned tab", "Wrap in tab group"])
            ui.unhover(try ui.window)
        }

        @Test func anEmptyPaneNamesEachButton() throws {
            let ui = UIDriver(layout: Fixture.saved(Fixture.window("w", Fixture.leaf("a"))))
            let empty = try #require(try ui.body("a").content as? EmptyPaneView)
            ui.layoutAll()
            #expect(!empty.actions.isEmpty)
            #expect(empty.buttonRects.map { toolTip(empty, at: center($0)) } == empty.actions.map(\.label))

            // Hovering a button no longer swaps the view's own tool tip.
            try ui.hover(at: center(empty.buttonRects[0]), in: empty)
            #expect(empty.toolTip == nil)
            ui.unhover(try ui.window)
        }
    }
}
