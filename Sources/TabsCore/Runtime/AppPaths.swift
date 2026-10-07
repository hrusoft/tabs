import Foundation
import TabsPluginSDK
import os

package enum Log {
    package static let subsystem = "com.hrusoft.tabs"
    package static let core = Logger(subsystem: subsystem, category: "core")
    package static let plugins = Logger(subsystem: subsystem, category: "plugins")
    package static let persistence = Logger(subsystem: subsystem, category: "persistence")

    package static func plugin(_ id: PluginID) -> Logger { Logger(subsystem: subsystem, category: "plugin.\(id.rawValue)") }
}

/// Where core keeps its files, and where each plugin gets its own.
/// `TABS_DATA_DIR` moves all of it (tests, the verify script and the Xcode
/// scheme use it to stay out of real data).
package struct AppPaths: Sendable {
    package let dataDirectory: URL
    package let cacheDirectory: URL
    package let temporaryDirectory: URL

    /// Caches and temporary files default to inside `dataDirectory`.
    package init(dataDirectory: URL, cacheDirectory: URL? = nil, temporaryDirectory: URL? = nil) {
        self.dataDirectory = dataDirectory
        self.cacheDirectory = cacheDirectory ?? dataDirectory.appending(path: "Caches", directoryHint: .isDirectory)
        self.temporaryDirectory =
            temporaryDirectory ?? dataDirectory.appending(path: "tmp-\(getpid())", directoryHint: .isDirectory)
    }

    package var settingsFile: URL { dataDirectory.appending(path: "settings.json") }
    package var layoutFile: URL { dataDirectory.appending(path: "layout.json") }

    package func pluginData(_ id: PluginID) -> URL { Self.plugin(id, in: dataDirectory.appending(path: "plugins")) }
    package func pluginCache(_ id: PluginID) -> URL { Self.plugin(id, in: cacheDirectory.appending(path: "plugins")) }
    package func pluginTemporary(_ id: PluginID) -> URL { Self.plugin(id, in: temporaryDirectory.appending(path: "plugins")) }

    private static func plugin(_ id: PluginID, in directory: URL) -> URL {
        directory.appending(path: id.rawValue, directoryHint: .isDirectory)
    }

    package static func fromEnvironment(_ environment: [String: String] = ProcessInfo.processInfo.environment) -> AppPaths {
        if let override = environment["TABS_DATA_DIR"], !override.isEmpty {
            return AppPaths(dataDirectory: URL(filePath: override, directoryHint: .isDirectory))
        }
        // Named by the bundle identifier, as macOS apps name their folders: a Debug build's
        // (com.hrusoft.tabs.debug) is never an installed Tabs'.
        let name = Bundle.main.bundleIdentifier ?? "com.hrusoft.tabs"
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return AppPaths(
            dataDirectory: support.appending(path: name, directoryHint: .isDirectory),
            cacheDirectory: caches.appending(path: name, directoryHint: .isDirectory),
            temporaryDirectory: FileManager.default.temporaryDirectory.appending(path: "\(name)-\(getpid())", directoryHint: .isDirectory))
    }
}
