import AppKit
import TabsPluginSDK
import Testing

@testable import Tabs
@testable import TabsCore

extension UITests {
    /// The browser's guide as the app ships it (docs/BROWSER.md I-4): `describe` serves it from the plugin's real bundle,
    /// the one the app loaded, where the plugin tier (`BrowserGuideTests`) reads its test bundle's copy of the sources.
    /// The script, wait and resource verbs themselves are the plugin tier's (`BrowserScriptVerbTests`,
    /// `BrowserWaitVerbTests`, `BrowserResourceVerbTests`).
    @MainActor
    @Suite struct BrowserScriptUITests {
        /// I-4: the guide the shipped bundle serves for `describe`, in the app the shell loaded plugins into.
        @Test func theShippedBundleServesTheGuide() async throws {
            let ui = UIDriver(layout: Fixture.saved(Fixture.tabsWindow("w", [Fixture.leaf("a", "text")])))
            defer { ui.discardWebData() }
            let described = await ui.runtime.control.handle(
                ControlDispatcher.Envelope(
                    command: "describe", arguments: ["capability": "browser"], targetPane: "a", cwd: URL(filePath: "/tmp")))
            let guide = try #require(described["result"]?["guide"]?.stringValue, "\(described)")
            #expect(guide.hasPrefix("# Browser panes") && !guide.contains("read-network"))
        }
    }
}
