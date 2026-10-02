import AppKit
import Foundation
import TabsPluginSDK
import Testing

@testable import TabsCore

/// Load failures and the error page (docs/BROWSER.md: C-4, C-5, J-5, J-2's error
/// names), against a real `WKWebView`: a failure is recorded by its Chromium
/// `ERR_*` name, shown as a page that is a real history entry, and forgotten when
/// the next load starts.
@MainActor
@Suite struct BrowserFailureTests {
    /// C-4, C-5: a refused connection is recorded by name and is a commit at the failed URL.
    @Test func aRefusedConnectionIsRecordedByNameAndCommitsAnErrorPageAtTheFailedURL() async throws {
        let bed = try await PageBed(serving: { $0.page("/a", title: "A", head: "<script>console.log('old page')</script>") })
        await bed.load("/a")
        #expect(bed.page.documentStatus?.status == 200)
        #expect(await bed.consoleHas("old page"))
        let dead = try await FixtureServer.closedPort()
        let failed = "http://127.0.0.1:\(dead)/nothing-here"
        bed.clearEvents()
        let outcome = await bed.load(failed)
        #expect(outcome == LoadOutcome(loaded: false, loadError: "ERR_CONNECTION_REFUSED"))
        #expect(bed.page.lastLoadError == "ERR_CONNECTION_REFUSED")
        #expect(bed.page.isShowingErrorPage)
        #expect(bed.page.url == failed, "the URL, the history and config.url follow the failure")
        #expect(bed.page.documentStatus == nil, "the previous document's status is dropped")
        #expect(bed.page.console.list().isEmpty, "and so is its console")
        #expect(bed.page.title == "127.0.0.1")
        #expect(bed.events.contains(.didFailLoad("ERR_CONNECTION_REFUSED")))
        #expect(bed.events.contains(.didNavigate(failed)))
        #expect(!bed.page.isLoading)
        let body = await bed.value("document.body.innerText")
        #expect(body.stringValue?.contains("ERR_CONNECTION_REFUSED") == true)
        #expect(body.stringValue?.contains("refused to connect") == true)
    }

    /// The error page is a real entry: Back leaves it and Forward comes back to it, with its reason.
    @Test func theErrorPageIsARealHistoryEntry() async throws {
        let bed = try await PageBed(serving: { $0.page("/a", title: "A") })
        await bed.load("/a")
        let dead = try await FixtureServer.closedPort()
        let failed = "http://127.0.0.1:\(dead)/x"
        await bed.load(failed)
        #expect(bed.page.canGoBack, "the page it came from is still a Back target")
        bed.page.goBack()
        #expect(await eventually { bed.page.url == bed.url("/a") && !bed.page.isShowingErrorPage })
        #expect(bed.page.lastLoadError == nil)
        #expect(bed.page.canGoForward)
        bed.page.goForward()
        #expect(await eventually { bed.page.url == failed })
        #expect(bed.page.isShowingErrorPage)
        #expect(bed.page.lastLoadError == "ERR_CONNECTION_REFUSED", "a history step onto a failed entry knows why it failed")
        #expect(bed.page.documentStatus == nil)
    }

    /// C-4: cleared when the next load starts.
    @Test func theNextLoadForgetsTheRecordedFailure() async throws {
        let bed = try await PageBed(serving: { $0.page("/a", title: "A") })
        let dead = try await FixtureServer.closedPort()
        await bed.load("http://127.0.0.1:\(dead)/x")
        #expect(bed.page.lastLoadError == "ERR_CONNECTION_REFUSED")
        bed.page.load(bed.url("/a"))
        #expect(bed.page.lastLoadError == nil, "cleared as the next load starts, before it ends")
        let outcome = await bed.page.waitForLoadEnd(timeoutMs: 10_000)
        #expect(outcome == LoadOutcome(loaded: true, loadError: nil))
        #expect(!bed.page.isShowingErrorPage)
    }

    /// C-4: recorded from the moment the page exists: a failure that lands before anything listens is known.
    @Test func aFailureThatLandsBeforeAnythingListensIsKnown() async throws {
        let dead = try await FixtureServer.closedPort()
        let bed = try await PageBed(url: { _ in "http://127.0.0.1:\(dead)/seed" })
        #expect(await eventually { bed.page.lastLoadError != nil })
        #expect(bed.page.lastLoadError == "ERR_CONNECTION_REFUSED")
        #expect(await eventually { bed.page.isShowingErrorPage })
        #expect(bed.page.url == "http://127.0.0.1:\(dead)/seed")
    }

    /// B-4: Refresh on an error page tries the failed URL again.
    @Test func reloadOnAnErrorPageRetriesTheFailedURL() async throws {
        let port = try await FixtureServer.closedPort()
        let bed = try await PageBed()
        let failed = "http://127.0.0.1:\(port)/back-soon"
        await bed.load(failed)
        #expect(bed.page.isShowingErrorPage)
        // The dev server comes up on that port.
        let revived = try await FixtureServer.start(port: port)
        defer { revived.stop() }
        revived.page("/back-soon", title: "Back soon", body: "up")
        bed.page.reload()
        #expect(await eventually { bed.page.title == "Back soon" })
        #expect(!bed.page.isShowingErrorPage && bed.page.lastLoadError == nil)
        #expect(bed.page.url == failed)
        #expect(revived.requests.contains { $0.path == "/back-soon" })
    }

    @Test func aRestrictedPortIsERR_UNSAFE_PORT() async throws {
        let bed = try await PageBed()
        let outcome = await bed.load("http://127.0.0.1:1/")
        #expect(outcome.loadError == "ERR_UNSAFE_PORT")
    }

    @Test func aPlainHTTPServerOverHTTPSIsAnSSLProtocolError() async throws {
        let bed = try await PageBed(serving: { $0.page("/", title: "plain") })
        let outcome = await bed.load("https://127.0.0.1:\(bed.server.port)/")
        // Which the engine reports depends on whether the server's plain answer or its close
        // reaches the TLS handshake first (measured: -1200 usually, -1005 under load): both are
        // this failure, and the mapping of each is what is pinned.
        #expect(["ERR_SSL_PROTOCOL_ERROR", "ERR_CONNECTION_RESET"].contains(outcome.loadError ?? ""), "\(outcome)")
    }

    @Test func aRedirectLoopIsERR_TOO_MANY_REDIRECTS() async throws {
        let bed = try await PageBed(serving: { $0.route("/loop", .redirect(to: "/loop")) })
        let outcome = await bed.load("/loop", timeoutMs: 20_000)
        #expect(outcome.loadError == "ERR_TOO_MANY_REDIRECTS", "\(outcome)")
    }

    @Test func aMissingFileIsERR_FILE_NOT_FOUND() async throws {
        let bed = try await PageBed()
        let outcome = await bed.load("file:///nonexistent-directory/file.html")
        #expect(outcome.loadError == "ERR_FILE_NOT_FOUND", "\(outcome)")
    }

    /// A load superseded by another is not a failure (Chromium's ERR_ABORTED).
    @Test func aSupersededNavigationIsNotAFailure() async throws {
        let bed = try await PageBed(serving: { server in
            server.route("/slow", .init(body: "<title>Slow</title>", delay: .seconds(2)))
            server.page("/a", title: "A")
        })
        bed.page.load(bed.url("/slow"))
        try await Task.sleep(for: .milliseconds(100))
        bed.page.load(bed.url("/a"))
        let outcome = await bed.page.waitForLoadEnd(timeoutMs: 10_000)
        #expect(outcome == LoadOutcome(loaded: true, loadError: nil))
        #expect(bed.page.url == bed.url("/a"))
        #expect(bed.page.lastLoadError == nil && !bed.page.isShowingErrorPage)
        #expect(!bed.events.contains { if case .didFailLoad = $0 { true } else { false } })
    }

    /// J-2: the names the verbs quote, for every NSURLError a load can fail with.
    @Test func mapsTheEnginesErrorsToChromiumsNames() {
        func name(_ domain: String, _ code: Int, underlying: NSError? = nil) -> String? {
            LoadErrors.name(for: NSError(domain: domain, code: code, userInfo: underlying.map { [NSUnderlyingErrorKey: $0] }))
        }
        let expected: [(Int, String)] = [
            (NSURLErrorBadURL, "ERR_INVALID_URL"), (NSURLErrorTimedOut, "ERR_CONNECTION_TIMED_OUT"),
            (NSURLErrorUnsupportedURL, "ERR_UNKNOWN_URL_SCHEME"), (NSURLErrorCannotFindHost, "ERR_NAME_NOT_RESOLVED"),
            (NSURLErrorCannotConnectToHost, "ERR_CONNECTION_REFUSED"), (NSURLErrorNetworkConnectionLost, "ERR_CONNECTION_RESET"),
            (NSURLErrorDNSLookupFailed, "ERR_NAME_NOT_RESOLVED"), (NSURLErrorHTTPTooManyRedirects, "ERR_TOO_MANY_REDIRECTS"),
            (NSURLErrorNotConnectedToInternet, "ERR_INTERNET_DISCONNECTED"), (NSURLErrorBadServerResponse, "ERR_INVALID_RESPONSE"),
            (NSURLErrorFileDoesNotExist, "ERR_FILE_NOT_FOUND"), (NSURLErrorNoPermissionsToReadFile, "ERR_ACCESS_DENIED"),
            (NSURLErrorSecureConnectionFailed, "ERR_SSL_PROTOCOL_ERROR"), (NSURLErrorServerCertificateHasBadDate, "ERR_CERT_DATE_INVALID"),
            (NSURLErrorServerCertificateUntrusted, "ERR_CERT_AUTHORITY_INVALID"),
            (NSURLErrorServerCertificateHasUnknownRoot, "ERR_CERT_AUTHORITY_INVALID"),
            (NSURLErrorServerCertificateNotYetValid, "ERR_CERT_DATE_INVALID"),
            (NSURLErrorClientCertificateRequired, "ERR_SSL_CLIENT_AUTH_CERT_NEEDED"), (-9999, "ERR_FAILED"),
        ]
        for (code, expectedName) in expected { #expect(name(NSURLErrorDomain, code) == expectedName, "\(code)") }
        #expect(name("WebKitErrorDomain", 103) == "ERR_UNSAFE_PORT")
        #expect(name("WebKitErrorDomain", 100) == "ERR_FAILED")
        #expect(name(NSURLErrorDomain, NSURLErrorCancelled) == nil, "ERR_ABORTED: a navigation superseded by another")
        #expect(name("WebKitErrorDomain", 102) == nil, "a load interrupted by a policy decision")
        #expect(name("Something", 1) == "ERR_FAILED")
        let unreachable = NSError(domain: NSPOSIXErrorDomain, code: Int(EHOSTUNREACH))
        #expect(name(NSURLErrorDomain, NSURLErrorCannotConnectToHost, underlying: unreachable) == "ERR_ADDRESS_UNREACHABLE")
        #expect(
            name(NSURLErrorDomain, NSURLErrorCannotConnectToHost, underlying: NSError(domain: NSPOSIXErrorDomain, code: Int(ETIMEDOUT)))
                == "ERR_CONNECTION_TIMED_OUT")
    }

    @Test func theErrorPageNamesTheHostAndTheCode() {
        let html = ErrorPage.html(failedURL: "http://example.com:81/x", code: "ERR_CONNECTION_TIMED_OUT")
        #expect(html.contains("<title>example.com</title>"))
        #expect(html.contains("example.com took too long to respond."))
        #expect(html.contains("ERR_CONNECTION_TIMED_OUT"))
        let url = ErrorPage.url(failedURL: "http://example.com/a?b=1&c=2", code: "ERR_FAILED")
        #expect(ErrorPage.parse(url)?.failedURL == "http://example.com/a?b=1&c=2")
        #expect(ErrorPage.parse(url)?.code == "ERR_FAILED")
        #expect(ErrorPage.parse(URL(string: "https://example.com")!) == nil)
        #expect(ErrorPage.html(failedURL: "http://a/<script>", code: "x").contains("<script>") == false, "escaped")
    }
}
