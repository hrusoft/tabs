import Darwin
import Foundation
import TabsPluginSDK

/// The flags a managed `caffeinate` process is launched with: one per
/// `caffeinate(8)` assertion the dialog offers, plus an optional timer. See
/// `argsFor` for the flag → argv mapping.
package struct CaffeinateFlags: Equatable, Sendable {
    /// `-d`: prevent display sleep.
    package var preventDisplaySleep = false
    /// `-i`: prevent idle system sleep.
    package var preventIdleSleep = false
    /// `-m`: prevent disk idle sleep.
    package var preventDiskSleep = false
    /// `-s`: prevent system sleep. Only has an effect on AC power.
    package var preventSystemSleep = false
    /// `-u`: declare the user active. Wakes the display; caffeinate's own
    /// assertion lasts 5s unless a timer is also set.
    package var declareUserActive = false
    /// `-t <seconds>`: stop automatically after this many seconds. Nil means
    /// "run until Decaf". Not necessarily whole: `argsFor` treats anything but
    /// a positive whole number as none.
    package var timerSeconds: Double?

    package init(
        preventDisplaySleep: Bool = false, preventIdleSleep: Bool = false, preventDiskSleep: Bool = false,
        preventSystemSleep: Bool = false, declareUserActive: Bool = false, timerSeconds: Double? = nil
    ) {
        self.preventDisplaySleep = preventDisplaySleep
        self.preventIdleSleep = preventIdleSleep
        self.preventDiskSleep = preventDiskSleep
        self.preventSystemSleep = preventSystemSleep
        self.declareUserActive = declareUserActive
        self.timerSeconds = timerSeconds
    }

    /// The dialog's defaults: keep the Mac running (idle sleep and AC-power
    /// system sleep both blocked) but let the display sleep — the common case
    /// for a long build, download or agent run, where the screen needn't stay
    /// lit. Disk idle sleep and "declare the user active" are opted into on
    /// purpose.
    package static let dialogDefaults = CaffeinateFlags(preventIdleSleep: true, preventSystemSleep: true)
}

/// `caffeinate(8)`'s own flags, in the order the dialog lists them, plus a
/// mandatory `-w <watchPid>`: the app's crash-safety backstop. Quitting kills
/// the process on the prompt path, but a crash or a SIGKILL never runs the quit
/// path at all — without `-w`, an orphaned caffeinate would keep the Mac awake
/// forever. `caffeinate` exits the moment the watched pid does (`-w` composes
/// with `-t`: whichever fires first ends it), so this is a second, independent
/// way for the process to end besides the app's own kill.
package func argsFor(_ flags: CaffeinateFlags, watchPid: Int32) -> [String] {
    var args: [String] = []
    if flags.preventDisplaySleep { args.append("-d") }
    if flags.preventIdleSleep { args.append("-i") }
    if flags.preventDiskSleep { args.append("-m") }
    if flags.preventSystemSleep { args.append("-s") }
    if flags.declareUserActive { args.append("-u") }
    if let timer = flags.timerSeconds, timer.isFinite, timer == timer.rounded(), timer > 0, let whole = Int(exactly: timer) {
        args += ["-t", String(whole)]
    }
    args += ["-w", String(watchPid)]
    return args
}

/// The app's one managed `caffeinate(8)` process: starting it, stopping it, and
/// whether it runs — the single source of truth the menu item's label, the
/// title-bar cup and the dialog read. Core, not a plugin: it's app-wide and
/// scoped to no pane.
///
/// "Not running" is never assumed: it's announced when the process has really
/// exited — after Decaf, after its own timer, or after something outside the
/// app killed it.
@MainActor
package final class Caffeinate {
    /// macOS's own binary.
    package static let standardBinary = URL(fileURLWithPath: "/usr/bin/caffeinate")

    private let binary: URL
    private var current: Process?
    /// Which start `current` is: what a late exit is matched against. Not the `Process`'s
    /// identity: a released one's address is soon a new one's (measured: 992 times in 1,000),
    /// and an old process's exit then ended the new one's state.
    private var currentLaunch = 0
    private var launches = 0
    private var observers: [Int: @MainActor (Bool) -> Void] = [:]
    private var nextObserver = 0

    /// - Parameter binary: what to run; tests point it elsewhere to make a
    ///   launch fail or end at once.
    package init(binary: URL = Caffeinate.standardBinary) {
        self.binary = binary
    }

    /// True while the managed process runs.
    package var isRunning: Bool { current != nil }

    /// The OS pid of the managed process, nil when none runs. For tests that
    /// must check the real process by its own pid: a name check (`pgrep
    /// caffeinate`) would see any unrelated caffeinate on the machine.
    package var pid: Int32? { current?.processIdentifier }

    /// Calls `handler` with the new state whenever it changes.
    package func observe(_ handler: @escaping @MainActor (Bool) -> Void) -> Subscription {
        let token = nextObserver
        nextObserver += 1
        observers[token] = handler
        return Subscription(onCancel: { [weak self] in self?.observers[token] = nil })
    }

    /// Starts the managed process with `flags`, watching this app's own pid
    /// (see `argsFor`'s `-w`). Does nothing if one is already running. A launch
    /// that fails leaves it not running.
    package func start(_ flags: CaffeinateFlags) {
        guard current == nil else { return }
        let process = Process()
        process.executableURL = binary
        process.arguments = argsFor(flags, watchPid: getpid())
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        launches += 1
        let launch = launches
        // A late exit — a process already superseded or forgotten (by Decaf
        // then another Start, by the quit's kill, by a test reset) — finds
        // another launch or none current, and changes nothing.
        process.terminationHandler = { [weak self] _ in
            Task { @MainActor in self?.processDidExit(launch) }
        }
        do {
            try process.run()
        } catch {
            Log.core.error("caffeinate could not be started: \(String(describing: error), privacy: .public)")
            return
        }
        current = process
        currentLaunch = launch
        announce()
    }

    /// Stops the managed process, if one is running. Signal only (SIGTERM):
    /// "not running" is announced once it has really exited.
    package func stop() {
        current?.terminate()
    }

    /// Stops the process and forgets it at once, so its exit announces
    /// nothing: for the quit path and a test reset, where nothing is left to
    /// tell. A plain signal to a process already running, never a new launch.
    package func killNow() {
        let process = current
        current = nil
        process?.terminate()
    }

    private func processDidExit(_ launch: Int) {
        guard current != nil, launch == currentLaunch else { return }
        current = nil
        announce()
    }

    private func announce() {
        let running = isRunning
        for observer in observers.values { observer(running) }
    }
}
