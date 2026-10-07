import AppKit
import Darwin
import Foundation
import TabsPluginSDK
import Testing

/// The app as a user runs it — a separate process with real plugin bundles
/// (its own, and the `fixture-text` test plugin for a pane to work with),
/// driven only over the control socket — shared by the whole suite and reset
/// to a fresh launch's state before each test.
///
/// Only what needs the launched process is here: the hidden mode a hosted test
/// never takes (its app starts nothing of its own, `AppDelegate.isHostingTests`)
/// and the reset the shared app stands on. What the app does with a request, a
/// shortcut or a setting is the lower tiers'.
@Suite(.serialized, .sharedApp, .timeLimit(.minutes(2))) struct EndToEndTests {
    /// Every window the app builds is built when asked for and never shown: the
    /// workspace window, Settings, Plugins, About and the Caffeinate dialog.
    @Test func hiddenModeShowsNoWindowNotEvenSettingsPluginsAboutOrCaffeinate() async throws {  // ABOUT.md A-9, CAFFEINATE.md D-15
        let app = try await SharedApp.fresh()
        for title in ["Settings…", "Plugins…", "About Tabs", "Caffeinate…"] {
            try await app.call("tabs.test.menu", ["title": .string(title)])
        }
        #expect(try await app.call("tabs.test.about")["title"] == "About Tabs", "About was built")
        #expect(try await app.caffeinate()["dialog"]?["title"] == "Caffeinate", "the dialog was built")
        #expect(try await app.call("tabs.test.shownWindows") == [])
    }

    @Test func hiddenModeIsABackgroundProcessOutOfTheDock() async throws {
        let app = try await SharedApp.fresh()
        let pid = try #require(try await app.call("tabs.info")["pid"]?.intValue)
        let running = try #require(NSRunningApplication(processIdentifier: pid_t(pid)))
        #expect(running.activationPolicy == .prohibited, "no Dock tile, no menu bar, never frontmost")
    }

    @Test func aResetLeavesNothingOfTheLastTestBehind() async throws {
        let app = try await SharedApp.fresh()
        let pane = try await app.newFixturePane()
        try await app.call("tabs.test.type", ["text": "from-the-previous-test"])
        let typed = ContinuousClock.now
        #expect(try await app.text(of: pane) == "from-the-previous-test")
        // Reset while that change's save is still pending (written 400 ms after
        // the burst's first change, so by `typed` + 400 ms), then watch
        // layout.json until a margin past that: an old workspace kept alive by
        // the reset would write it in between — what a crash then would restore.
        try await Task.sleep(until: typed + .milliseconds(150))
        try await app.call("tabs.test.reset")
        let file = app.dataDirectory.appending(path: "layout.json")
        let deadline = typed + .milliseconds(400 + 200)
        repeat {
            let layout = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
            #expect(!layout.contains("from-the-previous-test"), "the old workspace saved over the new one")
            if layout.contains("from-the-previous-test") { break }
            try await Task.sleep(for: .milliseconds(20))
        } while ContinuousClock.now < deadline
    }

    @Test func aResetStartsFromAFreshLaunchsState() async throws {
        let app = try await SharedApp.fresh()
        try await app.newFixturePane()
        try await app.call("tabs.setShortcut", ["command": "fixture-text.insertMarker", "chord": "none"])
        try await app.call("tabs.test.reset")
        guard case .array(let windows) = try await app.call("tabs.test.windows"), windows.count == 1,
            case .array(let panes)? = windows[0]["panes"], panes.count == 1
        else {
            Issue.record("expected one window with one pane")
            return
        }
        #expect(panes[0]["type"] == .null, "an empty pane, as a first launch has")
        guard case .array(let rows) = try await app.call("tabs.shortcuts") else { return }
        #expect(rows.first { $0["command"] == "fixture-text.insertMarker" }?["chord"] == "shift+cmd+d", "the user's settings are gone")
        #expect(try await app.call("tabs.info")["pid"] != nil, "the same process, the same socket")
    }
}

/// Tests whose subject is the process itself — quitting, a crash, the per-boot
/// socket, the caffeinate it runs — each with an app of its own.
@Suite(.serialized, .timeLimit(.minutes(2))) struct RelaunchTests {
    /// The socket itself is `ControlServerTests`'; this is the app's quit path.
    @Test func quittingRemovesThisBootsSocketAndStopsCaffeinate() async throws {  // P-14
        let app = try await LaunchedApp.launch()
        defer { app.terminate() }
        let path = app.socketPath
        #expect(try await app.call("tabs.info")["controlSocket"]?.stringValue == path, "the socket of this boot")
        try await app.call("tabs.test.startCaffeinate")
        let caffeinate = try await app.caffeinatePid()
        try await app.quit()
        var status = stat()
        #expect(stat(path, &status) != 0, "removed at quit")
        #expect(await app.eventually(3) { !OSProcess.isAlive(caffeinate) }, "the real caffeinate stopped with it")
    }

    @Test func aCrashLosesOnlyWhatWasNotYetSavedAndCaffeinateStillEnds() async throws {  // P-15
        let app = try await LaunchedApp.launch()
        defer { app.terminate() }
        let pane = try await app.newFixturePane()
        try await app.call("tabs.test.type", ["text": "saved"])
        try await app.call("tabs.test.startCaffeinate")
        let caffeinate = try await app.caffeinatePid()
        let pid = try #require(try await app.call("tabs.info")["pid"]?.intValue)
        #expect(OSProcess.argv(of: caffeinate).hasSuffix("-w \(pid)"), "it watches the app")
        // The save debounce writes it on its own, 400 ms after the change.
        let layout = app.dataDirectory.appending(path: "layout.json")
        #expect(await app.eventually { ((try? String(contentsOf: layout, encoding: .utf8)) ?? "").contains(#""saved""#) })
        try await app.call("tabs.test.type", ["text": " and not"])
        app.terminate()  // SIGKILL: no quit path at all, no final save
        let relaunched = try await LaunchedApp.launch(dataDirectory: app.dataDirectory)
        defer { relaunched.terminate() }
        #expect(try await relaunched.text(of: pane) == "saved")
        #expect(await app.eventually { !OSProcess.isAlive(caffeinate) }, "ended through -w, not the quit path")
        try await relaunched.quit()
    }
}
