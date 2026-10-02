import AppKit
import Foundation
import TabsPluginSDK

@testable import TabsCore

/// An in-process plugin driven by closures.
@MainActor
final class ClosurePlugin: TabsPlugin {
    private let onActivate: (any PluginContext) throws -> Void
    private let onDeactivate: () -> Void

    init(activate: @escaping (any PluginContext) throws -> Void, deactivate: @escaping () -> Void = {}) {
        onActivate = activate
        onDeactivate = deactivate
    }

    func activate(_ context: any PluginContext) throws { try onActivate(context) }
    func deactivate() { onDeactivate() }
}

/// A trivial pane for in-process content types.
@MainActor
final class StubPane: PaneController {
    let view = NSView()
    var config: JSONValue
    init(config: JSONValue) { self.config = config }
    func currentConfig() -> JSONValue { config }
}

final class TestBundleToken: NSObject {}

@MainActor
enum TestSupport {
    static var testBundle: Bundle { Bundle(for: TestBundleToken.self) }

    static func temporaryDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "tabs-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func runtime(dataDirectory: URL? = nil) -> CoreRuntime {
        CoreRuntime(paths: AppPaths(dataDirectory: dataDirectory ?? temporaryDirectory()))
    }

    static func manifest(
        _ id: String, contentTypes: [String] = [], sortOrder: Int = 100, canDisable: Bool = true
    ) -> PluginManifest {
        PluginManifest(
            id: PluginID(id), displayName: id.capitalized,
            contentTypes: contentTypes.map(ContentTypeID.init(_:)), canDisable: canDisable, sortOrder: sortOrder
        )
    }

    static func candidate(_ manifest: PluginManifest, _ plugin: @escaping @MainActor () -> any TabsPlugin) -> PluginCandidate {
        PluginCandidate(manifest: manifest, source: .inProcess(bundle: testBundle, make: plugin))
    }

    static func candidate(
        _ manifest: PluginManifest,
        activate: @escaping (any PluginContext) throws -> Void,
        deactivate: @escaping () -> Void = {}
    ) -> PluginCandidate {
        candidate(manifest) { ClosurePlugin(activate: activate, deactivate: deactivate) }
    }

    static func contentType(_ id: String) -> ContentTypeContribution {
        ContentTypeContribution(id: ContentTypeID(id), displayName: id.capitalized, icon: .symbol("square")) { pane in
            StubPane(config: pane.initialConfig)
        }
    }

    static func state(_ runtime: CoreRuntime, _ id: String) -> PluginState? {
        runtime.host.record(for: PluginID(id))?.state
    }

    /// Where the fixture plugin bundles are copied inside the test bundle.
    static var fixturesDirectory: URL {
        testBundle.resourceURL!.appending(path: "Fixtures", directoryHint: .isDirectory)
    }

    /// Writes a code-less plugin bundle (Info.plist and build stamp only) for
    /// discovery tests. `stamp` nil writes no stamp at all.
    @discardableResult
    static func writeBundle(named name: String, in directory: URL, info: [String: Any], stamp: BuildStamp? = pluginStamp()) -> URL {
        let bundle = directory.appending(path: name, directoryHint: .isDirectory)
        let resources = bundle.appending(path: "Contents/Resources", directoryHint: .isDirectory)
        try! FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        let data = try! PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        try! data.write(to: bundle.appending(path: "Contents/Info.plist"))
        if let stamp {
            let stampData = try! PropertyListSerialization.data(fromPropertyList: stamp.propertyList, format: .xml, options: 0)
            try! stampData.write(to: resources.appending(path: "\(BuildStamp.resourceName).plist"))
        }
        return bundle
    }

    /// Writes raw JSON, bypassing core's stores (to set up premises).
    static func writeJSON(_ value: JSONValue, to url: URL) {
        try! FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try! value.encodedData().write(to: url)
    }

    static func readJSON(_ url: URL) -> JSONValue? {
        (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode(JSONValue.self, from: $0) }
    }

    static func pluginStamp(fingerprint: String? = BuildStamp.loadedFingerprint, role: BuildStamp.Role = .plugin) -> BuildStamp {
        BuildStamp(role: role, configuration: "Test", fingerprint: fingerprint ?? "none")
    }

    static func info(id: String, contentTypes: [String] = []) -> [String: Any] {
        [
            "CFBundleIdentifier": "dev.tabs.test.\(id)",
            "CFBundlePackageType": "BNDL",
            "TabsPlugin": ["id": id, "displayName": id.capitalized, "contentTypes": contentTypes],
        ]
    }
}

/// A settings backend in memory.
@MainActor
final class MemoryBackend: SettingsBackend {
    var blobs: [PluginID: JSONValue] = [:]
    var isReadOnly = false
    var writes = 0
    func storedSettings(for plugin: PluginID) -> JSONValue? { blobs[plugin] }
    func store(_ value: JSONValue, for plugin: PluginID) {
        blobs[plugin] = value
        writes += 1
    }
}
