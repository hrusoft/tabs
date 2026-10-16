import AppKit
import Foundation
import TabsPluginSDK

@testable import TabsCore

extension PluginHarness {
    /// A harness running the Browser plugin (`plugin`, made here unless the test keeps its own), whose web
    /// data store (the one the harness's fresh data directory names) is deleted when the test process exits
    /// (`WebDataStores`). Every browser pane the layout shows sits in an `OnScreenWindow`, as the app puts a shown
    /// pane in a window someone is looking at: Browser tests drive active pages (docs/BROWSER.md, Testing). A pane
    /// the layout doesn't show (a background tab) is in no window, as in the app.
    static func browser(
        _ plugin: BrowserPlugin = BrowserPlugin(), withAgent: Bool = false, testFile: String = #filePath
    ) throws -> PluginHarness {
        let harness = try PluginHarness(withAgent: withAgent, testFile: testFile) { plugin }
        if let store = plugin.services?.webDataStore { WebDataStores.discard(store) }
        let screens = ShownBrowserPanes()
        harness.renderer.onRender = { [weak harness] model in
            guard let harness else { return }
            screens.place(model, harness: harness)
        }
        screens.place(harness.renderer.rendered, harness: harness)
        return harness
    }
}

/// The windows the harness's shown browser panes sit in, one each: a pane's page is in its window while the
/// layout shows the pane, and in none while it doesn't.
@MainActor
final class ShownBrowserPanes {
    private var windows: [PaneID: OnScreenWindow] = [:]

    func place(_ model: LayoutModel, harness: PluginHarness) {
        var present: Set<PaneID> = []
        for window in model.windows {
            for leaf in window.leaves {
                guard let browser = harness.controller(of: leaf.id, as: BrowserPane.self) else { continue }
                present.insert(leaf.id)
                let view = browser.view
                if window.isShowing(leaf.id) {
                    let host = windows[leaf.id] ?? OnScreenWindow.make()
                    windows[leaf.id] = host
                    // A page a test put somewhere of its own (a window, or a view in none) stays there.
                    if view.window == nil && view.superview == nil { host.contentView = view }
                } else if let host = windows[leaf.id], view.window === host {
                    host.contentView = nil
                }
            }
        }
        for (pane, window) in windows where !present.contains(pane) {
            window.contentView = nil
            window.close()
            windows[pane] = nil
        }
    }

    isolated deinit {
        for window in windows.values { window.close() }
    }
}
