import Foundation
import TabsPluginSDK
import Testing

@testable import TabsCore

/// The file sink behind `--out` and every generated path (docs/BROWSER.md J-26): exclusive creation,
/// generated names in a swept per-verb subdirectory, a ten-minute TTL, a sweep at most once a minute on
/// write, and one at launch.
@MainActor
@Suite struct BrowserAgentFilesTests {
    let root: URL
    var clock = Clock()

    /// A clock a test moves.
    final class Clock: @unchecked Sendable {
        var now = Date(timeIntervalSince1970: 1_800_000_000)
    }

    init() throws {
        root = TestTemporary.directory("agent-files")
    }

    private func sink() -> AgentFiles {
        let clock = clock
        return AgentFiles(root: root, now: { clock.now })
    }

    private func names(_ subdirectory: String) -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: root.appending(path: subdirectory).path))?.sorted() ?? []
    }

    /// Plants a file in `subdirectory` last modified at `date`.
    @discardableResult
    private func plant(_ name: String, in subdirectory: String, modified date: Date) throws -> URL {
        let directory = root.appending(path: subdirectory, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appending(path: name)
        try Data("old".utf8).write(to: file)
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: file.path)
        return file
    }

    @Test func aGeneratedFileIsAUUIDWithItsExtensionInItsOwnSubdirectory() throws {
        let files = sink()
        let path = try #require(
            files.write(Data("bytes".utf8), out: nil, subdirectory: "agent-resources", ext: "png", what: "resource").wrote)
        let file = URL(filePath: path)
        #expect(file.deletingLastPathComponent().lastPathComponent == "agent-resources")
        #expect(
            file.lastPathComponent.wholeMatch(of: /[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\.png/) != nil,
            "\(file.lastPathComponent)")
        #expect(try String(contentsOf: file, encoding: .utf8) == "bytes")
        // A bare --out arrives as true; an empty string is no name either.
        #expect(files.write(Data(), out: true, subdirectory: "agent-output", ext: "json", what: "result").wrote?.hasSuffix(".json") == true)
        #expect(files.write(Data(), out: "", subdirectory: "agent-output", ext: "txt", what: "result").wrote?.hasSuffix(".txt") == true)
        #expect(names("agent-output").count == 2)
    }

    /// J-26: a caller-named path is created exactly there and never overwritten, whatever is there.
    @Test func aCallerNamedPathIsWrittenExactlyAndNeverOverwritten() throws {
        let files = sink()
        let path = root.appending(path: "mine.bin").path
        #expect(
            files.write(Data("one".utf8), out: .string(path), subdirectory: "agent-resources", ext: "png", what: "resource").wrote == path)
        #expect(try String(contentsOfFile: path, encoding: .utf8) == "one")
        let again = files.write(Data("two".utf8), out: .string(path), subdirectory: "agent-resources", ext: "png", what: "resource")
        #expect(again.refused?.message == "refusing to overwrite an existing file: \(path)")
        #expect(try String(contentsOfFile: path, encoding: .utf8) == "one")
        #expect(names("agent-resources").isEmpty, "a named path never touches the generated directory")
        // Not even something that isn't a regular file.
        let directory = root.path
        #expect(
            files.write(Data(), out: .string(directory), subdirectory: "x", ext: "x", what: "resource").refused?.message
                == "refusing to overwrite an existing file: \(directory)")
    }

    /// J-26: a failure to write is a message, never a throw: a caller-named path in a directory that isn't there,
    /// and a cache that can't be created.
    @Test func aFailureToWriteIsAMessageNeverAThrow() throws {
        let files = sink()
        let missing = root.appending(path: "no/such/dir/file.txt").path
        let named = try #require(
            files.write(Data(), out: .string(missing), subdirectory: "agent-output", ext: "txt", what: "result").refused)
        #expect(named.message.hasPrefix("could not write the result to disk: "), "\(named.message)")
        // A root that is a file: no directory can be made under it.
        let blocker = root.appending(path: "blocker")
        try Data().write(to: blocker)
        let broken = AgentFiles(root: blocker)
        let generated = try #require(broken.write(Data(), out: nil, subdirectory: "agent-resources", ext: "bin", what: "resource").refused)
        #expect(generated.message.hasPrefix("could not write the resource to disk: "), "\(generated.message)")
    }

    /// J-26: a generated file lives ten minutes; a write sweeps its own subdirectory and no other.
    @Test func aWriteSweepsItsSubdirectoryOfFilesPastTheTimeToLive() throws {
        let files = sink()
        let now = clock.now
        try plant("stale.txt", in: "agent-resources", modified: now.addingTimeInterval(-11 * 60))
        try plant("fresh.txt", in: "agent-resources", modified: now.addingTimeInterval(-9 * 60))
        try plant("elsewhere.txt", in: "agent-output", modified: now.addingTimeInterval(-11 * 60))
        _ = files.write(Data(), out: nil, subdirectory: "agent-resources", ext: "bin", what: "resource")
        #expect(names("agent-resources").contains("stale.txt") == false)
        #expect(names("agent-resources").contains("fresh.txt"))
        #expect(names("agent-output") == ["elsewhere.txt"], "another verb's directory is another sweep's")
    }

    /// J-26: a write pays for a sweep at most once a minute, whatever it writes in between.
    @Test func aWriteSweepsAtMostOnceAMinute() throws {
        let files = sink()
        _ = files.write(Data(), out: nil, subdirectory: "agent-resources", ext: "bin", what: "resource")  // the first write sweeps
        try plant("stale.txt", in: "agent-resources", modified: clock.now.addingTimeInterval(-11 * 60))
        clock.now.addTimeInterval(59)
        _ = files.write(Data(), out: nil, subdirectory: "agent-resources", ext: "bin", what: "resource")
        #expect(names("agent-resources").contains("stale.txt"), "inside the minute: no sweep")
        clock.now.addTimeInterval(2)
        _ = files.write(Data(), out: nil, subdirectory: "agent-resources", ext: "bin", what: "resource")
        #expect(!names("agent-resources").contains("stale.txt"), "past it: swept")
    }

    /// J-26: the launch sweep, in the background, of every subdirectory: an agent's final files don't outlive the promise.
    @Test func theLaunchSweepClearsEverySubdirectoryInTheBackground() async throws {
        let files = sink()
        let old = clock.now.addingTimeInterval(-30 * 60)
        for subdirectory in AgentFiles.Subdirectory.all { try plant("old.bin", in: subdirectory, modified: old) }
        try plant("new.bin", in: "agent-resources", modified: clock.now)
        // Awaited, not polled: at background priority a busy machine can hold it back past any budget.
        await files.sweepInBackground().value
        #expect(AgentFiles.Subdirectory.all.allSatisfy { !names($0).contains("old.bin") })
        #expect(names("agent-resources") == ["new.bin"])
    }

    /// The launch sweep of a directory that isn't there is nothing to report.
    @Test func sweepingWhatIsNotThereIsNotAProblem() async {
        await AgentFiles(root: root.appending(path: "absent")).sweepInBackground().value
        AgentFiles.sweep(root.appending(path: "absent"), olderThan: .now)
    }
}

private extension Result {
    var wrote: Success? { if case .success(let value) = self { value } else { nil } }
    var refused: Failure? { if case .failure(let error) = self { error } else { nil } }
}
