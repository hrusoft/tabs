import Darwin
import Foundation

/// Where a test process keeps its files: a folder of its own, `tabs-tests.noindex/<pid>` in the
/// user's temporary directory, made on first use and removed as the process exits. Every test
/// folder and file goes under it, so none outlives its run: a full run makes about a thousand,
/// and they piled up in the hundred thousands, each one indexed. Spotlight skips a `.noindex`
/// folder; `Scripts/test-lanes.py` removes what a process that died before exiting left behind.
enum TestTemporary {
    /// This process's folder.
    static let root: URL = {
        let url = FileManager.default.temporaryDirectory.appending(
            path: "tabs-tests.noindex/\(getpid())", directoryHint: .isDirectory)
        // An earlier process with this pid that died before exiting.
        try? FileManager.default.removeItem(at: url)
        try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        atexit { try? FileManager.default.removeItem(at: TestTemporary.root) }
        return url
    }()

    /// A new, empty folder: `<name>-<UUID>`.
    static func directory(_ name: String) -> URL {
        let url = root.appending(path: "\(name)-\(UUID().uuidString)", directoryHint: .isDirectory)
        try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// A path no one has used, for a file or a folder the caller makes: `<name>-<UUID><suffix>`.
    static func location(_ name: String, suffix: String = "") -> URL {
        root.appending(path: "\(name)-\(UUID().uuidString)\(suffix)")
    }
}
