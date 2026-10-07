import Darwin
import Foundation
import Testing

@testable import TabsCore

/// The flag → argv mapping (docs/CAFFEINATE.md P-1…P-7), and the managed
/// process against the real `/usr/bin/caffeinate` (P-8…P-14): what starts,
/// what stops, and what is announced when.
@MainActor
@Suite struct CaffeinateTests {
    let allOff = CaffeinateFlags()
    /// An arbitrary, obviously fake pid: only threaded through to `-w` verbatim.
    let pid: Int32 = 4242

    // MARK: argsFor

    @Test func everyFlagOffProducesOnlyTheMandatoryW() {  // P-1
        #expect(argsFor(allOff, watchPid: pid) == ["-w", "4242"])
    }

    @Test func eachBooleanFlagMapsToItsOwnSwitchAheadOfW() {  // P-2
        #expect(argsFor(CaffeinateFlags(preventDisplaySleep: true), watchPid: pid) == ["-d", "-w", "4242"])
        #expect(argsFor(CaffeinateFlags(preventIdleSleep: true), watchPid: pid) == ["-i", "-w", "4242"])
        #expect(argsFor(CaffeinateFlags(preventDiskSleep: true), watchPid: pid) == ["-m", "-w", "4242"])
        #expect(argsFor(CaffeinateFlags(preventSystemSleep: true), watchPid: pid) == ["-s", "-w", "4242"])
        #expect(argsFor(CaffeinateFlags(declareUserActive: true), watchPid: pid) == ["-u", "-w", "4242"])
    }

    @Test func flagsCombineInTheOrderTheDialogListsThem() {  // P-3
        let all = CaffeinateFlags(
            preventDisplaySleep: true, preventIdleSleep: true, preventDiskSleep: true, preventSystemSleep: true, declareUserActive: true)
        #expect(argsFor(all, watchPid: pid) == ["-d", "-i", "-m", "-s", "-u", "-w", "4242"])
    }

    @Test func aPositiveIntegerTimerBecomesT() {  // P-4
        #expect(argsFor(CaffeinateFlags(preventDisplaySleep: true, timerSeconds: 300), watchPid: pid) == ["-d", "-t", "300", "-w", "4242"])
    }

    @Test func anAbsentTimerOmitsT() {  // P-5
        #expect(!argsFor(allOff, watchPid: pid).contains("-t"))
    }

    @Test func aNonPositiveOrNonIntegerTimerIsTreatedAsAbsent() {  // P-6
        #expect(argsFor(CaffeinateFlags(timerSeconds: 0), watchPid: pid) == ["-w", "4242"])
        #expect(argsFor(CaffeinateFlags(timerSeconds: -5), watchPid: pid) == ["-w", "4242"])
        #expect(argsFor(CaffeinateFlags(timerSeconds: 1.5), watchPid: pid) == ["-w", "4242"])
    }

    @Test func wAlwaysCarriesTheWatchedPid() {  // P-7
        #expect(argsFor(allOff, watchPid: 1) == ["-w", "1"])
        #expect(argsFor(allOff, watchPid: 99999) == ["-w", "99999"])
    }

    @Test func theDialogsDefaultsKeepTheMacRunningButLetTheDisplaySleep() {
        #expect(CaffeinateFlags.dialogDefaults == CaffeinateFlags(preventIdleSleep: true, preventSystemSleep: true))
    }

    // MARK: The process

    /// Records every announcement.
    @MainActor final class Heard {
        var states: [Bool] = []
    }

    /// Polls until `condition` holds (the exit arrives on the main actor after the process ends).
    private func eventually(_ seconds: Double = 5, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition() {
            if Date() > deadline { return false }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return true
    }

    private static func isAlive(_ pid: Int32) -> Bool { kill(pid, 0) == 0 }

    /// The real process's own argv, from ps.
    private static func argv(of pid: Int32) -> String {
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

    @Test func startRunsTheRealProcessWithTheFlags() async throws {  // P-8
        let caffeinate = Caffeinate()
        let heard = Heard()
        let subscription = caffeinate.observe { heard.states.append($0) }
        defer { subscription.cancel() }
        caffeinate.start(CaffeinateFlags(preventDisplaySleep: true, preventIdleSleep: true, timerSeconds: 600))
        defer { caffeinate.killNow() }
        let pid = try #require(caffeinate.pid)
        #expect(caffeinate.isRunning)
        #expect(heard.states == [true])
        #expect(Self.isAlive(pid))
        #expect(Self.argv(of: pid) == "/usr/bin/caffeinate -d -i -t 600 -w \(getpid())")
    }

    @Test func startWhileRunningIsANoOp() throws {  // P-9, D-13
        let caffeinate = Caffeinate()
        let heard = Heard()
        let subscription = caffeinate.observe { heard.states.append($0) }
        defer { subscription.cancel() }
        caffeinate.start(allOff)
        defer { caffeinate.killNow() }
        let pid = try #require(caffeinate.pid)
        caffeinate.start(CaffeinateFlags(preventDisplaySleep: true))
        #expect(caffeinate.pid == pid, "the same process")
        #expect(!Self.argv(of: pid).contains("-d"))
        #expect(heard.states == [true])
    }

    @Test func stopEndsTheProcessAndItsExitIsAnnounced() async throws {  // P-10
        let caffeinate = Caffeinate()
        let heard = Heard()
        let subscription = caffeinate.observe { heard.states.append($0) }
        defer { subscription.cancel() }
        caffeinate.start(allOff)
        let pid = try #require(caffeinate.pid)
        caffeinate.stop()
        #expect(caffeinate.isRunning, "not assumed: only once it has exited")
        #expect(await eventually { !caffeinate.isRunning })
        #expect(heard.states == [true, false])
        #expect(await eventually { !Self.isAlive(pid) })
    }

    @Test func aProcessEndingOnItsOwnIsNoticed() async throws {  // P-11
        let caffeinate = Caffeinate()
        let heard = Heard()
        let subscription = caffeinate.observe { heard.states.append($0) }
        defer { subscription.cancel() }
        caffeinate.start(CaffeinateFlags(timerSeconds: 1))
        let pid = try #require(caffeinate.pid)
        #expect(await eventually(8) { !caffeinate.isRunning }, "its own timer ended it")
        #expect(heard.states == [true, false])

        caffeinate.start(allOff)
        let second = try #require(caffeinate.pid)
        #expect(second != pid)
        kill(second, SIGKILL)  // something outside the app
        #expect(await eventually { !caffeinate.isRunning })
        #expect(heard.states == [true, false, true, false])
    }

    @Test func aLateExitOfAnOldProcessChangesNothing() async throws {  // P-12
        let caffeinate = Caffeinate()
        caffeinate.start(allOff)
        let old = try #require(caffeinate.pid)
        caffeinate.killNow()
        caffeinate.start(allOff)
        defer { caffeinate.killNow() }
        let current = try #require(caffeinate.pid)
        #expect(await eventually { !Self.isAlive(old) })
        try await Task.sleep(for: .milliseconds(50))  // the old exit's hop to the main actor
        #expect(caffeinate.isRunning)
        #expect(caffeinate.pid == current)
    }

    @Test func aSpawnThatFailsLeavesItNotRunning() {  // P-13
        let caffeinate = Caffeinate(binary: URL(fileURLWithPath: "/nonexistent/caffeinate"))
        let heard = Heard()
        let subscription = caffeinate.observe { heard.states.append($0) }
        defer { subscription.cancel() }
        caffeinate.start(allOff)
        #expect(!caffeinate.isRunning)
        #expect(caffeinate.pid == nil)
        #expect(heard.states.isEmpty)
    }

    @Test func killNowForgetsTheProcessAtOnce() async throws {  // P-14
        let caffeinate = Caffeinate()
        let heard = Heard()
        let subscription = caffeinate.observe { heard.states.append($0) }
        defer { subscription.cancel() }
        caffeinate.start(allOff)
        let pid = try #require(caffeinate.pid)
        caffeinate.killNow()
        #expect(!caffeinate.isRunning, "synchronously")
        #expect(await eventually { !Self.isAlive(pid) })
        try await Task.sleep(for: .milliseconds(50))  // its exit's hop to the main actor
        #expect(heard.states == [true], "its exit announces nothing: nobody is left to tell")
    }

    @Test func aNewRuntimeHasNothingRunning() {
        #expect(!TestSupport.runtime().caffeinate.isRunning)
    }
}
