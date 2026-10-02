import Darwin
import Foundation
import TabsPluginSDK
import Testing

/// Caffeinate in the running app against the real `/usr/bin/caffeinate`
/// (docs/CAFFEINATE.md), ported from `e2e/caffeinate.spec.ts`. "Really running"
/// is checked by the managed process's own pid, never by name: this Mac may
/// well have an unrelated caffeinate running.
extension LaunchedApp {
    func caffeinate() async throws -> JSONValue { try await call("tabs.test.caffeinate") }

    func caffeinatePid() async throws -> Int32 {
        guard let pid = try await caffeinate()["pid"]?.intValue, pid > 0 else { throw Failure(description: "no caffeinate running") }
        return Int32(pid)
    }

    /// Polls until `condition` holds.
    func eventually(_ seconds: Double = 5, _ condition: () async throws -> Bool) async rethrows -> Bool {
        let deadline = ContinuousClock.now + .seconds(seconds)
        while ContinuousClock.now < deadline {
            if try await condition() { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return try await condition()
    }
}

/// The OS's view of a pid: alive, and its argv.
enum OSProcess {
    static func isAlive(_ pid: Int32) -> Bool { kill(pid, 0) == 0 }

    static func argv(of pid: Int32) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-o", "args=", "-p", String(pid)]
        let pipe = Pipe()
        process.standardOutput = pipe
        try? process.run()
        process.waitUntilExit()
        return String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).trimmingCharacters(
            in: .whitespacesAndNewlines)
    }
}

@Suite(.serialized, .sharedApp, .timeLimit(.minutes(2))) struct CaffeinateEndToEndTests {
    @Test func theMenuOpensTheDialogAndStartLaunchesTheRealProcess() async throws {  // M-3, P-8, D-5
        let app = try await SharedApp.fresh()
        #expect(try await app.caffeinate()["running"] == false)
        try await app.call("tabs.test.menu", ["title": "Caffeinate…"])
        let dialog = try await app.caffeinate()["dialog"]
        #expect(dialog?["title"] == "Caffeinate")
        #expect(dialog?["flags"] == ["display": false, "idle": true, "disk": false, "system": true, "active": false], "the defaults")
        #expect(try await app.caffeinate()["running"] == false, "the menu starts nothing by itself")

        try await app.call("tabs.test.caffeinateDialog", ["display": true])
        try await app.call("tabs.test.click", ["window": "caffeinate", "identifier": "caffeinate-start-button"])
        #expect(try await app.caffeinate()["dialog"] == .null, "Start closes it")
        let pid = try await app.caffeinatePid()
        #expect(OSProcess.isAlive(pid))
        // -i and -s from the defaults, -d from the switch just turned on; never -m, -u or -t.
        let argv = OSProcess.argv(of: pid)
        for flag in ["-d", "-i", "-s", "-w"] { #expect(argv.contains(" \(flag)"), "\(argv)") }
        for flag in ["-m", "-u", "-t"] { #expect(!argv.contains(" \(flag)"), "\(argv)") }

        try await app.call("tabs.test.menu", ["title": "Decaf"])
        #expect(await app.eventually { !OSProcess.isAlive(pid) })
    }

    @Test func aTimerTypedIntoTheDialogReachesTheRealProcessAsT() async throws {  // D-5
        let app = try await SharedApp.fresh()
        try await app.call("tabs.test.menu", ["title": "Caffeinate…"])
        try await app.call("tabs.test.caffeinateDialog", ["timer": "1"])
        try await app.call("tabs.test.click", ["window": "caffeinate", "identifier": "caffeinate-start-button"])
        let pid = try await app.caffeinatePid()
        #expect(OSProcess.argv(of: pid).contains("-t 60"))
        try await app.call("tabs.test.menu", ["title": "Decaf"])
        #expect(await app.eventually { !OSProcess.isAlive(pid) })
    }

    @Test func decafFromTheMenuStopsTheRealProcess() async throws {  // M-2, M-4
        let app = try await SharedApp.fresh()
        try await app.call("tabs.test.startCaffeinate")
        let pid = try await app.caffeinatePid()
        await #expect(throws: LaunchedApp.Failure.self, "no Caffeinate… while running") {
            try await app.call("tabs.test.menu", ["title": "Caffeinate…"])
        }
        try await app.call("tabs.test.menu", ["title": "Decaf"])
        #expect(await app.eventually { !OSProcess.isAlive(pid) })
        #expect(try await app.eventually { try await app.caffeinate()["running"] == false })
        #expect(try await app.caffeinate()["dialog"] == .null, "Decaf opens no dialog")
        await #expect(throws: LaunchedApp.Failure.self, "Decaf is gone again") { try await app.call("tabs.test.menu", ["title": "Decaf"]) }
    }

    @Test func theCupStopsTheRealProcess() async throws {  // B-2
        let app = try await SharedApp.fresh()
        await #expect(throws: LaunchedApp.Failure.self, "no cup while nothing runs") {
            try await app.call("tabs.test.click", ["identifier": "caffeinate-decaf-button"])
        }
        try await app.call("tabs.test.startCaffeinate")
        let pid = try await app.caffeinatePid()
        try await app.call("tabs.test.click", ["identifier": "caffeinate-decaf-button"])
        #expect(await app.eventually { !OSProcess.isAlive(pid) })
        #expect(try await app.eventually { try await app.caffeinate()["running"] == false })
        await #expect(throws: LaunchedApp.Failure.self, "the cup is gone") {
            try await app.call("tabs.test.click", ["identifier": "caffeinate-decaf-button"])
        }
    }

    @Test func aTimerEndingTheProcessRevertsBothSurfaces() async throws {  // P-11
        let app = try await SharedApp.fresh()
        try await app.call("tabs.test.startCaffeinate", ["timerSeconds": 2])
        let pid = try await app.caffeinatePid()
        #expect(OSProcess.argv(of: pid).contains("-t 2"))
        #expect(await app.eventually(8) { !OSProcess.isAlive(pid) })
        #expect(try await app.eventually { try await app.caffeinate()["running"] == false })
        try await app.call("tabs.test.menu", ["title": "Caffeinate…"])  // back to its first label
        await #expect(throws: LaunchedApp.Failure.self) { try await app.call("tabs.test.click", ["identifier": "caffeinate-decaf-button"]) }
    }

    @Test func theDialogIsAWindowOfItsOwn() async throws {  // D-15, D-9, D-8
        let app = try await SharedApp.fresh()
        let workspaces = try await app.workspaceWindowCount
        try await app.call("tabs.test.menu", ["title": "Caffeinate…"])
        try await app.call("tabs.test.caffeinateDialog", ["timer": "7"])
        try await app.call("tabs.test.menu", ["title": "Caffeinate…"])
        let dialog = try #require(try await app.caffeinate()["dialog"])
        #expect(dialog["windows"] == 1, "one at a time")
        #expect(dialog["timer"] == "7", "asking again keeps what was typed")
        #expect(dialog["resizable"] == false)
        #expect(dialog["fullScreenAllowed"] == false)
        #expect(dialog["hasParent"] == false)
        #expect(dialog["visible"] == false, "hidden mode never shows or focuses it")
        #expect(try await app.workspaceWindowCount == workspaces, "not inside a workspace window, nor a new one")
        try await app.call("tabs.test.click", ["window": "caffeinate", "identifier": "caffeinate-cancel-button"])
        #expect(try await app.caffeinate() == ["running": false, "pid": .null, "dialog": .null], "Cancel starts nothing")
    }

    @Test func aResetStopsTheProcess() async throws {  // P-16, D-14
        let app = try await SharedApp.fresh()
        try await app.call("tabs.test.startCaffeinate")
        let pid = try await app.caffeinatePid()
        try await app.call("tabs.test.menu", ["title": "Decaf"])  // (stops it) then a fresh one…
        #expect(await app.eventually { !OSProcess.isAlive(pid) })
        try await app.call("tabs.test.startCaffeinate")
        let second = try await app.caffeinatePid()
        try await app.call("tabs.test.reset")
        #expect(await app.eventually { !OSProcess.isAlive(second) }, "nothing left running from the last test")
        #expect(try await app.caffeinate()["running"] == false)

        try await app.call("tabs.test.menu", ["title": "Caffeinate…"])
        try await app.call("tabs.test.reset")
        #expect(try await app.caffeinate()["dialog"] == .null, "an open dialog goes with the reset")
    }
}

/// Quitting and crashing, each with an app of its own.
@Suite(.serialized, .timeLimit(.minutes(2))) struct CaffeinateRelaunchTests {
    @Test func quittingStopsTheRealProcess() async throws {  // P-14
        let app = try await LaunchedApp.launch()
        defer { app.terminate() }
        try await app.call("tabs.test.startCaffeinate")
        let pid = try await app.caffeinatePid()
        try await app.quit()
        #expect(await app.eventually(3) { !OSProcess.isAlive(pid) })
    }

    @Test func aKilledAppStillEndsTheProcessThroughW() async throws {  // P-15
        let app = try await LaunchedApp.launch()
        defer { app.terminate() }
        try await app.call("tabs.test.startCaffeinate")
        let pid = try await app.caffeinatePid()
        let appPid = try #require(try await app.call("tabs.info")["pid"]?.intValue)
        #expect(OSProcess.argv(of: pid).hasSuffix("-w \(appPid)"))
        app.terminate()  // SIGKILL: no quit path at all
        #expect(await app.eventually(5) { !OSProcess.isAlive(pid) })
    }
}

/// Restore layout on relaunch across real relaunches (docs/RESTORE-LAYOUT.md),
/// ported from `e2e/layout.spec.ts`.
@Suite(.serialized, .timeLimit(.minutes(2))) struct RestoreLayoutRelaunchTests {
    private func paneCount(_ app: LaunchedApp) async throws -> Int {
        guard case .array(let windows) = try await app.call("tabs.test.windows"), case .array(let panes)? = windows.first?["panes"] else {
            return 0
        }
        return panes.count
    }

    @Test func offStartsTheNextLaunchFreshAndOnResumesSaving() async throws {  // R-4, R-5, R-7, R-9
        let app = try await LaunchedApp.launch()
        defer { app.terminate() }
        let layoutFile = app.dataDirectory.appending(path: "layout.json")
        try await app.call("tabs.test.paneSettings", ["set": ["persistLayoutOnExit": false]])
        try? FileManager.default.removeItem(at: layoutFile)
        #expect(try await app.call("tabs.test.press", ["key": "t", "modifiers": ["command"]]) == true)
        #expect(try await paneCount(app) == 2)

        try await app.relaunch()
        #expect(!FileManager.default.fileExists(atPath: layoutFile.path), "nothing was written, not even at quit")
        #expect(try await app.call("tabs.test.paneSettings")["persistLayoutOnExit"] == false, "the setting itself persisted")
        #expect(try await paneCount(app) == 1, "a fresh window")

        try await app.call("tabs.test.paneSettings", ["set": ["persistLayoutOnExit": true]])
        #expect(try await app.call("tabs.test.press", ["key": "t", "modifiers": ["command"]]) == true)
        #expect(try await paneCount(app) == 2)

        try await app.relaunch()
        #expect(try await paneCount(app) == 2, "turned back on, the layout is saved and restored")
        try await app.quit()
    }
}
