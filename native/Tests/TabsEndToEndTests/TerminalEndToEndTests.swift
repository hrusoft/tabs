import Darwin
import Foundation
import TabsPluginSDK
import Testing

/// Terminals in the running app (docs/TERMINAL.md): real login shells behind
/// the real plugin bundle, read back over the control socket with the Debug
/// verb `terminal.test.state`. Every test here quits, relaunches or kills its
/// app, so each has its own.
extension LaunchedApp {
    func terminal(_ pane: String) async throws -> JSONValue { try await call("terminal.test.state", paneId: pane) }

    /// Polls a terminal until `condition` holds; records an issue on timeout.
    @discardableResult
    func terminal(
        _ pane: String, within seconds: Double = 20, sourceLocation: SourceLocation = #_sourceLocation,
        until condition: (JSONValue) -> Bool
    ) async throws -> JSONValue {
        let deadline = ContinuousClock.now + .seconds(seconds)
        var state = try await terminal(pane)
        while !condition(state) {
            guard ContinuousClock.now < deadline else {
                Issue.record("timed out; the terminal: \(state["buffer"]?.stringValue?.suffix(1500) ?? "")", sourceLocation: sourceLocation)
                return state
            }
            try await Task.sleep(for: .milliseconds(50))
            state = try await terminal(pane)
        }
        return state
    }

    /// The pane's shell pid once it runs and has printed its prompt.
    func shell(_ pane: String) async throws -> Int32 {
        let state = try await terminal(pane) {
            $0["pid"]?.intValue != nil && !($0["buffer"]?.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        return Int32(try #require(state["pid"]?.intValue))
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
}

/// A launch whose shells read no one's dotfiles: dash as the login shell,
/// and an empty home, so its `~/.profile` doesn't exist (the system's
/// `/etc/profile` sets no locale). What the shell has is what the app gave it.
private func isolatedShellEnvironment() throws -> [String: String] {
    ["SHELL": "/bin/dash", "HOME": try scratchDirectory()]
}

private func isAlive(_ pid: Int32) -> Bool { kill(pid, 0) == 0 }

private func waitGone(_ pids: [Int32], within seconds: Double = 5) async throws -> Bool {
    let deadline = ContinuousClock.now + .seconds(seconds)
    while pids.contains(where: isAlive), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(50)) }
    return !pids.contains(where: isAlive)
}

/// A fresh directory, by its real path (`/private/var/…`, as the kernel reports a cwd;
/// Foundation's `resolvingSymlinksInPath` would strip the `/private`).
private func scratchDirectory() throws -> String {
    let url = FileManager.default.temporaryDirectory.appending(path: "tabs-e2e-cwd-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return realPath(url.path)
}

private func realPath(_ path: String) -> String {
    guard let resolved = realpath(path, nil) else { return path }
    defer { free(resolved) }
    return String(cString: resolved)
}

@Suite(.serialized, .timeLimit(.minutes(3))) struct TerminalEndToEndTests {
    /// T-5, T-6: the shell starts with the terminal's identity over the inherited environment, the
    /// app's socket and its own pane id, and none of the app's launch settings.
    @Test func theShellIsToldWhatTerminalItIsIn() async throws {
        let app = try await LaunchedApp.launch()
        defer { app.terminate() }
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
        for setting in ["TABS_DATA_DIR", "TABS_LISTEN_SOCKET", "TABS_E2E_HIDDEN"] {
            #expect(environment[setting] == nil, "\(setting) is how the app was launched, not the shell's")
        }
        try await app.quit()
    }

    /// T-5: a locale the app has is passed on as is (a shell reading no dotfiles, so nothing else
    /// could have set it).
    @Test func aLocaleTheAppHasIsPassedOnAsIs() async throws {
        let app = try await LaunchedApp.launch(
            removingEnvironment: ["LC_ALL", "LC_CTYPE"],
            addingEnvironment: try isolatedShellEnvironment().merging(["LANG": "fr_FR.UTF-8"]) { $1 })
        defer { app.terminate() }
        let (pane, _) = try await app.newTerminal()
        let environment = try await app.environment(of: pane)
        #expect(environment["LANG"] == "fr_FR.UTF-8")
        try await app.quit()
    }

    /// T-5 (decided): an app launched with no locale at all gives its shells a UTF-8 LANG. The
    /// shell reads no dotfiles (dash, an empty home), which could otherwise set one and hide the
    /// plugin's.
    @Test func aShellGetsAUTF8LocaleWhenTheAppHasNone() async throws {
        let app = try await LaunchedApp.launch(
            removingEnvironment: ["LANG", "LC_ALL", "LC_CTYPE"], addingEnvironment: try isolatedShellEnvironment())
        defer { app.terminate() }
        let (pane, _) = try await app.newTerminal()
        let environment = try await app.environment(of: pane)
        #expect(environment["SHELL"] == "/bin/dash")
        let lang = try #require(environment["LANG"], "set for the shell")
        #expect(lang.hasSuffix(".UTF-8"), "\(lang)")
        #expect(FileManager.default.fileExists(atPath: "/usr/share/locale/\(lang)"), "a locale the system has: \(lang)")
        try await app.quit()
    }

    /// T-68: quitting ends every shell, not only closed panes'.
    @Test func quittingEndsEveryShell() async throws {
        let app = try await LaunchedApp.launch()
        defer { app.terminate() }
        let (first, pid) = try await app.newTerminal()
        #expect(try await app.call("tabs.test.press", ["key": "t", "modifiers": ["command"]]) == true, "⌘T: another terminal")
        let second = try await app.activePane()
        #expect(second != first)
        let otherPid = try await app.shell(second)
        #expect(isAlive(pid) && isAlive(otherPid))
        try await app.quit()
        #expect(try await waitGone([pid, otherPid]), "no shell outlives the app")
    }

    /// T-69: a crash (SIGKILL: no quit at all) leaves no shell running either.
    @Test func aCrashLeavesNoShellRunning() async throws {
        let app = try await LaunchedApp.launch()
        defer { app.terminate() }
        let (_, pid) = try await app.newTerminal()
        app.terminate()
        #expect(try await waitGone([pid]), "the pty hung up with the app")
    }

    /// T-105, T-106: a relaunch restores the terminal on a fresh shell, in the directory it was
    /// in (after a `cd`), and working.
    @Test func aRelaunchRestoresAFreshShellWhereTheOldOneWas() async throws {
        let directory = try scratchDirectory()
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let app = try await LaunchedApp.launch()
        defer { app.terminate() }
        let (pane, pid) = try await app.newTerminal()
        try await app.run("cd '\(directory)'", in: pane)
        try await app.terminal(pane) { $0["cwd"]?.stringValue == directory }

        try await app.relaunch()

        let restored = try await app.shell(pane)
        #expect(restored != pid, "a new shell")
        #expect(!isAlive(pid))
        let state = try await app.terminal(pane) { $0["cwd"]?.stringValue == directory }
        #expect(state["cwd"]?.stringValue == directory)
        let pwd = try await app.run("pwd", in: pane, mark: 60)
        let output = pwd["buffer"]?.stringValue ?? ""
        #expect(output.contains("\n\(directory)\n"), "and it answers")
        try await app.quit()
    }

    /// T-106 (decided): the live directory is saved as it changes, so even a crash restores it.
    @Test func aCrashStillRestoresTheLiveDirectory() async throws {
        let directory = try scratchDirectory()
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let app = try await LaunchedApp.launch()
        defer { app.terminate() }
        let (pane, _) = try await app.newTerminal()
        try await app.run("cd '\(directory)'", in: pane)
        try await app.terminal(pane) { $0["cwd"]?.stringValue == directory }
        try await Task.sleep(for: .seconds(1))  // past the save debounce
        app.terminate()

        let relaunched = try await LaunchedApp.launch(dataDirectory: app.dataDirectory)
        defer { relaunched.terminate() }
        _ = try await relaunched.shell(pane)
        let state = try await relaunched.terminal(pane) { $0["cwd"]?.stringValue == directory }
        #expect(state["cwd"]?.stringValue == directory)
        try await relaunched.quit()
    }

    /// T-3 (decided): a saved directory deleted between launches starts the shell at home, not a
    /// dead pane.
    @Test func aDeletedSavedDirectoryStartsTheShellAtHome() async throws {
        let directory = try scratchDirectory()
        let app = try await LaunchedApp.launch()
        defer { app.terminate() }
        let (pane, _) = try await app.newTerminal()
        try await app.run("cd '\(directory)'", in: pane)
        try await app.terminal(pane) { $0["cwd"]?.stringValue == directory }
        try await app.quit()
        try FileManager.default.removeItem(atPath: directory)

        let relaunched = try await LaunchedApp.launch(dataDirectory: app.dataDirectory)
        defer { relaunched.terminate() }
        _ = try await relaunched.shell(pane)
        let home = realPath(NSHomeDirectory())
        let state = try await relaunched.terminal(pane) { $0["cwd"]?.stringValue == home }
        #expect(state["cwd"]?.stringValue == home)
        #expect(state["exited"] == false, "a working shell")
        try await relaunched.quit()
    }
}
