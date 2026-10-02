import AppKit
import Foundation
import TabsPluginSDK
import Testing

@testable import TabsCore

/// `wait-for`, `assert` and `batch` around them (docs/BROWSER.md J-20, J-21, H-12's browser half) as an
/// agent drives them, against the real plugin in a real core runtime and the `/waity` fixture page. The
/// Electron tests these port are in `e2e/external-control-flow.spec.ts`: every one drives its changes from
/// the test (through the page's own helpers) rather than from page-side timers, so "the wait was already
/// pending when the condition arrived" is a matter of test-side sequencing: start the wait, give it a
/// generous head start, then trigger the change. The `elapsedMs` floors assert exactly that pendingness.
@MainActor
@Suite struct BrowserWaitVerbTests {
    private func changeThePage(_ bed: ScriptVerbBed, _ code: String) async {
        let answer = await bed.ctl("execute-js", ["code": .string(code)])
        #expect(answer.ok, "\(answer.json)")
    }

    /// J-20: text: pending before the text exists; one call blocks until it appears and reports how long
    /// that took. A selector only matches what the page shows (`#panel` is in the DOM but `display: none`),
    /// so a bounded wait for it times out naming the condition; revealed mid-wait, the match reports a
    /// `read-page`-compatible ref.
    @Test func waitForResolvesWhenTextAppearsAndHandsBackAUsableRefForASelectorMatch() async throws {
        let bed = try await ScriptVerbBed.open("/waity")

        async let textWait = bed.ctl("wait-for", ["text": "MAGIC_DONE", "timeout": 30000])
        try await Task.sleep(for: .seconds(1))
        await changeThePage(bed, "window.appendReady('MAGIC_DONE')")
        let text = await textWait
        #expect(text.ok, "\(text.json)")
        let elapsed = text.result["elapsedMs"]?.intValue ?? 0
        #expect(elapsed >= 500 && elapsed < 30000, "\(elapsed)")
        #expect(text.result["ref"] == nil, "a text wait reports no element")

        let hidden = await bed.ctl("wait-for", ["selector": "#panel", "timeout": 1200])
        #expect(!hidden.ok)
        #expect(hidden.error?.contains("timed out after 1200ms") == true && hidden.error?.contains("#panel") == true, "\(hidden.json)")
        #expect(hidden.error == "timed out after 1200ms waiting for selector \"#panel\" to match a visible element")

        async let selectorWait = bed.ctl("wait-for", ["selector": "#panel", "timeout": 30000])
        try await Task.sleep(for: .seconds(1))
        await changeThePage(bed, "window.revealPanel()")
        let selector = await selectorWait
        #expect(selector.ok, "\(selector.json)")
        #expect(selector.result["tag"] == "div")
        #expect((selector.result["rect"]?["width"]?.doubleValue ?? 0) > 0)
        let ref = try #require(selector.result["ref"]?.stringValue)
        #expect(await bed.value("\(refResolverExpression(ref)).tagName") == "DIV", "the ref names the element")
    }

    /// J-20: the spinner is visible now, so the inverted condition does not hold yet; hiding it (`display:
    /// none`, gone by the visibility rule though still in the DOM) resolves the wait. A wait that never holds
    /// fails at its bound naming the condition, and the caller really waited that long. The wire shape is
    /// validated before anything waits.
    @Test func waitForGoneWaitsOutASpinnerAndValidatesItsConditionShapeLoudly() async throws {
        let bed = try await ScriptVerbBed.open("/waity")

        async let goneWait = bed.ctl("wait-for", ["selector": "#spinner", "gone": true, "timeout": 30000])
        try await Task.sleep(for: .seconds(1))
        await changeThePage(bed, "window.hideSpinner()")
        let gone = await goneWait
        #expect(gone.ok, "\(gone.json)")
        #expect((gone.result["elapsedMs"]?.intValue ?? 0) >= 500)

        let started = ContinuousClock.now
        let timedOut = await bed.ctl("wait-for", ["text": "NEVER_THERE", "timeout": 1500])
        #expect(ContinuousClock.now - started >= .milliseconds(1500), "the caller really waited that long")
        #expect(!timedOut.ok)
        #expect(timedOut.error == "timed out after 1500ms waiting for text \"NEVER_THERE\" to appear")
        let disappear = await bed.ctl("wait-for", ["text": "Waity fixture", "gone": true, "timeout": 300])
        #expect(disappear.error == "timed out after 300ms waiting for text \"Waity fixture\" to disappear")
        let alreadyGone = await bed.ctl("wait-for", ["text": "spinner is spinning", "gone": true, "timeout": 300])
        #expect(alreadyGone.ok, "the spinner was hidden above, so its text is already gone: \(alreadyGone.json)")
        let stops = await bed.ctl("wait-for", ["selector": "#nothing-there", "gone": true, "timeout": 300])
        #expect(stops.ok, "a selector that matches nothing is already gone: \(stops.json)")

        let none = await bed.ctl("wait-for")
        #expect(none.error == "waitFor needs a condition: one of text, selector, urlContains, idle")
        let two = await bed.ctl("wait-for", ["text": "x", "idle": true])
        #expect(
            two.error
                == "waitFor takes exactly one condition per call — run several waits (or a batch of them) to combine conditions")
        let badGone = await bed.ctl("wait-for", ["idle": true, "gone": true])
        #expect(badGone.error == "gone inverts text or selector — it needs one of them to invert")
        let blank = await bed.ctl("wait-for", ["text": "  "])
        #expect(blank.error == "waitFor needs a condition: one of text, selector, urlContains, idle", "a blank string is no condition")
    }

    /// J-20: `--url-contains` is host-side, never injects, and rides navigation. An in-page condition survives a
    /// cross-document navigation destroying the context holding the watcher: only the supervisor's re-injection
    /// can let this resolve, because the condition's text exists solely on the page the navigation lands on.
    @Test func waitForSurvivesThePageNavigatingMidWaitAndUrlContainsRidesNavigation() async throws {
        let bed = try await ScriptVerbBed.open("/waity")

        async let urlWait = bed.ctl("wait-for", ["url-contains": "/other", "timeout": 30000])
        try await Task.sleep(for: .seconds(1))
        await changeThePage(bed, "location.href = '/other'")
        let url = await urlWait
        #expect(url.ok, "\(url.json)")
        #expect(url.result["url"]?.stringValue?.contains("/other") == true)
        #expect((url.result["elapsedMs"]?.intValue ?? 0) >= 500)

        await bed.load("/waity")
        async let acrossNavigation = bed.ctl("wait-for", ["text": "Elsewhere", "timeout": 30000])
        try await Task.sleep(for: .seconds(1))
        await changeThePage(bed, "location.href = '/other'")
        let across = await acrossNavigation
        #expect(across.ok, "\(across.json)")
        #expect((across.result["elapsedMs"]?.intValue ?? 0) >= 500)
    }

    /// J-20: `--url-contains` also rides an in-page route change (`pushState`), which no document commits.
    @Test func urlContainsRidesAnInPageRouteChange() async throws {
        let bed = try await ScriptVerbBed.open("/waity")
        async let wait = bed.ctl("wait-for", ["url-contains": "/spa/route", "timeout": 30000])
        try await Task.sleep(for: .milliseconds(500))
        await changeThePage(bed, "(history.pushState({}, '', '/spa/route'), 1)")
        let answer = await wait
        #expect(answer.ok, "\(answer.json)")
    }

    /// J-20: the churn is already running when the wait starts and keeps mutating for ~2.5 s more; idle may
    /// only resolve after the churn ends plus the quiet period, so a resolution under the churn's remaining
    /// span means the quiet clock fired mid-churn: the failure this test exists to catch.
    @Test func waitForIdleSettlesOnlyOnceTheDOMStopsChurning() async throws {
        let bed = try await ScriptVerbBed.open("/waity")
        await changeThePage(bed, "window.churn(2500)")
        let idle = await bed.ctl("wait-for", ["idle": true, "timeout": 30000])
        #expect(idle.ok, "\(idle.json)")
        let elapsed = idle.result["elapsedMs"]?.intValue ?? 0
        #expect(elapsed >= 1000 && elapsed < 15000, "\(elapsed)")
        // A DOM that has been quiet for the period is idle at once; one still churning is not.
        #expect(await bed.ctl("wait-for", ["idle": true, "timeout": 300]).ok)
        await changeThePage(bed, "window.churn(2500)")
        let churning = await bed.ctl("wait-for", ["idle": true, "timeout": 300])
        #expect(churning.error == "timed out after 300ms waiting for the DOM to go idle (no mutations for 500ms)", "\(churning.json)")
    }

    /// J-20, H-10, H-12: click-wait-read as one call, with the wait sized past the 5 s default budget on
    /// purpose: a step priced by the batch's own budget (or the default) instead of the wait's per-request
    /// budget would time out at 5 s, so the ~6.5 s elapsed here is the arithmetic composing.
    @Test func waitForComposesInsideABatchOnItsOwnPerRequestBudget() async throws {
        let bed = try await ScriptVerbBed.open("/waity")
        let batched = await bed.harness.tabsCtl(
            "batch",
            [
                "requests": [
                    [
                        "type": "executeJavaScript", "targetPaneId": .string(bed.pane.rawValue),
                        "code": "(setTimeout(() => window.appendReady('BATCH_DONE'), 6500), true)",
                    ],
                    ["type": "waitFor", "targetPaneId": .string(bed.pane.rawValue), "text": "BATCH_DONE", "timeoutMs": 30000],
                    ["type": "executeJavaScript", "targetPaneId": .string(bed.pane.rawValue), "code": "document.body.innerText"],
                ]
            ])
        let answer = ScriptAnswer(batched)
        #expect(answer.ok, "\(batched)")
        #expect(answer.result["stoppedAt"] == nil)
        guard case .array(let steps)? = answer.result["steps"] else { Issue.record("no transcript: \(batched)"); return }
        #expect(steps.count == 3)
        #expect(steps[1]["ok"] == true, "\(steps[1])")
        #expect((steps[1]["result"]?["elapsedMs"]?.intValue ?? 0) > 5000)
        #expect((steps[1]["durationMs"]?.intValue ?? 0) > 5000, "the transcript's own timing agrees with the wait it wraps")
        #expect(steps[2]["result"]?["value"]?.stringValue?.contains("BATCH_DONE") == true)
    }

    /// J-21: text that is on the page holds; a selector match hands back a ref; `#panel` exists but is hidden,
    /// so asserting it fails, quickly (the fixed check budget, nowhere near `wait-for`'s 10 s default) and
    /// naming the premise; `--gone` inverts; the URL condition works both ways; validation mirrors `wait-for`'s,
    /// naming its own verb.
    @Test func assertChecksAConditionRightNowPassWithAUsableRefFailNamingThePremise() async throws {
        let bed = try await ScriptVerbBed.open("/waity")

        let pass = await bed.ctl("assert", ["text": "spinner is spinning"])
        #expect(pass.ok && pass.result == .emptyObject, "an assert reports no elapsed time: \(pass.json)")

        let matched = await bed.ctl("assert", ["selector": "#spinner"])
        #expect(matched.ok)
        let ref = try #require(matched.result["ref"]?.stringValue)
        #expect(ref.wholeMatch(of: /e[0-9]+-[0-9a-z]+/) != nil, "\(ref)")
        #expect(matched.result["tag"] == "div")
        #expect(await bed.value("\(refResolverExpression(ref)).id") == "spinner")

        let started = ContinuousClock.now
        let failed = await bed.ctl("assert", ["selector": "#panel"])
        #expect(!failed.ok)
        #expect(failed.error == "assertion failed: selector \"#panel\" does not match a visible element")
        #expect(ContinuousClock.now - started < .seconds(8))

        let goneFailed = await bed.ctl("assert", ["selector": "#spinner", "gone": true])
        #expect(goneFailed.error == "assertion failed: selector \"#spinner\" still matches a visible element")
        let textGoneFailed = await bed.ctl("assert", ["text": "spinner is spinning", "gone": true])
        #expect(textGoneFailed.error == "assertion failed: page text still contains \"spinner is spinning\"")
        await changeThePage(bed, "window.hideSpinner()")
        #expect(await bed.ctl("assert", ["selector": "#spinner", "gone": true]).ok)
        #expect(await bed.ctl("assert", ["text": "spinner is spinning", "gone": true]).ok)

        let url = await bed.ctl("assert", ["url-contains": "/waity"])
        #expect(url.ok && url.result["url"]?.stringValue?.contains("/waity") == true)
        let urlFailed = await bed.ctl("assert", ["url-contains": "/nowhere"])
        #expect(urlFailed.error == "assertion failed: the URL does not contain \"/nowhere\"")
        let textFailed = await bed.ctl("assert", ["text": "NOT_ON_THIS_PAGE"])
        #expect(textFailed.error == "assertion failed: page text does not contain \"NOT_ON_THIS_PAGE\"")

        let none = await bed.ctl("assert")
        #expect(none.error == "assert needs a condition: one of text, selector, urlContains")
        let two = await bed.ctl("assert", ["text": "x", "selector": "#y"])
        #expect(two.error == "assert takes exactly one condition per call — batch several asserts to combine them")
        let badGone = await bed.ctl("assert", ["url-contains": "x", "gone": true])
        #expect(badGone.error == "gone inverts text or selector — it needs one of them to invert")
        let idle = await bed.ctl("assert", ["idle": true])
        #expect(idle.error?.contains("idle") == true, "assert has no idle: \(idle.json)")
    }

    /// J-21, H-12: a batch stops at the failing premise, and its transcript names it.
    @Test func anAssertStepMakesABatchSelfVerifyingTheTranscriptNamesThePremiseThatBroke() async throws {
        let bed = try await ScriptVerbBed.open("/waity")
        let id = JSONValue.string(bed.pane.rawValue)
        let batched = ScriptAnswer(
            await bed.harness.tabsCtl(
                "batch",
                [
                    "requests": [
                        ["type": "assert", "targetPaneId": id, "text": "spinner is spinning"],
                        ["type": "assert", "targetPaneId": id, "text": "NOT_ON_THIS_PAGE"],
                        ["type": "executeJavaScript", "targetPaneId": id, "code": "document.body.innerText"],
                    ]
                ]))
        #expect(batched.ok, "the batch ran: \(batched.json)")
        #expect(batched.result["stoppedAt"] == 1)
        guard case .array(let steps)? = batched.result["steps"] else { Issue.record("no transcript"); return }
        #expect(steps[0]["ok"] == true)
        #expect(steps[1]["error"]?.stringValue?.contains("assertion failed") == true)
        #expect(steps[1]["error"]?.stringValue?.contains("NOT_ON_THIS_PAGE") == true)
        #expect(steps[2] == ["type": "executeJavaScript", "skipped": true])
    }

    /// H-12: a batch runs its requests in order, stops at the first failure with the unrun tail marked skipped,
    /// runs to the end under `--continue-on-error`, refuses a step naming somebody else's pane, and refuses nesting
    /// and the unbatchable. (The Electron test drives `click` and `get-page-text`; the ordering is the point, so
    /// the page's own script stands in for both here: those verbs are the other families'.)
    @Test func aBatchRunsItsRequestsInOrderStopsAtTheFirstFailureAndRefusesNesting() async throws {
        let bed = try await ScriptVerbBed.open("/page")
        let id = JSONValue.string(bed.pane.rawValue)
        func batch(_ requests: [JSONValue], continueOnError: Bool = false) async -> ScriptAnswer {
            var flags: [String: JSONValue] = ["requests": .array(requests)]
            if continueOnError { flags["continue-on-error"] = true }
            return ScriptAnswer(await bed.harness.tabsCtl("batch", flags))
        }
        func steps(_ answer: ScriptAnswer) -> [JSONValue] {
            if case .array(let list)? = answer.result["steps"] { list } else { [] }
        }
        let click: JSONValue = ["type": "executeJavaScript", "targetPaneId": id, "code": "(document.getElementById('go').click(), true)"]
        let read: JSONValue = ["type": "executeJavaScript", "targetPaneId": id, "code": "document.getElementById('status').textContent"]
        let missing: JSONValue = ["type": "executeJavaScript", "targetPaneId": id, "code": "document.getElementById('nope').click()"]

        // Ordering is the point: the click must land before the text is read back.
        let ordered = await batch([click, read])
        #expect(ordered.ok)
        let transcript = steps(ordered)
        #expect(transcript.compactMap { $0["type"]?.stringValue } == ["executeJavaScript", "executeJavaScript"])
        #expect(transcript.allSatisfy { $0["ok"] == true && ($0["durationMs"]?.intValue ?? -1) >= 0 })
        #expect(transcript[1]["result"]?["value"] == "clicked")

        // A failing step stops the batch and the transcript stays aligned to what was sent.
        let stopped = await batch([["type": "getPaneInfo", "targetPaneId": id], missing, read])
        #expect(stopped.result["stoppedAt"] == 1)
        let stoppedSteps = steps(stopped)
        #expect(stoppedSteps.count == 3)
        #expect(stoppedSteps[0]["ok"] == true && stoppedSteps[1]["ok"] == false)
        #expect(stoppedSteps[2] == ["type": "executeJavaScript", "skipped": true])

        // --continue-on-error runs the same sequence to the end.
        let continued = await batch([["type": "getPaneInfo", "targetPaneId": id], missing, read], continueOnError: true)
        #expect(continued.ok && continued.result["stoppedAt"] == nil)
        let continuedSteps = steps(continued)
        #expect(continuedSteps.count == 3 && continuedSteps[1]["ok"] == false && continuedSteps[2]["ok"] == true)
        #expect(continuedSteps[2]["result"]?["value"] == "clicked")

        // A sub-request naming somebody else's pane is refused like any other.
        let foreign = await batch([["type": "executeJavaScript", "targetPaneId": .string(bed.harness.agentPane.rawValue), "code": "1"]])
        #expect(steps(foreign)[0]["error"]?.stringValue?.contains("not the owner") == true)

        let refused: [(String, JSONValue)] = [
            ("nested batch", ["type": "batch", "requests": []]),
            ("createBrowserPane", ["type": "createBrowserPane", "url": "about:blank"]),
        ]
        for (label, step) in refused {
            let rejected = await batch([step])
            #expect(!rejected.ok || steps(rejected).first?["ok"] == false, "\(label) should be refused: \(rejected.json)")
        }
    }

    /// J-20: `--timeout 0` never checks: the wait ends at once, on the deadline, even against a condition
    /// that already holds. (Faithful: the supervisor tests the deadline before its first injection.)
    @Test func aTimeoutOfZeroNeverChecks() async throws {
        let bed = try await ScriptVerbBed.open("/waity")
        let answer = await bed.ctl("wait-for", ["text": "Waity fixture", "timeout": 0])
        #expect(answer.error == "timed out after 0ms waiting for text \"Waity fixture\" to appear", "\(answer.json)")
        let assertion = await bed.ctl("assert", ["text": "Waity fixture"])
        #expect(assertion.ok, "an assert has its own budget")
    }

    /// J-20: a wait whose pane closes aborts with the pane-gone error rather than burning the rest of its budget.
    @Test func aWaitEndsWhenItsPaneCloses() async throws {
        let bed = try await ScriptVerbBed.open("/waity")
        async let wait = bed.ctl("wait-for", ["text": "NEVER_THERE", "timeout": 60000])
        try await Task.sleep(for: .milliseconds(700))
        let started = ContinuousClock.now
        _ = bed.harness.runtime.panes.closePane(bed.pane)
        let answer = await wait
        #expect(!answer.ok)
        #expect(answer.error == "target pane no longer exists — it was closed; listOwnedPanes shows the panes still open", "\(answer.json)")
        #expect(ContinuousClock.now - started < .seconds(10))
    }

    /// J-20, H-10: the wait is priced per request: its own clamped timeout plus headroom; an assert on its
    /// fixed check budget plus headroom.
    @Test func waitBudgetsArePricedPerRequest() async throws {
        let bed = try await ScriptVerbBed.open()
        let wait = try #require(bed.verb("browser.waitFor"))
        let price = try #require(wait.timeoutFor)
        #expect(price([:]) == .seconds(10) + ControlBudget.headroom, "the default wait")
        #expect(price(["timeoutMs": 3000]) == .seconds(3) + ControlBudget.headroom)
        #expect(price(["timeoutMs": 1_000_000]) == .seconds(300) + ControlBudget.headroom, "the ceiling")
        #expect(price(["timeoutMs": -5]) == ControlBudget.headroom, "a negative wait is no wait")
        #expect(price(["timeoutMs": "soon"]) == .seconds(10) + ControlBudget.headroom, "untyped wire input falls back to the default")
        let assertion = try #require(bed.verb("browser.assert"))
        #expect(assertion.timeout == .seconds(1) + ControlBudget.headroom && assertion.timeoutFor == nil)
    }

    /// J-20, J-21, I-2: the verbs are declared as `controlSpec.ts` declares them, docs verbatim.
    @Test func waitForAndAssertAreDeclaredAsControlSpecDeclaresThem() async throws {
        let bed = try await ScriptVerbBed.open()
        let wait = try #require(bed.verb("browser.waitFor"))
        #expect(wait.command == "wait-for" && wait.wireType == "waitFor" && wait.batchable)
        #expect(wait.arguments.map(\.flagName) == ["text", "selector", "gone", "url-contains", "idle", "timeout", "poll"])
        #expect(wait.arguments.map(\.name) == ["text", "selector", "gone", "urlContains", "idle", "timeoutMs", "pollMs"])
        #expect(
            wait.arguments.first { $0.name == "timeoutMs" }?.summary
                == "Default 10000, capped at 300000. Long waits also need the Bash tool timeout raised.")
        #expect(
            wait.arguments.first { $0.name == "idle" }?.summary
                == "Resolve when the DOM stops mutating for 500ms — the fallback when nothing specific marks readiness.")
        #expect(
            wait.arguments.first { $0.name == "pollMs" }?.summary
                == "Fallback check interval, default 250; mutations are noticed immediately regardless.")
        let assertion = try #require(bed.verb("browser.assert"))
        #expect(assertion.command == "assert" && assertion.wireType == "assert")
        #expect(assertion.arguments.map(\.flagName) == ["text", "selector", "gone", "url-contains"])
        #expect(assertion.arguments.first { $0.name == "urlContains" }?.summary == "Assert the pane’s URL contains this.")
    }

    /// J-20, J-21: each wait's answer is shaped by the wire schema: a `timeoutMs` that isn't a number is refused
    /// by the schema before any wait starts, and `assert` has no `idle` in its vocabulary.
    @Test func waitRequestsAreValidatedAgainstTheWireSchema() async throws {
        let bed = try await ScriptVerbBed.open("/waity")
        let notNumber = await bed.wire("waitFor", ["text": "x", "timeoutMs": "soon"])
        #expect(notNumber.error?.contains("timeoutMs") == true, "\(notNumber.json)")
        let noIdle = await bed.wire("assert", ["idle": true])
        #expect(noIdle.error?.contains("idle") == true, "\(noIdle.json)")
    }

    // MARK: The wording, without a page

    @Test func theConditionsReadAsProse() {
        func text(_ fields: [String: JSONValue]) -> String { WaitVerbs.describeWaitCondition(fields) }
        #expect(text(["idle": true]) == "the DOM to go idle (no mutations for 500ms)")
        #expect(text(["urlContains": "/x"]) == "the URL to contain \"/x\"")
        #expect(text(["selector": ".a"]) == "selector \".a\" to match a visible element")
        #expect(text(["selector": ".a", "gone": true]) == "selector \".a\" to stop matching")
        #expect(text(["text": "hi \"there\""]) == "text \"hi \\\"there\\\"\" to appear")
        #expect(text(["text": "hi", "gone": true]) == "text \"hi\" to disappear")
        func failure(_ fields: [String: JSONValue]) -> String { WaitVerbs.describeAssertFailure(fields) }
        #expect(failure(["urlContains": "/x"]) == "the URL does not contain \"/x\"")
        #expect(failure(["selector": ".a"]) == "selector \".a\" does not match a visible element")
        #expect(failure(["text": "hi", "gone": true]) == "page text still contains \"hi\"")
    }

    @Test func theWaitSpecIsRebuiltFromTheValidatedFieldsNotSpreadFromTheWire() {
        #expect(WaitVerbs.pageWaitSpec(["urlContains": "/x", "text": "ignored"]) == PageWaitSpec(urlContains: "/x"))
        #expect(WaitVerbs.pageWaitSpec(["idle": true]) == PageWaitSpec(idle: true))
        #expect(
            WaitVerbs.pageWaitSpec(["text": "hi", "selector": "  ", "gone": true])
                == PageWaitSpec(condition: WaitConditionSpec(text: "hi", selector: nil, gone: true)))
        #expect(WaitVerbs.pageWaitSpec(["idle": false, "selector": ".a"]) == PageWaitSpec(condition: WaitConditionSpec(selector: ".a")))
    }
}
