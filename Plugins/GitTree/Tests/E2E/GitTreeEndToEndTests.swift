import Darwin
import Foundation
import TabsPluginSDK
import Testing

/// Git tree panes in the running app (docs/GIT-TREE.md): the real plugin
/// bundle reading real repositories, read back over the control socket with
/// the Debug verb `git-tree.test.state`.
extension LaunchedApp {
    func gitTree(_ pane: String) async throws -> JSONValue { try await call("git-tree.test.state", paneId: pane) }

    @discardableResult
    func gitTree(
        _ pane: String, within seconds: Double = 10, sourceLocation: SourceLocation = #_sourceLocation,
        until condition: (JSONValue) -> Bool
    ) async throws -> JSONValue {
        let deadline = ContinuousClock.now + .seconds(seconds)
        var state = try await gitTree(pane)
        while !condition(state) {
            guard ContinuousClock.now < deadline else {
                Issue.record("timed out; the git tree: \(state)", sourceLocation: sourceLocation)
                return state
            }
            try await Task.sleep(for: .milliseconds(50))
            state = try await gitTree(pane)
        }
        return state
    }
}

/// A repository with commits `subjects`, in a scratch directory (real path).
private func scratchRepository(_ subjects: [String]) throws -> String {
    let base = TestTemporary.location("e2e-git").path
    try FileManager.default.createDirectory(atPath: base, withIntermediateDirectories: true)
    let path =
        realpath(base, nil).map { pointer in
            defer { free(pointer) }
            return String(cString: pointer)
        } ?? base
    func git(_ args: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git"] + args
        process.currentDirectoryURL = URL(fileURLWithPath: path)
        var environment = ProcessInfo.processInfo.environment
        environment["HOME"] = path
        for key in ["GIT_AUTHOR_NAME", "GIT_COMMITTER_NAME"] { environment[key] = "Ann" }
        for key in ["GIT_AUTHOR_EMAIL", "GIT_COMMITTER_EMAIL"] { environment[key] = "ann@example.com" }
        process.environment = environment
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw CancellationError() }
    }
    try git(["init", "-q", "-b", "main"])
    for (index, subject) in subjects.enumerated() {
        try "\(index)".write(toFile: "\(path)/f\(index)", atomically: true, encoding: .utf8)
        try git(["add", "."])
        try git(["commit", "-q", "-m", subject])
    }
    return path
}

@Suite(.serialized, .sharedApp, .timeLimit(.minutes(2))) struct GitTreeEndToEndTests {
    /// The plugin's one check that the built bundle is wired into the launched app: a pane made from
    /// its creation button reads, with the real git, the repository typed into its path bar (D-7).
    /// What the pane does with a repository, and keeps of it across a relaunch (PS-1), is the unit and
    /// UI tiers' (`Plugins/GitTree/Tests`); the relaunch itself is core's (`RelaunchTests`).
    @Test func aPaneReadsTheRepositoryTypedIntoItsPathBar() async throws {
        let repo = try scratchRepository(["one", "two"])
        defer { try? FileManager.default.removeItem(atPath: repo) }
        let app = try await SharedApp.fresh()
        let pane = try await app.activePane()
        try await app.call("tabs.test.click", ["create": "git-tree", "paneId": .string(pane)])
        try await app.gitTree(pane) { $0["cwd"] != .null }
        try await app.call("tabs.test.click", ["identifier": "git-tree-path-input", "paneId": .string(pane)])
        try await app.gitTree(pane) { $0["editingPath"] == true }
        try await app.call("tabs.test.press", ["key": "a", "modifiers": ["command"]])
        try await app.call("tabs.test.type", ["text": .string(repo + "\n")])
        let state = try await app.gitTree(pane) { $0["subjects"] == ["two", "one"] }
        #expect(state["cwd"]?.stringValue == repo)
    }
}
