import Foundation
import TabsPluginSDK
import Testing

@testable import TabsCore

/// `batch` (docs/BROWSER.md H-12): raw wire requests run in order as the
/// batch's own caller, one transcript.
@MainActor
@Suite struct ControlBatchTests {
    let fixture = ControlFixture()

    private func batch(_ requests: [JSONValue], continueOnError: Bool = false, from caller: PaneID = "t1") async -> JSONValue {
        var flags: [String: JSONValue] = ["requests": .array(requests)]
        if continueOnError { flags["continue-on-error"] = true }
        return await fixture.ctl("batch", flags, from: caller)
    }

    private func steps(_ response: JSONValue) -> [JSONValue] {
        if case .array(let steps)? = response["result"]?["steps"] { steps } else { [] }
    }

    private func owned() async throws -> JSONValue { .string(try await fixture.createPane().rawValue) }

    @Test func runsInOrderAndAnswersWithATranscriptAlignedToWhatWasSent() async throws {
        let pane = try await owned()
        let response = await batch([
            ["type": "navigate", "targetPaneId": pane, "url": "one"], ["type": "reload", "targetPaneId": pane],
            ["type": "getPageText", "targetPaneId": pane, "maxLength": 5],
        ])
        #expect(response["ok"] == true)
        let steps = steps(response)
        #expect(steps.map { $0["type"]?.stringValue } == ["navigate", "reload", "getPageText"])
        #expect(steps.allSatisfy { $0["ok"] == true && $0["durationMs"]?.intValue != nil })
        #expect(steps[0]["result"] == ["echo": ["url": "one"]])
        #expect(steps[2]["result"] == ["echo": ["maxLength": 5]])
        #expect(response["result"]?["stoppedAt"] == nil)
        #expect(fixture.log.invocations.map(\.command).suffix(3) == ["navigate", "reload", "get-page-text"], "in order")
    }

    @Test func stopsAtTheFirstFailureAndMarksTheRestSkipped() async throws {
        let pane = try await owned()
        let response = await batch([
            ["type": "reload", "targetPaneId": pane], ["type": "navigate", "targetPaneId": pane],  // no url: fails
            ["type": "reload", "targetPaneId": pane],
        ])
        #expect(response["ok"] == true, "the batch ran: its transcript survives a failed step")
        #expect(response["result"]?["stoppedAt"] == 1)
        let steps = steps(response)
        #expect(steps.count == 3, "aligned to the requests")
        #expect(steps[0]["ok"] == true)
        #expect(steps[1]["ok"] == false)
        #expect(steps[1]["error"] == "request is missing required field \"url\"")
        #expect(steps[2] == ["type": "reload", "skipped": true])
        #expect(fixture.log.invocations.filter { $0.command == "reload" }.count == 1, "the skipped step never ran")
    }

    @Test func continueOnErrorRunsEveryStepAndHasNoStoppedAt() async throws {
        let pane = try await owned()
        let response = await batch(
            [
                ["type": "navigate", "targetPaneId": pane], ["type": "reload", "targetPaneId": pane],
                ["type": "navigate", "targetPaneId": pane, "url": 5],
            ], continueOnError: true)
        #expect(response["ok"] == true)
        #expect(response["result"]?["stoppedAt"] == nil)
        #expect(steps(response).map { $0["ok"] } == [false, true, false])
        #expect(steps(response).allSatisfy { $0["skipped"] == nil })
    }

    @Test func aBatchMayHoldAtMostFiftyRequests() async {
        let ping: JSONValue = ["type": "ping"]
        let fifty = await batch(Array(repeating: ping, count: 50))
        #expect(steps(fifty).count == 50)
        let fiftyOne = await batch(Array(repeating: ping, count: 51))
        #expect(fiftyOne == ControlDispatcher.failure("a batch may hold at most 50 requests"))
        #expect(ControlDispatcher.maxBatchSize == 50)
    }

    @Test func aBatchCannotContainAnotherBatchAndNothingRunsThen() async throws {
        let pane = try await owned()
        let response = await batch([
            ["type": "reload", "targetPaneId": pane], ["type": "batch", "requests": []],
        ])
        #expect(response == ControlDispatcher.failure("a batch cannot contain another batch"))
        #expect(fixture.log.invocations.filter { $0.command == "reload" }.isEmpty, "refused before any step ran")
    }

    @Test func aVerbThatOptedOutIsRefusedByItsOwnName() async throws {
        let pane = try await owned()
        let response = await batch([["type": "reload", "targetPaneId": pane], ["type": "createWebPane", "url": "about:blank"]])
        #expect(response == ControlDispatcher.failure("createWebPane cannot be used inside a batch"))
        #expect(fixture.log.openedPanes.count == 1, "only the one made first")
    }

    @Test func everyStepRunsAsTheBatchsOwnCallerWhateverItClaims() async throws {
        let pane = try await owned()  // owned by t1
        let claiming = await batch(
            [["type": "reload", "targetPaneId": pane, "paneId": "t2"]], from: "t1")
        #expect(steps(claiming).first?["ok"] == true, "paneId was overwritten, not trusted")
        #expect(fixture.log.invocations.last?.invocation.callerPane == "t1")

        // And t2's batch can't smuggle a step as t1 either.
        let smuggled = await batch([["type": "reload", "targetPaneId": pane, "paneId": "t1"]], from: "t2")
        #expect(steps(smuggled).first?["error"] == "not the owner of this pane")
    }

    @Test func aStepIsHeldToTheSameChecksAsAnyRequest() async throws {
        let pane = try await owned()
        let response = await batch(
            [
                ["type": "navigate", "targetPaneId": "t2", "url": "x"], ["type": "reload", "targetPaneId": pane],
            ], continueOnError: true)
        #expect(steps(response)[0]["error"] == "not the owner of this pane")
        #expect(steps(response)[1]["ok"] == true)
    }

    @Test func aStepThatIsNotARequestFailsByItself() async {
        let response = await batch([7, ["type": "nope"], ["type": "ping"]], continueOnError: true)
        let steps = steps(response)
        #expect(steps[0]["error"] == "unknown request type: (none)")
        #expect(steps[0]["type"] == nil)
        #expect(steps[1]["error"] == "unknown request type: nope")
        #expect(steps[2]["ok"] == true)
    }

    @Test func aWireRequestFromARawClientNeedsAListOfRequests() async {
        let response = await fixture.wire(["type": "batch", "requests": ["type": "ping"]])
        #expect(response == ControlDispatcher.failure("request.requests must be a array (got object)"))
        #expect(await fixture.wire(["type": "batch"]) == ControlDispatcher.failure("request is missing required field \"requests\""))
    }

    @Test func theFlagFormTakesJSONTextAndABareContinueOnError() async throws {
        let pane = try await owned()
        let text = #"[{"type":"navigate","targetPaneId":"\#(pane.stringValue ?? "")"},{"type":"ping"}]"#
        let response = await fixture.ctl("batch", ["requests": .string(text), "continue-on-error": true])
        #expect(steps(response).map { $0["ok"] } == [false, true])
        #expect(await fixture.ctl("batch", ["requests": "{not json"])["error"]?.stringValue?.contains("not valid JSON") == true)
    }

    @Test func aStepThatOutlivesItsBudgetFailsAloneAndTheBatchCarriesOn() async throws {
        fixture.runtime.control.headroom = .milliseconds(20)
        let pane = try await owned()
        let response = await batch(
            [["type": "hang", "targetPaneId": pane], ["type": "reload", "targetPaneId": pane]], continueOnError: true)
        #expect(response["ok"] == true, "a batch has no deadline of its own")
        #expect(steps(response)[0]["error"] == "hang timed out after 20ms")
        #expect(steps(response)[1]["ok"] == true)
    }

    @Test func aBatchCannotBeCutOffByTheBudgetsOfItsSteps() async throws {
        // Many quick steps, each well inside its own budget, taking longer than any one.
        fixture.runtime.control.headroom = .milliseconds(20)
        let ping: JSONValue = ["type": "ping"]
        let response = await batch(Array(repeating: ping, count: 50))
        #expect(steps(response).count == 50)
    }
}
