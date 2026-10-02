import Foundation
import TabsPluginSDK
import Testing

@testable import TabsCore

/// Core's own control verbs — `ping`, `activate-pane`, `close-pane`,
/// `list-panes`, `pane-info` — and protocol discovery, `capabilities` and
/// `describe` (docs/BROWSER.md H-11, H-13).
@MainActor
@Suite struct CoreControlVerbTests {
    let fixture = ControlFixture()

    private func id(_ pane: PaneID) -> JSONValue { .string(pane.rawValue) }
    private func listed(from caller: PaneID = "t1") async -> [JSONValue] {
        if case .array(let panes)? = await fixture.ctl("list-panes", from: caller)["result"]?["panes"] { panes } else { [] }
    }

    // MARK: activate-pane

    @Test func activatePaneRevealsABackgroundedPaneWithoutActivatingIt() async throws {
        let pane = try await fixture.createPane()
        let window = { self.fixture.engine.model.window("w")! }
        // create-web-pane opens as a new tab beside the caller and (it is a tab) shows it.
        #expect(window().isShowing(pane))
        // The user goes back to their terminal's tab.
        fixture.engine.perform(in: "w") { layout, titles in layout.reveal("t1", titles: titles) }
        #expect(!window().isShowing(pane))
        #expect(window().activeLeafID == "t1")

        let focusRequests = fixture.renderer.focused.count
        #expect(await fixture.ctl("activate-pane", ["pane": id(pane)]) == ["ok": true])
        #expect(window().isShowing(pane), "brought to the front")
        #expect(window().activeLeafID == "t1", "the user's active pane is untouched")
        #expect(fixture.renderer.focused.count == focusRequests, "and the keyboard is not stolen")
    }

    @Test func activatePaneRaisesAFloatingPane() async throws {
        let pane = try #require(
            fixture.runtime.panes.openPane(PaneRequest(type: "web", placement: .floating(near: "t1"), controlledBy: "t1")))
        _ = try #require(fixture.runtime.panes.openPane(PaneRequest(type: "web", placement: .floating(near: "t1"))))  // on top now
        let floats = { self.fixture.engine.model.window("w")!.floating.map(\.content.id) }
        #expect(floats().last != pane)
        #expect(await fixture.ctl("activate-pane", ["pane": id(pane)]) == ["ok": true])
        #expect(floats().last == pane)
    }

    // MARK: close-pane

    @Test func closePaneEndsThePaneAndItsOwnership() async throws {
        let pane = try await fixture.createPane()
        #expect(await fixture.ctl("close-pane", ["pane": id(pane)]) == ["ok": true])
        #expect(fixture.web(pane) == nil)
        #expect(!fixture.runtime.panes.ownership.isOwned(pane))
        #expect(await listed().isEmpty)
    }

    @Test func aCloseTheUserDeclinedKeepsThePaneAndItsOwnership() async throws {
        let pane = try await fixture.createPane()
        fixture.web(pane)?.warning = "still busy"
        fixture.renderer.answers = [false]
        let response = await fixture.ctl("close-pane", ["pane": id(pane)])
        #expect(response == ControlDispatcher.failure("the pane was not closed"))
        #expect(fixture.web(pane) != nil)
        #expect(fixture.runtime.panes.ownership.owner(of: pane) == "t1", "a failed close must not strand a live pane as unownable")
        #expect(fixture.runtime.signals.raised(on: pane).map(\.id) == ["controlled"])
    }

    // MARK: list-panes

    @Test func listPanesShowsOnlyThePanesThisCallerCreatedWithEachPanesSummary() async throws {
        let mine = try await fixture.createPane(url: "https://mine.example/")
        let hidden = try await fixture.createPane()
        fixture.web(hidden)?.listed = false
        #expect(await listed() == [["paneId": id(mine), "type": "web", "title": "", "url": "https://mine.example/"]])
        #expect(await listed(from: "t2").isEmpty, "never includes anyone else's, or the user's own")
    }

    @Test func listPanesReadsCoresLiveTitle() async throws {
        let pane = try await fixture.createPane()
        fixture.web(pane)?.context.setTitle("  Example Domain \n")
        #expect(await listed().first?["title"] == "Example Domain")
    }

    @Test func listPanesSeesEveryWindowAndFollowsAPaneThatMoved() async throws {
        let fixture = ControlFixture(windows: [ControlFixture.terminals("t1", id: "w"), ControlFixture.terminals("t3", id: "w2")])
        let first = try await fixture.createPane(from: "t1")
        let second = try await fixture.createPane(from: "t3")
        func ids(_ caller: PaneID) async -> [String] {
            let response = await fixture.ctl("list-panes", from: caller)
            guard case .array(let panes)? = response["result"]?["panes"] else { return [] }
            return panes.compactMap { $0["paneId"]?.stringValue }
        }
        #expect(await ids("t1") == [first.rawValue])
        #expect(await ids("t3") == [second.rawValue])
        // The user drags t1's pane into the other window: still t1's, still listed, still driven.
        let moved = fixture.engine.move(.pane(first), from: "w", to: "w2", at: .dock(targetID: "t3", zone: .right))
        #expect(moved)
        #expect(fixture.engine.model.window("w2")?.holds(first) == true)
        #expect(await ids("t1") == [first.rawValue])
        #expect(await fixture.ctl("reload", ["pane": .string(first.rawValue)], from: "t1")["ok"] == true)
        #expect(await ids("t3") == [second.rawValue])
    }

    // MARK: pane-info

    @Test func paneInfoAddsThePanesLiveFieldsToItsIdentity() async throws {
        let pane = try await fixture.createPane()
        fixture.web(pane)?.describes = .fields(["url": "about:blank", "isLoading": false, "title": "from the page"])
        fixture.web(pane)?.context.setTitle("Tab title")
        let response = await fixture.ctl("pane-info", ["pane": id(pane)])
        #expect(
            response == [
                "ok": true,
                "result": ["paneId": id(pane), "type": "web", "title": "from the page", "url": "about:blank", "isLoading": false],
            ], "the plugin's fields win where they clash")
    }

    @Test func paneInfoSaysWhyAPaneCannotAnswer() async throws {
        let pane = try await fixture.createPane()
        fixture.web(pane)?.describes = .error("browser pane is not currently mounted")
        #expect(await fixture.ctl("pane-info", ["pane": id(pane)]) == ControlDispatcher.failure("browser pane is not currently mounted"))
    }

    @Test func aTypeThatCannotBeInspectedSaysSo() async {
        fixture.runtime.panes.grantOwnership(of: "t2", to: "t1")
        #expect(
            await fixture.ctl("pane-info", ["pane": "t2"]) == ControlDispatcher.failure("term panes cannot be inspected with getPaneInfo"))
    }

    @Test func paneInfoForAClosedPaneIsGone() async throws {
        let pane = try await fixture.createPane()
        fixture.engine.close(pane)
        #expect(await fixture.ctl("pane-info", ["pane": id(pane)]) == ControlDispatcher.failure(ControlDispatcher.paneGoneError))
    }

    // MARK: capabilities

    @Test func everyControlPlaneVerbIsReachableByItsCommandItsQualifiedNameAndItsWireType() throws {
        let control = fixture.runtime.control
        let typed = control.verbs().filter { $0.verb.wireType != nil }
        #expect(typed.count == 8 + ControlFixture.wireTypes.count)
        for (verb, _) in typed {
            let command = try #require(verb.command)
            guard case .found(let byCommand, _) = control.resolve(command: command) else {
                Issue.record("\(command) doesn't resolve")
                continue
            }
            #expect(byCommand.name == verb.name)
            #expect(control.verb(named: verb.name)?.verb.name == verb.name)
            #expect(control.verb(wireType: try #require(verb.wireType))?.verb.name == verb.name)
        }
        // A wire type is core's or a plugin's, never both: core's are the reserved ones.
        let core = Set(control.verbs().filter { $0.owner == "tabs" }.compactMap(\.verb.wireType))
        #expect(core == CoreExtensionPoints.coreWireTypes)
    }

    @Test func capabilitiesListsCoreThenEveryPluginWithItsCommands() async throws {
        let response = await fixture.ctl("capabilities")
        guard case .array(let capabilities)? = response["result"]?["capabilities"] else {
            Issue.record("no capabilities: \(response)")
            return
        }
        #expect(capabilities.map { $0["id"]?.stringValue } == ["core", "web"])
        #expect(capabilities.map { $0["displayName"]?.stringValue } == ["Core", "Web"])
        #expect(capabilities.allSatisfy { $0["enabled"] == true })

        guard case .array(let core)? = capabilities[0]["commands"] else { return }
        #expect(core.count == 8)
        #expect(core.first?.stringValue == "tabs-ctl ping — Check that the control socket is reachable.")
        #expect(
            core.contains(
                "tabs-ctl activate-pane --pane <pane> — Bring a pane you own to the front of its tab group without capturing it. screenshot does this itself when needed."
            ))
        #expect(
            core.contains(
                "tabs-ctl describe --capability <capability> — Full command reference for one capability — flags, wire schema, result shape, and its guide."
            ))
        guard case .array(let web)? = capabilities[1]["commands"] else { return }
        #expect(web.allSatisfy { $0.stringValue?.contains("\n") == false && $0.stringValue?.hasPrefix("tabs-ctl ") == true })
        #expect(
            web.contains(
                "tabs-ctl navigate --pane <pane> --url <url> [--retry-on-redirect] — Load a URL into a pane you own and wait for it to settle."
            ))
        #expect(
            web.contains(
                "tabs-ctl click --pane <pane> [--ref <ref>] [--x <x>] [--y <y>] [--role <role>] [--name <name>] [--selector <css>] [--nth <nth>] (--role/--name/--selector [--nth <n>] | --ref <ref> | --x <n> --y <n>) — Click an element or a viewport coordinate."
            ))
        #expect(web.contains("tabs-ctl scroll --pane <pane> --direction <up|down|left|right> [--amount <amount>] — Scroll the document."))
    }

    @Test func aDisabledPluginsCapabilityIsListedDisabledAndItsVerbsStillAnswer() async throws {
        let pane = try await fixture.createPane()
        fixture.runtime.host.setUserEnabled(false, for: "web")
        let response = await fixture.ctl("capabilities")
        #expect(response["result"]?["capabilities"]?[1]?["enabled"] == false)
        #expect(await fixture.ctl("reload", ["pane": id(pane)])["ok"] == true, "panes that exist keep being driven")
    }

    // MARK: describe

    @Test func describeCoreServesItsLimitsAndCommandsButNoGuide() async throws {
        let response = await fixture.ctl("describe", ["capability": "core"])
        let result = try #require(response["result"])
        #expect(result["capability"] == "core")
        #expect(result["limits"] == ["maxBatchRequests": 50])
        #expect(result["guide"] == nil)
        guard case .array(let commands)? = result["commands"] else { return }
        #expect(
            commands.map { $0["command"]?.stringValue }
                == ["ping", "activate-pane", "close-pane", "list-panes", "pane-info", "batch", "capabilities", "describe"])
        let batch = try #require(commands.first { $0["command"] == "batch" })
        #expect(batch["usage"] == "tabs-ctl batch --requests <requests> [--continue-on-error]")
        #expect(
            batch["flags"] == [
                "requests": [
                    "required": true, "type": "json",
                    "doc": "A JSON array of wire requests — see describe --capability <name> for each verb’s wire shape.",
                ],
                "continue-on-error": [
                    "required": false, "type": "boolean", "doc": "Run every step even after one fails; failures stay visible per step.",
                ],
            ])
        #expect(
            batch["wire"] == [
                "type": "object",
                "properties": ["type": ["const": "batch"], "requests": ["type": "array"], "continueOnError": ["type": "boolean"]],
                "required": ["type", "requests"], "additionalProperties": false,
            ])
        #expect(batch["result"] == ["steps": ["object"], "stoppedAt": "number"])
        let close = try #require(commands.first { $0["command"] == "close-pane" })
        #expect(close["flags"] == ["pane": ["required": true, "doc": "A pane id you own."]])
        #expect(
            close["wire"] == [
                "type": "object", "properties": ["type": ["const": "closePane"], "targetPaneId": ["type": "string"]],
                "required": ["type", "targetPaneId"], "additionalProperties": false,
            ])
    }

    @Test func describeAPluginServesItsGuideLimitsAndEveryCommandsFlagsWireAndResult() async throws {
        let response = await fixture.ctl("describe", ["capability": "web"])
        let result = try #require(response["result"])
        #expect(result["capability"] == "web")
        #expect(result["guide"] == "Web panes. Read the page before you click.")
        #expect(result["limits"] == ["maxText": 50_000])
        guard case .array(let commands)? = result["commands"] else { return }
        let click = try #require(commands.first { $0["command"] == "click" })
        #expect(click["usage"]?.stringValue?.hasPrefix("tabs-ctl click --pane <pane>") == true)
        #expect(click["wire"]?["type"] == "object")
        #expect(click["wire"]?["required"] == ["type", "targetPaneId", "target"])
        #expect(click["target"]?.stringValue?.hasPrefix("Pass any of --role/--name/--selector") == true)
        #expect(
            click["flags"]?["nth"] == [
                "required": false, "type": "number", "min": 0, "doc": "0-based pick among several matches of the strictest tier.",
            ])
        #expect(click["flags"]?["selector"]?["doc"] == "Match by CSS selector, combined with --role/--name.")
        let navigate = try #require(commands.first { $0["command"] == "navigate" })
        #expect(navigate["result"] == ["loaded": "boolean", "url": "string"])
        #expect(
            navigate["flags"] == [
                "pane": ["required": true, "doc": "A pane id you own."],
                "url": ["required": true, "doc": "http://, https://, or about:blank."],
                "retry-on-redirect": [
                    "required": false, "type": "boolean", "doc": "Re-issue the navigation once if it lands elsewhere.",
                ],
            ])
        let scroll = try #require(commands.first { $0["command"] == "scroll" })
        #expect(scroll["flags"]?["direction"] == ["required": true, "enum": ["up", "down", "left", "right"]])
        let out = try #require(commands.first { $0["command"] == "execute-js" })
        #expect(out["flags"]?["out"] == ["required": false, "type": "path", "doc": "Write the result here."])
        let create = try #require(commands.first { $0["command"] == "create-web-pane" })
        #expect(create["flags"]?["pane"] == nil, "a verb with no target takes no --pane")
    }

    @Test func anUnknownCapabilityIsRefusedNamingCapabilities() async {
        let response = await fixture.ctl("describe", ["capability": "nonexistent"])
        #expect(response == ControlDispatcher.failure("unknown capability \"nonexistent\" — run capabilities to list them"))
    }
}
