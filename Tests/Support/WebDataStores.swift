import Foundation

/// The web data stores the browser tests' pages use, deleted when the test process exits (why, and Spotlight:
/// `Scripts/test-lanes.py`). Every test's pages get a store of their own (a page bed's, or the one a fresh data
/// directory names), so no test sees another's cookies, and WebKit keeps every store on disk for good. At exit
/// no page of the process is left: a store is its directory in WebKit's container for the app that used it
/// (`~/Library/WebKit/<bundle id>/WebsiteDataStore/<id>`), deleted if it is there; only stores a test names
/// here are. (Not WebKit's own removal while tests run, `WKWebsiteDataStore.remove(forIdentifier:)`: a run
/// sweeping with it hung a later test.)
enum WebDataStores {
    private final class Named: @unchecked Sendable {
        let lock = NSLock()
        var stores: Set<URL> = []
        var armed = false
    }

    private static let named = Named()

    /// Deletes the store `id` of the app `bundleIdentifier` (this process's own by default) when this process exits.
    static func discard(_ id: UUID, ofApp bundleIdentifier: String? = Bundle.main.bundleIdentifier) {
        guard let bundleIdentifier, !bundleIdentifier.isEmpty else { return }
        let store = FileManager.default.homeDirectoryForCurrentUser.appending(
            path: "Library/WebKit/\(bundleIdentifier)/WebsiteDataStore/\(id.uuidString.lowercased())", directoryHint: .isDirectory)
        let arm = named.lock.withLock {
            named.stores.insert(store)
            defer { named.armed = true }
            return !named.armed
        }
        if arm { atexit { WebDataStores.deleteAll() } }
    }

    private static func deleteAll() {
        for store in named.lock.withLock({ named.stores }) where FileManager.default.fileExists(atPath: store.path) {
            try? FileManager.default.removeItem(at: store)
        }
    }
}
