import AppKit
import MachO
import TabsPluginSDK
import Testing

@testable import Tabs
@testable import TabsCore

/// The real thing: the plugins shipped in Tabs.app/Contents/PlugIns and the
/// fixture bundles, loaded across real image boundaries through the app's one
/// copy of the SDK. Which plugins ship is the build's business: these tests
/// read them from the app's stamp and never name one, and what a plugin does
/// across the boundary is shown with the fixtures.
@MainActor
@Suite(.serialized) struct BundleIntegrationTests {
    private func shippedRuntime(dataDirectory: URL? = nil, required: Set<ContentTypeID> = []) -> CoreRuntime {
        let runtime = TestSupport.runtime(dataDirectory: dataDirectory)
        runtime.startBundledPlugins(of: .main, requiredContentTypes: required)
        return runtime
    }

    /// The fixture bundles, from this test bundle's own resources: `fixture-text`
    /// (a text pane, a command and a verb) and `fixture-throws` (rolled back).
    private func fixtureRuntime() -> CoreRuntime {
        let runtime = TestSupport.runtime()
        runtime.startPlugins(from: TestSupport.fixturesDirectory)
        return runtime
    }

    /// The manifests of the plugins the app's stamp lists, read from their bundles.
    private func shippedManifests() throws -> [PluginManifest] {
        let bundled = try #require(BuildStamp(of: .main)?.bundledPlugins)
        let plugIns = try #require(Bundle.main.builtInPlugInsURL)
        return try bundled.map { id in
            let bundle = try #require(Bundle(url: plugIns.appending(path: "\(id).tabsplugin")), "\(id) is in PlugIns")
            return try PluginManifest(infoDictionary: try #require(bundle.infoDictionary))
        }
    }

    @Test func theTestHostIsABackgroundProcessOutOfTheDock() {
        #expect(NSApp.activationPolicy() == .prohibited, "no Dock tile, no menu bar, never frontmost")
    }

    @Test func appAndSDKComeFromTheSameBuild() {
        #expect(BuildIntegrity.problems(appBundle: .main).isEmpty)
        #expect(BuildStamp.loadedFingerprint?.count == 16)
    }

    @Test func everyBundledPluginActivates() throws {
        let bundled = try #require(BuildStamp(of: .main)?.bundledPlugins)
        let runtime = shippedRuntime()
        #expect(Set(runtime.host.records.map(\.id)) == Set(bundled))
        for record in runtime.host.records {
            #expect(record.state == .active, "\(record.id): \(record.state.detail ?? "")")
        }
        let order = runtime.host.records.map { runtime.host.rank(of: $0.id) }
        #expect(zip(order, order.dropFirst()).allSatisfy { $0 <= $1 }, "UI order is (manifest sortOrder, id)")
    }

    @Test func theShippedPluginsOfferTheirContentTypesInUIOrder() throws {
        let manifests = try shippedManifests()
        let offered = shippedRuntime().panes.creatableTypes()
        #expect(Set(offered.map(\.value.id)) == Set(manifests.flatMap(\.contentTypes)), "every declared type, and nothing else")
        let rank = Dictionary(uniqueKeysWithValues: manifests.map { ($0.id, ($0.sortOrder, $0.id.rawValue)) })
        let order = offered.compactMap { rank[$0.owner] }
        #expect(zip(order, order.dropFirst()).allSatisfy { $0 <= $1 }, "UI order is (manifest sortOrder, id)")
    }

    @Test func theProcessHoldsExactlyOneSDKImage() {
        _ = shippedRuntime()
        var sdkImages: [String] = []
        for index in 0..<_dyld_image_count() {
            let path = String(cString: _dyld_get_image_name(index))
            if path.hasSuffix("TabsPluginSDK.framework/Versions/A/TabsPluginSDK") { sdkImages.append(path) }
        }
        #expect(sdkImages.count == 1, "\(sdkImages)")
    }

    @Test func aPluginCommandActsOnItsOwnPaneAcrossTheImageBoundary() throws {
        let runtime = fixtureRuntime()
        let engine = LayoutEngine(runtime: runtime)
        engine.restore(nil)
        let paneID = try #require(runtime.panes.openPane(ofType: "fixture-text", config: nil))
        defer { engine.close(paneID) }
        let router = CommandRouter(runtime: runtime, engine: engine)

        let command = try #require(runtime.registry.contribution(to: .commands, id: "fixture-text.insertMarker"))
        let invocation = router.invocation(for: command.owner)
        #expect(invocation.paneID == paneID)
        #expect(invocation.pane != nil, "the plugin sees its own pane's controller")
        #expect(router.invocation(for: "fixture-throws").pane == nil, "another plugin sees only the pane's id and type")
        command.value.perform(invocation)
        #expect(runtime.panes.pane(paneID).map(runtime.panes.snapshot)?.config == ["text": "[marker]"], "and the command ran on it")
    }

    @Test func aFixtureThatThrowsIsRolledBackAcrossTheImageBoundary() throws {
        let runtime = TestSupport.runtime()
        runtime.startPlugins(from: TestSupport.fixturesDirectory)
        let bundle = try #require(Bundle(url: TestSupport.fixturesDirectory.appending(path: "fixture-throws.tabsplugin")))
        #expect(bundle.isLoaded, "its code really was loaded and run")
        #expect(TestSupport.state(runtime, "fixture-throws") == .failed("activate() threw: deliberate failure from the fixture"))
        #expect(!runtime.registry.contributions(to: .commands).contains { $0.owner == "fixture-throws" })
        #expect(!runtime.registry.contributions(to: .controlVerbs).contains { $0.owner == "fixture-throws" })
        #expect(runtime.hub.subscriberCount(channelID: "tabs.paneOpened", owner: "fixture-throws") == 0)
        #expect(TestSupport.state(runtime, "fixture-text") == .active, "the other fixture is unaffected")
    }

    @Test func controlVerbsRouteToTheirPluginAcrossTheImageBoundary() async throws {
        let runtime = fixtureRuntime()
        let engine = LayoutEngine(runtime: runtime)
        engine.restore(nil)
        let pane = try #require(runtime.panes.openPane(ofType: "fixture-text", config: ["text": "routed"]))
        defer { engine.close(pane) }
        let response = await runtime.control.handle(.init(command: "fixture-text.text", arguments: .emptyObject, targetPane: pane))
        #expect(response["result"]?["text"] == "routed", "the plugin got its own pane's controller: \(response)")
        let verbs = await runtime.control.handle(.init(command: "tabs.verbs"))
        let names = Set(
            verbs["result"].map { value -> [String] in
                guard case .array(let items) = value else { return [] }
                return items.compactMap { $0["name"]?.stringValue }
            } ?? [])
        #expect(Set(["fixture-text.text", "tabs.plugins", "tabs.verbs"]).isSubset(of: names))
        #expect(!names.contains("fixture-throws.verb"), "a rolled-back plugin's verb is gone")
    }
}
