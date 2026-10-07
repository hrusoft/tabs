import AppKit
import Foundation
import TabsPluginSDK
import Testing

@testable import TabsCore

/// The page's navigation records, against a real `WKWebView` and a fixture server
/// (docs/BROWSER.md: B-2…B-4, C-2, C-4…C-6, C-9, and what the header and the
/// verbs read from them).
@MainActor
@Suite struct BrowserNavigationTests {
    /// B-3: the pane's starting blank is not a Back target, and a later, deliberate one is.
    @Test func theStartingBlankIsNotABackTarget() async throws {
        let bed = try await PageBed { server in
            server.page("/a", title: "A"); server.page("/b", title: "B")
        }
        #expect(bed.page.url == "about:blank")
        #expect(!bed.page.hasCommitted && !bed.page.canGoBack && !bed.page.canGoForward)
        await bed.load("/a")
        #expect(bed.page.url == bed.url("/a"))
        #expect(!bed.page.canGoBack, "the first real navigation leaves Back disabled")
        await bed.load("/b")
        #expect(bed.page.canGoBack && !bed.page.canGoForward)
        bed.page.goBack()
        #expect(await eventually { bed.page.url == bed.url("/a") })
        #expect(bed.page.canGoForward && !bed.page.canGoBack)
        bed.page.goForward()
        #expect(await eventually { bed.page.url == bed.url("/b") })
    }

    @Test func aDeliberateAboutBlankKeepsItsHistory() async throws {
        let bed = try await PageBed(serving: { $0.page("/a", title: "A") })
        await bed.load("/a")
        await bed.load("about:blank")
        #expect(bed.page.url == "about:blank" && bed.page.hasCommitted)
        #expect(bed.page.canGoBack, "somewhere the user chose to be keeps its history")
        bed.page.goBack()
        #expect(await eventually { bed.page.url == bed.url("/a") })
    }

    @Test func anAboutBlankTypedOnTheStartingBlankStaysPut() async throws {
        let bed = try await PageBed(serving: { $0.page("/a", title: "A") })
        await bed.load("about:blank")
        #expect(!bed.page.hasCommitted && !bed.page.isLoading && bed.page.url == "about:blank")
        await bed.load("/a")
        #expect(!bed.page.canGoBack)
    }

    /// B-4: Back, Forward and Refresh step the history / reload; nothing to step to does nothing.
    @Test func historyStepsWithNothingToStepToDoNothing() async throws {
        let bed = try await PageBed(serving: { $0.page("/a", title: "A") })
        bed.page.goBack()
        bed.page.goForward()
        bed.page.reload()
        #expect(!bed.page.isLoading)
        await bed.load("/a")
        bed.page.goBack()
        #expect(bed.page.url == bed.url("/a"))
    }

    @Test func reloadRequestsThePageAgain() async throws {
        let bed = try await PageBed(serving: { $0.page("/a", title: "A") })
        await bed.load("/a")
        let before = bed.server.requests.count
        bed.page.reload()
        #expect(await eventually { bed.server.requests.count > before })
        #expect(await bed.page.waitForLoadEnd(timeoutMs: 5_000).loaded)
    }

    /// B-6: the URL is the committed one, the seed until something commits.
    @Test func theURLIsTheCommittedOneNotThePendingOne() async throws {
        let bed = try await PageBed(serving: { $0.route("/slow", .init(body: "<title>Slow</title>slow", gate: $0.gate("/slow"))) })
        bed.page.load(bed.url("/slow"))
        #expect(bed.page.isLoading)
        // The request is out and held unanswered (until the test opens the gate): nothing can have committed.
        #expect(await eventually { bed.server.requests.contains { $0.path == "/slow" } })
        #expect(bed.page.url == "about:blank", "still the seed: nothing has committed")
        bed.server.gate("/slow").open()
        #expect(await bed.page.waitForLoadEnd(timeoutMs: 10_000).loaded)
        #expect(bed.page.url == bed.url("/slow"))
        // The order the header and the wait supervisor rely on.
        let interesting = bed.events.filter { $0 != .titleDidChange }
        #expect(interesting == [.didStartLoading, .didNavigate(bed.url("/slow")), .didStopLoading])
    }

    /// C-1: the title is the document's own, else a URL-derived stand-in.
    @Test func theTitleFollowsThePageWithAURLStandInForAPageWithoutOne() async throws {
        let bed = try await PageBed { server in
            server.page("/titled", title: "The Title")
            server.page("/untitled", body: "no title here")
        }
        #expect(bed.page.title == "", "the blank page has none")
        await bed.load("/titled")
        #expect(await eventually { bed.page.title == "The Title" })
        await bed.load("/untitled")
        #expect(await eventually { bed.page.title == "127.0.0.1:\(bed.server.port)/untitled" })
        #expect(bed.events.contains(.titleDidChange))
        await bed.load("/titled")
        #expect(await eventually { bed.page.title == "The Title" }, "the same title as before still shows")
        var told: [String] = []
        bed.page.onTitle = { told.append($0) }
        await bed.load("/untitled")
        #expect(await eventually { told.last == "127.0.0.1:\(bed.server.port)/untitled" })
    }

    @Test func theFallbackTitleIsDerivedFromEachKindOfURL() {
        #expect(fallbackTitle(forURL: "about:blank") == "")
        #expect(fallbackTitle(forURL: "http://example.com/") == "example.com")
        #expect(fallbackTitle(forURL: "http://example.com/a/b?c=1") == "example.com/a/b?c=1")
        #expect(fallbackTitle(forURL: "https://example.com/a") == "https://example.com/a")
        #expect(fallbackTitle(forURL: "file:///tmp/notes.txt") == "notes.txt")
        #expect(fallbackTitle(forURL: "data:text/plain,hi") == "data:text/plain,hi")
    }

    /// A redirect commits at the URL it lands on.
    @Test func aRedirectCommitsAtTheFinalURL() async throws {
        let bed = try await PageBed(serving: { server in
            server.route("/bounce", .redirect(to: "/a"))
            server.page("/a", title: "A")
        })
        await bed.load("/bounce")
        #expect(bed.page.url == bed.url("/a"))
        #expect(bed.page.documentStatus == DocumentStatus(status: 200, statusText: "OK"))
    }

    /// C-6: the HTTP status and status text of the committed document; none for a non-HTTP one.
    @Test func recordsTheStatusOfTheCommittedDocument() async throws {
        let bed = try await PageBed { server in
            server.page("/ok", title: "ok")
            server.route("/missing", .init(status: 404, body: "<title>404</title>gone"))
            server.route("/broken", .init(status: 500, body: "<title>500</title>oops"))
        }
        #expect(bed.page.documentStatus == nil, "about:blank has none")
        await bed.load("/ok")
        #expect(bed.page.documentStatus == DocumentStatus(status: 200, statusText: "OK"))
        await bed.load("/missing")
        #expect(bed.page.documentStatus == DocumentStatus(status: 404, statusText: "Not Found"))
        await bed.load("/broken")
        #expect(bed.page.documentStatus == DocumentStatus(status: 500, statusText: "Internal Server Error"))
        await bed.load("about:blank")
        #expect(bed.page.documentStatus == nil, "a non-HTTP document has none")
    }

    /// C-6: an in-page navigation carries the status forward, and a history step lands on the entry's own.
    @Test func anInPageNavigationCarriesTheStatusForwardAndAHistoryStepKeepsTheEntrys() async throws {
        let bed = try await PageBed { server in
            server.route("/missing", .init(status: 404, body: "<title>404</title>gone"))
            server.page("/ok", title: "ok")
        }
        await bed.load("/missing")
        await bed.value("(history.pushState({}, '', '/missing#in'), 1)")
        #expect(await eventually { bed.page.url == bed.url("/missing#in") })
        #expect(bed.page.documentStatus?.status == 404)
        await bed.load("/ok")
        #expect(bed.page.documentStatus?.status == 200)
        bed.page.goBack()
        #expect(await eventually { bed.page.url == bed.url("/missing#in") })
        #expect(await eventually { bed.page.documentStatus?.status == 404 })
    }

    /// A-5, C-2: an in-page navigation commits no document, and clears no console.
    @Test func anInPageNavigationCommitsNoDocumentAndKeepsTheConsole() async throws {
        let bed = try await PageBed(serving: { $0.page("/a", title: "A", head: "<script>console.log('kept')</script>") })
        await bed.load("/a")
        #expect(await bed.consoleHas("kept"))
        bed.clearEvents()
        await bed.value("(history.pushState({}, '', '/a#pushed'), 1)")
        #expect(await eventually { bed.page.url == bed.url("/a#pushed") })
        await bed.value("(location.hash = '#hashed', 1)")
        #expect(await eventually { bed.page.url == bed.url("/a#hashed") })
        await bed.value("(history.back(), 1)")
        #expect(await eventually { bed.page.url == bed.url("/a#pushed") })
        #expect(bed.events.contains(.didNavigateInPage(bed.url("/a#pushed"))))
        #expect(!bed.events.contains { if case .didNavigate = $0 { true } else { false } }, "no new document")
        #expect(bed.page.console.list().map(\.text) == ["kept"], "the same document keeps its console")
    }

    /// C-2: a committed main-frame document clears the console, before its own scripts run.
    @Test func aNewDocumentClearsTheConsoleBeforeItsOwnScriptsRun() async throws {
        let bed = try await PageBed { server in
            server.page("/one", title: "One", head: "<script>console.log('from one')</script>")
            server.page("/two", title: "Two", head: "<script>console.log('from two')</script>")
        }
        await bed.load("/one")
        #expect(await bed.consoleHas("from one"))
        let lastSeq = bed.page.console.list().last?.seq ?? 0
        await bed.load("/two")
        #expect(await bed.consoleHas("from two"))
        #expect(bed.page.console.list().map(\.text) == ["from two"], "the old document's output is gone, the new one's kept")
        #expect((bed.page.console.list().last?.seq ?? 0) > lastSeq, "a stale sinceSeq can't replay")
    }

    /// C-9: what a verb reports about the page's history is the engine's own.
    @Test func canGoBackAndForwardAreThePagesOwnHistory() async throws {
        let bed = try await PageBed { server in
            server.page("/a", title: "A"); server.page("/b", title: "B"); server.page("/c", title: "C")
        }
        for path in ["/a", "/b", "/c"] { await bed.load(path) }
        bed.page.goBack()
        #expect(await eventually { bed.page.url == bed.url("/b") })
        #expect(bed.page.canGoBack && bed.page.canGoForward)
        await bed.load("/a")
        #expect(!bed.page.canGoForward, "a new navigation drops the forward entries")
    }

    /// The load records: `isLoading`, and the wait for a load to end.
    @Test func waitForLoadEndTimesOutOnALoadThatNeverEnds() async throws {
        let bed = try await PageBed(serving: { $0.route("/hang", .init(body: "<title>never</title>", hangs: true)) })
        bed.page.load(bed.url("/hang"))
        let outcome = await bed.page.waitForLoadEnd(timeoutMs: 150)
        #expect(outcome == LoadOutcome(loaded: false, loadError: nil), "still loading: the caller's to keep polling")
        #expect(bed.page.isLoading)
    }

    @Test func waitForLoadEndResolvesAtOnceForAPageThatIsAlreadyIdle() async throws {
        let bed = try await PageBed()
        let started = ContinuousClock.now
        #expect(await bed.page.waitForLoadEnd(timeoutMs: 5_000) == LoadOutcome(loaded: true, loadError: nil))
        #expect(ContinuousClock.now - started < .seconds(2), "the poll fallback answers within a tick or two")
    }

    /// E-5: a pane that is not shown (a background tab: its view is in no window, or hidden) keeps its page running.
    @Test func aPageThatIsNotOnScreenKeepsLoadingAndRunning() async throws {
        let bed = try await PageBed(
            serving: {
                $0.page(
                    "/ticking", title: "Ticking", head: "<script>let n = 0; setInterval(() => console.log('tick ' + n++), 100)</script>")
            },
            mounted: false)
        await bed.load("/ticking")
        #expect(bed.page.url == bed.url("/ticking"), "it loaded with no window")
        #expect(await eventually { bed.page.title == "Ticking" })
        #expect(await eventually { bed.page.console.list().count >= 3 }, "and its timers run")
        #expect(bed.page.console.list().contains { $0.text == "tick 2" || $0.text == "tick 1" })
        #expect(await bed.value("document.title") == "Ticking", "and it can be asked things")
        // Hidden in a window, the same.
        let hidden = try await PageBed(serving: {
            $0.page("/ticking", title: "Ticking", head: "<script>let n = 0; setInterval(() => console.log('tick ' + n++), 100)</script>")
        })
        hidden.page.webView.isHidden = true
        await hidden.load("/ticking")
        #expect(await eventually { hidden.page.console.list().count >= 3 })
    }

    /// The page's identity: stable for the life of the object.
    @Test func pageInstanceIsStableForAsLongAsThePageLives() async throws {
        let bed = try await PageBed(serving: { $0.page("/a", title: "A") })
        let first = bed.page.pageInstance
        await bed.load("/a")
        bed.window.contentView = NSView()
        bed.window.contentView = bed.page.webView
        #expect(bed.page.pageInstance == first, "a move never changes it")
        let other = BrowserPage(
            dataStore: bed.dataStore, url: "about:blank", loopbackExemption: LoopbackExemption(directory: bed.ruleListDirectory))
        #expect(other.pageInstance != first, "a re-created page's does")
        other.destroy()
    }

    // MARK: Script a navigation orphans

    /// `task`'s answer, or nil if it hasn't come within `ms` (an orphaned script call never answers).
    private func answer(
        of task: Task<Result<JSONValue, PageScriptError>, Never>, within ms: Int
    ) async -> Result<JSONValue, PageScriptError>? {
        let shot = OneShot<Result<JSONValue, PageScriptError>?>()
        Task { shot.resolve(await task.value) }
        Task {
            await delay(milliseconds: ms)
            shot.resolve(nil)
        }
        return await shot.wait()
    }

    /// A promise the next document orphans never settles: the call answers unavailable at the
    /// navigation rather than never (its task would stay suspended for good, holding the page).
    @Test func aScriptCallANavigationOrphansAnswersUnavailable() async throws {
        let bed = try await PageBed(serving: {
            $0.page("/a", title: "A")
            $0.page("/b", title: "B")
        })
        await bed.load("/a")
        let pending = Task { await bed.page.evaluate("new Promise(() => {})") }
        await delay(milliseconds: 100)
        bed.page.load(bed.url("/b"))
        #expect(await answer(of: pending, within: 10_000) == .failure(.unavailable))
    }

    @Test func aCancelledScriptCallAnswersUnavailable() async throws {
        let bed = try await PageBed(serving: { $0.page("/a", title: "A") })
        await bed.load("/a")
        let pending = Task { await bed.page.evaluate("new Promise(() => {})") }
        await delay(milliseconds: 100)
        pending.cancel()
        #expect(await answer(of: pending, within: 5_000) == .failure(.unavailable))
    }

    /// A load of the same page with a new fragment ends, though it starts no navigation of its own, whatever
    /// way it's written: WebKit spells the address its own way (an origin with no path gains its `/`, the
    /// scheme and host go lower case).
    @Test(arguments: ["path", "no path", "upper-case scheme"])
    func aLoadOfANewFragmentEnds(written: String) async throws {
        let bed = try await PageBed(serving: { server in
            server.page("/a", title: "A", body: "<p id=part>part</p>")
            server.page("/", title: "Root", body: "<p id=part>part</p>")
        })
        let origin = String(bed.url("/").dropLast())  // http://127.0.0.1:<port>
        let (document, asked) =
            switch written {
            case "path": (bed.url("/a"), bed.url("/a#part"))
            case "no path": (origin, "\(origin)#part")
            default: (origin, origin.replacingOccurrences(of: "http://", with: "HTTP://") + "#part")
            }
        await bed.load(document)
        #expect(bed.page.hasCommitted)
        bed.page.load(asked)
        #expect(await bed.page.waitForLoadEnd(timeoutMs: 5_000) == LoadOutcome(loaded: true), "\(asked)")
        #expect(bed.page.url.hasSuffix("#part"), "\(bed.page.url)")
        #expect(!bed.page.isLoading, "\(asked) still loading")
    }
}
