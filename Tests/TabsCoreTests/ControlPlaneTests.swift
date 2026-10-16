import Foundation
import TabsPluginSDK
import Testing

@testable import TabsCore

/// The control plane's dispatch, envelope handling and ownership rules — the
/// cases of docs/BROWSER.md H-1 … H-5, H-9, H-15, H-17 and J-24's core half, against
/// a real core with the layout engine, a fake renderer and the fixture plugin
/// (whose verbs are shaped like the browser's, and are nothing else).
@MainActor
@Suite struct ControlPlaneTests {
    let fixture = ControlFixture()
    var log: ControlFixture.Log { fixture.log }
    var ledger: PaneOwnership { fixture.runtime.panes.ownership }
    var signals: PaneSignals { fixture.runtime.signals }

    private static let gone = ControlDispatcher.paneGoneError

    /// The panes the registry put under control, as it announced them.
    @MainActor final class Enabled {
        var panes: [PaneID] = []
    }

    // MARK: H-1: who is asking

    @Test func aCallerWithNoLivePaneIsRefusedBeforeAnythingElse() async {
        // Not a pane in this app at all: a socket client that guessed a shape.
        for command in ["ping", "list-panes", "capabilities", "create-web-pane"] {
            let flags: [String: JSONValue] = command == "create-web-pane" ? ["url": "about:blank"] : [:]
            let response = await fixture.ctl(command, flags, from: "ghost")
            #expect(response == ControlDispatcher.failure("not running inside a Tabs pane"), "\(command)")
        }
        #expect(log.invocations.isEmpty)
        #expect(log.openedPanes.isEmpty)
    }

    @Test func aCallerWithNoPaneIdAtAllIsRefusedTheSameWay() async {
        let response = await fixture.runtime.control.handle(
            ControlDispatcher.Envelope(command: "ping", arguments: .emptyObject, targetPane: nil))
        #expect(response == ControlDispatcher.failure("not running inside a Tabs pane"))
    }

    @Test func aPaneThatIsMadeButNotOpenYetIsNotACaller() async throws {
        let unopened = try #require(fixture.runtime.panes.create(PaneRequest(type: "term"), in: "w"))
        #expect(await fixture.ctl("ping", from: unopened.id) == ControlDispatcher.failure("not running inside a Tabs pane"))
    }

    @Test func aLiveCallerOfAnyPluginMayAsk() async {
        #expect(await fixture.ctl("ping", from: "t2") == ["ok": true])
    }

    // MARK: H-2: ownership

    @Test func anAgentCreatesAPaneOwnsItAndDrivesItButNoOther() async throws {
        let pane = try await fixture.createPane()
        #expect(ledger.controller(of: pane) == "t1")
        #expect(await fixture.ctl("navigate", ["pane": .string(pane.rawValue), "url": "about:blank"])["ok"] == true)

        // t2 is the user's own pane, a real pane: not its owner's to drive.
        let refused = ControlDispatcher.failure("not the owner of this pane")
        #expect(await fixture.ctl("navigate", ["pane": "t2", "url": "about:blank"]) == refused)
        #expect(await fixture.ctl("navigate", ["pane": "not-a-pane-this-agent-created", "url": "about:blank"]) == refused)
    }

    @Test func oneAgentCannotDriveAPaneAnotherAgentCreated() async throws {
        let pane = try await fixture.createPane(from: "t1")
        let refused = await fixture.ctl("navigate", ["pane": .string(pane.rawValue), "url": "about:blank"], from: "t2")
        #expect(refused == ControlDispatcher.failure("not the owner of this pane"))
        let listed = await fixture.ctl("list-panes", from: "t2")
        #expect(listed["result"]?["panes"] == [])
        #expect(log.invocations.filter { $0.command == "navigate" }.isEmpty, "the handler never ran")
    }

    @Test func everyVerbANamedTargetIsRefusedUniformly() async throws {
        // Enforced once, in core: a verb a plugin adds can't ship without it.
        let refused = ControlDispatcher.failure("not the owner of this pane")
        for command in ["navigate", "reload", "click", "scroll", "get-page-text", "activate-pane", "close-pane", "pane-info"] {
            var flags: [String: JSONValue] = ["pane": "t2"]
            switch command {
            case "navigate": flags["url"] = "x"
            case "click": flags["ref"] = "e1"
            case "scroll": flags["direction"] = "up"
            default: break
            }
            #expect(await fixture.ctl(command, flags) == refused, "\(command)")
        }
        #expect(log.invocations.isEmpty)
    }

    @Test func ownershipOutlivesTheUserNavigatingThePaneByHand() async throws {
        let pane = try await fixture.createPane()
        fixture.web(pane)?.url = "https://elsewhere.example/"
        #expect(await fixture.ctl("navigate", ["pane": .string(pane.rawValue), "url": "about:blank"])["ok"] == true)
        #expect(ledger.controller(of: pane) == "t1", "never expired, never re-scoped")
    }

    // MARK: H-3: a pane that is gone

    @Test func aPaneItsOwnerClosedIsGoneToThatOwnerAndUniformlyRefusedToEveryoneElse() async throws {
        let pane = try await fixture.createPane(from: "t1")
        let id = JSONValue.string(pane.rawValue)
        #expect(await fixture.ctl("close-pane", ["pane": id]) == ["ok": true])
        #expect(fixture.web(pane) == nil)

        let closer = await fixture.ctl("navigate", ["pane": id, "url": "about:blank"], from: "t1")
        #expect(closer == ControlDispatcher.failure(Self.gone))
        let stranger = await fixture.ctl("navigate", ["pane": id, "url": "about:blank"], from: "t2")
        #expect(stranger == ControlDispatcher.failure("not the owner of this pane"), "no liveness oracle")
    }

    @Test func aPaneTheUserClosedByHandIsGoneToItsOwnerToo() async throws {
        let pane = try await fixture.createPane(from: "t1")
        fixture.engine.close(pane)
        #expect(fixture.web(pane) == nil)
        let response = await fixture.ctl("get-page-text", ["pane": .string(pane.rawValue)], from: "t1")
        #expect(response == ControlDispatcher.failure(Self.gone), "not 'not a web pane', not 'not the owner'")
        #expect(
            await fixture.ctl("pane-info", ["pane": .string(pane.rawValue)], from: "t2")
                == ControlDispatcher.failure("not the owner of this pane"))
        #expect(!ledger.isControlled(pane))
    }

    @Test func theLedgerRemembersTheLastHundredClosedPanes() async {
        // Ids no open pane has: brought under control as panes being made.
        for index in 0...PaneOwnership.closedPaneMemory {
            ledger.enableControl(ofNewPane: PaneID("old\(index)"), from: "t1")
            ledger.paneClosed(PaneID("old\(index)"))
        }
        let request: (String) async -> JSONValue = { id in
            await self.fixture.wire(["type": "reload", "targetPaneId": .string(id)])
        }
        #expect(await request("old0") == ControlDispatcher.failure("not the owner of this pane"), "the oldest was forgotten")
        #expect(await request("old1") == ControlDispatcher.failure(Self.gone))
        #expect(await request("old100") == ControlDispatcher.failure(Self.gone))
    }

    @Test func aPaneThatWasNeverPlacedLeavesNoTombstone() async throws {
        // The layout has nowhere to put it: the pane is made, owned, then dropped unopened.
        let shell = FakeShell(runtime: fixture.runtime.panes)
        shell.refusesPlacement = true
        let enabled = Enabled()
        ledger.observe { if case .enabled(let pair) = $0 { enabled.panes.append(pair.controlled) } }
        let opened = fixture.runtime.panes.openPane(PaneRequest(type: "web", controlledBy: "t1"))
        #expect(opened == nil)
        let made = try #require(enabled.panes.first, "it was controlled while being made")
        #expect(ledger.pairs.isEmpty)
        #expect(!ledger.wasClosed(made, by: "t1"), "nobody learned its id: no tombstone")
        withExtendedLifetime(shell) {}
    }

    // MARK: H-4: granting

    @Test func aPaneIsOwnedFromTheInstantItsPluginBuildsIt() async throws {
        let pane = try await fixture.createPane(from: "t1")
        #expect(fixture.web(pane)?.controllerAtInit == "t1", "before its view, before anything it loads first")
        #expect(fixture.web(pane)?.context.controller == "t1")
        fixture.engine.close(pane)
        #expect(ledger.controller(of: pane) == nil)
    }

    @Test func aPluginMayNameOnlyTheCallerOfItsOwnRunningVerbAsAControllerAndNeverOutsideOne() async throws {
        // Outside any verb: refused, and no pane is made.
        let before = fixture.runtime.panes.panes(ofType: "web")
        let outside = fixture.runtime.panes.openPane(PaneRequest(type: "web", controlledBy: "t1"), by: "web")
        #expect(outside == nil)
        // Inside a verb, naming another pane than the one asking: refused.
        let stolen = await fixture.ctl("steal-pane", ["controller": "t2"], from: "t1")
        #expect(stolen == ControlDispatcher.failure("the pane could not be opened"))
        #expect(fixture.runtime.panes.panes(ofType: "web") == before)
        // Naming the caller: allowed.
        let own = await fixture.ctl("steal-pane", ["controller": "t1"], from: "t1")
        #expect(own["ok"] == true)
        // And core itself may name anyone.
        let core = try #require(fixture.runtime.panes.openPane(PaneRequest(type: "web", controlledBy: "t2")))
        #expect(ledger.controller(of: core) == "t2")
        #expect(!ledger.isRunning("web", for: "t1"), "a finished verb no longer counts")
    }

    // MARK: H-5: the controlled signal

    @Test func anOwnedPaneCarriesTheControlledSignalAndItNeverReachesItsTab() async throws {
        let pane = try await fixture.createPane()
        #expect(signals.raised(on: pane).map(\.id) == ["controlled"])
        #expect(signals.raised(on: "t1").isEmpty, "the caller is not marked")
        let leaves = fixture.engine.model.window("w")?.leaves.map(\.id) ?? []
        #expect(signals.tabMarks(for: leaves).isEmpty, "controlled never marks a tab")
    }

    @Test func closingThePaneWithdrawsItWhoeverClosesIt() async throws {
        let byOwner = try await fixture.createPane()
        _ = await fixture.ctl("close-pane", ["pane": .string(byOwner.rawValue)])
        #expect(signals.raised(on: byOwner).isEmpty)

        let byHand = try await fixture.createPane()
        fixture.engine.close(byHand)
        #expect(signals.raised(on: byHand).isEmpty)
    }

    @Test func enablingControlOfAPaneThatIsAlreadyOpenRaisesTheCue() {
        ledger.enableControl(of: "t2", from: "t1")
        #expect(signals.raised(on: "t2").map(\.id) == ["controlled"])
        #expect(ledger.controller(of: "t2") == "t1")
    }

    // MARK: H-17: one registry, both ends

    @Test func closingTheControllerFreesItsPanesAndTakesTheirCueDown() async throws {
        let pane = try await fixture.createPane(from: "t1")
        let other = try await fixture.createPane(from: "t2")
        fixture.engine.close("t1")
        #expect(fixture.web(pane) != nil, "freed, not closed")
        #expect(ledger.controller(of: pane) == nil)
        #expect(fixture.web(pane)?.context.controller == nil, "what the plugin's guards read")
        #expect(signals.raised(on: pane).isEmpty)
        #expect(ledger.controller(of: other) == "t2", "another controller's pane is untouched")
        #expect(signals.raised(on: other).map(\.id) == ["controlled"])
    }

    @Test func disablingControlTakesTheCueDownAndRefusesTheFormerControllerLikeAnyoneElse() async throws {
        let pane = try await fixture.createPane(from: "t1")
        ledger.disableControl(of: pane, from: "t1")
        #expect(signals.raised(on: pane).isEmpty)
        let response = await fixture.ctl("reload", ["pane": .string(pane.rawValue)], from: "t1")
        #expect(response == ControlDispatcher.failure("not the owner of this pane"), "still open: not 'gone'")
        #expect(await fixture.ctl("list-panes", from: "t1")["result"]?["panes"] == .array([]))
    }

    @Test func controlIsNeverTakenOverOnlyHandedOverOnceDisabled() async throws {
        let pane = try await fixture.createPane(from: "t1")
        let id = JSONValue.string(pane.rawValue)
        let takenOver = ledger.enableControl(of: pane, from: "t2")
        #expect(!takenOver)
        #expect(await fixture.ctl("reload", ["pane": id], from: "t1")["ok"] == true, "the agent keeps its pane")
        #expect(await fixture.ctl("reload", ["pane": id], from: "t2") == ControlDispatcher.failure("not the owner of this pane"))

        ledger.disableControl(of: pane, from: "t1")
        let handedOver = ledger.enableControl(of: pane, from: "t2")
        #expect(handedOver)
        #expect(fixture.web(pane)?.context.controller == "t2")
        #expect(signals.raised(on: pane).map(\.id) == ["controlled"])
        #expect(await fixture.ctl("reload", ["pane": id], from: "t1") == ControlDispatcher.failure("not the owner of this pane"))
        #expect(await fixture.ctl("reload", ["pane": id], from: "t2")["ok"] == true)
    }

    @Test func aPaneIsNotOpenedUnderAControllerThatIsNotOpen() {
        let built = log.builtPanes
        #expect(fixture.runtime.panes.openPane(PaneRequest(type: "web", controlledBy: "gone")) == nil)
        #expect(log.builtPanes == built, "the plugin never built it")
        #expect(ledger.pairs.isEmpty)
    }

    @Test func controlOfAPaneThatIsNotOpenIsRefused() {
        let refused = ledger.enableControl(of: "nobody", from: "t1")
        #expect(!refused, "a later pane with that id would start out controlled")
        #expect(ledger.pairs.isEmpty)
    }

    // MARK: The order of checks

    @Test func callerThenOwnershipThenSchemaThenTargetThenHandler() async throws {
        let owned = try await fixture.createPane()
        let ownedID = JSONValue.string(owned.rawValue)
        fixture.runtime.panes.ownership.enableControl(of: "t2", from: "t1")  // owned, but a term pane
        log.invocations.removeAll()

        // 1. A caller that isn't a pane beats everything, an unowned target and a bad shape included.
        let ghost = await fixture.wire(["type": "navigate", "targetPaneId": "nobody", "wat": 1], from: "ghost")
        #expect(ghost == ControlDispatcher.failure("not running inside a Tabs pane"))
        // 2. An unowned target beats a bad shape.
        let unowned = await fixture.wire(["type": "navigate", "targetPaneId": "nobody", "wat": 1])
        #expect(unowned == ControlDispatcher.failure("not the owner of this pane"))
        // 3. A bad shape beats the target being of the wrong type.
        let shaped = await fixture.wire(["type": "navigate", "targetPaneId": "t2"])
        #expect(shaped == ControlDispatcher.failure("request is missing required field \"url\""))
        // 4. The target's type beats the handler.
        let typed = await fixture.wire(["type": "navigate", "targetPaneId": "t2", "url": "x"])
        #expect(typed == ControlDispatcher.failure("target is not a web pane"))
        #expect(log.invocations.isEmpty, "no handler ran")
        // And with everything right, it runs.
        #expect(await fixture.wire(["type": "navigate", "targetPaneId": ownedID, "url": "x"])["ok"] == true)
        #expect(log.invocations.count == 1)
    }

    @Test func anUnknownRequestTypeIsNamedBeforeAnythingIsChecked() async {
        #expect(await fixture.wire(["type": "nope"], from: "ghost") == ControlDispatcher.failure("unknown request type: nope"))
        #expect(await fixture.wire([:], from: "ghost") == ControlDispatcher.failure("unknown request type: (none)"))
        #expect(await fixture.wire(["type": 5]) == ControlDispatcher.failure("unknown request type: (none)"))
    }

    // MARK: J-24 (core's half): the target's type

    @Test func aTargetOfAnotherTypeIsRefusedByNameBeforeTheHandlerRuns() async {
        fixture.runtime.panes.ownership.enableControl(of: "t2", from: "t1")
        #expect(await fixture.ctl("navigate", ["pane": "t2", "url": "x"]) == ControlDispatcher.failure("target is not a web pane"))
        #expect(await fixture.ctl("reload", ["pane": "t2"]) == ControlDispatcher.failure("target is not a web pane"))
        #expect(log.invocations.isEmpty)
        // Core's own verbs take any type.
        #expect(await fixture.ctl("activate-pane", ["pane": "t2"]) == ["ok": true])
    }

    // MARK: H-9: the wire schema, for flags and for a step alike

    @Test func aWireRequestIsValidatedAgainstTheVerbsOwnSchema() async throws {
        let pane = try await fixture.createPane()
        let id = JSONValue.string(pane.rawValue)
        #expect(
            await fixture.wire(["type": "navigate", "targetPaneId": id, "url": 5])
                == ControlDispatcher.failure("request.url must be a string (got number)"))
        #expect(
            await fixture.wire(["type": "navigate", "targetPaneId": id, "url": "x", "colour": "red"])
                == ControlDispatcher.failure("request has an unexpected field \"colour\""))
        #expect(
            await fixture.wire(["type": "scroll", "targetPaneId": id, "direction": "sideways"])
                == ControlDispatcher.failure("request.direction must be one of up, down, left, right (got \"sideways\")"))
        #expect(
            await fixture.wire(["type": "getPageText", "targetPaneId": id, "maxLength": 0])
                == ControlDispatcher.failure("request.maxLength must be at least 1 (got 0)"))
        #expect(
            await fixture.wire(["type": "click", "targetPaneId": id, "target": ["x": 1]])
                == ControlDispatcher.failure("request.target must match exactly one of its allowed shapes (matched 0)"))
        #expect(log.invocations.filter { $0.command != "create-web-pane" }.isEmpty)
    }

    /// A path on the wire is a string or `true` ("generate one"), never
    /// anything else a handler could mistake for one.
    @Test func aPathOnTheWireIsAStringOrTrue() async throws {  // H-9
        let pane = try await fixture.createPane()
        let id = JSONValue.string(pane.rawValue)
        let refused = ControlDispatcher.failure("request.outPath must match at least one of its allowed shapes")
        for value: JSONValue in [false, 0, ["a.png"]] {
            #expect(await fixture.wire(["type": "executeJavaScript", "targetPaneId": id, "code": "1", "outPath": value]) == refused)
        }
        let batch = await fixture.ctl(
            "batch", ["requests": [["type": "executeJavaScript", "targetPaneId": id, "code": "1", "outPath": false]]])
        let step = batch["result"]?["steps"]?[0]
        #expect(step?["ok"] == false && step?["error"] == refused["error"], "\(batch)")
        #expect(log.invocations.filter { $0.command == "execute-js" }.isEmpty, "no handler ran")
    }

    @Test func aTargetPaneIdThatIsNotAStringIsNotAnOwner() async {
        #expect(
            await fixture.wire(["type": "reload", "targetPaneId": 7]) == ControlDispatcher.failure("not the owner of this pane"))
    }

    @Test func aTargetLessRequestForATargetedVerbIsAMissingField() async {
        #expect(await fixture.wire(["type": "reload"]) == ControlDispatcher.failure("request is missing required field \"targetPaneId\""))
    }

    /// `null` counts as absent on the wire, as it does for a flag: a batch step
    /// may spell an optional field it doesn't use as `null`.
    @Test func aNullFieldOnTheWireIsAbsent() async throws {  // H-9
        let pane = try await fixture.createPane()
        let id = JSONValue.string(pane.rawValue)
        let batch = await fixture.ctl(
            "batch", ["requests": [["type": "navigate", "targetPaneId": id, "url": "x", "retryOnRedirect": nil]]])
        #expect(batch["result"]?["steps"]?[0]?["ok"] == true, "\(batch)")
        #expect(log.invocations.last?.invocation.arguments == ["url": "x"], "the handler never sees it")
        // A null target is no target: a targeted verb misses it, an untargeted one runs.
        #expect(
            await fixture.wire(["type": "reload", "targetPaneId": nil])
                == ControlDispatcher.failure("request is missing required field \"targetPaneId\""))
        #expect(await fixture.wire(["type": "ping", "targetPaneId": nil]) == ["ok": true])
        // A null type is no type, and a null caller no caller.
        #expect(await fixture.wire(["type": nil]) == ControlDispatcher.failure("unknown request type: (none)"))
        #expect(
            await fixture.runtime.control.dispatch(wire: ["type": "ping", "paneId": nil], cwd: nil)
                == ControlDispatcher.failure("not running inside a Tabs pane"))
    }

    // MARK: H-15: the envelope

    @Test func aMalformedEnvelopeIsRefusedWithAValidationMessageBeforeAnythingIsDispatched() async {
        #expect(await fixture.ctl("not-a-real-command")["error"]?.stringValue?.contains("unknown command") == true)
        let missing = await fixture.ctl("navigate", ["pane": "whatever"])
        #expect(missing["error"]?.stringValue?.contains("--url is required") == true)
        #expect(log.invocations.isEmpty)
        #expect(
            await fixture.runtime.control.handle(json: #"{"args":{}}"#) == ControlDispatcher.failure("request has no \"command\" string"))
        #expect(
            await fixture.runtime.control.handle(json: #"{"command":"ping","args":[1],"paneId":"t1"}"#)
                == ControlDispatcher.failure("\"args\" must be an object"))
    }

    @Test func aBareCommandIsUnknownInTabsCtlsWordsAndAQualifiedOneInTabsVerbs() async {
        #expect(await fixture.ctl("nope") == ControlDispatcher.failure("unknown command: nope — run capabilities to list them"))
        #expect(await fixture.ctl("web.nope") == ControlDispatcher.failure("unknown command \"web.nope\" (tabs.verbs lists them)"))
    }

    // MARK: Commands

    @Test func aVerbAnswersToItsCommandAndToItsQualifiedName() async throws {
        let pane = try await fixture.createPane()
        let flags: [String: JSONValue] = ["pane": .string(pane.rawValue), "url": "about:blank"]
        #expect(await fixture.ctl("navigate", flags)["ok"] == true)
        #expect(await fixture.ctl("web.navigate", flags)["ok"] == true)
        #expect(await fixture.ctl("tabs.ping") == ["ok": true])
        #expect(await fixture.ctl("ping") == ["ok": true])
    }

    @Test func aBareCommandTwoVerbsShareIsRefusedNamingBoth() async throws {
        let other = TestSupport.candidate(TestSupport.manifest("alt")) { context in
            context.register(ControlCapabilityContribution(id: "alt", displayName: "Alt"))
            context.register(
                ControlVerbContribution(name: "alt.navigate", summary: "another", command: "navigate", wireType: "altNavigate") { _ in nil }
            )
        }
        let fixture = ControlFixture(extra: [other])
        let response = await fixture.ctl("navigate")
        #expect(
            response == ControlDispatcher.failure("command \"navigate\" is ambiguous (alt.navigate, web.navigate); use a qualified name"))
        #expect(await fixture.ctl("alt.navigate")["ok"] == true, "the qualified name still works")
    }

    // MARK: What the handler gets

    @Test func aHandlerGetsTheWireFieldsTheCallerTheTargetAndTheCwd() async throws {
        let pane = try await fixture.createPane()
        log.invocations.removeAll()
        let response = await fixture.ctl(
            "execute-js", ["pane": .string(pane.rawValue), "code": "1 + 1", "out": "notes/result.json"], from: "t1",
            cwd: URL(filePath: "/work", directoryHint: .isDirectory))
        #expect(response == ["ok": true, "result": ["echo": ["code": "1 + 1", "outPath": "/work/notes/result.json"]]])
        let seen = try #require(log.invocations.first?.invocation)
        #expect(seen.callerPane == "t1")
        #expect(seen.targetPane == pane)
        #expect(seen.cwd == URL(filePath: "/work", directoryHint: .isDirectory))
        #expect(seen.arguments["type"] == nil && seen.arguments["paneId"] == nil && seen.arguments["targetPaneId"] == nil)
        #expect(seen.pane(as: WebPane.self) === fixture.web(pane), "its own plugin's pane, through core")
    }

    @Test func aRelativePathInARawWireRequestIsResolvedAgainstTheCwdToo() async throws {
        let pane = try await fixture.createPane()
        let id = JSONValue.string(pane.rawValue)
        let response = await fixture.wire(["type": "saveResource", "targetPaneId": id, "outPath": "a/b.png"], cwd: URL(filePath: "/work"))
        #expect(response["result"]?["echo"]?["outPath"] == "/work/a/b.png")
        let bare = await fixture.wire(["type": "saveResource", "targetPaneId": id, "outPath": true])
        #expect(bare["result"]?["echo"]?["outPath"] == true, "true means generate one; the handler decides")
        let homeless = await fixture.wire(["type": "saveResource", "targetPaneId": id, "outPath": "a.png"], cwd: nil)
        #expect(homeless == ControlDispatcher.failure("request.outPath: relative path \"a.png\" needs the request's \"cwd\""))
    }

    @Test func defaultsApplyToFlagsAndNotToARawWireRequest() async throws {
        let verb = TestSupport.candidate(TestSupport.manifest("dflt")) { context in
            context.register(ControlCapabilityContribution(id: "dflt", displayName: "Dflt"))
            context.register(
                ControlVerbContribution(
                    name: "dflt.count", summary: "counts",
                    arguments: [ControlArgument("times", .integer, defaultValue: 3)], command: "count", wireType: "count"
                ) { invocation in .object(invocation.arguments) })
        }
        let fixture = ControlFixture(extra: [verb])
        #expect(await fixture.ctl("count")["result"] == ["times": 3])
        #expect(await fixture.wire(["type": "count"]) == ["ok": true, "result": [:]], "no default: the handler sees nothing")
    }

    // MARK: Answers

    @Test func aHandlerErrorGoesOutAsWrittenWithNoVerbPrefix() async throws {
        let refuser = TestSupport.candidate(TestSupport.manifest("bad")) { context in
            context.register(ControlCapabilityContribution(id: "bad", displayName: "Bad"))
            context.register(
                ControlVerbContribution(name: "bad.refuse", summary: "r", command: "refuse", wireType: "refuse") { _ in
                    throw ControlVerbError("cannot go back — no earlier page in this pane's history")
                })
            context.register(
                ControlVerbContribution(name: "bad.nan", summary: "n", command: "nan", wireType: "nan") { _ in ["x": .double(.nan)] })
            context.register(
                ControlVerbContribution(name: "bad.odd", summary: "o", command: "odd", wireType: "odd") { _ in
                    struct Odd: Error {}
                    throw Odd()
                })
        }
        let fixture = ControlFixture(extra: [refuser])
        #expect(await fixture.ctl("refuse") == ControlDispatcher.failure("cannot go back — no earlier page in this pane's history"))
        #expect(await fixture.ctl("nan") == ControlDispatcher.failure("nan returned a result that isn't valid JSON (NaN or infinity)"))
        #expect(await fixture.ctl("odd") == ControlDispatcher.failure("Odd()"))
    }

    @Test func aResultRidesUnderResultAndNothingIsABareOk() async throws {
        let pane = try await fixture.createPane()
        let id = JSONValue.string(pane.rawValue)
        #expect(await fixture.ctl("navigate", ["pane": id, "url": "x"]) == ["ok": true, "result": ["echo": ["url": "x"]]])
        #expect(await fixture.ctl("ping") == ["ok": true])
    }
}
