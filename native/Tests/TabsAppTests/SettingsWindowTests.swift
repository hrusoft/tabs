import AppKit
import TabsPluginSDK
import Testing

@testable import Tabs
@testable import TabsCore

/// The Settings window with every shipped plugin's pages: each tab sized to its page, and no page
/// wider or taller than its window (a longer one scrolls in it rather than being cut off).
@MainActor
@Suite struct SettingsWindowTests {
    @Test func everyPageFitsItsWindowAndALongerOneScrolls() throws {
        let runtime = TestSupport.runtime()
        runtime.startBundledPlugins(of: .main, requiredContentTypes: [])
        let controller = makeSettingsWindow(for: runtime)
        defer { controller.close() }
        let window = try #require(controller.window)
        let tabs = try #require(controller.contentViewController as? NSTabViewController)
        #expect(tabs.tabViewItems.count > 3, "core's pages and the plugins'")
        #expect(window.title == tabs.tabViewItems.first?.label, "the selected page names the window from the start")

        for (index, item) in tabs.tabViewItems.enumerated() {
            let size = try #require(item.viewController?.preferredContentSize)
            #expect(size.width == SettingsPageContribution.width, "\(item.label)")
            #expect(size.height > 0 && size.height <= SettingsPageSizing.maxHeight, "\(item.label): \(size.height)")
            // What the tab controller does for a window on screen.
            tabs.selectedTabViewItemIndex = index
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
}
