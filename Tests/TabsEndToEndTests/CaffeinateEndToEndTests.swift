import Darwin
import Foundation
import TabsPluginSDK
import Testing

/// Caffeinate in the running app against the real `/usr/bin/caffeinate`
/// (docs/CAFFEINATE.md). "Really running" is checked by the managed process's
/// own pid, never by name: this Mac may well have an unrelated caffeinate
/// running. Quitting and crashing with one running are `RelaunchTests`'; the
/// menu, the dialog, the cup and the process itself are the lower tiers'
/// (`UITests.Caffeinate`, `UITests.CaffeinateDialog`, `CaffeinateTests`).
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
            try? await Task.sleep(for: .milliseconds(10))
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

/// What the shared app's reset owes Caffeinate: no test inherits the last one's process or dialog.
@Suite(.serialized, .sharedApp, .timeLimit(.minutes(2))) struct CaffeinateEndToEndTests {
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
