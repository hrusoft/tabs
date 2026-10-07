import AppKit
import WebKit

@testable import Tabs
@testable import TabsCore

extension UIDriver {
    /// Hands the web data store of this driver's pages to `WebDataStores`, to be deleted when the test process
    /// exits: every `UIDriver` runs the plugin on a fresh data directory, which names a store of its own (one per
    /// driver: every browser pane of a runtime shares its plugin's). `defer { ui.discardWebData() }` where a test
    /// makes its driver.
    func discardWebData() {
        func webViews(in view: NSView) -> [WKWebView] {
            (view as? WKWebView).map { [$0] } ?? view.subviews.flatMap(webViews)
        }
        // A pane's view is its page's web view, shown or not; the windows hold the ones a test made by hand too.
        let views =
            runtime.panes.panes(ofType: "browser").compactMap { engine.live($0)?.controller.view }.flatMap(webViews)
            + renderer.windows.compactMap { $0.window?.contentView }.flatMap(webViews)
        for store in Set(views.compactMap { $0.configuration.websiteDataStore.identifier }) { WebDataStores.discard(store) }
    }
}
