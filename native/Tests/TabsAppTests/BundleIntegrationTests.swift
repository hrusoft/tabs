import AppKit
import MachO
import TabsPluginSDK
import Testing

@testable import Tabs
@testable import TabsCore

/// The real thing: the plugins shipped in Tabs.app/Contents/PlugIns and the
/// fixture bundle, loaded across real image boundaries through the app's one
/// copy of the SDK.
@MainActor
@Suite(.serialized) struct BundleIntegrationTests {
    private func shippedRuntime(dataDirectory: URL? = nil, required: Set<ContentTypeID> = []) -> CoreRuntime {
        let runtime = TestSupport.runtime(dataDirectory: dataDirectory)
        runtime.startBundledPlugins(of: .main, requiredContentTypes: required)
        return runtime
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

    @Test func theShippedPluginsOfferTheirContentTypesInUIOrder() {
        let types = shippedRuntime().panes.creatableTypes().map(\.value.id)
        #expect(types == ["terminal", "browser", "git-tree"])
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
        let runtime = shippedRuntime()
        let engine = LayoutEngine(runtime: runtime)
        engine.restore(nil)
        let paneID = try #require(runtime.panes.openPane(ofType: "terminal", config: nil))
        defer { engine.close(paneID) }
        let router = CommandRouter(runtime: runtime, engine: engine)

        let command = try #require(runtime.registry.contribution(to: .commands, id: "terminal.clearBuffer"))
        let invocation = router.invocation(for: command.owner)
        #expect(invocation.paneID == paneID)
        #expect(invocation.pane != nil, "the terminal sees its own pane's controller")
        #expect(router.invocation(for: "browser").pane == nil, "the browser sees only the pane's id and type")
        command.value.perform(invocation)
    }

    @Test func aFixtureThatThrowsIsRolledBackAcrossTheImageBoundary() throws {
        let runtime = TestSupport.runtime()
        runtime.startPlugins(from: TestSupport.fixturesDirectory)
        let bundle = try #require(Bundle(url: TestSupport.fixturesDirectory.appending(path: "fixture-throws.tabsplugin")))
        #expect(bundle.isLoaded, "its code really was loaded and run")
        #expect(TestSupport.state(runtime, "fixture-throws") == .failed("activate() threw: deliberate failure from the fixture"))
        #expect(runtime.registry.contributions(to: .commands).isEmpty)
        #expect(runtime.registry.contributions(to: .controlVerbs).isEmpty)
        #expect(runtime.hub.subscriberCount(channelID: "tabs.paneOpened", owner: "fixture-throws") == 0)
    }

    @Test func controlVerbsRouteToRealPlugins() async throws {
        let runtime = shippedRuntime()
        let engine = LayoutEngine(runtime: runtime)
        engine.restore(nil)
        let pane = try #require(runtime.panes.openPane(ofType: "terminal", config: nil))
        defer { engine.close(pane) }
        let response = await runtime.control.handle(.init(command: "terminal.test.state", arguments: .emptyObject, targetPane: pane))
        #expect(response["ok"] == true, "the plugin got its own pane's controller: \(response)")
        #expect(response["result"]?["columns"] != nil)
        let verbs = await runtime.control.handle(.init(command: "tabs.verbs"))
        let names = verbs["result"].map { value -> [String] in
            guard case .array(let items) = value else { return [] }
            return items.compactMap { $0["name"]?.stringValue }
        }
        #expect(Set(["browser.navigate", "terminal.test.state", "tabs.plugins", "tabs.verbs"]).isSubset(of: Set(names ?? [])))
    }
}
