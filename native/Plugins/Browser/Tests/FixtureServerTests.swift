import AppKit
import Foundation
import TabsPluginSDK
import Testing

@testable import TabsCore

/// The standard pages (`Tests/Support/FixtureServer+Standard.swift`, the Electron external-control tests'
/// `e2e/helpers/testServer.ts`), each loaded into a real page: one distinctive fact per route, so a page
/// that drifted from the Electron server's is named here and not in a verb test three files away.
@MainActor
@Suite struct FixtureServerTests {
    private func standardBed() async throws -> PageBed {
        try await PageBed(serving: { $0.installStandardPages() })
    }

    /// Polls an expression until it answers `expected`.
    private func eventuallyValue(_ bed: PageBed, _ script: String, is expected: JSONValue, timeout: Duration = .seconds(5)) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if case .success(let value) = await bed.page.evaluate(script), value == expected { return true }
            try? await Task.sleep(for: .milliseconds(25))
        }
        return false
    }

    /// One request, as a script outside a page makes it: headers and body as sent.
    private func fetch(_ server: FixtureServer, _ path: String) async throws -> (HTTPURLResponse, Data) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        let (data, response) = try await URLSession(configuration: configuration).data(from: URL(string: server.url(path))!)
        return (response as! HTTPURLResponse, data)
    }

    @Test func thePageIsTheBusyFixtureAndItsLoadsRunTheWayTheVerbTestsNeedThem() async throws {
        let bed = try await standardBed()
        await bed.load("/page")
        #expect(await bed.value("document.title") == "Fixture")
        #expect(await bed.value("document.getElementById('status').textContent") == "idle")
        #expect(await bed.value("window.__fixtureScriptLoaded") == true, "/script.js ran")
        #expect(await bed.value("document.querySelectorAll('[aria-label=Duplicate]').length") == 3)
        #expect(await bed.value("document.body.scrollHeight > 3000") == true)
        #expect(await bed.consoleHas("fixture ready"))
        #expect(await bed.consoleHas("a warning happened"))
        #expect(await bed.consoleHas("an error happened"))
        #expect(await bed.consoleHas("delayed message"), "the late message arrives")
        #expect(await eventually { bed.server.requests.contains { $0.path == "/api/secret" } }, "the page fetches a sub-resource")
        await bed.value("document.getElementById('go').click()")
        #expect(await bed.value("document.getElementById('status').textContent") == "clicked")
        await bed.value("document.getElementById('cart-add').click()")
        #expect(await bed.value("document.getElementById('status').textContent") == "cart-added")
    }

    @Test func anyPathNothingClaimsAnswersTheFixtureLikeTheElectronServer() async throws {
        let bed = try await standardBed()
        await bed.load("/")
        #expect(await bed.value("document.title") == "Fixture")
        await bed.load("/whatever?x=1")
        #expect(await bed.value("document.title") == "Fixture")
        #expect(bed.page.documentStatus?.status == 200)
    }

    @Test func otherIsElsewhere() async throws {
        let bed = try await standardBed()
        await bed.load("/other")
        #expect(await bed.value("document.title") == "Elsewhere")
        #expect(await bed.value("document.body.textContent") == "Elsewhere")
    }

    @Test func shiftyReportsWhichButtonAClickReached() async throws {
        let bed = try await standardBed()
        await bed.load("/shifty")
        #expect(await bed.value("document.title") == "Shifty")
        await bed.value("document.getElementById('decoy').click()")
        #expect(await bed.value("document.getElementById('status').textContent") == "decoy-clicked")
        await bed.value("document.getElementById('target').click()")
        #expect(await bed.value("document.getElementById('status').textContent") == "target-clicked")
    }

    @Test func waityChangesOnlyWhenTheTestDrivesIt() async throws {
        let bed = try await standardBed()
        await bed.load("/waity")
        #expect(await bed.value("document.title") == "Waity")
        #expect(await bed.value("getComputedStyle(document.getElementById('panel')).display") == "none")
        await bed.value("window.revealPanel()")
        #expect(await bed.value("getComputedStyle(document.getElementById('panel')).display") == "block")
        await bed.value("window.hideSpinner()")
        #expect(await bed.value("getComputedStyle(document.getElementById('spinner')).display") == "none")
        await bed.value("window.appendReady('ready now')")
        #expect(await bed.value("document.body.lastElementChild.textContent") == "ready now")
        await bed.value("window.churn(300)")
        let first = await bed.value("document.getElementById('churn-target').textContent")
        #expect(first.stringValue?.hasPrefix("churn ") == true)
        try await Task.sleep(for: .milliseconds(150))
        #expect(await bed.value("document.getElementById('churn-target').textContent") != first, "the DOM keeps changing while it churns")
    }

    @Test func nestedHoldsAFrameAndAnOpenShadowRoot() async throws {
        let bed = try await standardBed()
        await bed.load("/nested")
        #expect(await bed.value("document.title") == "Nested content")
        #expect(await eventuallyValue(bed, "document.getElementById('the-frame').contentDocument?.title ?? ''", is: "Inner frame"))
        #expect(await bed.value("document.getElementById('shadow-host').shadowRoot.querySelector('button').textContent") == "Shadow button")
        #expect(
            await bed.value("document.querySelectorAll('button').length") == 1, "querySelectorAll sees neither the frame nor the shadow")
        // The frame's button reaches the top document by postMessage, the shadow's sets the flag itself.
        await bed.value("document.getElementById('the-frame').contentDocument.getElementById('frame-button').click()")
        #expect(await eventuallyValue(bed, "window.frameButtonClicked", is: true))
        await bed.value("document.getElementById('shadow-host').shadowRoot.querySelector('button').click()")
        #expect(await bed.value("window.shadowButtonClicked") == true)
    }

    @Test func nestedFrameIsItsOwnPage() async throws {
        let bed = try await standardBed()
        await bed.load("/nested-frame")
        #expect(await bed.value("document.title") == "Inner frame")
    }

    @Test func listingHasFarMoreCheckboxesThanTheReadCapBeforeItsSelect() async throws {
        let bed = try await standardBed()
        await bed.load("/listing")
        #expect(await bed.value("document.title") == "Listing")
        #expect(await bed.value("document.querySelectorAll('input[type=checkbox]').length") == 240)
        #expect(await bed.value("document.getElementById('brand239').getAttribute('aria-label')") == "Brand 239")
        #expect(
            await bed.value(
                "document.getElementById('brand239').compareDocumentPosition(document.getElementById('sort')) & Node.DOCUMENT_POSITION_FOLLOWING"
            )
                != 0, "the select sits after them in document order")
        #expect(await bed.value("document.querySelectorAll('img').length") == 3)
    }

    @Test func smoothOptsIntoSmoothScrolling() async throws {
        let bed = try await standardBed()
        await bed.load("/smooth")
        #expect(await bed.value("document.title") == "Smooth")
        #expect(await bed.value("getComputedStyle(document.documentElement).scrollBehavior") == "smooth")
        #expect(await bed.value("document.documentElement.scrollHeight >= 5000") == true)
    }

    @Test func hoveryKeepsItsSubmenuHiddenUntilTheMenuIsEntered() async throws {
        let bed = try await standardBed()
        await bed.load("/hovery")
        #expect(await bed.value("document.title") == "Hovery")
        #expect(await bed.value("getComputedStyle(document.getElementById('submenu')).display") == "none")
        // Hover itself can't be produced in a window that is never shown; the handler is the fixture's own.
        await bed.value("document.getElementById('menu').dispatchEvent(new MouseEvent('mouseenter'))")
        #expect(await bed.value("getComputedStyle(document.getElementById('submenu')).display") == "block")
        #expect(await bed.value("document.getElementById('status').textContent") == "menu-open")
        #expect(await bed.value("document.getElementById('sub-widgets').getAttribute('href')") == "/other")
    }

    @Test func formSubmitsWithoutNavigatingAndLogsItsKeys() async throws {
        let bed = try await standardBed()
        await bed.load("/form")
        #expect(await bed.value("document.title") == "Form")
        #expect(await bed.value("window.__submits") == 0)
        await bed.value("document.getElementById('form').requestSubmit()")
        #expect(await bed.value("window.__submits") == 1)
        #expect(bed.page.url == bed.url("/form"), "the handler prevents the navigation")
        await bed.value("document.dispatchEvent(new KeyboardEvent('keydown', { key: 'a', code: 'KeyA', shiftKey: true }))")
        #expect(await bed.value("JSON.stringify(window.__keys)") == #"[["keydown","a","KeyA",true]]"#)
    }

    @Test func controlsCoverEveryStateReadPageNames() async throws {
        let bed = try await standardBed()
        await bed.load("/controls")
        #expect(await bed.value("document.title") == "Controls")
        #expect(await bed.value("document.getElementById('some').indeterminate") == true, "set from script by the page")
        #expect(await bed.value("document.getElementById('subscribed').checked") == true)
        #expect(await bed.value("document.getElementById('agree').checked") == false)
        #expect(await bed.value("document.getElementById('bare').value") == "Beta")
        #expect(await bed.value("document.getElementById('wifi').getAttribute('aria-checked')") == "true")
        #expect(await bed.value("document.getElementById('qty').labels[0].textContent.trim().startsWith('Qty')") == true)
    }

    @Test func blobpageShowsABlobInAFrameBehindACSPThatBlocksFetchingIt() async throws {
        let bed = try await standardBed()
        await bed.load("/blobpage")
        #expect(await bed.value("document.title") == "Blob holder")
        #expect(await eventuallyValue(bed, "window.__blobReady", is: true))
        #expect(await bed.value("window.__blobUrl.startsWith('blob:')") == true)
        // The strict CSP is the point: an in-page fetch of the blob is refused.
        #expect(await bed.value("fetch(window.__blobUrl).then(() => 'fetched', () => 'blocked')") == "blocked")
        #expect(
            await eventuallyValue(bed, "document.getElementById('pic').naturalWidth === 0", is: true), "the bytes are not a decodable image"
        )
        let (response, _) = try await fetch(bed.server, "/blobpage")
        #expect(response.value(forHTTPHeaderField: "Content-Security-Policy")?.contains("connect-src 'self'") == true)
    }

    @Test func theAssetIsFiveHundredTwentyDeterministicBytesOpeningWithThePNGSignature() async throws {
        let bed = try await standardBed()
        let (response, data) = try await fetch(bed.server, "/asset.png")
        #expect(response.value(forHTTPHeaderField: "Content-Type") == "image/png")
        #expect(data.count == 520)
        #expect(Array(data.prefix(8)) == [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a])
        #expect(data == FixtureServer.Standard.assetBytes)
        #expect(data[8 + 300] == UInt8(300 % 256))
        // The same bytes through the page.
        await bed.load("/blobpage")
        #expect(await bed.value("fetch('/asset.png').then((r) => r.arrayBuffer()).then((b) => b.byteLength)") == 520)
    }

    @Test func theScriptSetsItsFlagAndTheSecretCarriesTheHeadersARedactionPassStrips() async throws {
        let bed = try await standardBed()
        let (script, scriptBody) = try await fetch(bed.server, "/script.js")
        #expect(script.value(forHTTPHeaderField: "Content-Type") == "text/javascript")
        #expect(String(decoding: scriptBody, as: UTF8.self) == "window.__fixtureScriptLoaded = true")

        let (secret, secretBody) = try await fetch(bed.server, "/api/secret")
        #expect(secret.value(forHTTPHeaderField: "Content-Type") == "application/json")
        #expect(secret.value(forHTTPHeaderField: "Set-Cookie") == "session=super-secret-value; Path=/")
        #expect(secret.value(forHTTPHeaderField: "X-Fixture-Header") == "fixture-value")
        #expect(String(decoding: secretBody, as: UTF8.self) == #"{"ok":true}"#)

        let (big, bigBody) = try await fetch(bed.server, "/api/big")
        #expect(big.value(forHTTPHeaderField: "Content-Type") == "application/json")
        #expect(bigBody.count == #"{"filler":""}"#.utf8.count + 20000)
    }

    @Test func slowAnswersAboutASecondLate() async throws {
        let bed = try await standardBed()
        let started = ContinuousClock.now
        bed.page.load(bed.url("/slow"))
        #expect(bed.page.isLoading)
        let outcome = await bed.page.waitForLoadEnd(timeoutMs: 10_000)
        let elapsed = started.duration(to: .now)
        #expect(outcome.loaded)
        #expect(elapsed >= .milliseconds(900), "\(elapsed)")
        #expect(elapsed < .seconds(5), "\(elapsed)")
        #expect(await bed.value("document.body.textContent") == "Eventually loaded")
    }

    @Test func bigtextIsFarPastThePipeBufferAndEndsWithItsMarker() async throws {
        let bed = try await standardBed()
        await bed.load("/bigtext")
        #expect(await bed.value("document.title") == "Big")
        #expect(await bed.value("document.body.innerText.length >= 120000") == true)
        #expect(await bed.value("document.body.innerText.trim().endsWith('END-OF-BIGTEXT')") == true)
        #expect(FixtureServer.Standard.bigTextSize > 65536)
    }

    @Test func missingIsA404WithPlainText() async throws {
        let bed = try await standardBed()
        await bed.load("/missing")
        #expect(bed.page.documentStatus?.status == 404)
        #expect(bed.page.documentStatus?.statusText == "Not Found")
        let (response, data) = try await fetch(bed.server, "/missing")
        #expect(response.value(forHTTPHeaderField: "Content-Type") == "text/plain")
        #expect(String(decoding: data, as: UTF8.self) == "nope")
    }

    @Test func redirectSendsARelativeLocationToOther() async throws {
        let bed = try await standardBed()
        await bed.load("/redirect")
        #expect(bed.page.url == bed.url("/other"), "the committed URL is the final one, absolute")
        #expect(await bed.value("document.title") == "Elsewhere")
        #expect(bed.page.documentStatus?.status == 200)
        #expect(bed.server.requests.map(\.path).suffix(2) == ["/redirect", "/other"])
    }

    @Test func lateTitleHasNoTitleUntilAScriptSetsOneASecondLater() async throws {
        let bed = try await standardBed()
        await bed.load("/late-title")
        #expect(await bed.value("document.title") == "", "no <title> when the load settles")
        #expect(await eventuallyValue(bed, "document.title", is: "Set later"))
    }

    @Test func bounceOnceRedirectsTheFirstRequestPerTokenOnly() async throws {
        let bed = try await standardBed()
        await bed.load("/bounce-once/abc")
        #expect(bed.page.url == bed.url("/other"), "the first hit bounces away")
        await bed.load("/bounce-once/abc")
        #expect(bed.page.url == bed.url("/bounce-once/abc"))
        #expect(await bed.value("document.title") == "Deep link")
        #expect(await bed.value("document.body.textContent") == "Deep link content")
        await bed.load("/bounce-once/def")
        #expect(bed.page.url == bed.url("/other"), "another token is a fresh session")
    }

    @Test func aFreshServerBouncesAgain() async throws {
        let first = try await standardBed()
        await first.load("/bounce-once/abc")
        await first.load("/bounce-once/abc")
        #expect(await first.value("document.title") == "Deep link")
        let second = try await standardBed()
        await second.load("/bounce-once/abc")
        #expect(second.page.url == second.url("/other"), "the state is per server")
    }

    @Test func startStandardIsAServerWithThePagesInstalled() async throws {
        let server = try await FixtureServer.startStandard()
        defer { server.stop() }
        let (response, data) = try await fetch(server, "/other")
        #expect(response.statusCode == 200)
        #expect(String(decoding: data, as: UTF8.self).contains("Elsewhere"))
    }

    @Test func aDeadOriginRefusesTheConnection() async throws {
        let bed = try await standardBed()
        let outcome = await bed.load(try await FixtureServer.deadOrigin())
        #expect(!outcome.loaded)
        #expect(outcome.loadError != nil)
    }

    @Test func aDataPageIsATitleAndABodyPercentEncoded() async throws {
        let url = FixtureServer.dataPage("Data page", "<p id=x>a b&c</p>")
        #expect(url == "data:text/html,%3Ctitle%3EData%20page%3C%2Ftitle%3E%3Cp%20id%3Dx%3Ea%20b%26c%3C%2Fp%3E")
        let bed = try await standardBed()
        await bed.load(url)
        #expect(await bed.value("document.title") == "Data page")
        #expect(await bed.value("document.getElementById('x').textContent") == "a b&c")
    }
}
