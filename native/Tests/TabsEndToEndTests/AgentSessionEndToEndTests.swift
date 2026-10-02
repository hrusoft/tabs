import Foundation
import TabsPluginSDK
import Testing

/// `AgentSession` and the standard pages against the running app: what the browser verb tests stand on.
/// (`create-browser-pane` itself is another slice's verb; a pane the user opens by hand stands in here.)
@Suite(.serialized, .sharedApp, .timeLimit(.minutes(2)), .enabled(if: LaunchedApp.nodeIsInstalled, "tabs-ctl runs under Node"))
struct AgentSessionEndToEndTests {
    @Test func aSessionRunsTabsCtlFromItsCallerPaneAndOutsideTabs() async throws {
        let agent = try await AgentSession.open(SharedApp.fresh())
        let ping = try await agent.ctl("ping")
        #expect(ping.ok && ping.exitCode == 0)
        let outside = try await agent.ctlOutsideTabs(["ping"])
        #expect(!outside.ok && outside.exitCode == 1)
        #expect(outside.error?.contains("not running inside a Tabs terminal pane") == true)
        #expect(try await agent.ctl(["ping"], from: agent.caller).ok)
    }

    @Test func aHandOpenedBrowserPaneIsReadBackThroughItsPage() async throws {
        let server = try await FixtureServer.startStandard()
        defer { server.stop() }
        let agent = try await AgentSession.open(SharedApp.fresh(), foreignPane: true)
        let pane = try #require(agent.foreignPane)
        #expect(pane != agent.caller)
        #expect(try await agent.browserPanes().map(\.pane) == [pane])

        let loaded = try await agent.load(pane, server.url("/page"))
        #expect(loaded["loaded"] == true)
        let state = try await agent.state(pane) { $0["title"] == "Fixture" }
        #expect(state["url"] == .string(server.url("/page")))
        #expect(try await agent.text(pane, "#status") == "idle")
        #expect(try await agent.text(pane, "#nope") == nil)
        #expect(try await agent.eval(pane, "1 + 1") == 2)
        #expect(try await agent.eval(pane, "fetch('/api/secret').then((r) => r.json())") == ["ok": true], "a promise is awaited")

        try await agent.show(pane)
        // A trusted click at the button's centre reaches the page's own handler.
        let rect = try await agent.eval(
            pane,
            "(() => { const r = document.getElementById('go').getBoundingClientRect(); return [r.x + r.width / 2, r.y + r.height / 2] })()")
        guard case .array(let point) = rect, let x = point[0].doubleValue, let y = point[1].doubleValue else {
            Issue.record("no button rect: \(rect)")
            return
        }
        try await agent.input(pane, x: x, y: y)
        #expect(try await agent.text(pane, "#status") == "clicked")

        await #expect(throws: LaunchedApp.Failure.self) { try await agent.eval(pane, "nope.nope") }
    }

    @Test func aDeadOriginIsRefusedByTheEngine() async throws {
        let agent = try await AgentSession.open(SharedApp.fresh(), foreignPane: true)
        let pane = try #require(agent.foreignPane)
        let loaded = try await agent.load(pane, try await FixtureServer.deadOrigin())
        #expect(loaded["loaded"] == false)
        #expect(loaded["loadError"] != nil)
    }

    @Test func theForeignPaneScaffoldSeesEveryCommandRefused() async throws {
        try await AgentSession.expectRefusedForForeignPane(SharedApp.fresh()) { foreign in
            [["activate-pane", "--pane", foreign], ["close-pane", "--pane", foreign], ["pane-info", "--pane", foreign]]
        }
    }
}
