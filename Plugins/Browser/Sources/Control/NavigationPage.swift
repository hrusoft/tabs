import Foundation
import TabsPluginSDK

/// The verbs that load a document into a browser pane and the page state every one
/// of them reports once the load settles.
@MainActor
enum NavigationPage {
    /// How one issued navigation ended. `loaded` is about the *requested* document (did the
    /// load itself finish); `settled` is about the pane (has it stopped loading). WebKit
    /// reports a superseded load as no event of its own (its loading flag stays up until the
    /// replacement ends), so the two always agree: a superseded navigation waits out its
    /// replacement and answers `loaded: true`, and `redirected` is what says the pane went
    /// elsewhere (BROWSER.md, Notes).
    struct Attempt: Equatable {
        var loaded: Bool
        var settled: Bool
    }

    /// Where the pane actually is, read at the moment an answer is formed. Every navigation
    /// verb reports this alongside `loaded`, because a load "settling" says nothing about
    /// *what* it settled on: a server redirect, a client-side router or a post-load script
    /// redirect all settle happily on some other page. A caller should trust `url` over the
    /// URL it asked for.
    ///
    /// `status`/`statusText` ride along for the same reason: a 404 is a *successful* load of an
    /// error document, so `loaded: true` alone can't answer "is this page real". They describe
    /// the last committed main-frame document, and are absent for a non-HTTP one (about:blank,
    /// a failed load's error page).
    ///
    /// `titleFromUrl: true` marks a `title` the document never actually set: the URL-derived
    /// fallback for a page with no `<title>`, which for an SPA is routinely the state at
    /// load-settle, with the real title arriving from script moments later. The verbs
    /// deliberately do not wait for it (answer latency is their core promise); the flag tells
    /// the caller the title is a stand-in, and `pane-info` reflects the live one.
    ///
    /// The flag reads `document.title` straight out of the page at response time, not from
    /// title events: the title of a reload, or of a history step onto a page sharing its
    /// predecessor's title, changes nothing, so an event-tracked flag would report the
    /// *previous* document's explicitness.
    static func pageState(_ page: BrowserPage) async -> [String: JSONValue] {
        // A page that can't run script right now (mid-navigation, an error page) is rare enough,
        // and the flag advisory enough, that assuming an explicit title (no flag) beats failing
        // the whole verb: the same stance `title` and `url` take by reading what was last
        // committed. The read is bounded because a script a navigation orphaned never answers.
        let explicit = await documentTitleIsExplicit(page)
        var state: [String: JSONValue] = ["url": .string(page.url), "title": .string(page.title)]
        if let status = page.documentStatus {
            state["status"] = .int(Int64(status.status))
            if !status.statusText.isEmpty { state["statusText"] = .string(status.statusText) }
        }
        if !explicit { state["titleFromUrl"] = true }
        return state
    }

    private static func documentTitleIsExplicit(_ page: BrowserPage) async -> Bool {
        let answer = OneShot<Bool>()
        page.evaluate("document.title") { result in
            if case .success(.string(let title)) = result { answer.resolve(!title.isEmpty) } else { answer.resolve(true) }
        }
        let budget = Task { @MainActor in
            await delay(milliseconds: 1_000)
            answer.resolve(true)
        }
        let explicit = await answer.wait()
        budget.cancel()
        return explicit
    }

    /// Issues one navigation and waits for it to end, one way or another.
    static func attempt(_ page: BrowserPage, url: String, waitMs: Int) async -> Result<Attempt, VerbFailure> {
        page.load(url)
        let outcome = await page.waitForLoadSettle(timeoutMs: waitMs)
        if let code = outcome.loadError {
            if let failed = outcome.failedURL, failed != url {
                return .failure(VerbFailure("failed to load \(failed) (where \(url) sent itself): \(code)"))
            }
            return .failure(VerbFailure("failed to load \(url): \(code)"))
        }
        return .success(Attempt(loaded: outcome.loaded, settled: outcome.loaded))
    }

    /// The result every navigation answer is built from. `redirected` is present only when the
    /// pane has settled: an unsettled pane hasn't ended up anywhere yet, and flagging its
    /// transient URL would be exactly the string-compare guesswork the flag exists to replace.
    private static func navigationResult(_ page: BrowserPage, _ attempt: Attempt, requestedURL: String) async -> [String: JSONValue] {
        var result = await pageState(page)
        result["loaded"] = .bool(attempt.loaded)
        if attempt.settled { result["redirected"] = .bool(!isTrivialUrlChange(requested: requestedURL, final: page.url)) }
        return result
    }

    static func navigate(_ invocation: ControlInvocation) async throws -> JSONValue {
        let url = invocation["url"]?.stringValue ?? ""
        guard isAllowedUrl(url) else { throw ControlVerbError("url not allowed: \(url)") }
        let page = try VerbSupport.pane(invocation).page
        let retry = invocation["retryOnRedirect"]?.boolValue ?? false
        let first: Attempt
        switch await attempt(page, url: url, waitMs: BrowserLimits.loadWaitMs) {
        case .failure(let failure): throw ControlVerbError(failure.message)
        case .success(let done): first = done
        }
        let firstURL = page.url
        // Retry only a settled miss: the pane demonstrably ended up somewhere other than the
        // requested URL (an auth bounce whose first hit establishes the session), whether the
        // requested load finished there or was superseded on the way. A pane still loading gets
        // no retry: issuing a second load at an unsettled pane is the blind race this verb is
        // being cured of.
        let settledElsewhere = first.settled && !isTrivialUrlChange(requested: url, final: firstURL)
        guard retry, settledElsewhere else {
            return .object(await navigationResult(page, first, requestedURL: url))
        }
        let second: Attempt
        switch await attempt(page, url: url, waitMs: BrowserLimits.loadWaitMs) {
        case .failure(let failure):
            throw ControlVerbError("\(failure.message) (on the retry — the first attempt landed on \(firstURL))")
        case .success(let done): second = done
        }
        // The final attempt answers top-level; `firstUrl` keeps the first attempt's landing
        // visible so a caller can see what the bounce was.
        var result = await navigationResult(page, second, requestedURL: url)
        result["retried"] = true
        result["firstUrl"] = .string(firstURL)
        return .object(result)
    }

    static func reload(_ invocation: ControlInvocation) async throws -> JSONValue {
        let page = try VerbSupport.pane(invocation).page
        page.reload()
        return .object(await settledState(page))
    }

    enum Step {
        case back, forward
    }

    static func step(_ step: Step, _ invocation: ControlInvocation) async throws -> JSONValue {
        let page = try VerbSupport.pane(invocation).page
        switch step {
        case .back:
            guard page.canGoBack else { throw ControlVerbError("cannot go back — no earlier page in this pane's history") }
            page.goBack()
        case .forward:
            guard page.canGoForward else { throw ControlVerbError("cannot go forward — no later page in this pane's history") }
            page.goForward()
        }
        return .object(await settledState(page))
    }

    /// What `reload` and the history steps answer: the load's outcome and the page it landed
    /// on, with no `redirected` (there is no requested URL to compare against: the subject is
    /// whatever page the pane already had).
    private static func settledState(_ page: BrowserPage) async -> [String: JSONValue] {
        var outcome = await page.waitForLoadEnd(timeoutMs: BrowserLimits.loadWaitMs)
        // A history step onto a failed entry shows its error page without asking the network
        // again: the entry itself knows why it failed.
        if outcome.loaded, outcome.loadError == nil, page.isShowingErrorPage, let error = page.lastLoadError {
            outcome = LoadOutcome(loaded: false, loadError: error)
        }
        var result = await pageState(page)
        result["loaded"] = .bool(outcome.loaded)
        if let error = outcome.loadError { result["loadError"] = .string(error) }
        return result
    }
}
