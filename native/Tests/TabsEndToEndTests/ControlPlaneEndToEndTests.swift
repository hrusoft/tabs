import Darwin
import Foundation
import TabsPluginSDK
import Testing

/// The agent's side of the control plane (docs/BROWSER.md H-14, I-1): the
/// skill's real `tabs-ctl` script (`resources/skills/tabs`, the one copy the
/// Electron app ships too) run under Node against the running app's socket,
/// from a pane the app made.
extension LaunchedApp {
    struct CtlResult {
        var response: JSONValue
        var exitCode: Int32
        var elapsed: Duration
    }

    /// The skill's script, from the repository root above this test's source.
    static var tabsCtlScript: URL {
        URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appending(path: "resources/skills/tabs/scripts/tabs-ctl")
    }

    static let nodeIsInstalled: Bool = {
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/env")
        process.arguments = ["node", "--version"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return false }
        process.waitUntilExit()
        return process.terminationStatus == 0
    }()

    /// Runs `tabs-ctl <arguments>` as the shell in `pane` would (`TABS_PANE_ID`,
    /// `TABS_CONTROL_SOCKET`), parses the one line it prints, and reports its exit code.
    func tabsCtl(_ arguments: [String], from pane: String?, cwd: URL? = nil) async throws -> CtlResult {
        let socket = socketPath
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global().async {
                continuation.resume(
                    with: Result {
                        let process = Process()
                        process.executableURL = URL(filePath: "/usr/bin/env")
                        process.arguments = ["node", Self.tabsCtlScript.path] + arguments
                        var environment = ProcessInfo.processInfo.environment
                        environment["TABS_PANE_ID"] = pane
                        environment["TABS_CONTROL_SOCKET"] = pane == nil ? nil : socket
                        process.environment = environment
                        if let cwd { process.currentDirectoryURL = cwd }
                        let output = Pipe()
                        process.standardOutput = output
                        process.standardError = FileHandle.nullDevice
                        let clock = ContinuousClock()
                        let started = clock.now
                        try process.run()
                        // A script waiting on a socket that never closes is the failure this guards.
                        let watchdog = DispatchWorkItem { process.terminate() }
                        DispatchQueue.global().asyncAfter(deadline: .now() + 20, execute: watchdog)
                        let data = output.fileHandleForReading.readDataToEndOfFile()
                        process.waitUntilExit()
                        watchdog.cancel()
                        let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                        let response = try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
                        return CtlResult(response: response, exitCode: process.terminationStatus, elapsed: started.duration(to: clock.now))
                    })
            }
        }
    }
}

@Suite(.serialized, .sharedApp, .timeLimit(.minutes(2)), .enabled(if: LaunchedApp.nodeIsInstalled, "tabs-ctl runs under Node"))
struct ControlPlaneEndToEndTests {
    /// A pane to run tabs-ctl "in": a terminal, as in a real session.
    private func caller(_ app: LaunchedApp) async throws -> String {
        let pane = try await app.activePane()
        try await app.call("tabs.test.click", ["create": "terminal", "paneId": .string(pane)])
        return pane
    }

    @Test func tabsCtlGetsItsAnswerWithoutWaitingForTheServerToClose() async throws {
        let app = try await SharedApp.fresh()
        let pane = try await caller(app)
        let ping = try await app.tabsCtl(["ping"], from: pane)
        #expect(ping.response == ["ok": true])
        #expect(ping.exitCode == 0)
        #expect(ping.elapsed < .seconds(10), "the native socket keeps a connection open: the script answers on the line, not on the close")
    }

    @Test func aSkillOutsideTabsOrInAPaneThatIsNotOneIsRefusedBeforeItCanDoAnything() async throws {
        let app = try await SharedApp.fresh()
        let outside = try await app.tabsCtl(["ping"], from: nil)
        #expect(outside.response["ok"] == false)
        #expect(outside.response["error"]?.stringValue?.contains("not running inside a Tabs terminal pane") == true)
        #expect(outside.exitCode == 1)
        let stranger = try await app.tabsCtl(["list-panes"], from: "not-a-pane")
        #expect(stranger.response == ["ok": false, "error": "not running inside a Tabs pane"])
        #expect(stranger.exitCode == 1)
    }

    @Test func capabilitiesAndDescribeServeCoresReference() async throws {
        let app = try await SharedApp.fresh()
        let pane = try await caller(app)
        let capabilities = try await app.tabsCtl(["capabilities"], from: pane)
        #expect(capabilities.exitCode == 0)
        let ids = capabilities.response["result"]?["capabilities"].flatMap { value -> [String]? in
            if case .array(let entries) = value { entries.compactMap { $0["id"]?.stringValue } } else { nil }
        }
        #expect(ids?.first == "core")

        let describe = try await app.tabsCtl(["describe", "--capability", "core"], from: pane)
        #expect(describe.response["result"]?["limits"] == ["maxBatchRequests": 50])
        let unknown = try await app.tabsCtl(["describe", "--capability", "nonexistent"], from: pane)
        #expect(unknown.exitCode == 1)
        #expect(unknown.response["error"] == "unknown capability \"nonexistent\" — run capabilities to list them")
    }

    @Test func aMalformedEnvelopeIsRefusedWithAValidationMessageBeforeAnythingIsDispatched() async throws {
        let app = try await SharedApp.fresh()
        let pane = try await caller(app)
        let unknown = try await app.tabsCtl(["not-a-real-command"], from: pane)
        #expect(unknown.response["error"]?.stringValue?.contains("unknown command") == true)
        #expect(unknown.exitCode == 1)
        let flag = try await app.tabsCtl(["activate-pane", "--panee", "x"], from: pane)
        #expect(flag.response["error"]?.stringValue?.contains("unknown flag --panee") == true)
        let missing = try await app.tabsCtl(["activate-pane"], from: pane)
        #expect(missing.response["error"] == "--pane is required")
    }

    @Test func aPaneTheCallerDoesNotOwnIsRefusedForEveryVerbNamingIt() async throws {
        let app = try await SharedApp.fresh()
        let pane = try await caller(app)
        for command in ["activate-pane", "close-pane", "pane-info"] {
            let result = try await app.tabsCtl([command, "--pane", pane], from: pane)
            #expect(result.response == ["ok": false, "error": "not the owner of this pane"], "\(command)")
            #expect(result.exitCode == 1)
        }
        let listed = try await app.tabsCtl(["list-panes"], from: pane)
        #expect(listed.response == ["ok": true, "result": ["panes": []]])
    }

    @Test func aBatchStopsAtTheFirstFailureAndTheExitCodeSaysSo() async throws {
        let app = try await SharedApp.fresh()
        let pane = try await caller(app)
        let ran = try await app.tabsCtl(["batch", "--requests", #"[{"type":"ping"},{"type":"listOwnedPanes"}]"#], from: pane)
        #expect(ran.exitCode == 0)
        #expect(ran.response["result"]?["steps"]?[1]?["result"] == ["panes": []])
        let failed = try await app.tabsCtl(["batch", "--requests", #"[{"type":"ping"},{"type":"nope"},{"type":"ping"}]"#], from: pane)
        #expect(failed.response["ok"] == true, "the batch ran")
        #expect(failed.response["result"]?["stoppedAt"] == 1)
        #expect(failed.response["result"]?["steps"]?[2] == ["type": "ping", "skipped": true])
        #expect(failed.exitCode == 1, "a failed step fails the exit code: `&&` means what it looks like")
    }

    @Test func aRequestWithNonASCIIComesBackIntact() async throws {
        let app = try await SharedApp.fresh()
        let pane = try await caller(app)
        // The refusal echoes the command back: multi-byte characters through the whole path.
        let result = try await app.tabsCtl(["nope-🙂-é"], from: pane)
        #expect(result.response["error"] == "unknown command: nope-🙂-é — run capabilities to list them")
    }
}
