import Darwin
import Foundation
import TabsPluginSDK
import Testing

/// The agent's side of the control plane (docs/BROWSER.md H-14, I-1): the
/// built app's own `tabs-ctl` against the running app's socket, from a pane
/// the app made (`LaunchedApp.tabsCtl`). The relay's own reads and exit code;
/// what it sends and how core answers are `RelayTests`' and `ControlPlaneTests`'.
@Suite(.serialized, .sharedApp, .timeLimit(.minutes(2)))
struct ControlPlaneEndToEndTests {
    /// The caller is a pane to run tabs-ctl "in". In a real session it is a
    /// terminal; core asks only that the caller is a live pane, so the test
    /// plugin's will do.
    @Test func tabsCtlGetsItsAnswerOnTheLineIntactAndExitsNonZeroForAFailedStep() async throws {
        let app = try await SharedApp.fresh()
        let pane = try await app.newFixturePane()
        let ping = try await app.tabsCtl(["ping"], from: pane)
        #expect(ping.response == ["ok": true])
        #expect(ping.exitCode == 0)
        #expect(ping.elapsed < .seconds(10), "the socket keeps a connection open: tabs-ctl answers on the line, not on the close")

        let failed = try await app.tabsCtl(["batch", "--requests", #"[{"type":"ping"},{"type":"nope"},{"type":"ping"}]"#], from: pane)
        #expect(failed.response["ok"] == true, "the batch ran")
        #expect(failed.response["result"]?["stoppedAt"] == 1)
        #expect(failed.exitCode == 1, "a failed step fails the exit code: `&&` means what it looks like")

        // The refusal echoes the command back: multi-byte characters through the whole path, out and back.
        let unknown = try await app.tabsCtl(["nope-🙂-é"], from: pane)
        #expect(unknown.response["error"] == "unknown command: nope-🙂-é — run capabilities to list them")
        #expect(unknown.exitCode == 1)
    }
}
