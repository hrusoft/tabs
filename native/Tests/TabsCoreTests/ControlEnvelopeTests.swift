import Foundation
import TabsPluginSDK
import Testing

@testable import TabsCore

/// `ControlEnvelope.build` is what replaced `tabs-ctl`'s own hand-written
/// `buildRequest`: flag coercion runs in the app, against the same specs
/// `capabilities` and `describe` serve. The port of the Electron app's
/// `controlEnvelope.test.ts`, test for test (same names, camelCased), against
/// the fixture plugin whose verbs carry the Electron browser's flags.
///
/// Messages are not required to match the old CLI's byte for byte (only the
/// two "pane is gone" sentences SKILL.md quotes are frozen, and neither is a
/// flag-coercion message), but every case that used to be refused before
/// anything reached the socket still is.
///
/// Every command here also takes `--pane` (required), so most calls include
/// `pane: TARGET_PANE` even when the subject is a different flag — omitting it
/// would fail on "--pane is required" before ever reaching the behavior under
/// test.
@MainActor
@Suite struct ControlEnvelopeTests {
    let fixture = ControlFixture()
    let pane: PaneID = "pane-1"
    let targetPane = JSONValue.string("target-1")
    let cwd = URL(filePath: "/Users/agent/project", directoryHint: .isDirectory)

    private func build(_ command: String, _ args: [String: JSONValue]) -> ControlEnvelope.Built {
        fixture.runtime.control.buildRequest(command: command, args: args, paneId: pane, cwd: cwd)
    }

    @Test func namesTheCommandWhenItIsUnknown() {
        #expect(build("nonsense", [:]).error?.contains("unknown command: nonsense") == true)
    }

    @Test func namesTheValidFlagsWhenOneIsMisspelled() {
        let error = build("click", ["panee": "x"]).error
        #expect(error?.contains("unknown flag --panee") == true)
        #expect(error?.contains("--ref") == true)
    }

    @Test func rejectsAValueOutsideAFlagsEnum() {
        let built = build("scroll", ["pane": targetPane, "direction": "sideways"])
        #expect(built.error?.contains("must be one of up, down, left, right") == true)
    }

    @Test func rejectsANonNumericValueForANumericFlag() {
        let built = build("get-page-text", ["pane": targetPane, "max-length": "abc"])
        #expect(built.error?.contains("must be a number") == true)
    }

    @Test func reportsAMissingRequiredFlag() {
        #expect(build("navigate", ["pane": targetPane]).error?.contains("--url is required") == true)
    }

    @Test func reportsTheImplicitPaneFlagAsMissingToo() {
        #expect(build("reload", [:]).error?.contains("--pane is required") == true)
    }

    @Test func rejectsNumericGarbageBelowAFlagsFloor() {
        #expect(
            build("get-page-text", ["pane": targetPane, "max-length": "-5"]).error?.contains("--max-length must be at least 1") == true)
        #expect(
            build("read-console", ["pane": targetPane, "since-seq": "-1"]).error?.contains("--since-seq must be at least 0") == true)
    }

    @Test func leavesALegitimateFloorValueAlone() {
        let built = build("read-console", ["pane": targetPane, "since-seq": "0"])
        #expect(built.error == nil)
        #expect(matches(built.request, ["sinceSeq": 0]))
    }

    @Test func rejectsMalformedJSONForAJSONValuedFlag() {
        #expect(build("batch", ["requests": "{not json"]).error?.contains("not valid JSON") == true)
    }

    @Test func parsesAWellFormedJSONFlag() {
        let built = build("batch", ["requests": #"[{"type":"ping"}]"#])
        #expect(matches(built.request, ["requests": [["type": "ping"]]]))
    }

    @Test func splitsACsvFlagOnCommas() {
        let built = build("key", ["pane": targetPane, "key": "a", "modifiers": "meta,shift"])
        #expect(matches(built.request, ["modifiers": ["meta", "shift"]]))
    }

    @Test func mapsABareBooleanFlagToTrueAndAnInvertingFlagToItsDeclaredValue() {
        let on = build("capture-bodies", ["pane": targetPane])
        #expect(matches(on.request, ["type": "captureNetworkBodies"]))
        #expect(on.request?["enabled"] == nil)

        let off = build("capture-bodies", ["pane": targetPane, "off": true])
        #expect(matches(off.request, ["enabled": false]))
    }

    @Test func resolvesAPathFlagAgainstTheCallersCwdAndPassesBareTrueThroughUnresolved() {
        let named = build("execute-js", ["pane": targetPane, "code": "1", "out": "out/result.json"])
        #expect(matches(named.request, ["outPath": "/Users/agent/project/out/result.json"]))

        let bare = build("execute-js", ["pane": targetPane, "code": "1", "out": true])
        #expect(matches(bare.request, ["outPath": true]))
    }

    // A value-taking flag given bare. tabs-ctl turns a flag with nothing after
    // it — end of argv, or immediately followed by another flag — into `true`.
    // That's correct for a boolean flag and for a path flag's "generate one"
    // bare form, and wrong for everything else: left unchecked, Number(true) is
    // 1 (a bare --timeout silently became timeoutMs: 1, not "no timeout"), and
    // String(true) is "true" (a bare --ref silently became a real-looking ref).
    // Every case here used to build a corrupted request instead of refusing.

    @Test func refusesABareNumericFlagRatherThanSending1() {
        let built = build("wait-for", ["pane": targetPane, "text": "x", "timeout": true])
        #expect(built.error == "--timeout needs a value")
        #expect(built.request == nil)
    }

    @Test func refusesABarePlainStringFlag() {
        #expect(build("navigate", ["pane": targetPane, "url": true]).error == "--url needs a value")
    }

    @Test func refusesABareCsvFlag() {
        #expect(build("key", ["pane": targetPane, "key": "a", "modifiers": true]).error == "--modifiers needs a value")
    }

    @Test func refusesABareJsonFlag() {
        #expect(build("batch", ["requests": true]).error == "--requests needs a value")
    }

    @Test func stillAcceptsABareBooleanFlag() {
        let built = build("read-network", ["pane": targetPane, "failed": true])
        #expect(built.error == nil)
        #expect(matches(built.request, ["failed": true]))
    }

    @Test func stillAcceptsABarePathFlagGenerateOne() {
        let built = build("save-resource", ["pane": targetPane, "url": "https://example.com/x.pdf", "out": true])
        #expect(built.error == nil)
        #expect(matches(built.request, ["outPath": true]))
    }

    @Test func refusesABareRefInsteadOfSendingRefTrue() {
        #expect(build("click", ["pane": targetPane, "ref": true]).error == "--ref needs a value")
    }

    @Test func refusesABareXYInsteadOfSending11() {
        #expect(build("click", ["pane": targetPane, "x": true, "y": "10"]).error == "--x needs a value")
        #expect(build("click", ["pane": targetPane, "x": "10", "y": true]).error == "--y needs a value")
    }

    @Test func refusesABareNthInsteadOfSendingNth1() {
        #expect(build("click", ["pane": targetPane, "role": "button", "nth": true]).error == "--nth needs a value")
    }

    // Element-target composition.

    @Test func buildsARefTarget() {
        let built = build("click", ["pane": targetPane, "ref": "e1"])
        #expect(matches(built.request, ["target": ["ref": "e1"]]))
    }

    @Test func buildsACoordinateTargetWithNoStrayTopLevelXY() {
        let built = build("click", ["pane": targetPane, "x": "10", "y": "20"])
        #expect(
            built.request == ["type": "click", "paneId": "pane-1", "targetPaneId": "target-1", "target": ["x": 10, "y": 20]])
    }

    @Test func rejectsANonNumericCoordinateInsteadOfSendingNaN() {
        let built = build("click", ["pane": targetPane, "x": "abc", "y": "10"])
        #expect(built.error?.contains("--x and --y must be numbers") == true)
    }

    @Test func buildsASemanticTargetWithNth() {
        let built = build("click", ["pane": targetPane, "role": "button", "name": "Save", "nth": "1"])
        #expect(matches(built.request, ["target": ["role": "button", "name": "Save", "nth": 1]]))
    }

    @Test func requiresAtLeastOneTargetForm() {
        let built = build("click", ["pane": targetPane])
        #expect(built.error?.contains("--role/--name/--selector, --ref, or both --x and --y") == true)
    }

    @Test func rejectsACoordinateMissingOneAxis() {
        #expect(build("click", ["pane": targetPane, "x": "10"]).error?.contains("needs both --x and --y") == true)
    }

    @Test func rejectsMixingTargetForms() {
        let built = build("click", ["pane": targetPane, "ref": "e1", "name": "Save"])
        #expect(built.error?.contains("pass only one") == true)
    }

    @Test func rejectsNthWithoutASemanticFlag() {
        let built = build("click", ["pane": targetPane, "ref": "e1", "nth": "0"])
        #expect(built.error?.contains("--nth only applies") == true)
    }

    @Test func rejectsABareSemanticFlagRatherThanMatchingTheStringTrue() {
        #expect(build("click", ["pane": targetPane, "name": true]).error?.contains("--name needs a value") == true)
    }

    @Test func buildsAnOrdinaryCommandMappingPaneToTargetPaneId() {
        let built = build("reload", ["pane": targetPane])
        #expect(built.error == nil)
        #expect(built.request == ["type": "reload", "paneId": "pane-1", "targetPaneId": "target-1"])
    }

    @Test func leavesAnUnknownCapabilityForTheDescribeHandlerToRefuseNotCoercion() {
        let built = build("describe", ["capability": "nonexistent"])
        // Coercion only checks the flag exists and is required — the capability
        // itself is validated by the describe handler, which knows the census.
        #expect(built.error == nil)
        #expect(matches(built.request, ["type": "describe", "capability": "nonexistent"]))
    }
}
