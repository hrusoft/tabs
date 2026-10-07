import Darwin
import Foundation
import TabsPluginSDK
import Testing

/// The built Tabs.app as a user runs it — its own process, hidden
/// (`TABS_E2E_HIDDEN`), in a scratch data directory, with the `fixture-text`
/// test plugin beside its own (`TABS_E2E_PLUGINS`) — driven only through its
/// control socket. `relaunch()` quits and starts it again on the same data, to
/// test persistence.
final class LaunchedApp: @unchecked Sendable {
    struct Failure: Error, CustomStringConvertible {
        let description: String
    }

    let dataDirectory: URL
    /// Variables of the test runner's environment the app is launched without.
    let removedEnvironment: Set<String>
    /// Variables the app is launched with on top of the test runner's.
    let addedEnvironment: [String: String]
    private(set) var socketPath: String
    private var process: Process?
    private var client: ControlClient?
    /// Everything the app wrote to stderr, across launches.
    private let errors = Output()

    private final class Output: @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()
        func append(_ chunk: Data) { lock.withLock { data.append(chunk) } }
        var text: String { lock.withLock { String(decoding: data, as: UTF8.self) } }
    }

    /// The Tabs.app built alongside this test bundle.
    static var appURL: URL {
        Bundle(for: LaunchedApp.self).bundleURL.deletingLastPathComponent().appending(path: "Tabs.app")
    }

    /// The test plugins the app starts beside its own (`TABS_E2E_PLUGINS`): this
    /// bundle's `fixture-text`, a pane no shipped plugin owns.
    static var fixturesDirectory: URL {
        Bundle(for: LaunchedApp.self).resourceURL!.appending(path: "Fixtures", directoryHint: .isDirectory)
    }

    private init(dataDirectory: URL, removedEnvironment: Set<String>, addedEnvironment: [String: String]) {
        self.dataDirectory = dataDirectory
        self.removedEnvironment = removedEnvironment
        self.addedEnvironment = addedEnvironment
        self.socketPath = shortSocketPath("e2e")
    }

    static func launch(
        dataDirectory: URL? = nil, removingEnvironment removed: Set<String> = [], addingEnvironment added: [String: String] = [:]
    ) async throws -> LaunchedApp {
        let directory =
            dataDirectory
            ?? TestTemporary.directory("e2e")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let app = LaunchedApp(dataDirectory: directory, removedEnvironment: removed, addedEnvironment: added)
        try await app.start()
        return app
    }

    private func start() async throws {
        let process = Process()
        process.executableURL = Self.appURL.appending(path: "Contents/MacOS/Tabs")
        var environment = ProcessInfo.processInfo.environment
        environment["TABS_DATA_DIR"] = dataDirectory.path
        environment["TABS_LISTEN_SOCKET"] = socketPath
        environment["TABS_E2E_HIDDEN"] = "1"
        environment["TABS_E2E_PLUGINS"] = Self.fixturesDirectory.path
        // Shells start on the tests' startup files, not the user's (`TestShell`).
        environment["ZDOTDIR"] = TestShell.directory
        for key in environment.keys where key.hasPrefix("XCTest") || key.hasPrefix("DYLD_") || removedEnvironment.contains(key) {
            environment[key] = nil
        }
        environment.merge(addedEnvironment) { _, added in added }
        process.environment = environment
        // A fresh pipe per launch (a Process consumes its handles), drained as
        // it fills: reading it on demand would block while the app runs.
        let stderr = Pipe()
        let errors = errors
        stderr.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            // At end of file the handler is called again and again with
            // nothing, spinning a thread for as long as the test process lives.
            if chunk.isEmpty { handle.readabilityHandler = nil } else { errors.append(chunk) }
        }
        process.standardError = stderr
        process.standardOutput = FileHandle.nullDevice
        try process.run()
        self.process = process

        // Ready when the socket answers.
        let deadline = ContinuousClock.now + .seconds(20)
        while ContinuousClock.now < deadline {
            guard isRunning else {
                // `terminationStatus` raises while `Process` hasn't heard of the
                // exit yet (the kernel may know first): read it only once it has.
                let status = process.isRunning ? "status unknown" : "\(process.terminationStatus)"
                throw Failure(description: "Tabs exited during launch (\(status)): \(errorOutput())")
            }
            if let client = try? ControlClient(path: socketPath), (try? await client.send(#"{"command":"tabs.info"}"#)) != nil {
                self.client = client
                return
            }
            // A connect to a socket not there yet fails in microseconds: polling often costs nothing.
            try await Task.sleep(for: .milliseconds(5))
        }
        terminate()
        throw Failure(description: "Tabs didn't answer on \(socketPath) within 20s: \(errorOutput())")
    }

    /// Sends one request; returns `result`, or throws the app's error message.
    @discardableResult
    func call(_ command: String, _ arguments: JSONValue = .emptyObject, paneId: String? = nil) async throws -> JSONValue {
        let response = try await raw(envelope(command, arguments, paneId: paneId))
        if response["ok"] == true { return response["result"] ?? .null }
        throw Failure(description: response["error"]?.stringValue ?? "malformed response: \(response)")
    }

    /// Sends one line as-is and returns the decoded response.
    func raw(_ line: String) async throws -> JSONValue {
        guard let client else { throw Failure(description: "not running") }
        let answer = try await client.send(line)
        return try JSONDecoder().decode(JSONValue.self, from: Data(answer.utf8))
    }

    /// Quits through the app's normal path (it saves) and waits for the exit.
    func quit() async throws {
        do {
            try await call("tabs.test.quit")
        } catch is ControlClient.Failure {
            // The app went before its answer did: the quit is under way.
        }
        client = nil
        let deadline = ContinuousClock.now + .seconds(10)
        while isRunning {
            guard ContinuousClock.now < deadline else {
                terminate()
                throw Failure(description: "Tabs didn't quit within 10s")
            }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    /// Quits, then launches again on the same data directory.
    func relaunch() async throws {
        try await quit()
        socketPath = shortSocketPath("e2e")
        try await start()
    }

    /// Ends the process without a normal quit (cleanup, or simulating a crash).
    ///
    /// Waits for the kernel, not for `Process`: `waitUntilExit()` here once
    /// waited five hours, after every test had passed, for an app that was
    /// long gone (not even a zombie). Why `Process` never heard of that exit
    /// wasn't pinned down; the kernel's answer can't go stale.
    func terminate() {
        client = nil
        guard let pid = process?.processIdentifier, isApp(pid) else { return }
        kill(pid, SIGKILL)
        let deadline = Date().addingTimeInterval(10)
        while isApp(pid), Date() < deadline { usleep(5_000) }
        unlink(socketPath)  // a killed app can't remove its own
    }

    /// Whether the launched app is still running: its pid is still this app's
    /// executable (not exited, reaped or reused), whatever `Process` has heard.
    var isRunning: Bool { process.map { isApp($0.processIdentifier) } ?? false }

    private func isApp(_ pid: pid_t) -> Bool {
        guard pid > 0 else { return false }
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size, info.pbi_status != UInt32(SZOMB) else { return false }
        var path = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        guard proc_pidpath(pid, &path, UInt32(path.count)) > 0 else { return false }
        let executable = String(decoding: path.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        return executable.hasSuffix("/Tabs.app/Contents/MacOS/Tabs")
    }

    func errorOutput() -> String {
        errors.text
    }

    private func envelope(_ command: String, _ arguments: JSONValue, paneId: String?) throws -> String {
        var object: [String: JSONValue] = ["command": .string(command), "args": arguments]
        if let paneId { object["paneId"] = .string(paneId) }
        return String(decoding: try JSONValue.object(object).encodedData(pretty: false), as: UTF8.self)
    }

    deinit {
        terminate()
    }
}

/// One app for a whole suite (`@Suite(.sharedApp)`), launched once and reset
/// before each test with `tabs.test.reset` — a fraction of a launch. Tests that
/// quit, relaunch or crash the app launch their own instead.
struct SharedApp: SuiteTrait, TestScoping {
    @TaskLocal static var current: LaunchedApp?

    func provideScope(for test: Test, testCase: Test.Case?, performing function: @Sendable () async throws -> Void) async throws {
        let app = try await LaunchedApp.launch()
        defer { app.terminate() }
        try await Self.$current.withValue(app) { try await function() }
    }

    /// The suite's app, reset to the state of a fresh launch.
    static func fresh() async throws -> LaunchedApp {
        guard let app = current else { throw LaunchedApp.Failure(description: "not in a .sharedApp suite") }
        try await app.call("tabs.test.reset")
        return app
    }
}

extension Trait where Self == SharedApp {
    static var sharedApp: Self { SharedApp() }
}
