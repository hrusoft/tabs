import AppKit
import Foundation
import TabsPluginSDK
import Testing

@testable import TabsCore

/// The navigation-surviving wait supervisor (docs/BROWSER.md J-20, `PageWait`)
/// against a real page: in-page condition waits, re-arming after a navigation, the
/// URL wait that never injects, idle, the host-side deadline and the pane-gone abort.
@MainActor
@Suite struct BrowserWaitTests {
    /// A wait that should settle gets 20 s: met in a few hundred milliseconds, unless four lanes of tests
    /// starve the page (a 200 ms change once took longer than 5 s). One that should time out names its own.
    private func options(_ timeout: Int = 20_000, poll: Int = 50, invalid: (@MainActor () -> String?)? = nil) -> PageWaitOptions {
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
        #expect(done.details.isEmpty)
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
        let outcome = await wait(bed, PageWaitSpec(condition: WaitConditionSpec(text: "never")), options(200))
        guard case .timedOut(let elapsed) = outcome else { Issue.record("\(outcome)"); return }
        #expect(elapsed >= 190 && elapsed < 2_500, "\(elapsed)")
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
        let reservation = try FixtureServer.reservePort()
        let bed = try await PageBed()
        await bed.load("http://127.0.0.1:\(reservation.port)/soon")
        #expect(bed.page.isShowingErrorPage)
        let before = await bed.page.countingObservers()
        async let outcome = wait(bed, PageWaitSpec(condition: WaitConditionSpec(text: "the app is up")), options(10_000))
        #expect(await bed.page.observing(beyond: before), "armed on the error page")
        reservation.release()
        let revived = try await FixtureServer.start(port: reservation.port)
        defer { revived.stop() }
        revived.page("/soon", title: "Soon", body: "the app is up")
        bed.page.reload()
        let resumed = await outcome
        #expect(settled(resumed) != nil, "\(resumed)")
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
        var listeners = bed.page.events.listenerCount
        async let navigated = wait(bed, PageWaitSpec(urlContains: "/b"), options())
        #expect(await bed.page.listening(beyond: listeners), "the wait listens for navigations")
        bed.page.load(bed.url("/b"))
        let landed = await navigated
        #expect(settled(landed)?.details["url"] == .string(bed.url("/b")), "\(landed)")
        listeners = bed.page.events.listenerCount
        async let inPage = wait(bed, PageWaitSpec(urlContains: "#route"), options())
        #expect(await bed.page.listening(beyond: listeners))
        _ = await bed.page.evaluate("(history.pushState({}, '', '/b#route'), 1)")
        let routed = await inPage
        #expect(settled(routed) != nil, "\(routed)")
        // A page that can't run script is still waited on by URL.
        await bed.load("http://127.0.0.1:1/x")
        let failedPage = await wait(bed, PageWaitSpec(urlContains: "127.0.0.1:1"), options())
        #expect(settled(failedPage) != nil, "\(failedPage)")
    }

    /// `--idle` resolves once the DOM has been quiet for the quiet period, and not before: the page changes
    /// every 100 ms for 600 ms, from before the wait starts. By the page's own clock: changes made from here
    /// are as far apart as a busy main actor makes them, and could leave a real quiet period between them.
    @Test func idleSettlesOnlyOnceTheDOMStopsChurning() async throws {
        let bed = try await PageBed(serving: { $0.installStandardPages() })
        await bed.load("/waity")
        await bed.value("window.churn(600)")
        let idle = await wait(bed, PageWaitSpec(idle: true), options(10_000))
        let quietMs = await bed.value("Date.now() - window.lastChurnAt").intValue ?? 0
        let done = try #require(settled(idle), "\(idle)")
        #expect(quietMs >= Int64(BrowserLimits.waitIdleQuietMs - 20), "answered \(quietMs) ms after the last change, by the page's clock")
        #expect(done.elapsedMs >= BrowserLimits.waitIdleQuietMs, "\(done.elapsedMs)")
        // Already quiet: at once, without a quiet period of its own.
        let again = await wait(bed, PageWaitSpec(idle: true), options(5_000))
        #expect((settled(again)?.elapsedMs ?? 9_999) < BrowserLimits.waitIdleQuietMs, "\(again)")
    }

    /// A closed pane aborts the wait instead of burning the rest of the budget.
    @Test func aClosedPaneAbortsTheWaitWithTheCallersReason() async throws {
        let bed = try await PageBed(serving: { $0.page("/a", title: "A") })
        await bed.load("/a")
        let gone = Flag()
        let before = await bed.page.countingObservers()
        async let outcome = wait(
            bed, PageWaitSpec(condition: WaitConditionSpec(text: "never")),
            options(20_000, invalid: { gone.value ? "target pane no longer exists" : nil }))
        #expect(await bed.page.observing(beyond: before))
        let started = ContinuousClock.now
        gone.value = true
        bed.page.destroy()
        #expect(await outcome == .failed("target pane no longer exists"))
        #expect(ContinuousClock.now - started < .seconds(5))
    }

    /// State a wait's closure reads after the test changes it.
    @MainActor final class Flag {
        var value = false
    }

    @Test func pollUntilAnswersTheFinalAnswerWithinTheDeadline() async {
        var calls = 0
        // A deadline far off: what's pinned is answering the final answer, not how fast polls come.
        let met = await pollUntil(deadline: Date().addingTimeInterval(30), everyMs: 10) {
            calls += 1
            return calls >= 5
        }
        #expect(met && calls == 5)
        let missed = await pollUntil(deadline: Date().addingTimeInterval(0.1), everyMs: 10) { false }
        #expect(!missed)
    }
}
