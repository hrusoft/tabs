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
}

/// The app as a user runs it — a separate process with real plugin bundles,
/// driven only over the control socket — shared by the whole suite and reset
/// to a fresh launch's state before each test.
@Suite(.serialized, .sharedApp, .timeLimit(.minutes(2))) struct EndToEndTests {
    @Test func aPluginShortcutRunsThroughTheRealMenu() async throws {
        let app = try await SharedApp.fresh()
        let (pane, _) = try await app.newTerminal()
        try await app.run("echo hello", in: pane, mark: 50)
        #expect(try await app.call("tabs.test.press", ["key": "k", "modifiers": ["command"]]) == true, "⌘K is Edit ▸ Clear Buffer")
        let cleared = try await app.terminal(pane) { !($0["buffer"]?.stringValue ?? "").contains("MARK-51") }
        let buffer = cleared["buffer"]?.stringValue ?? ""
        #expect(!buffer.contains("MARK-51"), "the scrollback went with the screen")
    }

    @Test func everyBundledPluginIsActiveInTheRunningApp() async throws {
        let app = try await SharedApp.fresh()
        guard case .array(let plugins)? = try await app.call("tabs.plugins")["plugins"] else {
            Issue.record("no plugins")
            return
        }
        #expect(!plugins.isEmpty)
        for plugin in plugins { #expect(plugin["state"] == "active", "\(plugin)") }
    }

    @Test func badRequestsAreAnsweredAndTheConnectionLivesOn() async throws {
        let app = try await SharedApp.fresh()
        #expect(try await app.raw("not json")["error"] == "request is not valid JSON")
        #expect(try await app.raw(#"{"command":"no.such.verb"}"#)["ok"] == false)
        await #expect(throws: LaunchedApp.Failure.self) { try await app.call("tabs.test.click", ["identifier": "no-such-control"]) }
        #expect(try await app.call("tabs.info")["pid"] != nil, "same connection, still answering")
    }

    @Test func clientsHangingUpBeforeTheirAnswerDoNotKillTheApp() async throws {
        let app = try await SharedApp.fresh()
        for attempt in 0..<20 {
            let client: ControlClient
            do {
                client = try ControlClient(path: app.socketPath)
            } catch {
                Issue.record("connect #\(attempt) failed (app running: \(app.isRunning)): \(error) \(app.errorOutput())")
                return
            }
            client.sendRaw(Array("{\"command\":\"tabs.plugins\"}\n".utf8))
        }  // each client closes at once; the app writes its answers into broken pipes
        try await Task.sleep(for: .milliseconds(500))
        #expect(app.isRunning, "a broken pipe is an EPIPE, not a SIGPIPE: \(app.errorOutput())")
        #expect(try await app.call("tabs.info")["pid"] != nil)
    }

    @Test func aResetLeavesNothingOfTheLastTestBehind() async throws {
        let app = try await SharedApp.fresh()
        let server = try await FixtureServer.start()
        defer { server.stop() }
        server.page("/from-the-previous-test", title: "Previous")
        let pane = try await app.activePane()
        try await app.call("tabs.test.click", ["create": "browser", "paneId": .string(pane)])
        try await app.call("browser.test.load", ["url": .string(server.url("/from-the-previous-test"))], paneId: pane)
        try await app.browser(pane) { $0["configURL"] == .string(server.url("/from-the-previous-test")) }
        // Reset while that change's save is still pending (the delay is 400 ms),
        // then watch layout.json: an old workspace kept alive by the reset
        // would write it in between — what a crash then would restore.
        try await Task.sleep(for: .milliseconds(300))
        try await app.call("tabs.test.reset")
        let file = app.dataDirectory.appending(path: "layout.json")
        let deadline = ContinuousClock.now + .seconds(1)
        while ContinuousClock.now < deadline {
            let layout = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
            #expect(!layout.contains("from-the-previous-test"), "the old workspace saved over the new one")
            if layout.contains("from-the-previous-test") { break }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    @Test func aResetStartsFromAFreshLaunchsState() async throws {
        let app = try await SharedApp.fresh()
        let pane = try await app.activePane()
        try await app.call("tabs.test.click", ["create": "browser", "paneId": .string(pane)])
        try await app.call("tabs.setShortcut", ["command": "terminal.clearBuffer", "chord": "none"])
        try await app.call("tabs.test.reset")
        guard case .array(let windows) = try await app.call("tabs.test.windows"), windows.count == 1,
            case .array(let panes)? = windows[0]["panes"], panes.count == 1
        else {
            Issue.record("expected one window with one pane")
            return
        }
        #expect(panes[0]["type"] == .null, "an empty pane, as a first launch has")
        guard case .array(let rows) = try await app.call("tabs.shortcuts") else { return }
        #expect(rows.first { $0["command"] == "terminal.clearBuffer" }?["chord"] == "cmd+k", "the user's settings are gone")
        #expect(try await app.call("tabs.info")["pid"] != nil, "the same process, the same socket")
    }
}

/// Tests whose subject is the process itself — quit and relaunch, a crash,
/// the per-boot socket — each with an app of its own.
@Suite(.serialized, .timeLimit(.minutes(2))) struct RelaunchTests {
    @Test func aShortcutTheUserRebindsWorksAtOnceAndAfterRelaunch() async throws {
        let app = try await LaunchedApp.launch()
        defer { app.terminate() }
        let pane = try await app.activePane()
        try await app.call("tabs.test.click", ["create": "terminal", "paneId": .string(pane)])
        let rebound = try await app.call("tabs.setShortcut", ["command": "terminal.clearBuffer", "chord": "shift+cmd+e"])
        #expect(rebound["chord"] == "shift+cmd+e")
        #expect(try await app.call("tabs.test.press", ["key": "e", "modifiers": ["command", "shift"]]) == true)

        try await app.relaunch()

        #expect(try await app.call("tabs.test.press", ["key": "k", "modifiers": ["command"]]) == false)
        #expect(try await app.call("tabs.test.press", ["key": "e", "modifiers": ["command", "shift"]]) == true)
        guard case .array(let rows) = try await app.call("tabs.shortcuts"),
            let row = rows.first(where: { $0["command"] == "terminal.clearBuffer" })
        else {
            Issue.record("no shortcut rows")
            return
        }
        #expect(row["chord"] == "shift+cmd+e")
        #expect(row["source"] == "user")
        try await app.quit()
    }

    @Test func theSocketIsPerBootOwnerOnlyAndGoneAfterQuit() async throws {
        let app = try await LaunchedApp.launch()
        defer { app.terminate() }
        let info = try await app.call("tabs.info")
        #expect(info["controlSocket"]?.stringValue == app.socketPath)
        var status = stat()
        #expect(stat(app.socketPath, &status) == 0)
        #expect(status.st_mode & 0o777 == 0o600)
        let path = app.socketPath
        try await app.quit()
        #expect(stat(path, &status) != 0, "removed at quit")
    }

    @Test func aCrashLosesOnlyWhatWasNotYetSaved() async throws {
        let server = try await FixtureServer.start()
        defer { server.stop() }
        server.page("/saved", title: "Saved")
        let app = try await LaunchedApp.launch()
        defer { app.terminate() }
        let pane = try await app.activePane()
        try await app.call("tabs.test.click", ["create": "browser", "paneId": .string(pane)])
        try await app.call("browser.test.load", ["url": .string(server.url("/saved"))], paneId: pane)
        try await app.browser(pane) { $0["configURL"] == .string(server.url("/saved")) }
        try await Task.sleep(for: .seconds(1))  // past the 400 ms save debounce
        app.terminate()  // SIGKILL: no quit, no final save
        let relaunched = try await LaunchedApp.launch(dataDirectory: app.dataDirectory)
        defer { relaunched.terminate() }
        let after = try await relaunched.browser(pane) { $0["title"] == "Saved" }
        #expect(after["url"] == .string(server.url("/saved")))
        try await relaunched.quit()
    }
}
