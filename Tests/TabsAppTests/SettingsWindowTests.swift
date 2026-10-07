import AppKit
import TabsPluginSDK
import Testing

@testable import Tabs
@testable import TabsCore

/// The Settings window with every bundled plugin's pages: each tab sized to its page, and no page
/// wider or taller than its window (a longer one scrolls in it rather than being cut off). A page
/// is made only when its tab is first chosen.
@MainActor
@Suite struct SettingsWindowTests {
    @Test func everyPageFitsItsWindowAndALongerOneScrolls() throws {
        let runtime = TestSupport.runtime()
        runtime.startBundledPlugins(of: .main, requiredContentTypes: [])
        let controller = makeSettingsWindow(for: runtime)
        defer { controller.close() }
        let window = try #require(controller.window)
        let tabs = try #require(controller.contentViewController as? NSTabViewController)
        #expect(tabs.tabViewItems.count == 3 + runtime.settingsPages().count, "core's three pages and the plugins'")
        #expect(window.title == tabs.tabViewItems.first?.label, "the selected page names the window from the start")

        for (index, item) in tabs.tabViewItems.enumerated() {
            // The page gets its size as its tab is chosen; the window takes it, as the tab
            // controller does for a window on screen.
            tabs.selectedTabViewItemIndex = index
            let size = try #require(item.viewController?.preferredContentSize)
            #expect(size.width == SettingsPageContribution.width, "\(item.label)")
            #expect(size.height > 0 && size.height <= SettingsPageSizing.maxHeight, "\(item.label): \(size.height)")
            window.setContentSize(size)
            window.contentView?.layoutSubtreeIfNeeded()
            let page = try #require(item.view)
            #expect(page.frame.size == size, "\(item.label) fills its window")
            #expect(page.fittingSize.width <= size.width, "\(item.label) is wider than its window")
            for scrollView in page.allSubviews.compactMap({ $0 as? NSScrollView }) {
                #expect(scrollView.frame.height <= size.height + 0.5, "\(item.label)'s form is taller than its window, so it can't scroll")
            }
        }
    }

    /// Every tab is in the toolbar from the start, but only the page the window opens on is made;
    /// another is made, and sized, as its tab is first chosen, and the window takes its size.
    @Test func aPageIsMadeWhenItsTabIsFirstChosenAndTheWindowTakesItsSize() throws {
        let runtime = TestSupport.runtime()
        runtime.startBundledPlugins(of: .main, requiredContentTypes: [])
        let controller = makeSettingsWindow(for: runtime)
        defer { controller.close() }
        let window = try #require(controller.window)
        let tabs = try #require(controller.contentViewController as? NSTabViewController)
        let items = tabs.tabViewItems
        #expect(items.allSatisfy { !$0.label.isEmpty && $0.image != nil }, "every tab, label and symbol")
        func made() -> [String] { items.filter { $0.viewController?.isViewLoaded == true }.map(\.label) }
        #expect(made() == ["Panes & Tabs"], "only the page the window opens on")
        #expect(window.contentLayoutRect.size == items.first?.viewController?.preferredContentSize, "and the window has its size")

        let ai = try #require(items.last)
        let before = window.contentLayoutRect.size
        tabs.selectedTabViewItemIndex = items.count - 1
        #expect(made() == ["Panes & Tabs", "AI"], "the chosen page, and no other")
        let size = try #require(ai.viewController?.preferredContentSize)
        #expect(size.width == SettingsPageContribution.width)
        #expect(size.height > 0 && size != before, "AI's own size, not the page before's: \(size)")
        // The tab controller gives the window that size (animated, on screen).
        let deadline = Date().addingTimeInterval(5)
        while window.contentLayoutRect.size != size, Date() < deadline { runLoopTurns() }
        #expect(window.contentLayoutRect.size == size)
    }
}
