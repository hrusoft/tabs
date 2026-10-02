import Foundation
import TabsPluginSDK
import Testing

/// Browser panes in the running app (docs/BROWSER.md): the real plugin bundle,
/// its own process and web view, reading pages from a loopback server in this
/// process, read back over the control socket with the Debug verb
/// `browser.test.state`. The tests here relaunch their app.
extension LaunchedApp {
    func browser(_ pane: String) async throws -> JSONValue { try await call("browser.test.state", paneId: pane) }

    @discardableResult
    func browser(
        _ pane: String, within seconds: Double = 15, sourceLocation: SourceLocation = #_sourceLocation,
        until condition: (JSONValue) -> Bool
    ) async throws -> JSONValue {
        let deadline = ContinuousClock.now + .seconds(seconds)
        var state = try await browser(pane)
        while !condition(state) {
            guard ContinuousClock.now < deadline else {
                Issue.record("timed out; the browser: \(state)", sourceLocation: sourceLocation)
                return state
            }
            try await Task.sleep(for: .milliseconds(50))
            state = try await browser(pane)
        }
        return state
    }
}

@Suite(.serialized) struct BrowserEndToEndTests {
    /// A-3, A-4, A-5: a new pane starts blank, and the page it was on survives a relaunch: a re-created
    /// pane returns to the saved URL, not to the seed.
    @Test func thePageAPaneWasOnSurvivesARelaunch() async throws {
        let server = try await FixtureServer.start()
        defer { server.stop() }
        server.page("/first", title: "First")
        server.page("/second", title: "Second")
        let app = try await LaunchedApp.launch()
        defer { app.terminate() }
        let pane = try await app.activePane()
        try await app.call("tabs.test.click", ["create": "browser", "paneId": .string(pane)])
        let blank = try await app.browser(pane) { $0["addressText"] != nil }
        #expect(blank["url"] == "about:blank" && blank["addressText"] == "about:blank", "a new pane starts blank")

        try await app.call("browser.test.load", ["url": .string(server.url("/first"))], paneId: pane)
        try await app.call("browser.test.load", ["url": .string(server.url("/second"))], paneId: pane)
        let there = try await app.browser(pane) { $0["title"] == "Second" && $0["backEnabled"] == true }
        #expect(there["addressText"] == .string(server.url("/second")) && there["configURL"] == .string(server.url("/second")))

        try await app.relaunch()

        let after = try await app.browser(pane) { $0["title"] == "Second" }
        #expect(after["url"] == .string(server.url("/second")), "the saved URL, not the seed")
        #expect(after["addressText"] == .string(server.url("/second")))
        #expect(after["backEnabled"] == false, "history isn't saved: a re-created page starts its own")
        try await app.quit()
    }

    /// A-4: a pane left blank stays blank across a relaunch.
    @Test func aBlankPaneStaysBlank() async throws {
        let app = try await LaunchedApp.launch()
        defer { app.terminate() }
        let pane = try await app.activePane()
        try await app.call("tabs.test.click", ["create": "browser", "paneId": .string(pane)])
        try await app.browser(pane) { $0["addressText"] != nil }
        try await app.relaunch()
        let state = try await app.browser(pane) { $0["addressText"] != nil }
        #expect(state["url"] == "about:blank" && state["hasCommitted"] == false)
        try await app.quit()
    }
}
