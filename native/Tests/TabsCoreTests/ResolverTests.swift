import TabsPluginSDK
import Testing

@testable import TabsCore

@Suite struct ResolverTests {
    private func m(_ id: String, order: Int = 100, types: [String] = [], canDisable: Bool = true) -> PluginManifest {
        PluginManifest(
            id: PluginID(id), displayName: id, contentTypes: types.map(ContentTypeID.init(_:)), canDisable: canDisable, sortOrder: order)
    }

    @Test func ordersBySortOrderThenID() {
        let output = PluginResolver.resolve(
            .init(manifests: [m("zeta", order: 1), m("beta", order: 50), m("alpha", order: 50), m("app", order: 0)]))
        #expect(output.activationOrder == ["app", "zeta", "alpha", "beta"])
        #expect(output.disabled.isEmpty)
    }

    @Test func disabledPluginsDoNotLoad() {
        let output = PluginResolver.resolve(.init(manifests: [m("a"), m("b")], disabled: ["b"]))
        #expect(output.activationOrder == ["a"])
        #expect(output.disabled == ["b"])
    }

    @Test func aDisabledPluginStillLoadsWhenAnOpenPaneNeedsIt() {
        let output = PluginResolver.resolve(
            .init(
                manifests: [m("alpha", types: ["alpha"]), m("beta", types: ["beta"])],
                disabled: ["alpha", "beta"], requiredContentTypes: ["alpha"]
            ))
        #expect(output.activationOrder == ["alpha"])
        #expect(output.disabled == ["beta"])
        #expect(output.loadedWhileDisabled == ["alpha": "an open pane shows its content type \"alpha\""])
    }

    @Test func pluginsThatCannotBeDisabledIgnoreTheSetting() {
        let output = PluginResolver.resolve(.init(manifests: [m("core-ish", canDisable: false)], disabled: ["core-ish"]))
        #expect(output.activationOrder == ["core-ish"])
        #expect(output.loadedWhileDisabled.isEmpty)
    }
}
