import Foundation
import TabsPluginSDK
import Testing

@testable import TabsCore

/// Discovery runs on Info.plist alone, so these bundles have no code at all —
/// which also proves a rejected plugin is never loaded: there is nothing to load.
@MainActor
@Suite struct DiscoveryTests {
    let directory = TestSupport.temporaryDirectory()
    let fingerprint = BuildStamp.loadedFingerprint

    private func discover() -> PluginDiscovery.Result {
        PluginDiscovery.discover(in: directory, expectedFingerprint: fingerprint)
    }

    private func rejection(_ id: String, in result: PluginDiscovery.Result) -> String? {
        result.rejected.first { $0.id.rawValue == id }?.state.detail
    }

    @Test func acceptsAWellFormedBundleWithoutLoadingIt() throws {
        let url = TestSupport.writeBundle(
            named: "good.tabsplugin", in: directory, info: TestSupport.info(id: "good", contentTypes: ["good"]))
        let result = discover()
        #expect(result.rejected.isEmpty)
        #expect(result.candidates.map(\.manifest.id) == ["good"])
        #expect(Bundle(url: url)?.isLoaded == false)
    }

    @Test func rejectsAStaleFingerprintBeforeLoading() {
        TestSupport.writeBundle(
            named: "stale.tabsplugin", in: directory, info: TestSupport.info(id: "stale"),
            stamp: TestSupport.pluginStamp(fingerprint: "0000000000000000"))
        TestSupport.writeBundle(named: "unstamped.tabsplugin", in: directory, info: TestSupport.info(id: "unstamped"), stamp: nil)
        let result = discover()
        #expect(result.candidates.isEmpty)
        #expect(rejection("stale", in: result)?.contains("fingerprint 0000000000000000") == true)
        #expect(rejection("stale", in: result)?.contains("rebuild it with the app") == true)
        #expect(rejection("unstamped", in: result) == "carries no build stamp; it was not built by this project's build")
    }

    @Test func bundleNameMustEqualManifestID() {
        TestSupport.writeBundle(named: "alias.tabsplugin", in: directory, info: TestSupport.info(id: "real"))
        let result = discover()
        #expect(rejection("alias", in: result) == "manifest id \"real\" does not match the bundle name \"alias.tabsplugin\"")
        #expect(!result.rejected.contains { $0.id == "real" }, "keyed by file name, so it can't shadow a real plugin")
    }

    @Test func bundledListIsReconciledBothWays() {
        TestSupport.writeBundle(named: "listed.tabsplugin", in: directory, info: TestSupport.info(id: "listed"))
        TestSupport.writeBundle(named: "stray.tabsplugin", in: directory, info: TestSupport.info(id: "stray"))
        let result = PluginDiscovery.discover(in: directory, expectedFingerprint: fingerprint, bundled: ["listed", "absent"])
        #expect(result.candidates.map(\.manifest.id) == ["listed"])
        #expect(rejection("stray", in: result)?.contains("not one of the app's bundled plugins") == true)
        #expect(rejection("absent", in: result)?.contains("missing from its PlugIns directory") == true)
    }

    @Test func aBundleStampedWithAnotherRoleIsNotAPlugin() {
        TestSupport.writeBundle(
            named: "framework-ish.tabsplugin", in: directory, info: TestSupport.info(id: "framework-ish"),
            stamp: TestSupport.pluginStamp(role: .core))
        #expect(rejection("framework-ish", in: discover()) == "is stamped with role \"core\", not \"plugin\"")
    }

    @Test func missingOrInvalidManifestsAreRejectedWithAReason() {
        TestSupport.writeBundle(named: "bare.tabsplugin", in: directory, info: ["CFBundleIdentifier": "x"])
        TestSupport.writeBundle(named: "tabs.tabsplugin", in: directory, info: TestSupport.info(id: "tabs"))
        let result = discover()
        #expect(rejection("bare", in: result) == "Info.plist has no TabsPlugin manifest")
        #expect(rejection("tabs", in: result) == "invalid manifest: id \"tabs\" is reserved for core")
    }

    @Test func contentTypesMustBeInThePluginsNamespace() {
        TestSupport.writeBundle(
            named: "one.tabsplugin", in: directory, info: TestSupport.info(id: "one", contentTypes: ["one", "one.more"]))
        TestSupport.writeBundle(named: "two.tabsplugin", in: directory, info: TestSupport.info(id: "two", contentTypes: ["one"]))
        let result = discover()
        #expect(result.candidates.map(\.manifest.id) == ["one"])
        #expect(rejection("two", in: result) == "invalid manifest: content type \"one\" must be \"two\" or start with \"two.\"")
    }

    @Test func symlinksAndOtherFilesAreNotPlugins() throws {
        let elsewhere = TestSupport.temporaryDirectory()
        let real = TestSupport.writeBundle(named: "linked.tabsplugin", in: elsewhere, info: TestSupport.info(id: "linked"))
        try FileManager.default.createSymbolicLink(at: directory.appending(path: "linked.tabsplugin"), withDestinationURL: real)
        TestSupport.writeBundle(named: "readme.bundle", in: directory, info: TestSupport.info(id: "readme"))
        let result = discover()
        #expect(result.candidates.isEmpty)
        #expect(result.rejected.map(\.id) == ["linked"])
        #expect(rejection("linked", in: result)?.contains("symbolic link") == true)
    }
}

/// Every way a principal class can be wrong, using classes from this test bundle.
@MainActor
@Suite struct LoaderTests {
    final class NotAPlugin: NSObject {}
    final class PureSwift {}

    @Test func acceptsAConformingClassFromTheExpectedBundle() throws {
        let plugin = try PluginLoader.instantiate(principalClass: FixturePrincipal.self, expectedBundle: TestSupport.testBundle)
        #expect(plugin is FixturePrincipal)
    }

    @Test func rejectsAClassFromAnotherImage() {
        #expect(throws: PluginLoader.LoadError.foreignClass(className: NSStringFromClass(FixturePrincipal.self))) {
            try PluginLoader.instantiate(principalClass: FixturePrincipal.self, expectedBundle: .main)
        }
    }

    @Test func rejectsNonConformingAndNonObjectClasses() {
        #expect(throws: PluginLoader.LoadError.notAPlugin(className: NSStringFromClass(NotAPlugin.self))) {
            try PluginLoader.instantiate(principalClass: NotAPlugin.self, expectedBundle: TestSupport.testBundle)
        }
        #expect(throws: PluginLoader.LoadError.notNSObject(className: NSStringFromClass(PureSwift.self))) {
            try PluginLoader.instantiate(principalClass: PureSwift.self, expectedBundle: TestSupport.testBundle)
        }
        #expect(throws: PluginLoader.LoadError.noPrincipalClass) {
            try PluginLoader.instantiate(principalClass: nil, expectedBundle: TestSupport.testBundle)
        }
    }
}

@MainActor
final class FixturePrincipal: NSObject, TabsPlugin {
    func activate(_ context: any PluginContext) throws {}
}
