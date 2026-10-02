import Foundation

/// The browser's URL scheme policy (`urlPolicy.ts`), which is *two* policies for
/// two genuinely different questions — kept in one file because they read as
/// one subject, but each unforked across its own enforcement points.
///
/// ## `isAllowedUrl` — steer-to
///
/// What an agent may *navigate a pane to*. Two enforcement points that must not
/// fork: the navigating verbs check it up front, and the navigation guard on
/// agent-owned panes (`BrowserPane`'s `decidePolicyFor`) re-checks it for
/// navigations the *page* initiates — a script setting `location.href`, a link
/// click — which would otherwise walk straight around the verb-level check
/// (e.g. to `file://`, turning get-page-text into a local file reader).
/// Navigation is a load into the visible pane, so it is deliberately narrow:
/// `http`/`https`/`about:blank`.
///
/// ## `isAllowedResourceUrl` — read-from
///
/// What `save-resource` may *fetch bytes from*. A resource fetch is a read in
/// the page's own context, not a navigation, so it is a different question
/// with a different answer: `blob:` and `data:` are page-minted content and the
/// whole point of the verb, though they are meaningless as navigation targets.
/// `file:` stays refused: the http(s) route could read a local file if asked,
/// so the refusal is checked against *both* the caller's `--url` and the URL
/// resolved from an element's `src` (a hostile attribute could hold `file:`).
/// Everything not on the list is refused.
func isAllowedUrl(_ raw: String) -> Bool {
    if raw == "about:blank" { return true }
    guard let scheme = parsedScheme(raw) else { return false }
    return scheme == "http" || scheme == "https"
}

/// The read-from twin of `isAllowedUrl` — see its header for why it differs.
func isAllowedResourceUrl(_ raw: String) -> Bool {
    guard let scheme = parsedScheme(raw) else { return false }
    return ["http", "https", "blob", "data"].contains(scheme)
}

/// Protocols handed to the OS's default handler (`isSafeExternalUrl`): anything
/// a page can print or link is attacker-influenceable in principle, and the OS
/// will happily launch a `file:` path or a registered custom scheme, so the
/// allowlist is deliberately tiny.
func isSafeExternalUrl(_ url: String) -> Bool {
    guard let scheme = parsedScheme(url) else { return false }
    return scheme == "http" || scheme == "https" || scheme == "mailto"
}

/// The lowercased scheme of an absolute URL, or nil for anything `new URL(…)`
/// would refuse: no scheme, or (for the hierarchical web schemes) no host.
func parsedScheme(_ raw: String) -> String? {
    guard let match = raw.firstMatch(of: /^([a-zA-Z][a-zA-Z0-9+.-]*):/) else { return nil }
    let scheme = match.1.lowercased()
    guard let url = URL(string: raw) else { return nil }
    if scheme == "http" || scheme == "https" {
        // `http:` alone, or `http://` with nothing after it, is not a URL.
        guard let host = url.host(percentEncoded: false), !host.isEmpty else { return nil }
    }
    return scheme
}
