import Darwin
import Foundation
import TabsPluginSDK
import Testing

/// Terminals in the running app (docs/TERMINAL.md): real login shells behind
/// the real plugin bundle, on the tests' own startup files (`TestShell`), read
/// back over the control socket with the Debug verb `terminal.test.state`.
/// A test that quits, relaunches or kills its app has its own; the rest share
/// one (`.sharedApp`).
extension LaunchedApp {
    func terminal(_ pane: String) async throws -> JSONValue { try await call("terminal.test.state", paneId: pane) }

    /// Polls a terminal until `condition` holds; records an issue on timeout, and a warning (which
    /// fails nothing) when it held only after more than 3 s.
    @discardableResult
    func terminal(
        _ pane: String, within seconds: Double = 10, sourceLocation: SourceLocation = #_sourceLocation,
        until condition: (JSONValue) -> Bool
    ) async throws -> JSONValue {
        let clock = ContinuousClock()
        let start = clock.now
        var state = try await terminal(pane)
        while !condition(state) {
            guard clock.now < start + .seconds(seconds) else {
                Issue.record("timed out; the terminal: \(state["buffer"]?.stringValue?.suffix(1500) ?? "")", sourceLocation: sourceLocation)
                return state
            }
            try await Task.sleep(for: .milliseconds(20))
            state = try await terminal(pane)
        }
        let waited = start.duration(to: clock.now)
        if waited > .seconds(3) {
            let shown = String(format: "%.1f s", Double(waited.components.seconds) + Double(waited.components.attoseconds) / 1e18)
            Issue.record("slow: held after \(shown) of its \(Int(seconds)) s", severity: .warning, sourceLocation: sourceLocation)
        }
        return state
    }

    /// The pane's shell pid once it runs and has printed its prompt.
    func shell(_ pane: String, sourceLocation: SourceLocation = #_sourceLocation) async throws -> Int32 {
        let state = try await terminal(pane, sourceLocation: sourceLocation) {
            $0["pid"]?.intValue != nil && !($0["buffer"]?.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        return Int32(try #require(state["pid"]?.intValue, sourceLocation: sourceLocation))
    }

    /// A new terminal in the active (empty) pane: its id and shell.
    func newTerminal() async throws -> (pane: String, pid: Int32) {
        let pane = try await activePane()
        try await call("tabs.test.click", ["create": "terminal", "paneId": .string(pane)])
        return (pane, try await shell(pane))
    }

    /// Types `command; echo MARK-$((n+1))` into the focused terminal `pane` and waits for `MARK-<n+1>`.
    @discardableResult
    func run(_ command: String, in pane: String, mark: Int = 41) async throws -> JSONValue {
        try await call("tabs.test.type", ["text": .string("\(command); echo MARK-$((\(mark)+1))\n")])
        return try await terminal(pane) { ($0["buffer"]?.stringValue ?? "").contains("MARK-\(mark + 1)") }
    }
}

extension LaunchedApp {
    /// The shell's environment, as `env` prints it at its prompt: `ENV:`-prefixed lines, so the
    /// echoed command line never matches. (macOS no longer hands out another process's starting
    /// environment through `KERN_PROCARGS2`.)
    func environment(of pane: String, mark: Int = 90) async throws -> [String: String] {
        let state = try await run("env | sed 's/^/ENV:/'", in: pane, mark: mark)
        var environment: [String: String] = [:]
        for line in (state["buffer"]?.stringValue ?? "").split(separator: "\n") where line.hasPrefix("ENV:") {
            let entry = line.dropFirst(4)
            guard let separator = entry.firstIndex(of: "=") else { continue }
            environment[String(entry[..<separator])] = String(entry[entry.index(after: separator)...])
        }
        return environment
    }

    /// Whether the layout on disk (`layout.json`, as the app last saved it) holds `text` as a value.
    func savedLayoutHolds(_ text: String) -> Bool {
        guard let data = try? Data(contentsOf: dataDirectory.appending(path: "layout.json")),
            let layout = try? JSONDecoder().decode(JSONValue.self, from: data)
        else { return false }
        func holds(_ value: JSONValue) -> Bool {
            switch value {
            case .string(let string): string == text
            case .array(let values): values.contains(where: holds)
            case .object(let object): object.values.contains(where: holds)
            default: false
            }
        }
        return holds(layout)
    }
}

private func isAlive(_ pid: Int32) -> Bool { kill(pid, 0) == 0 }

private func waitGone(_ pids: [Int32], within seconds: Double = 5) async throws -> Bool {
    let deadline = ContinuousClock.now + .seconds(seconds)
    while pids.contains(where: isAlive), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
    return !pids.contains(where: isAlive)
}

/// A fresh directory, by its real path (`/private/var/…`, as the kernel reports a cwd;
/// Foundation's `resolvingSymlinksInPath` would strip the `/private`).
private func scratchDirectory() throws -> String {
    realPath(TestTemporary.directory("e2e-cwd").path)
}

private func realPath(_ path: String) -> String {
    guard let resolved = realpath(path, nil) else { return path }
    defer { free(resolved) }
    return String(cString: resolved)
}

/// Terminals in one app shared by the suite, reset before each test.
@Suite(.serialized, .sharedApp, .timeLimit(.minutes(2))) struct TerminalSharedAppEndToEndTests {
    /// T-5, T-6: the shell starts with the terminal's identity over the inherited environment, the
    /// app's socket and its own pane id, and none of the app's launch settings. The plugin's one check
    /// that the built bundle is wired into the launched app: what each piece of the environment is made
    /// of is the unit tier's (`EnvironmentTests`, `PaneRuntimeTests`); that the app hands it the version
    /// of the bundle it shipped, its own socket and the launch it was given, only a launch shows.
    @Test func theShellIsToldWhatTerminalItIsIn() async throws {
        let app = try await SharedApp.fresh()
        let (pane, _) = try await app.newTerminal()
        let environment = try await app.environment(of: pane)
        let info = try #require(NSDictionary(contentsOf: LaunchedApp.appURL.appending(path: "Contents/Info.plist")))
        #expect(environment["TERM"] == "xterm-256color")
        #expect(environment["COLORTERM"] == "truecolor")
        #expect(environment["TERM_PROGRAM"] == "Tabs")
        #expect(environment["TERM_PROGRAM_VERSION"] == info["CFBundleShortVersionString"] as? String)
        #expect(environment["TERM_PROGRAM_VERSION"]?.isEmpty == false)
        #expect(environment["TABS_PANE_ID"] == pane)
        #expect(environment["TABS_CONTROL_SOCKET"] == app.socketPath)
        for setting in ["TABS_DATA_DIR", "TABS_LISTEN_SOCKET", "TABS_E2E_HIDDEN", "TABS_E2E_PLUGINS"] {
            #expect(environment[setting] == nil, "\(setting) is how the app was launched, not the shell's")
        }
        #expect(environment["TABS_TEST_ZPROFILE"] == "1", "a login shell on the tests' own startup files (TestShell)")
    }
}

/// Terminals across the app's own lifecycle, each test with an app of its own (it quits, relaunches or
/// kills it): what no lower tier can show, shells outliving neither a quit nor a crash. Independent of
/// each other: they may run at once.
@Suite(.timeLimit(.minutes(3))) struct TerminalEndToEndTests {
    /// T-68, T-105, T-106, T-107: quitting ends every shell, a background tab's too; a relaunch
    /// restores the terminals, each on a fresh shell — the background tab's started at launch —
    /// the active one in the directory it was in (after a `cd`), and working.
    @Test func aRelaunchRestoresAFreshShellWhereTheOldOneWas() async throws {
        let directory = try scratchDirectory()
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let app = try await LaunchedApp.launch()
        defer { app.terminate() }
        let (background, backgroundPid) = try await app.newTerminal()
        #expect(try await app.call("tabs.test.press", ["key": "t", "modifiers": ["command"]]) == true, "⌘T: another terminal")
        let pane = try await app.activePane()
        #expect(pane != background)
        let pid = try await app.shell(pane)
        try await app.run("cd '\(directory)'", in: pane)
        try await app.terminal(pane) { $0["cwd"]?.stringValue == directory }

        try await app.relaunch()
        #expect(try await waitGone([pid, backgroundPid]), "no shell outlives the app, the background tab's included")

        let restored = try await app.shell(pane)
        #expect(restored != pid, "a new shell")
        let state = try await app.terminal(pane) { $0["cwd"]?.stringValue == directory }
        #expect(state["cwd"]?.stringValue == directory)
        let pwd = try await app.run("pwd", in: pane, mark: 60)
        let output = pwd["buffer"]?.stringValue ?? ""
        #expect(output.contains("\n\(directory)\n"), "and it answers")
        #expect(try await app.shell(background) != backgroundPid, "the background tab's shell is running too, a new one")
        try await app.quit()
    }

    /// T-69, T-106 (decided): a crash (SIGKILL: no quit at all) leaves no shell running — the pty
    /// hangs up with the app — and the live directory, saved as it changed, is restored.
    @Test func aCrashStillRestoresTheLiveDirectory() async throws {
        let directory = try scratchDirectory()
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let app = try await LaunchedApp.launch()
        defer { app.terminate() }
        let (pane, pid) = try await app.newTerminal()
        try await app.run("cd '\(directory)'", in: pane)
        try await app.terminal(pane) { $0["cwd"]?.stringValue == directory }
        // Past the save's debounce: on disk before the crash.
        let deadline = ContinuousClock.now + .seconds(10)
        while !app.savedLayoutHolds(directory), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        #expect(app.savedLayoutHolds(directory), "saved as it changed")
        app.terminate()
        #expect(try await waitGone([pid]), "the pty hung up with the app")

        let relaunched = try await LaunchedApp.launch(dataDirectory: app.dataDirectory)
        defer { relaunched.terminate() }
        _ = try await relaunched.shell(pane)
        let state = try await relaunched.terminal(pane) { $0["cwd"]?.stringValue == directory }
        #expect(state["cwd"]?.stringValue == directory)
        try await relaunched.quit()
    }
}
