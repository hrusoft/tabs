import Foundation
import TabsPluginSDK
import Testing

@testable import TabsCore

/// A control-plane verb's budget (docs/BROWSER.md H-10): the Electron app's
/// `verbBudgetFor` and `withVerbDeadline`. A verb's own bounded answer must
/// beat the deadline; past it the caller is answered `timed out` and the
/// handler cancelled, even one that ignores the cancellation.
@MainActor
@Suite struct ControlBudgetTests {
    let fixture = ControlFixture()

    private func owned() async throws -> JSONValue { .string(try await fixture.createPane().rawValue) }

    private func verb(_ name: String) throws -> ControlVerbContribution {
        try #require(fixture.runtime.control.verb(named: name)?.verb)
    }

    @Test func aHandlerThatNeverReturnsIsAnsweredAtTheDeadlineNotBefore() async throws {
        fixture.runtime.control.headroom = .milliseconds(150)
        let pane = try await owned()
        let clock = ContinuousClock()
        let started = clock.now
        let response = await fixture.ctl("hang", ["pane": pane])
        let elapsed = started.duration(to: clock.now)
        #expect(response == ControlDispatcher.failure("hang timed out after 20ms"), "the message names the budget")
        #expect(elapsed >= .milliseconds(150), "budget 20ms plus headroom 150ms: \(elapsed)")
        #expect(elapsed < .seconds(5))
    }

    @Test func aHandlerThatHonorsCancellationIsCancelledAtTheDeadline() async throws {
        fixture.runtime.control.headroom = .milliseconds(30)
        let pane = try await owned()
        let response = await fixture.ctl("slow", ["pane": pane])
        #expect(response == ControlDispatcher.failure("slow timed out after 20ms"))
        // Answered at the deadline; the handler then sees its cancellation.
        for _ in 0..<200 where fixture.log.cancellations == 0 { try await Task.sleep(for: .milliseconds(5)) }
        #expect(fixture.log.cancellations == 1)
    }

    @Test func aVerbsOwnBoundedAnswerBeatsTheDeadline() async throws {
        // Declared budget 20ms, a handler that takes 120ms — inside the headroom, so it answers.
        fixture.runtime.control.headroom = .seconds(2)
        let pane = try await owned()
        let response = await fixture.ctl("nap", ["pane": pane, "ms": "120"])
        #expect(response == ["ok": true, "result": ["napped": true]])
    }

    @Test func aPerRequestBudgetIsTheClampedWaitPlusHeadroom() throws {
        let wait = try verb("web.waitFor")
        let budget = { (arguments: [String: JSONValue]) in ControlDispatcher.budget(of: wait, arguments) }
        #expect(budget([:]) == .milliseconds(10_000) + ControlBudget.headroom, "the default wait")
        #expect(budget(["timeoutMs": 3_000]) == .milliseconds(3_000) + ControlBudget.headroom)
        #expect(budget(["timeoutMs": 900_000]) == .milliseconds(300_000) + ControlBudget.headroom, "clamped to the cap")
        #expect(ControlBudget.headroom == .seconds(5))
    }

    @Test func aVerbWithoutAPerRequestBudgetUsesItsFixedOne() throws {
        #expect(ControlDispatcher.budget(of: try verb("web.click"), [:]) == .seconds(5))
        #expect(ControlDispatcher.budget(of: try verb("web.saveResource"), ["url": "x"]) == .seconds(30))
    }

    @Test func coresVerbsAreQuickAndBatchHasNoDeadline() throws {
        for name in [
            "tabs.ping", "tabs.activatePane", "tabs.closePane", "tabs.listPanes", "tabs.paneInfo", "tabs.capabilities", "tabs.describe",
        ] {
            #expect(try verb(name).timeout == .seconds(5), "\(name)")
        }
        #expect(try verb("tabs.batch").timeout >= ControlBudget.unbounded)
    }

    @Test func aBatchIsNotCutOffByItsOwnTimeoutOnlyItsStepsAre() async throws {
        fixture.runtime.control.headroom = .milliseconds(200)
        let pane = try await owned()
        // Three steps of 90ms each: the batch takes longer than any one step's 220ms deadline allows.
        let steps = [JSONValue](repeating: ["type": "nap", "targetPaneId": pane, "ms": 90], count: 3)
        let response = await fixture.ctl("batch", ["requests": .array(steps)])
        #expect(response["ok"] == true)
        guard case .array(let transcript)? = response["result"]?["steps"] else { return }
        #expect(transcript.map { $0["ok"] } == [true, true, true], "each step ran within its own budget plus headroom")
        #expect(transcript.compactMap { $0["durationMs"]?.intValue }.reduce(0, +) > 220, "and together they outlasted a single deadline")
    }

    @Test func aTimedOutVerbNoLongerLetsItsPluginNameTheCaller() async throws {
        fixture.runtime.control.headroom = .milliseconds(20)
        let pane = try await owned()
        _ = await fixture.ctl("hang", ["pane": pane])
        #expect(!fixture.runtime.panes.ownership.isRunning("web", for: "t1"))
    }

    @Test func aFailingHandlerIsAnswerEarlierThanItsDeadline() async throws {
        let pane = try await owned()
        let clock = ContinuousClock()
        let started = clock.now
        // No such argument: refused in core, at once.
        let response = await fixture.ctl("nap", ["pane": pane])
        #expect(response == ControlDispatcher.failure("--ms is required"))
        #expect(started.duration(to: clock.now) < .seconds(1))
    }
}
