import Foundation
import TabsPluginSDK

/// The host half of `wait-for`: a supervisor over the in-page wait scripts
/// (`WaitScripts`) that owns everything the page structurally cannot.
///
/// The page polls itself: one evaluation per page, however long the wait runs,
/// but three things only this side can provide:
///
/// - **The deadline.** A hidden page's timers are throttled, so the page's own
///   budget timer can fire arbitrarily late; the host-side deadline here is
///   exact, and always under the verb's budget (both derive from the same
///   `clampWaitTimeout`).
/// - **Surviving navigation.** A cross-document navigation destroys the page
///   context mid-wait, and the already-pending evaluation **never settles**:
///   measured on `WebKit` with `callAsyncJavaScript` (a promise stayed pending
///   after the page demonstrably navigated, neither resolving nor rejecting).
///   Nothing here may therefore await the page's promise alone: every injection
///   is raced against the page's disruption events (a navigation, the page being
///   destroyed) and re-injected into whatever document emerges, with whatever
///   budget remains. That is also what the
///   auth-bounce case *needs*: the condition is satisfied by the page a mid-wait
///   navigation lands on.
/// - **Failing fast when the pane vanishes.** `invalidReason` is re-checked between
///   injections, so a closed pane aborts the wait with the standard pane-gone
///   error instead of burning the rest of a five-minute budget.
///
/// An injection that *fails* (a document mid-load, a viewer that runs no script)
/// is retried on a short host-side delay until the deadline.
///
/// `urlContains` never injects at all: the page's URL and the navigation events
/// answer it from this side, which also makes it work against pages script
/// cannot run on. In-page route changes matter only here, for the page scripts
/// they are invisible by design (the context survives them and the
/// MutationObserver keeps watching).

/// What a wait settles to. `details` carries what the page reported (`ref`,
/// `tag`, `rect` for a selector match) or the URL for `urlContains`.
enum PageWaitOutcome: Equatable {
    case settled(elapsedMs: Int, details: [String: JSONValue])
    case timedOut(elapsedMs: Int)
    /// A wait that cannot proceed at all: the pane vanished, an invalid selector.
    case failed(String)
}

struct PageWaitSpec: Equatable {
    var condition = WaitConditionSpec()
    var urlContains: String?
    var idle = false

    init(condition: WaitConditionSpec = WaitConditionSpec(), urlContains: String? = nil, idle: Bool = false) {
        self.condition = condition
        self.urlContains = urlContains
        self.idle = idle
    }
}

struct PageWaitOptions {
    var timeoutMs: Int
    var pollMs: Int
    /// Re-checked between steps; a non-nil answer aborts the wait with that
    /// error. The caller's place to say "this pane no longer exists".
    var invalidReason: (@MainActor () -> String?)?

    init(timeoutMs: Int, pollMs: Int, invalidReason: (@MainActor () -> String?)? = nil) {
        self.timeoutMs = timeoutMs
        self.pollMs = pollMs
        self.invalidReason = invalidReason
    }
}

/// How long to back off before retrying an injection the page refused.
private let injectRetryMs = 100

/// Polls `condition` every `everyMs` until it answers true or `deadline`
/// passes, answering the final answer. The bounded busy-waits (a page
/// mounting, a revealed pane becoming paintable) share this rather than each
/// spelling its own deadline arithmetic.
@MainActor
func pollUntil(deadline: Date, everyMs: Int = 50, _ condition: @MainActor () async -> Bool) async -> Bool {
    var satisfied = await condition()
    while !satisfied && Date() < deadline {
        await delay(milliseconds: everyMs)
        satisfied = await condition()
    }
    return satisfied
}

@MainActor
enum PageWait {
    /// Waits until `spec` holds against the page: exactly one of `text`/`selector`
    /// (optionally inverted via `gone`), `urlContains`, or `idle`. The caller
    /// validates that shape; this trusts it and only picks the mechanism.
    /// Timeout is `.timedOut` with the elapsed time.
    static func wait(page: BrowserPage, spec: PageWaitSpec, options: PageWaitOptions) async -> PageWaitOutcome {
        if let needle = spec.urlContains { return await waitForURL(page: page, containing: needle, options: options) }
        if spec.idle {
            return await supervise(page: page, options: options) { remaining in
                domIdleScript(quietMs: BrowserLimits.waitIdleQuietMs, budgetMs: remaining)
            }
        }
        return await supervise(page: page, options: options) { remaining in
            waitConditionScript(spec.condition, budgetMs: remaining, pollMs: options.pollMs)
        }
    }

    private enum Race {
        case guest(Result<JSONValue, PageScriptError>)
        case disrupted
        case deadline
        case tick
    }

    /// The injection loop shared by every page-script wait: inject with the
    /// remaining budget, race the page's answer against disruption and the
    /// deadline, re-inject after a disruption, retry after a refusal, and enforce
    /// the deadline host-side throughout.
    private static func supervise(
        page: BrowserPage, options: PageWaitOptions, buildScript: @MainActor (Int) -> String
    ) async -> PageWaitOutcome {
        let startedAt = Date()
        let deadlineAt = startedAt.addingTimeInterval(Double(options.timeoutMs) / 1000)
        func elapsed() -> Int { Int(Date().timeIntervalSince(startedAt) * 1000) }

        while true {
            if let invalid = options.invalidReason?() { return .failed(invalid) }
            let remaining = Int(deadlineAt.timeIntervalSinceNow * 1000)
            if remaining <= 0 { return .timedOut(elapsedMs: elapsed()) }

            let shot = OneShot<Race>()
            let subscription = page.events.subscribe { event in
                switch event {
                case .didNavigate, .destroyed: shot.resolve(.disrupted)
                default: break
                }
            }
            let deadline = Task { @MainActor in
                await delay(milliseconds: remaining)
                shot.resolve(.deadline)
            }
            // The page's answer can be orphaned for good, so it only ever
            // *resolves* the race, and an abandoned one is simply ignored.
            page.evaluate(buildScript(remaining)) { shot.resolve(.guest($0)) }
            let raced = await shot.wait()
            subscription.cancel()
            deadline.cancel()

            switch raced {
            case .guest(.success(let value)):
                if case .object(let object) = value {
                    if let error = object["error"]?.stringValue { return .failed(error) }
                    if object["settled"]?.boolValue == true {
                        var details = object
                        details["settled"] = nil
                        return .settled(elapsedMs: elapsed(), details: details)
                    }
                    if object["settled"]?.boolValue == false {
                        // The page's own budget ran out; the loop re-checks ours,
                        // which in a throttled (hidden) page can still have time
                        // left: if so, re-inject rather than under-waiting.
                        continue
                    }
                }
                // Not a shape our scripts produce: a hostile page rewrote the
                // answer. Retry on the shared backoff; the deadline bounds it.
                await delay(milliseconds: injectRetryMs)
            case .guest(.failure):
                await delay(milliseconds: injectRetryMs)
            case .disrupted, .tick:
                // Re-inject into whatever document emerges. If it is still
                // loading, the next injection lands on the refusal backoff above.
                continue
            case .deadline:
                return .timedOut(elapsedMs: elapsed())
            }
        }
    }

    /// The URL wait: host-side entirely: the page's URL is read, and the events
    /// (a navigation, an in-page route change) say when to read it again.
    private static func waitForURL(page: BrowserPage, containing needle: String, options: PageWaitOptions) async -> PageWaitOutcome {
        let startedAt = Date()
        let deadlineAt = startedAt.addingTimeInterval(Double(options.timeoutMs) / 1000)
        func elapsed() -> Int { Int(Date().timeIntervalSince(startedAt) * 1000) }

        while true {
            if let invalid = options.invalidReason?() { return .failed(invalid) }
            let url = page.url
            if url.contains(needle) { return .settled(elapsedMs: elapsed(), details: ["url": .string(url)]) }
            let remaining = Int(deadlineAt.timeIntervalSinceNow * 1000)
            if remaining <= 0 { return .timedOut(elapsedMs: elapsed()) }

            // Event-driven with a poll fallback: the events cover every
            // navigation the engine announces, the tick covers anything it doesn't.
            let shot = OneShot<Race>()
            let subscription = page.events.subscribe { event in
                switch event {
                case .didNavigate, .didNavigateInPage, .destroyed: shot.resolve(.disrupted)
                default: break
                }
            }
            let tick = Task { @MainActor in
                await delay(milliseconds: min(options.pollMs, remaining))
                shot.resolve(.tick)
            }
            _ = await shot.wait()
            subscription.cancel()
            tick.cancel()
        }
    }
}
