import Foundation
import TabsPluginSDK

/// `wait-for` and its single-shot twin `assert` (docs/BROWSER.md J-20, J-21): validating the one
/// condition a call names, and turning the supervisor's outcome (`PageWait`) into an answer that
/// says what never held.
@MainActor
enum WaitVerbs {
    static func all(services: BrowserServices) -> [ControlVerbContribution] { [waitForVerb, assertVerb] }

    /// The one wait/assert message that names neither verb: hoisted because the two validators are
    /// deliberately separate per verb (their other messages name their own verb), and a shared
    /// string is the only part that may not fork.
    private static let goneNeedsTarget = "gone inverts text or selector — it needs one of them to invert"

    /// What core tells the owner of a pane that has closed (`ControlPlane.paneGoneError`), which
    /// a wait re-checks between injections: a closed pane aborts the wait rather than burning the
    /// rest of a five-minute budget.
    private static let paneGoneMessage = "target pane no longer exists — it was closed; listOwnedPanes shows the panes still open"

    // MARK: wait-for

    /// One call in place of a caller's sleep-and-poll loop: the mechanics live in `PageWait` (the
    /// navigation-surviving supervisor) and `WaitScripts` (the in-page watchers); this verb validates
    /// the wire shape, clamps the bounds with the same shared arithmetic the budget is priced from, and
    /// turns the outcome into an answer. On success the elapsed time tells the caller what the page
    /// actually took; on timeout the error names the condition that never held, which is the
    /// difference between a diagnosis and a shrug.
    ///
    /// Budget: priced per request, not per verb: the wait is the request's own (clamped) timeout, so
    /// a 3-second wait whose page dies fails in seconds instead of holding the socket for the 300 s
    /// ceiling. The verb and its budget compute the same `clampWaitTimeout` of the same field, which
    /// is what keeps "the deadline always outlives the wait" true for every request: the timeout answer
    /// names the condition that never held and must always beat the budget to the caller.
    ///
    /// A `--timeout` of 0 never checks: the supervisor tests the deadline before its first injection,
    /// so the wait ends at once, on the deadline, even against a condition that already holds.
    /// (Pinned: a caller wanting one look uses `assert`.)
    private static let waitForVerb = ControlVerbContribution(
        name: "browser.waitFor",
        summary:
            "Wait inside the page until a condition holds — one call in place of a sleep-and-poll loop. Exactly one of --text, --selector, --url-contains, --idle per call.",
        arguments: [
            ControlArgument("text", .string, summary: "Resolve when the rendered page text contains this.", placeholder: "string"),
            ControlArgument(
                "selector", .string, summary: "Resolve when this matches a visible element; reports its ref for click/type.",
                placeholder: "css"),
            ControlArgument("gone", .bool, summary: "Invert --text/--selector: resolve when it stops holding."),
            ControlArgument(
                "urlContains", .string,
                summary: "Resolve when the pane’s URL contains this. Survives navigation, so it covers auth bounces and SPA routes.",
                placeholder: "string", flag: "url-contains"),
            ControlArgument(
                "idle", .bool,
                summary:
                    "Resolve when the DOM stops mutating for \(BrowserLimits.waitIdleQuietMs)ms — the fallback when nothing specific marks readiness."
            ),
            ControlArgument(
                "timeoutMs", .number,
                summary:
                    "Default \(BrowserLimits.waitDefaultTimeoutMs), capped at \(BrowserLimits.waitMaxTimeoutMs). Long waits also need the Bash tool timeout raised.",
                placeholder: "ms", flag: "timeout"),
            ControlArgument(
                "pollMs", .number,
                summary:
                    "Fallback check interval, default \(BrowserLimits.waitDefaultPollMs); mutations are noticed immediately regardless.",
                placeholder: "ms", flag: "poll"),
        ],
        target: .ownedPane(ofTypes: ["browser"]), timeout: .milliseconds(BrowserLimits.waitDefaultTimeoutMs) + ControlBudget.headroom,
        command: "wait-for", wireType: "waitFor",
        timeoutFor: { .milliseconds(clampWaitTimeout($0["timeoutMs"])) + ControlBudget.headroom },
        resultShape: [
            "elapsedMs": "number", "ref": "string", "tag": "string",
            "rect": ["x": "number", "y": "number", "width": "number", "height": "number"], "url": "string",
        ]
    ) { invocation in
        let pane = try VerbSupport.pane(invocation)
        if let invalid = waitSpecError(invocation.arguments) { throw ControlVerbError(invalid) }
        let timeoutMs = clampWaitTimeout(invocation["timeoutMs"])
        let pollMs = clampWaitPoll(invocation["pollMs"])
        let outcome = await run(pane, invocation.arguments, timeoutMs: timeoutMs, pollMs: pollMs)
        switch outcome {
        case .failed(let error): throw ControlVerbError(error)
        case .timedOut:
            throw ControlVerbError("timed out after \(timeoutMs)ms waiting for \(describeWaitCondition(invocation.arguments))")
        case .settled(let elapsedMs, let details):
            var result = details
            result["elapsedMs"] = .int(Int64(elapsedMs))
            return .object(result)
        }
    }

    /// Why this `wait-for` request cannot run as it stands, or nil if it can. Checked host-side for
    /// the same reason as `semanticTargetError`: what arrives over the socket is untyped wire input,
    /// so "exactly one condition" is a promise this check keeps, not one the compiler does. Exactly
    /// one is a decision, not a limitation: AND-ed conditions read plausibly but hide which half never
    /// held when the wait times out, and a sequence of waits (or a batch) states the same thing legibly.
    static func waitSpecError(_ arguments: [String: JSONValue]) -> String? {
        let conditions = [
            VerbSupport.namedString(arguments["text"]), VerbSupport.namedString(arguments["selector"]),
            VerbSupport.namedString(arguments["urlContains"]), arguments["idle"]?.boolValue == true,
        ].filter { $0 }.count
        if conditions == 0 { return "waitFor needs a condition: one of text, selector, urlContains, idle" }
        if conditions > 1 {
            return "waitFor takes exactly one condition per call — run several waits (or a batch of them) to combine conditions"
        }
        if arguments["gone"]?.boolValue == true, !VerbSupport.namedString(arguments["text"]),
            !VerbSupport.namedString(arguments["selector"])
        {
            return goneNeedsTarget
        }
        return nil
    }

    /// The wait spec, rebuilt from the validated fields rather than spread from the wire, so a
    /// blank-but-present string can't reach the page as a condition.
    ///
    /// Shared by `wait-for` and `assert`: unlike their validators and their prose, which are
    /// deliberately per verb (each message must name its own verb), this holds no wording at all, so a
    /// condition added to one and not the other would be a condition the validator accepts and the spec
    /// silently drops. `idle` is absent from assert's vocabulary and simply never set for it.
    static func pageWaitSpec(_ arguments: [String: JSONValue]) -> PageWaitSpec {
        if VerbSupport.namedString(arguments["urlContains"]) { return PageWaitSpec(urlContains: arguments["urlContains"]?.stringValue) }
        if arguments["idle"]?.boolValue == true { return PageWaitSpec(idle: true) }
        return PageWaitSpec(
            condition: WaitConditionSpec(
                text: VerbSupport.namedString(arguments["text"]) ? arguments["text"]?.stringValue : nil,
                selector: VerbSupport.namedString(arguments["selector"]) ? arguments["selector"]?.stringValue : nil,
                gone: arguments["gone"]?.boolValue == true))
    }

    /// The condition as prose, for the timeout error naming what never held.
    static func describeWaitCondition(_ arguments: [String: JSONValue]) -> String {
        if arguments["idle"]?.boolValue == true { return "the DOM to go idle (no mutations for \(BrowserLimits.waitIdleQuietMs)ms)" }
        if VerbSupport.namedString(arguments["urlContains"]) {
            return "the URL to contain \(jsonQuoted(arguments["urlContains"]?.stringValue ?? ""))"
        }
        let gone = arguments["gone"]?.boolValue == true
        if VerbSupport.namedString(arguments["selector"]) {
            return
                "selector \(jsonQuoted(arguments["selector"]?.stringValue ?? "")) to \(gone ? "stop matching" : "match a visible element")"
        }
        return "text \(jsonQuoted(arguments["text"]?.stringValue ?? "")) to \(gone ? "disappear" : "appear")"
    }

    // MARK: assert

    /// `wait-for`'s single-shot twin: the same conditions, evaluated once, with a failure that *fails
    /// the verb*, which is what lets a failing premise stop a batch and be named in its transcript,
    /// instead of coming back as data the caller must inspect.
    ///
    /// Runs through the same supervisor as `wait-for`, on the fixed `assertCheckBudgetMs`, rather than
    /// injecting a bare one-shot check: the supervisor is what survives an injection refused by a
    /// mid-load document and a navigation racing the check, and the in-page script checks synchronously
    /// on arrival, so a condition that holds settles on the first look regardless. See the constant's
    /// doc for the tolerance this knowingly grants a condition that arrives late. `elapsedMs` is
    /// deliberately not reported: for a bounded check it is machinery noise, where for a wait it is the
    /// answer.
    ///
    /// Budget: its check is bounded by a constant rather than a caller wait, so the budget derives from
    /// that bound the way the load verbs derive from `loadWaitMs`.
    private static let assertVerb = ControlVerbContribution(
        name: "browser.assert",
        summary:
            "Check that a condition holds right now, failing (non-zero) when it doesn’t — the self-verifying step for a batch. Exactly one of --text, --selector, --url-contains.",
        arguments: [
            ControlArgument("text", .string, summary: "Assert the rendered page text contains this.", placeholder: "string"),
            ControlArgument(
                "selector", .string, summary: "Assert this matches a visible element; reports its ref for click/type.", placeholder: "css"),
            ControlArgument("gone", .bool, summary: "Invert --text/--selector: assert it does not hold."),
            ControlArgument(
                "urlContains", .string, summary: "Assert the pane’s URL contains this.", placeholder: "string", flag: "url-contains"),
        ],
        target: .ownedPane(ofTypes: ["browser"]), timeout: .milliseconds(BrowserLimits.assertCheckBudgetMs) + ControlBudget.headroom,
        command: "assert", wireType: "assert",
        resultShape: [
            "ref": "string", "tag": "string", "rect": ["x": "number", "y": "number", "width": "number", "height": "number"],
            "url": "string",
        ]
    ) { invocation in
        let pane = try VerbSupport.pane(invocation)
        if let invalid = assertSpecError(invocation.arguments) { throw ControlVerbError(invalid) }
        switch await run(pane, invocation.arguments, timeoutMs: BrowserLimits.assertCheckBudgetMs, pollMs: BrowserLimits.waitMinPollMs) {
        case .failed(let error): throw ControlVerbError(error)
        case .timedOut: throw ControlVerbError("assertion failed: \(describeAssertFailure(invocation.arguments))")
        case .settled(_, let details): return .object(details)
        }
    }

    /// `waitSpecError`'s twin, kept separate rather than parameterized: the vocabularies differ (no
    /// idle here), and each message should name its own verb: a validation error is the one part of a
    /// verb an agent quotes back.
    static func assertSpecError(_ arguments: [String: JSONValue]) -> String? {
        let conditions = [
            VerbSupport.namedString(arguments["text"]), VerbSupport.namedString(arguments["selector"]),
            VerbSupport.namedString(arguments["urlContains"]),
        ].filter { $0 }.count
        if conditions == 0 { return "assert needs a condition: one of text, selector, urlContains" }
        if conditions > 1 { return "assert takes exactly one condition per call — batch several asserts to combine them" }
        if arguments["gone"]?.boolValue == true, !VerbSupport.namedString(arguments["text"]),
            !VerbSupport.namedString(arguments["selector"])
        {
            return goneNeedsTarget
        }
        return nil
    }

    /// The failed premise as prose: the transcript line that says what broke.
    static func describeAssertFailure(_ arguments: [String: JSONValue]) -> String {
        if VerbSupport.namedString(arguments["urlContains"]) {
            return "the URL does not contain \(jsonQuoted(arguments["urlContains"]?.stringValue ?? ""))"
        }
        let gone = arguments["gone"]?.boolValue == true
        if VerbSupport.namedString(arguments["selector"]) {
            let selector = jsonQuoted(arguments["selector"]?.stringValue ?? "")
            return gone ? "selector \(selector) still matches a visible element" : "selector \(selector) does not match a visible element"
        }
        let text = jsonQuoted(arguments["text"]?.stringValue ?? "")
        return gone ? "page text still contains \(text)" : "page text does not contain \(text)"
    }

    // MARK: Running the wait

    /// The supervisor run both verbs share, with the pane's closing wired to the abort: only the
    /// pane's existence, never its mount state (transient while a pane is moved, and exactly what
    /// re-arming survives).
    private static func run(_ pane: BrowserPane, _ arguments: [String: JSONValue], timeoutMs: Int, pollMs: Int) async -> PageWaitOutcome {
        let watch = ClosedWatch(pane.page)
        defer { watch.cancel() }
        return await PageWait.wait(
            page: pane.page, spec: pageWaitSpec(arguments),
            options: PageWaitOptions(timeoutMs: timeoutMs, pollMs: pollMs) { watch.closed ? paneGoneMessage : nil })
    }
}

/// Whether the page's pane has closed since this began watching.
@MainActor
private final class ClosedWatch {
    private(set) var closed = false
    private var subscription: PageSubscription?

    init(_ page: BrowserPage) {
        subscription = page.events.subscribe { [weak self] event in
            if event == .destroyed { self?.closed = true }
        }
    }

    func cancel() { subscription?.cancel() }
}
