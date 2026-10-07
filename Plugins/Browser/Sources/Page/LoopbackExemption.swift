import Foundation
import WebKit

/// `upgrade-insecure-requests` without the loopback upgrade (C-10).
///
/// A dev server on `http://localhost` that sends the directive (helmet's default policy does)
/// must come up: a loopback URL is potentially trustworthy as it is, so the browser never
/// upgrades one. WebKit upgrades those too
/// (`ContentSecurityPolicy::upgradeInsecureRequestIfNeeded` passes
/// `ShouldUpgradeLocalhostAndIPAddress::Yes`), and nothing turns that off: every script, style,
/// image and `fetch` goes to `https://localhost:<port>`, which a plain-HTTP server can't answer,
/// so the page never comes up, and a same-origin link fails with `ERR_SSL_PROTOCOL_ERROR`.
///
/// The upgrade is undone after the fact: a content rule list redirects an `https` loopback
/// request back to `http`, keeping its port (the directive keeps it, bar 80 → 443).
/// - `BrowserPage` turns it on only while its document `wantsLoopbackExemption`, where an
///   `https` loopback request is, as far as can be told, one the directive upgraded. A request
///   the page makes for `https://localhost` itself is downgraded too, then: a rule can't tell
///   the two apart (docs/BROWSER.md, Notes).
/// - WebKit runs a list's `redirect` only for URLs the navigation's
///   `_activeContentRuleListActionPatterns` grant (what Safari gives a web extension's host
///   permissions), which is SPI. A WebKit without it runs the rules as no-ops and the upgrade
///   stands. (Removing the header instead can't be done: measured, a list's `modify-headers`
///   never applies to a response.)
///
/// Not covered (measured): a WebSocket (the constructor upgrades `ws:`, and no rule redirects
/// its handshake), and a directive in a `<meta>` tag (a response decision sees headers only).
///
/// One per plugin instance (`BrowserServices`), shared by its pages: the list is compiled once,
/// into the plugin's own cache.
@MainActor
final class LoopbackExemption {
    static let identifier = "com.hrusoft.tabs.plugin.browser.loopback-exemption"

    /// The redirect, one rule per kind of loopback host (`isLoopbackHost`); a content rule's
    /// regex has no alternation.
    static let rules: String = {
        let hosts = [#"localhost\.?"#, #"[a-z0-9.-]*\.localhost\.?"#, #"127\.[0-9]+\.[0-9]+\.[0-9]+"#, #"\[::1\]"#]
        let rules = hosts.map { host -> [String: Any] in
            [
                "trigger": ["url-filter": "^https://\(host)[:/]"],
                "action": ["type": "redirect", "redirect": ["transform": ["scheme": "http"]]],
            ]
        }
        let data = try! JSONSerialization.data(withJSONObject: rules)
        return String(decoding: data, as: UTF8.self)
    }()

    /// Lets the list redirect in every navigation of a web view made with `configuration`. The
    /// rules name the hosts, so the grant is every URL.
    static func grant(_ configuration: WKWebViewConfiguration) {
        let selector = NSSelectorFromString("_setActiveContentRuleListActionPatterns:")
        guard let preferences = configuration.defaultWebpagePreferences, preferences.responds(to: selector) else { return }
        preferences.perform(selector, with: [identifier: Set(["*://*/*"])] as NSDictionary)
    }

    private let directory: URL
    /// The list, once compiled (nil until a page first wanted it, or if it failed to compile).
    private(set) var compiled: WKContentRuleList?
    private var compiling: Task<WKContentRuleList?, Never>?

    /// - Parameter directory: where the compiled list is stored (`ContentRuleLists` in the
    ///   plugin's cache).
    init(directory: URL) {
        self.directory = directory
    }

    /// Compiles the list on first use.
    func ruleList() async -> WKContentRuleList? {
        if let compiled { return compiled }
        let directory = directory
        let task =
            compiling
            ?? Task {
                try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                return try? await WKContentRuleListStore(url: directory).compileContentRuleList(
                    forIdentifier: Self.identifier, encodedContentRuleList: Self.rules)
            }
        compiling = task
        compiled = await task.value
        return compiled
    }
}
