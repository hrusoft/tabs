import AppKit
import Foundation
import TabsPluginSDK
import Testing
import WebKit

@testable import TabsCore

/// `upgrade-insecure-requests` leaves a loopback page's URLs alone (docs/BROWSER.md: C-10), against
/// a real `WKWebView`: WebKit upgrades them, and `LoopbackExemption` undoes it.
@MainActor
@Suite struct BrowserLoopbackExemptionTests {
    private static let upgrading = ["Content-Security-Policy": "default-src 'self' 'unsafe-inline'; upgrade-insecure-requests"]

    /// `/` sends the directive, runs a script, fetches, and links to `/next` and `/plain`.
    private func bed() async throws -> PageBed {
        try await PageBed(serving: { server in
            server.page(
                "/", title: "Upgrading", head: "<script src='/script.js'></script>",
                body: """
                    <a id=next href='/next'>next</a><a id=plain href='/plain'>plain</a>
                    <script>fetch('/api').then(r => r.text()).then(t => window.__fetched = t, e => window.__fetched = String(e))</script>
                    """,
                headers: Self.upgrading)
            server.route("/script.js", .init(contentType: "text/javascript", body: "window.__ran = true"))
            server.route("/api", .init(contentType: "text/plain", body: "api-ok"))
            server.page("/next", title: "Next", headers: Self.upgrading)
            server.page("/plain", title: "Plain")
        })
    }

    private func https(_ bed: PageBed, _ path: String) -> String {
        bed.server.url(path, host: "127.0.0.1").replacingOccurrences(of: "http://", with: "https://")
    }

    private func requested(_ bed: PageBed, _ path: String) -> Bool { bed.server.requests.contains { $0.path == path } }

    /// Clicks a link and waits for the page it leads to.
    private func follow(_ bed: PageBed, _ id: String) async {
        let before = bed.page.url
        await bed.value("(document.getElementById('\(id)').click(), 1)")
        #expect(await eventually { bed.page.url != before })
        _ = await bed.page.waitForLoadEnd(timeoutMs: 5000)
    }

    @Test func aDirectiveIsAnyPolicysUpgradeInsecureRequests() {
        #expect(upgradesInsecureRequests("upgrade-insecure-requests"))
        #expect(upgradesInsecureRequests("default-src 'self'; Upgrade-Insecure-Requests ;img-src *"))
        #expect(upgradesInsecureRequests("default-src 'self', upgrade-insecure-requests"), "a second header, joined")
        #expect(upgradesInsecureRequests("script-src 'self';\tupgrade-insecure-requests"))
        #expect(!upgradesInsecureRequests("default-src 'self'; block-all-mixed-content"))
        #expect(!upgradesInsecureRequests("upgrade-insecure-requests-not; report-uri /upgrade-insecure-requests"))
        #expect(!upgradesInsecureRequests(""))
    }

    @Test func theLoopbackHostsAreLocalhostAndTheLoopbackAddresses() {
        for host in ["localhost", "LOCALHOST", "localhost.", "app.localhost", "127.0.0.1", "127.1.2.3", "::1", "[::1]"] {
            #expect(isLoopbackHost(host), "\(host)")
        }
        for host in ["example.com", "localhost.example.com", "notlocalhost", "128.0.0.1", "127.0.0", "127.0.0.256", "10.0.0.1", "::2"] {
            #expect(!isLoopbackHost(host), "\(host)")
        }
    }

    @Test func onlyAnHttpLoopbackDocumentWithTheDirectiveIsExempted() {
        let policy = "upgrade-insecure-requests"
        #expect(wantsLoopbackExemption(url: URL(string: "http://localhost:3000/"), contentSecurityPolicy: policy))
        #expect(wantsLoopbackExemption(url: URL(string: "http://127.0.0.1/app"), contentSecurityPolicy: policy))
        #expect(wantsLoopbackExemption(url: URL(string: "http://[::1]:8080/"), contentSecurityPolicy: policy))
        #expect(!wantsLoopbackExemption(url: URL(string: "https://localhost:3000/"), contentSecurityPolicy: policy))
        #expect(!wantsLoopbackExemption(url: URL(string: "http://example.com/"), contentSecurityPolicy: policy), "not loopback: upgraded")
        #expect(!wantsLoopbackExemption(url: URL(string: "http://localhost:3000/"), contentSecurityPolicy: "default-src 'self'"))
        #expect(!wantsLoopbackExemption(url: URL(string: "http://localhost:3000/"), contentSecurityPolicy: nil))
        #expect(!wantsLoopbackExemption(url: nil, contentSecurityPolicy: policy))
    }

    @Test func theRuleListCompiles() async throws {
        let bed = try await bed()
        #expect(await LoopbackExemption(directory: bed.ruleListDirectory).ruleList() != nil)
    }

    /// C-10: the page's script, its fetch and a same-origin link all stay on http, on either loopback name.
    @Test(arguments: ["localhost", "127.0.0.1"]) func aLoopbackPageWithTheDirectiveLoadsOverHttp(host: String) async throws {
        let bed = try await bed()
        let outcome = await bed.load(bed.server.url("/", host: host))
        #expect(outcome.loaded && outcome.loadError == nil)
        #expect(await bed.value("String(window.__ran)") == "true", "the script loaded")
        #expect(await eventually { requested(bed, "/api") })
        #expect(await bed.value("new Promise(r => setTimeout(() => r(String(window.__fetched)), 100))") == "api-ok")
        await follow(bed, "next")
        #expect(bed.page.url == bed.server.url("/next", host: host))
        #expect(bed.page.lastLoadError == nil)
        #expect(bed.page.documentStatus?.status == 200)
    }

    /// C-10: without the directive nothing is redirected: a page's own https loopback URL stays https.
    @Test func aPageWithoutTheDirectiveKeepsItsOwnHttpsLoopbackUrls() async throws {
        let bed = try await bed()
        bed.server.page("/explicit", title: "Explicit", head: "<script src='\(https(bed, "/script.js"))'></script>")
        await bed.load("/explicit")
        #expect(await bed.value("String(window.__ran)") == "undefined")
        #expect(!requested(bed, "/script.js"))
    }

    /// C-10: an https loopback URL asked for from an exempted page stays https (and fails, served over http).
    @Test func anHttpsLoopbackUrlAskedForFromAnExemptedPageStaysHttps() async throws {
        let bed = try await bed()
        await bed.load("/")
        let outcome = await bed.load(https(bed, "/plain"))
        #expect(outcome.loadError != nil)
        #expect(bed.page.url == https(bed, "/plain"))
        #expect(!requested(bed, "/plain"))
    }

    /// C-10: a history step back onto an exempted page brings its exemption back, and a page without
    /// the directive leaves it off.
    @Test func theExemptionFollowsTheDocumentThroughHistory() async throws {
        let bed = try await bed()
        await bed.load("/")
        await follow(bed, "plain")
        #expect(bed.page.url == bed.url("/plain"))
        let script = "fetch('\(https(bed, "/api"))').then(r => r.text(), e => 'failed')"
        #expect(await bed.value(script) == "failed", "no exemption on a page without the directive")
        bed.page.goBack()
        #expect(await eventually { bed.page.url == bed.url("/") })
        _ = await bed.page.waitForLoadEnd(timeoutMs: 5000)
        #expect(await bed.value("fetch('/api').then(r => r.text(), e => String(e))") == "api-ok")
    }
}
