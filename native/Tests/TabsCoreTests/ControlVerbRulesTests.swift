import Foundation
import TabsPluginSDK
import Testing

@testable import TabsCore

/// What a plugin may declare as a control-plane verb or capability: every rule
/// is about its own contributions, so no plugin can make another fail.
@MainActor
@Suite struct ControlVerbRulesTests {
    private func run(_ plugins: PluginCandidate...) -> CoreRuntime {
        let runtime = TestSupport.runtime()
        runtime.startPlugins(from: nil, inProcess: plugins)
        return runtime
    }

    private func failure(_ id: String, _ register: @escaping @MainActor (any PluginContext) -> Void) -> String? {
        let runtime = run(
            TestSupport.candidate(TestSupport.manifest(id, contentTypes: ["\(id)"])) { context in
                context.register(TestSupport.contentType(id))
                register(context)
            })
        if case .failed(let reason)? = TestSupport.state(runtime, id) { return reason }
        return nil
    }

    private func verb(
        _ plugin: String, command: String? = "go", wireType: String? = "go", arguments: [ControlArgument] = [],
        target: ControlTarget = .none, composition: ControlFlagComposition? = nil
    ) -> ControlVerbContribution {
        ControlVerbContribution(
            name: "\(plugin).go", summary: "go", arguments: arguments, target: target, command: command, wireType: wireType,
            composition: composition
        ) { _ in nil }
    }

    private func capability(_ plugin: String) -> ControlCapabilityContribution {
        ControlCapabilityContribution(id: plugin, displayName: "P")
    }

    @Test func aCommandNeedsAWireTypeAndAWireTypeACommand() {
        #expect(
            failure("p") { $0.register(self.verb("p", command: "go", wireType: nil)) }?.contains("a command needs a wireType") == true)
        #expect(
            failure("p") { $0.register(self.verb("p", command: nil, wireType: "go")) }?.contains("a wireType needs a command") == true)
    }

    @Test func aControlPlaneVerbIsSpelledRight() {
        #expect(failure("p") { $0.register(self.verb("p", command: "Go Now")) }?.contains("must be kebab-case") == true)
        #expect(failure("p") { $0.register(self.verb("p", wireType: "go-now")) }?.contains("must be lowerCamelCase") == true)
        #expect(
            failure("p") {
                $0.register(self.capability("p")); $0.register(self.verb("p", command: "go-now", wireType: "goNow"))
            } == nil)
    }

    @Test func aWireTypeMayNotBeOneOfCoresNorAnotherPluginsButACommandMayBeShared() {
        #expect(
            failure("p") {
                $0.register(self.capability("p")); $0.register(self.verb("p", command: "go", wireType: "ping"))
            }?
            .contains("wireType \"ping\" is one of core's") == true)
        let runtime = run(
            TestSupport.candidate(TestSupport.manifest("one")) { context in
                context.register(self.capability("one"))
                context.register(self.verb("one"))
            },
            TestSupport.candidate(TestSupport.manifest("two")) { context in
                context.register(self.capability("two"))
                context.register(self.verb("two", command: "go", wireType: "go"))
            })
        #expect(TestSupport.state(runtime, "one") == .active, "the first is unaffected")
        guard case .failed(let reason)? = TestSupport.state(runtime, "two") else {
            Issue.record("the second should fail")
            return
        }
        #expect(reason.contains("wireType \"go\" is already one's"))

        let sharing = run(
            TestSupport.candidate(TestSupport.manifest("one")) { context in
                context.register(self.capability("one"))
                context.register(self.verb("one", command: "go", wireType: "oneGo"))
            },
            TestSupport.candidate(TestSupport.manifest("two")) { context in
                context.register(self.capability("two"))
                context.register(self.verb("two", command: "go", wireType: "twoGo"))
            })
        #expect(TestSupport.state(sharing, "one") == .active && TestSupport.state(sharing, "two") == .active)
    }

    @Test func anArgumentMayNotBeAFieldOfTheWireRequestItself() {
        for name in ["type", "paneId", "targetPaneId"] {
            let reason = failure("p") { context in
                context.register(self.capability("p"))
                context.register(self.verb("p", arguments: [ControlArgument(name, .string)]))
            }
            #expect(reason?.contains("argument \"\(name)\" is a field of the wire request itself") == true, "\(name)")
        }
        let reason = failure("p") { context in
            context.register(self.capability("p"))
            context.register(self.verb("p", arguments: [ControlArgument("target", .string)], composition: .elementTarget))
        }
        #expect(reason?.contains("argument \"target\" is a field of the wire request itself") == true)
    }

    @Test func aFlagMayNotBeDeclaredTwiceOrClashWithOneCoreAdds() {
        let twice = failure("p") { context in
            context.register(self.capability("p"))
            context.register(self.verb("p", arguments: [ControlArgument("outPath", .path, flag: "out"), ControlArgument("out", .string)]))
        }
        #expect(twice?.contains("flag --out is declared twice") == true)
        let pane = failure("p") { context in
            context.register(self.capability("p"))
            context.register(
                self.verb("p", arguments: [ControlArgument("which", .string, flag: "pane")], target: .ownedPane(ofTypes: ["p"])))
        }
        #expect(pane?.contains("flag --pane is declared twice (or is one core adds)") == true)
        let composed = failure("p") { context in
            context.register(self.capability("p"))
            context.register(
                self.verb(
                    "p", arguments: [ControlArgument("ref", .string)], target: .ownedPane(ofTypes: ["p"]), composition: .elementTarget))
        }
        #expect(composed?.contains("flag --ref is declared twice") == true)
        let bad = failure("p") { context in
            context.register(self.capability("p"))
            context.register(self.verb("p", arguments: [ControlArgument("x", .string, flag: "Not Kebab")]))
        }
        #expect(bad?.contains("must be kebab-case") == true)
    }

    @Test func anOwnedPaneTargetAndACompositionAreForControlPlaneVerbs() {
        let target = failure("p") {
            $0.register(self.verb("p", command: nil, wireType: nil, target: .ownedPane(ofTypes: ["p"])))
        }
        #expect(target?.contains("an owned-pane target is for control-plane verbs") == true)
        let composition = failure("p") {
            $0.register(self.verb("p", command: nil, wireType: nil, composition: .elementTarget))
        }
        #expect(composition?.contains("a flag composition is for control-plane verbs") == true)
    }

    @Test func anOwnedPaneTargetNamesOnlyThePluginsOwnTypes() {
        let foreign = failure("p") { context in
            context.register(self.capability("p"))
            context.register(self.verb("p", target: .ownedPane(ofTypes: ["other"])))
        }
        #expect(foreign?.contains("target type \"other\" is not one of this plugin's content types") == true)
        let empty = failure("p") { context in
            context.register(self.capability("p"))
            context.register(self.verb("p", target: .ownedPane(ofTypes: [])))
        }
        #expect(empty?.contains("an owned-pane target names no content types") == true)
        #expect(
            failure("p") { context in
                context.register(self.capability("p"))
                context.register(self.verb("p", target: .ownedPane(ofTypes: nil)))
            } == nil, "any type is core's own three")
    }

    @Test func aPluginWithCommandsMustDeclareItsCapability() {
        let reason = failure("p") { $0.register(self.verb("p")) }
        #expect(reason?.contains("must also register a ControlCapabilityContribution") == true)
    }

    @Test func aCapabilityIsThePluginsOwnAndHasAName() {
        #expect(
            failure("p") { $0.register(ControlCapabilityContribution(id: "other", displayName: "O")) }?.contains(
                "must be the plugin's own id, \"p\"") == true)
        #expect(
            failure("p") { $0.register(ControlCapabilityContribution(id: "p", displayName: " ")) }?.contains("displayName is empty") == true
        )
        #expect(
            failure("p") { $0.register(ControlCapabilityContribution(id: "p", displayName: "P", limits: ["x": .double(.nan)])) }?
                .contains("limits must be valid JSON") == true)
        #expect(failure("p") { $0.register(ControlCapabilityContribution(id: "p", displayName: "P")) } == nil)
    }

    @Test func aPluginsBadVerbDoesNotFailAnother() {
        let runtime = run(
            TestSupport.candidate(TestSupport.manifest("bad")) { $0.register(self.verb("bad", command: "Go Now")) },
            TestSupport.candidate(TestSupport.manifest("good")) { context in
                context.register(self.capability("good"))
                context.register(self.verb("good", command: "go", wireType: "goodGo"))
            })
        #expect(TestSupport.state(runtime, "good") == .active)
        #expect(runtime.control.verbs().contains { $0.verb.name == "good.go" })
        #expect(!runtime.control.verbs().contains { $0.verb.name == "bad.go" })
    }

    @Test func tabsVerbsDescribesAControlPlaneVerbsCommandWireTypeAndFlags() async throws {
        let runtime = run(
            TestSupport.candidate(TestSupport.manifest("p")) { context in
                context.register(self.capability("p"))
                context.register(
                    self.verb(
                        "p", command: "go-now", wireType: "goNow",
                        arguments: [ControlArgument("timeoutMs", .number, minimum: 1, flag: "timeout")]))
            })
        let response = await runtime.control.handle(json: #"{"command":"tabs.verbs"}"#)
        guard case .array(let verbs)? = response["result"] else { return }
        let go = try #require(verbs.first { $0["name"] == "p.go" })
        #expect(go["command"] == "go-now" && go["wireType"] == "goNow" && go["batchable"] == true)
        #expect(go["arguments"]?[0]?["flag"] == "timeout")
        #expect(go["arguments"]?[0]?["minimum"] == 1)
        let ping = try #require(verbs.first { $0["name"] == "tabs.ping" })
        #expect(ping["command"] == "ping" && ping["target"] == JSONValue.null)
        let close = try #require(verbs.first { $0["name"] == "tabs.closePane" })
        #expect(close["target"] == ["ownedPane": "any"])
    }
}
