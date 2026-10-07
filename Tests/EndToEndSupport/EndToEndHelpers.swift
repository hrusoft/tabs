import Darwin
import Foundation
import TabsPluginSDK
import Testing

/// Where a test finds the frontmost window and its active pane.
extension LaunchedApp {
    func frontmost() async throws -> JSONValue {
        guard case .array(let windows) = try await call("tabs.test.windows"),
            let window = windows.first(where: { $0["frontmost"] == true })
        else { throw Failure(description: "no frontmost window") }
        return window
    }

    func activePane() async throws -> String {
        guard let id = try await frontmost()["activePane"]?.stringValue else { throw Failure(description: "no active pane") }
        return id
    }

    var workspaceWindowCount: Int {
        get async throws {
            guard case .array(let windows) = try await call("tabs.test.windows") else { return 0 }
            return windows.count
        }
    }
}

/// The `fixture-text` test plugin's panes (`LaunchedApp.fixturesDirectory`): a
/// pane no shipped plugin owns — a text view whose config is its text, with
/// Edit ▸ Insert Marker (⇧⌘D) for it.
extension LaunchedApp {
    /// Fills an empty pane (the active one by default) with a fixture-text pane, as its creation button does; returns its id.
    @discardableResult
    func newFixturePane(in pane: String? = nil) async throws -> String {
        let target: String
        if let pane { target = pane } else { target = try await activePane() }
        try await call("tabs.test.click", ["create": "fixture-text", "paneId": .string(target)])
        return target
    }

    /// A fixture-text pane's text, as core would save it now.
    func text(of pane: String) async throws -> String? {
        try await call("tabs.test.paneConfig", ["paneId": .string(pane)])["text"]?.stringValue
    }
}

/// The agent's side of the control plane (docs/BROWSER.md H-14, I-1): the
/// built app's own `tabs-ctl` (the skill's `scripts/tabs-ctl`, which runs
/// `Contents/Helpers/tabs-ctl`) against the running app's socket, from a pane
/// the app made.
extension LaunchedApp {
    struct CtlResult {
        var response: JSONValue
        var exitCode: Int32
        var elapsed: Duration
    }

    /// The skill's `tabs-ctl` in the app under test, as an agent's shell runs it.
    static var tabsCtlScript: URL {
        appURL.appending(path: "Contents/Resources/skills/tabs/scripts/tabs-ctl")
    }

    /// Runs `tabs-ctl <arguments>` as the shell in `pane` would (`TABS_PANE_ID`,
    /// `TABS_CONTROL_SOCKET`), parses the one line it prints, and reports its exit code.
    func tabsCtl(_ arguments: [String], from pane: String?) async throws -> CtlResult {
        let socket = socketPath
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global().async {
                continuation.resume(
                    with: Result {
                        let process = Process()
                        process.executableURL = Self.tabsCtlScript
                        process.arguments = arguments
                        var environment = ProcessInfo.processInfo.environment
                        environment["TABS_PANE_ID"] = pane
                        environment["TABS_CONTROL_SOCKET"] = pane == nil ? nil : socket
                        process.environment = environment
                        let output = Pipe()
                        process.standardOutput = output
                        process.standardError = FileHandle.nullDevice
                        let clock = ContinuousClock()
                        let started = clock.now
                        try process.run()
                        // A relay waiting on a socket that never closes is the failure this guards.
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
