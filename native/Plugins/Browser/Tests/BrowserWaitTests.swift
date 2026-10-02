import AppKit
import Foundation
import TabsPluginSDK
import Testing

@testable import TabsCore

/// The navigation-surviving wait supervisor (docs/BROWSER.md J-20, `pageWait.ts`)
/// against a real page: in-page condition waits, re-arming after a navigation, the
/// URL wait that never injects, idle, the host-side deadline and the pane-gone abort.
@MainActor
@Suite struct BrowserWaitTests {
    private func options(_ timeout: Int = 5_000, poll: Int = 50, invalid: (@MainActor () -> String?)? = nil) -> PageWaitOptions {
        PageWaitOptions(timeoutMs: timeout, pollMs: poll, invalidReason: invalid)
    }

    private func wait(_ bed: PageBed, _ spec: PageWaitSpec, _ options: PageWaitOptions) async -> PageWaitOutcome {
        await PageWait.wait(page: bed.page, spec: spec, options: options)
    }

    private func settled(_ outcome: PageWaitOutcome) -> (elapsedMs: Int, details: [String: JSONValue])? {
        if case .settled(let elapsed, let details) = outcome { (elapsed, details) } else { nil }
    }

    @Test func resolvesWhenTextAppearsAndHandsBackAUsableRefForASelector() async throws {
        let bed = try await PageBed(serving: { server in
            server.page(
                "/late", title: "Late",
                body:
                    "<p id=p>waiting</p><script>setTimeout(() => { p.textContent = 'ready now'; document.body.insertAdjacentHTML('beforeend', '<b id=late>x</b>') }, 200)</script>"
            )
        })
        await bed.load("/late")
        let text = await wait(bed, PageWaitSpec(condition: WaitConditionSpec(text: "ready now")), options())
        let done = try #require(settled(text), "\(text)")
        #expect(done.elapsedMs < 4_000 && done.details.isEmpty)
        let selector = await wait(bed, PageWaitSpec(condition: WaitConditionSpec(selector: "#late")), options())
        let match = try #require(settled(selector), "\(selector)")
        #expect(match.details["tag"] == "b")
        let ref = try #require(match.details["ref"]?.stringValue)
        #expect(await bed.value(refResolverExpression(ref) + ".id") == "late", "the ref is usable")
    }

    @Test func goneWaitsOutASpinner() async throws {
        let bed = try await PageBed(serving: { server in
            server.page(
                "/spin", title: "Spin",
                body: "<div id=spinner>Loading…</div><script>setTimeout(() => { spinner.style.display = 'none' }, 250)</script>")
        })
        await bed.load("/spin")
        let outcome = await wait(bed, PageWaitSpec(condition: WaitConditionSpec(selector: "#spinner", gone: true)), options())
        #expect(settled(outcome) != nil, "\(outcome)")
        let text = await wait(bed, PageWaitSpec(condition: WaitConditionSpec(text: "Loading…", gone: true)), options())
        #expect(settled(text) != nil, "\(text)")
    }

    @Test func aBadSelectorFailsLoudly() async throws {
        let bed = try await PageBed(serving: { $0.page("/a", title: "A") })
        await bed.load("/a")
        let outcome = await wait(bed, PageWaitSpec(condition: WaitConditionSpec(selector: "[")), options())
        #expect(outcome == .failed("invalid selector: ["))
    }

    /// A timeout names how long it waited, on the host's clock.
    @Test func aConditionThatNeverHoldsTimesOutOnTheHostsDeadline() async throws {
        let bed = try await PageBed(serving: { $0.page("/a", title: "A") })
        await bed.load("/a")
        let outcome = await wait(bed, PageWaitSpec(condition: WaitConditionSpec(text: "never")), options(600))
        guard case .timedOut(let elapsed) = outcome else { Issue.record("\(outcome)"); return }
        #expect(elapsed >= 550 && elapsed < 2_500, "\(elapsed)")
        // A zero wait is one immediate check.
        let none = await wait(bed, PageWaitSpec(condition: WaitConditionSpec(text: "never")), options(0))
        guard case .timedOut = none else { Issue.record("\(none)"); return }
        let hit = await wait(bed, PageWaitSpec(condition: WaitConditionSpec(selector: "body")), options(0))
        #expect(settled(hit) == nil, "with no time to inject, a zero wait can only time out: \(hit)")
    }

    /// The navigation race: the wait survives the page navigating mid-wait by re-arming into the new document.
    @Test func survivesThePageNavigatingMidWait() async throws {
        let bed = try await PageBed(serving: { server in
            server.page("/first", title: "First", body: "first page<script>setTimeout(() => { location.href = '/second' }, 300)</script>")
            server.page("/second", title: "Second", body: "SECOND PAGE TEXT")
        })
        await bed.load("/first")
        let outcome = await wait(bed, PageWaitSpec(condition: WaitConditionSpec(text: "SECOND PAGE TEXT")), options(10_000))
        let done = try #require(settled(outcome), "the auth-bounce shape: the wait is satisfied by the page it lands on: \(outcome)")
        #expect(done.elapsedMs < 9_000)
        #expect(bed.page.url == bed.url("/second"))
    }

    @Test func aWaitStartedOnAFailedPageResumesWhenTheAppComesUp() async throws {
        let port = try await FixtureServer.closedPort()
        let bed = try await PageBed()
        await bed.load("http://127.0.0.1:\(port)/soon")
        #expect(bed.page.isShowingErrorPage)
        let revived = try await FixtureServer.start(port: port)
        defer { revived.stop() }
        revived.page("/soon", title: "Soon", body: "the app is up")
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(300))
            bed.page.reload()
        }
        let outcome = await wait(bed, PageWaitSpec(condition: WaitConditionSpec(text: "the app is up")), options(10_000))
        #expect(settled(outcome) != nil, "\(outcome)")
    }

    /// `--url-contains` never injects, and rides navigations and in-page route changes.
    @Test func urlContainsRidesNavigationAndNeverInjects() async throws {
        let bed = try await PageBed(serving: { server in
            server.page("/a", title: "A"); server.page("/b", title: "B")
        })
        await bed.load("/a")
        // Already true: at once.
        let immediate = await wait(bed, PageWaitSpec(urlContains: "/a"), options())
        #expect(settled(immediate)?.details["url"] == .string(bed.url("/a")))
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(200))
            bed.page.load(bed.url("/b"))
        }
        let navigated = await wait(bed, PageWaitSpec(urlContains: "/b"), options())
        #expect(settled(navigated)?.details["url"] == .string(bed.url("/b")), "\(navigated)")
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(200))
            _ = await bed.page.evaluate("(history.pushState({}, '', '/b#route'), 1)")
        }
        let inPage = await wait(bed, PageWaitSpec(urlContains: "#route"), options())
        #expect(settled(inPage) != nil, "\(inPage)")
        // A page that can't run script is still waited on by URL.
        await bed.load(try await FixtureServer.closedPort().description.isEmpty ? "/a" : "http://127.0.0.1:1/x")
        let failedPage = await wait(bed, PageWaitSpec(urlContains: "127.0.0.1:1"), options())
        #expect(settled(failedPage) != nil, "\(failedPage)")
    }

    /// `--idle` resolves once the DOM has been quiet for the quiet period, and not before.
    @Test func idleSettlesOnlyOnceTheDOMStopsChurning() async throws {
        let bed = try await PageBed(serving: { server in
            server.page(
                "/churn", title: "Churn",
                body:
                    "<script>let n = 0; const t = setInterval(() => { document.body.append(String(n++)); if (n > 8) clearInterval(t) }, 100)</script>"
            )
        })
        await bed.load("/churn")
        let outcome = await wait(bed, PageWaitSpec(idle: true), options(10_000))
        let done = try #require(settled(outcome), "\(outcome)")
        #expect(done.elapsedMs >= 900, "churn lasts ~900ms and quiet must then hold 500ms: \(done.elapsedMs)")
        // Already quiet: at once.
        let again = await wait(bed, PageWaitSpec(idle: true), options(5_000))
        #expect((settled(again)?.elapsedMs ?? 9_999) < 300, "\(again)")
    }

    /// A closed pane aborts the wait instead of burning the rest of the budget.
    @Test func aClosedPaneAbortsTheWaitWithTheCallersReason() async throws {
        let bed = try await PageBed(serving: { $0.page("/a", title: "A") })
        await bed.load("/a")
        var gone = false
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(300))
            gone = true
            bed.page.destroy()
        }
        let started = ContinuousClock.now
        let outcome = await wait(
            bed, PageWaitSpec(condition: WaitConditionSpec(text: "never")),
            options(20_000, invalid: { gone ? "target pane no longer exists" : nil }))
        #expect(outcome == .failed("target pane no longer exists"))
        #expect(ContinuousClock.now - started < .seconds(5))
    }

    @Test func pollUntilAnswersTheFinalAnswerWithinTheDeadline() async {
        var calls = 0
        let met = await pollUntil(deadline: Date().addingTimeInterval(2), everyMs: 10) {
            calls += 1
            return calls >= 5
        }
        #expect(met && calls == 5)
        let missed = await pollUntil(deadline: Date().addingTimeInterval(0.1), everyMs: 10) { false }
        #expect(!missed)
    }
}
