import Foundation
import TabsPluginSDK
import Testing

/// The browser in the running app (docs/BROWSER.md): the built bundle, its own process and web view, reading a
/// page from a loopback server in this process, driven by the app's real bundled `tabs-ctl` from a pane the app
/// made (a `fixture-text` pane standing for the agent's terminal: the browser's tests never need another plugin).
/// What each verb does, and how a pane is placed, moved and restored, is the unit and UI tiers'
/// (`Plugins/Browser/Tests`, `Plugins/Browser/Tests/UI`).
@Suite(.serialized, .sharedApp, .timeLimit(.minutes(2)))
struct BrowserControlEndToEndTests {
    /// H-14: "tabs-ctl drains a response bigger than the pipe buffer…" (the get-page-text side of it). It is also
    /// the plugin's one check that the bundle is wired into the launched app: its verbs answer through the relay,
    /// and the pane one made reads back.
    @Test func aPageTextBiggerThanThePipeBufferComesBackWhole() async throws {
        let server = try await FixtureServer.startStandard()
        defer { server.stop() }
        let app = try await SharedApp.fresh()
        let caller = try await app.newFixturePane()
        try await LaunchedWebData.record(app)
        let created = try await app.tabsCtl(["create-browser-pane", "--url", server.url("/bigtext")], from: caller)
        #expect(created.exitCode == 0 && created.response["result"]?["loaded"] == true, "\(created.response)")
        let pane = try #require(created.response["result"]?["paneId"]?.stringValue, "\(created.response)")
        let big = try await app.tabsCtl(["get-page-text", "--pane", pane, "--max-length", "200000"], from: caller)
        #expect(big.response["ok"] == true && big.exitCode == 0, "\(big.response["error"] ?? .null)")
        let text = big.response["result"]?["text"]?.stringValue ?? ""
        #expect(text.count > 65_536 && text.contains("END-OF-BIGTEXT"))
    }
}

/// The web data store a launched app's pages use: each app runs on a scratch data directory, which names a
/// store of its own in the app's WebKit container (beside the user's own app's, which no test app ever names).
enum LaunchedWebData {
    /// Has the store `app`'s pages use (`browser.test.dataStore`) deleted when this test process exits, when every
    /// app it launched is gone (`WebDataStores`).
    static func record(_ app: LaunchedApp) async throws {
        guard let store = try await app.call("browser.test.dataStore").stringValue.flatMap(UUID.init(uuidString:)) else { return }
        WebDataStores.discard(store, ofApp: Bundle(url: LaunchedApp.appURL)?.bundleIdentifier)
    }
}
