import Darwin
import Foundation
import TabsPluginSDK

/// The on-disk sink for bytes an agent verb produces (`main/agentFiles.ts`): saved
/// resources, screenshots and `execute-js --out` output, each into its own subdirectory. Every one of these hands the sink some bytes and gets back
/// a *path*, because `tabs-ctl`'s stdout becomes the calling agent's context verbatim and
/// inline bytes there are both enormous and unreadable.
///
/// One type so the verbs that write files don't each reinvent the directory choice, the TTL
/// sweep and the guard around a directory that can vanish under a live app. Each caller names
/// its own subdirectory, so a sweep of one kind never touches another's.
///
/// The root is the plugin's own cache directory (`PluginContext.cacheDirectory`): files that
/// are readable page content live somewhere attributable to this plugin and sweepable by it,
/// not in a world-writable directory beside everything else on the machine.
@MainActor
final class AgentFiles {
    /// The subdirectories the verbs write into, swept independently.
    enum Subdirectory {
        static let screenshots = "agent-screenshots"
        static let resources = "agent-resources"
        static let output = "agent-output"
        static let all = [screenshots, resources, output]
    }

    /// How long a generated agent file stays on disk. Swept on write rather than on a timer, so
    /// a directory can't grow without bound and a caller still has ample time to read the file
    /// it was just handed. A caller-named path (an explicit `--out`) is the caller's to manage
    /// and is never swept.
    static let timeToLive: TimeInterval = 10 * 60

    /// How often a *write* may pay for a sweep. The TTL is ten minutes, so nothing here needs
    /// per-write precision, and without a floor the cost is quadratic: an agent screenshotting
    /// on a one-second timer reaches ~600 files inside the TTL and then pays ~600 stats per
    /// further screenshot. The launch-time sweep is unaffected; this only throttles the
    /// incidental one.
    static let sweepInterval: TimeInterval = 60

    private let root: URL
    private let now: () -> Date
    /// When each subdirectory was last swept from a write, by name.
    private var lastSweptAt: [String: Date] = [:]

    /// - Parameters:
    ///   - root: the directory the subdirectories live in.
    ///   - now: the clock (tests age files by moving it).
    init(root: URL, now: @escaping () -> Date = Date.init) {
        self.root = root
        self.now = now
    }

    /// The directory for `subdirectory`, created if it isn't there.
    func directory(_ subdirectory: String) throws -> URL {
        let directory = root.appending(path: subdirectory, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    /// Sweeps every subdirectory left by a previous run. Called at activation, because the
    /// 10-minute TTL is otherwise only enforced on the *next* write: an agent's final
    /// screenshots or saved resources would outlive the promise in the guide indefinitely
    /// without it. The listing and the stats happen off the main actor (none of it needs to
    /// finish before the first window exists), and every failure stays here: a sweep is
    /// housekeeping, never something that can take the plugin down.
    func sweepInBackground() {
        let root = root
        let cutoff = now().addingTimeInterval(-Self.timeToLive)
        Task.detached(priority: .background) {
            for subdirectory in Subdirectory.all {
                Self.sweep(root.appending(path: subdirectory, directoryHint: .isDirectory), olderThan: cutoff)
            }
        }
    }

    /// Removes the files in `directory` last modified before `cutoff`. Best effort: a directory
    /// that isn't listable, or a file another sweep already removed, is nothing to report.
    nonisolated static func sweep(_ directory: URL, olderThan cutoff: Date) {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return }
        for name in names {
            let file = directory.appending(path: name)
            guard let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate,
                modified < cutoff
            else { continue }
            try? FileManager.default.removeItem(at: file)
        }
    }

    /// Sweeps `subdirectory` now.
    func sweep(_ subdirectory: String) {
        lastSweptAt[subdirectory] = now()
        Self.sweep(root.appending(path: subdirectory, directoryHint: .isDirectory), olderThan: now().addingTimeInterval(-Self.timeToLive))
    }

    /// The whole of the `--out` contract every byte-producing verb shares, so none of them
    /// restates it: an `out` string is a caller-named absolute path (core resolved it against
    /// the caller's cwd), created exclusively and never swept, since the file is the caller's
    /// to manage; anything else (a bare `--out` arrives as `true`) gets a generated
    /// `<uuid>.<ext>` under the swept `subdirectory`.
    ///
    /// Exclusive creation is what refuses to clobber. The caller named this path, and silently
    /// overwriting whatever is there is the worse surprise; a re-run with a fresh name is one
    /// line for the caller. That is why the refusal's wording is a contract SKILL.md leans on,
    /// and belongs here rather than in each verb. `what` names the thing in the generic failure
    /// message ("could not write the <what> to disk").
    ///
    /// Answers the path written, or the message a verb fails with: it never throws, so a verb
    /// handler stays a straight line.
    func write(_ bytes: Data, out: JSONValue?, subdirectory: String, ext: String, what: String) -> Result<String, VerbFailure> {
        do {
            if let path = out?.stringValue, !path.isEmpty {
                try Self.writeExclusively(bytes, to: path)
                return .success(path)
            }
            return .success(try writeGenerated(bytes, subdirectory: subdirectory, ext: ext))
        } catch let error as Refusal {
            return .failure(VerbFailure("refusing to overwrite an existing file: \(error.path)"))
        } catch {
            return .failure(VerbFailure("could not write the \(what) to disk: \(error.localizedDescription)"))
        }
    }

    private func writeGenerated(_ bytes: Data, subdirectory: String, ext: String) throws -> String {
        let directory = try directory(subdirectory)
        if now().timeIntervalSince(lastSweptAt[subdirectory] ?? .distantPast) >= Self.sweepInterval { sweep(subdirectory) }
        let path = directory.appending(path: "\(UUID().uuidString.lowercased()).\(ext)").path
        try Self.writeExclusively(bytes, to: path)
        return path
    }

    private struct Refusal: Error { let path: String }

    /// `open(2)` with `O_EXCL`: the file is created or the write is refused, with no window between
    /// the check and the creation.
    private static func writeExclusively(_ bytes: Data, to path: String) throws {
        let descriptor = open(path, O_WRONLY | O_CREAT | O_EXCL, 0o644)
        if descriptor < 0 {
            if errno == EEXIST { throw Refusal(path: path) }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        do {
            try handle.write(contentsOf: bytes)
            try handle.close()
        } catch {
            // A half-written file the caller never learns of is worse than none.
            try? handle.close()
            unlink(path)
            throw error
        }
    }
}
