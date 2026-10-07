import AppKit
import Foundation
import TabsPluginSDK
import Testing

@testable import TabsCore

/// `save-resource`'s fetch layer (docs/BROWSER.md J-22, F-7): the scheme policy, `data:` decoding and
/// extension inference, and the routes that need a page: `http(s)` with the page's cookies, and a `blob:`
/// read inside the page in a world of its own, against a real `WKWebView`.
@MainActor
@Suite struct BrowserResourceFetchTests {
    // MARK: Scheme policy, decoding, extensions

    @Test func allowsTheFourReadFromSchemes() {
        #expect(isAllowedResourceUrl("http://example.com/a.png"))
        #expect(isAllowedResourceUrl("https://example.com/a.png"))
        #expect(isAllowedResourceUrl("blob:http://example.com/uuid"))
        #expect(isAllowedResourceUrl("data:text/plain,hi"))
    }

    /// The load-bearing overlap with the http(s) route, which would otherwise read a local file.
    @Test func refusesFileAndEveryOtherSchemeTheLoadBearingOverlapWithTheHTTPRoute() {
        #expect(!isAllowedResourceUrl("file:///etc/hosts"))
        #expect(!isAllowedResourceUrl("chrome://version"))
        #expect(!isAllowedResourceUrl("javascript:alert(1)"))
        #expect(!isAllowedResourceUrl("ftp://example.com/x"))
        #expect(!isAllowedResourceUrl("not a url"))
    }

    private func fetched(_ result: Result<FetchedResource, VerbFailure>, sourceLocation: SourceLocation = #_sourceLocation)
        -> FetchedResource?
    {
        switch result {
        case .success(let resource): return resource
        case .failure(let failure):
            Issue.record("\(failure.message)", sourceLocation: sourceLocation)
            return nil
        }
    }

    @Test func decodesABase64DataURLAndReportsItsMediatype() throws {
        let url = "data:application/pdf;base64,\(Data([1, 2, 3, 4]).base64EncodedString())"
        let resource = try #require(fetched(ResourceFetch.decodeDataURL(url)))
        #expect([UInt8](resource.bytes) == [1, 2, 3, 4])
        #expect(resource.contentType == "application/pdf")
    }

    @Test func decodesAPercentEncodedNonBase64DataURL() throws {
        let resource = try #require(fetched(ResourceFetch.decodeDataURL("data:text/plain,Hello%20%26%20bye")))
        #expect(String(decoding: resource.bytes, as: UTF8.self) == "Hello & bye")
        #expect(resource.contentType == "text/plain")
    }

    @Test func rejectsAMalformedDataURLRatherThanGuessing() {
        #expect(ResourceFetch.decodeDataURL("data:nothinghere") == .failure(VerbFailure("malformed data: URL")))
    }

    /// A cap of a megabyte stands in for the 50 MB one (`BrowserLimits.maxResourceBytes`, pinned with the other
    /// limits): crossing it is the same code at a fiftieth of the input.
    nonisolated static let cap = 1024 * 1024

    @Test func refusesADataURLOverTheByteCap() {
        let big = Data(count: Self.cap + 1).base64EncodedString()
        guard case .failure(let failure) = ResourceFetch.decodeDataURL("data:application/octet-stream;base64,\(big)", maxBytes: Self.cap)
        else {
            Issue.record("a data: URL over the cap was accepted")
            return
        }
        #expect(failure.message == "resource is too large to save (1.0MB; the cap is 1.0MB)")
        let atTheCap = Data(count: Self.cap).base64EncodedString()
        #expect(fetched(ResourceFetch.decodeDataURL("data:;base64,\(atTheCap)", maxBytes: Self.cap))?.bytes.count == Self.cap)
    }

    @Test func extensionForPrefersAKnownContentType() {
        let empty = Data()
        #expect(ResourceFetch.extensionFor(url: "https://x/y", contentType: "application/pdf", bytes: empty) == "pdf")
        #expect(ResourceFetch.extensionFor(url: "https://x/y", contentType: "image/jpeg", bytes: empty) == "jpg")
        #expect(ResourceFetch.extensionFor(url: "https://x/y", contentType: "IMAGE/PNG", bytes: empty) == "png")
    }

    /// The blob case, where a route reports no type.
    @Test func extensionForSniffsMagicBytesWhenTheTypeIsUnknown() {
        func sniff(_ bytes: [UInt8]) -> String {
            ResourceFetch.extensionFor(url: "blob:https://x/uuid", contentType: nil, bytes: Data(bytes))
        }
        #expect(sniff([0x25, 0x50, 0x44, 0x46]) == "pdf")
        #expect(sniff([0x89, 0x50, 0x4e, 0x47]) == "png")
        #expect(sniff([0xff, 0xd8, 0xff]) == "jpg")
        #expect(sniff([0x47, 0x49, 0x46, 0x38]) == "gif")
        #expect(sniff([0x50, 0x4b, 0x03, 0x04]) == "zip")
        #expect(sniff([0x52, 0x49, 0x46, 0x46, 0, 0, 0, 0, 0x57, 0x45, 0x42, 0x50]) == "webp")
    }

    @Test func extensionForFallsBackToTheURLPathExtensionThenToBin() {
        let empty = Data()
        #expect(ResourceFetch.extensionFor(url: "https://x/report.csv", contentType: nil, bytes: empty) == "csv")
        #expect(ResourceFetch.extensionFor(url: "https://x/nofile", contentType: nil, bytes: empty) == "bin")
        #expect(ResourceFetch.extensionFor(url: "blob:https://x/uuid", contentType: nil, bytes: empty) == "bin")
        #expect(
            ResourceFetch.extensionFor(url: "http://127.0.0.1:8080/asset", contentType: nil, bytes: empty) == "bin",
            "a dot in the host is not an extension")
        #expect(ResourceFetch.extensionFor(url: "https://x/a.toolongforanext", contentType: nil, bytes: empty) == "bin")
        #expect(
            ResourceFetch.extensionFor(url: "https://x/a.TXT?x=1.png", contentType: nil, bytes: empty) == "txt", "the path, not the query")
    }

    // MARK: data:

    @Test func aDataURLReadsTheWayAJavaScriptEngineDoes() throws {
        // Either base64 alphabet, whitespace skipped, padding optional.
        let plain = try #require(fetched(ResourceFetch.decodeDataURL("data:text/plain;base64,aGk")))
        #expect(String(decoding: plain.bytes, as: UTF8.self) == "hi")
        let urlSafe = try #require(fetched(ResourceFetch.decodeDataURL("data:;base64,-_-_")))
        #expect([UInt8](urlSafe.bytes) == [0xfb, 0xff, 0xbf])
        #expect(urlSafe.contentType == nil, "no mediatype is none")
        // An empty mediatype with parameters only: `data:;charset=utf-8,x` has none either.
        let charsetOnly = try #require(fetched(ResourceFetch.decodeDataURL("data:;charset=utf-8,x")))
        #expect(charsetOnly.contentType == nil)
        let withParameters = try #require(fetched(ResourceFetch.decodeDataURL("data:text/html;charset=utf-8,%3Cb%3E")))
        #expect(withParameters.contentType == "text/html" && String(decoding: withParameters.bytes, as: UTF8.self) == "<b>")
        guard case .failure(let bad) = ResourceFetch.decodeDataURL("data:text/plain,100%") else {
            Issue.record("a dangling percent sign decoded")
            return
        }
        #expect(bad.message == "could not decode data: URL: URIError: URI malformed")
    }

    // MARK: http(s)

    private func bed(serving: (FixtureServer) -> Void = { _ in }) async throws -> PageBed {
        try await PageBed(serving: { server in
            server.installStandardPages()
            serving(server)
        })
    }

    /// J-22: the fetch is the host's, so it reaches any origin (no CSP or CORS applies), and carries the page's
    /// cookies: the pane's own session, not an anonymous one.
    @Test func anHTTPResourceIsFetchedWithThePagesCookies() async throws {
        let bed = try await bed { server in
            server.route("/sets-cookie") { _ in
                .init(contentType: "text/plain", headers: ["Set-Cookie": "session=abc123; Path=/"], body: "hello")
            }
            server.route("/whoami") { request in .init(contentType: "text/plain", body: request.headers["cookie"] ?? "no cookie") }
        }
        await bed.load("/sets-cookie")
        let anonymous = try #require(fetched(await ResourceFetch.fetch(bed.url("/whoami"), page: bed.page)))
        #expect(String(decoding: anonymous.bytes, as: UTF8.self) == "session=abc123", "the page's cookie rides along")
        #expect(anonymous.contentType == "text/plain")
    }

    /// J-22: the cookies a response sets go where the page's session keeps them.
    @Test func cookiesAResponseSetsAreKeptInThePagesStore() async throws {
        let bed = try await bed { server in
            server.route("/login") { _ in .init(contentType: "text/plain", headers: ["Set-Cookie": "token=t0k3n; Path=/"], body: "in") }
            server.route("/whoami") { request in .init(contentType: "text/plain", body: request.headers["cookie"] ?? "no cookie") }
        }
        await bed.load("/whoami")
        #expect(fetched(await ResourceFetch.fetch(bed.url("/login"), page: bed.page)) != nil)
        // The page itself, later, sends what the fetch was given.
        #expect(await bed.value("fetch('/whoami').then((r) => r.text())") == "token=t0k3n")
    }

    /// J-22: an answer of 400 or more is refused, not saved.
    @Test func anHTTPStatusOfFourHundredOrMoreIsRefused() async throws {
        let bed = try await bed()
        guard case .failure(let failure) = await ResourceFetch.fetch(bed.url("/missing"), page: bed.page) else {
            Issue.record("a 404 was saved")
            return
        }
        #expect(failure.message == "the resource returned HTTP 404")
    }

    /// J-22: the body is streamed under the cap, so a runaway one is aborted mid-flight.
    @Test func aBodyOverTheCapIsAbortedNotBufferedWhole() async throws {
        let bed = try await bed { server in
            server.route("/huge") { _ in
                .init(status: 200, contentType: "application/octet-stream", data: Data(count: Self.cap + 2 * 1024 * 1024))
            }
        }
        guard case .failure(let failure) = await ResourceFetch.fetch(bed.url("/huge"), page: bed.page, maxBytes: Self.cap) else {
            Issue.record("an oversized body was saved")
            return
        }
        #expect(
            failure.message.hasPrefix("resource is too large to save (") && failure.message.hasSuffix("the cap is 1.0MB)"),
            "\(failure.message)")
    }

    /// J-22: a server that stalls is aborted at the deadline, and the request is released.
    @Test func aServerThatNeverFinishesIsAbortedAtTheDeadline() async throws {
        let bed = try await bed { server in
            server.route("/stall") { _ in .init(contentType: "text/plain", body: "partial", hangs: true) }
        }
        let started = ContinuousClock.now
        guard case .failure(let failure) = await ResourceFetch.fetch(bed.url("/stall"), page: bed.page, httpTimeout: .milliseconds(200))
        else {
            Issue.record("a stalled download was saved")
            return
        }
        #expect(failure.message == "the resource did not finish downloading within 200ms")
        #expect(ResourceFetch.describe(ResourceFetch.httpTimeout) == "25s", "the real deadline reads in seconds")
        #expect(ContinuousClock.now - started < .seconds(10))
    }

    /// H-10: a verb cancelled by its deadline releases the request rather than leaving it streaming.
    @Test func aCancelledDownloadEndsAtOnce() async throws {
        let bed = try await bed { server in
            server.route("/stall") { _ in .init(contentType: "text/plain", body: "partial", hangs: true) }
        }
        let started = ContinuousClock.now
        let download = Task { await ResourceFetch.fetch(bed.url("/stall"), page: bed.page, httpTimeout: .seconds(30)) }
        // Cancelled mid-download: once the server has the request.
        #expect(await eventually { bed.server.requests.contains { $0.path == "/stall" } })
        download.cancel()
        guard case .failure(let failure) = await download.value else {
            Issue.record("a cancelled download was saved")
            return
        }
        #expect(failure.message == "the download was cancelled")
        #expect(ContinuousClock.now - started < .seconds(10))
        // One cancelled before it began answers too, rather than waiting for a deadline nobody is left to hear.
        let early = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await ResourceFetch.fetch(bed.url("/stall"), page: bed.page, httpTimeout: .seconds(30))
        }
        guard case .failure(let refused) = await early.value else {
            Issue.record("a download cancelled before it began was saved")
            return
        }
        #expect(refused.message == "the download was cancelled")
    }

    /// F-7: a redirect must not walk the fetch off http(s): a server could otherwise point it at `file:`.
    @Test func aRedirectToAFileURLIsNotFollowed() async throws {
        let bed = try await bed { server in
            server.route("/to-file") { _ in .redirect(to: "file:///etc/hosts") }
        }
        guard case .failure(let failure) = await ResourceFetch.fetch(bed.url("/to-file"), page: bed.page) else {
            Issue.record("a redirect to file: was followed")
            return
        }
        // The engine refuses an http-to-file redirect itself; the delegate's own refusal covers every other scheme.
        #expect(
            failure.message.hasPrefix("could not fetch the resource: ")
                || failure.message.hasPrefix("the resource redirected to file:///etc/hosts"),
            "\(failure.message)")
    }

    /// J-22: the front door: `file:` and everything not on the list is refused with the allowlist named.
    @Test func aSchemeNotOnTheListIsRefusedBeforeAnyRoute() async throws {
        let bed = try await bed()
        for url in ["file:///etc/hosts", "ftp://example.com/x", "javascript:alert(1)", "not a url"] {
            guard case .failure(let failure) = await ResourceFetch.fetch(url, page: bed.page) else {
                Issue.record("\(url) was fetched")
                continue
            }
            #expect(failure.message == "url not allowed: \(url) (save-resource reads http, https, blob and data URLs)")
        }
    }

    @Test func aConnectionRefusedIsNamedAsSuch() async throws {
        let bed = try await bed()
        guard case .failure(let failure) = await ResourceFetch.fetch(try await FixtureServer.deadOrigin() + "x.png", page: bed.page) else {
            Issue.record("a dead origin answered")
            return
        }
        #expect(failure.message.hasPrefix("could not fetch the resource: "), "\(failure.message)")
    }

    // MARK: blob:

    /// J-22: a blob loaded into an iframe on a page whose CSP is `connect-src 'self'`: the page's own `fetch`
    /// is refused, and the read inside the page's other world is not (measured).
    @Test func aBlobBehindAStrictCSPIsReadEvenThoughThePagesOwnFetchIsBlocked() async throws {
        let bed = try await bed()
        await bed.load("/blobpage")
        for _ in 0..<100 where await bed.value("window.__blobReady") != true { try await Task.sleep(for: .milliseconds(50)) }
        let blob = try #require(await bed.value("window.__blobUrl").stringValue)
        #expect(await bed.value("fetch(window.__blobUrl).then(() => 'reached', (e) => 'blocked:' + e.name)") == "blocked:TypeError")
        let resource = try #require(fetched(await ResourceFetch.fetch(blob, page: bed.page)))
        #expect(resource.bytes == FixtureServer.Standard.assetBytes)
        #expect(resource.contentType == "application/pdf")
    }

    /// J-22: a blob minted and never loaded, on a page whose CSP forbids blob fetches, is reachable.
    @Test func aBlobThePageOnlyMintedIsReadEvenBehindAStrictCSP() async throws {
        let bed = try await bed()
        await bed.load("/blobpage")
        let minted = try #require(
            await bed.value("(window.__unloaded = URL.createObjectURL(new Blob(['x'])), window.__unloaded)").stringValue)
        #expect(await bed.value("fetch(window.__unloaded).then(() => 'reached', (e) => 'blocked:' + e.name)") == "blocked:TypeError")
        let resource = try #require(fetched(await ResourceFetch.fetch(minted, page: bed.page)))
        #expect(resource.bytes == Data("x".utf8))
    }

    /// J-22: a blob on an `about:blank` page (`blob:null/…`), minted and never loaded, then loaded into an iframe.
    @Test func aBlobOnAnAboutBlankPageIsRead() async throws {
        let bed = try await PageBed()
        let expected = Data((0..<600).map { UInt8(($0 * 7 + 3) % 256) })
        let blob = try #require(
            await bed.value(
                "(window.__u = URL.createObjectURL(new Blob([Uint8Array.from({ length: 600 }, (_, i) => (i * 7 + 3) % 256)], { type: 'application/pdf' })), window.__u)"
            ).stringValue)
        #expect(blob.hasPrefix("blob:"))
        let minted = try #require(fetched(await ResourceFetch.fetch(blob, page: bed.page)))
        #expect(minted.bytes == expected && minted.contentType == "application/pdf")
        _ = await bed.value(
            "(() => { const f = document.createElement('iframe'); f.id = 'fr'; f.src = window.__u; document.body.appendChild(f); return true })()"
        )
        let element = try #require(fetched(await fetchedSource(bed, selector: "#fr")))
        #expect(element.bytes == expected)
    }

    private func fetchedSource(_ bed: PageBed, selector: String) async -> Result<FetchedResource, VerbFailure> {
        switch await ResourceFetch.resolveElementSrc(in: bed.page, ref: nil, selector: selector) {
        case .success(let url): return await ResourceFetch.fetch(url, page: bed.page)
        case .failure(let failure): return .failure(failure)
        }
    }

    /// J-22: the cap is checked inside the page against `blob.size` before anything is encoded: an oversized blob costs no giant string.
    @Test func aBlobOverTheCapIsRefusedBeforeItIsEncoded() async throws {
        let bed = try await PageBed()
        let blob = try #require(
            await bed.value("(window.__u = URL.createObjectURL(new Blob([new Uint8Array(\(Self.cap + 1))])), window.__u)").stringValue)
        guard case .failure(let failure) = await ResourceFetch.fetch(blob, page: bed.page, maxBytes: Self.cap) else {
            Issue.record("an oversized blob was read")
            return
        }
        #expect(failure.message == "resource is too large to save (1.0MB; the cap is 1.0MB)")
    }

    /// J-22: a revoked blob is gone, and the error says what was tried and why it may be so.
    @Test func aRevokedBlobIsGoneAndTheErrorSaysSo() async throws {
        let bed = try await PageBed()
        let blob = try #require(
            await bed.value("(window.__u = URL.createObjectURL(new Blob(['x'])), URL.revokeObjectURL(window.__u), window.__u)").stringValue)
        guard case .failure(let failure) = await ResourceFetch.fetch(blob, page: bed.page) else {
            Issue.record("a revoked blob was read")
            return
        }
        #expect(failure.message.hasPrefix("the blob could not be read: fetching it inside the page failed ("), "\(failure.message)")
        #expect(failure.message.hasSuffix("a revoked blob URL is gone entirely"))
    }

    // MARK: Naming the resource from an element

    /// J-22: an element's `currentSrc`/`src`/`href`/`data`, by selector or by a `read-page` ref; each miss says why.
    @Test func anElementNamesItsResourceBySelectorOrRefAndEveryMissSaysWhy() async throws {
        let bed = try await bed()
        await bed.load("/blobpage")
        func source(ref: String? = nil, selector: String? = nil) async -> String {
            switch await ResourceFetch.resolveElementSrc(in: bed.page, ref: ref, selector: selector) {
            case .success(let url): return url
            case .failure(let failure): return "ERROR: \(failure.message)"
            }
        }
        #expect(await source(selector: "img#pic") == bed.url("/asset.png"))
        #expect(await source(selector: "a#dl") == bed.url("/asset.png"))
        #expect(await source(selector: "h1") == "ERROR: the element has no src/href to save")
        #expect(await source(selector: "#nothing") == "ERROR: no element matches selector \"#nothing\"")
        #expect(await source(selector: "[").hasPrefix("ERROR: invalid selector: "))
        #expect(await source(ref: "e1-zzzzz") == "ERROR: \(staleRefError("e1-zzzzz"))")
        // A ref minted by read-page resolves to the same element's source.
        let read = await bed.value(readPageScript(ReadPageFilter(role: "link")))
        let ref = try #require(read["elements"]?[0]?["ref"]?.stringValue)
        #expect(await source(ref: ref) == bed.url("/asset.png"))
    }
}
