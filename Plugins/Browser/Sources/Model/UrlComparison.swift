import Foundation

/// The rule behind the navigation verbs' `redirected` flag: is the URL a
/// navigation settled on a *different place* than the one requested, or just a
/// cosmetically normalized form of it?
///
/// `navigate` and `create-browser-pane` report `redirected: true` when this
/// returns false, so a caller never has to string-compare heuristically. The
/// flag exists to say "you did not get the page you asked for" — so anything
/// that still delivers the requested page counts as trivial:
///
/// - a trailing slash added or dropped (`/foo/` vs `/foo`, `""` vs `/`)
/// - query parameters *added* (a tracking param, a session id) — but a
///   parameter the caller asked for being dropped or changed is a real
///   difference, since auth flows routinely stash the deep link there
/// - the scheme (an http→https upgrade delivers the page asked for)
/// - the fragment (same document either way)
///
/// A different host, port, or path is never trivial. URLs that don't parse are
/// compared as plain strings.
func isTrivialUrlChange(requested: String, final: String) -> Bool {
    if requested == final { return true }
    guard let from = ParsedURL(requested), let to = ParsedURL(final) else {
        // Unparseable and not string-equal: report the difference rather than
        // guessing at its shape.
        return false
    }
    // A hostname is case-insensitive and a scheme's default port is no port,
    // so http→https with default ports compares equal here — which is the
    // point. An explicit port survives and must match.
    if from.host != to.host || from.port != to.port { return false }
    if normalizedPath(from.path) != normalizedPath(to.path) { return false }
    // Every parameter the caller asked for must survive with its value; what
    // the destination *added* alongside is its own business.
    for (key, value) in from.query where !to.query.contains(where: { $0.0 == key && $0.1 == value }) {
        return false
    }
    return true
}

/// `/foo/` and `/foo` name the same place; the root's lone slash stays.
private func normalizedPath(_ path: String) -> String {
    path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
}

/// The parts of an absolute URL the comparison reads, as `new URL(…)` reports
/// them: `host` lowercased, `port` empty for the scheme's default, `path`
/// never empty for a hierarchical URL, `query` decoded as `URLSearchParams`
/// decodes it.
struct ParsedURL {
    var host: String
    var port: String
    var path: String
    var query: [(String, String)]

    init?(_ raw: String) {
        guard let scheme = parsedScheme(raw), let components = URLComponents(string: raw) ?? URLComponents(string: Self.encoded(raw)) else {
            return nil
        }
        host = (components.host ?? "").lowercased()
        let defaults = ["http": 80, "https": 443, "ws": 80, "wss": 443, "ftp": 21]
        if let explicit = components.port, explicit != defaults[scheme] { port = String(explicit) } else { port = "" }
        let hierarchical = raw.contains("://")
        path = components.percentEncodedPath.isEmpty && hierarchical ? "/" : components.percentEncodedPath
        query = (components.percentEncodedQuery ?? "").split(separator: "&", omittingEmptySubsequences: true).map { pair in
            let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            return (Self.decode(parts[0]), parts.count > 1 ? Self.decode(parts[1]) : "")
        }
    }

    /// A URL the strict parser refuses (a space, a raw `<`) with what it can't hold percent-encoded.
    private static func encoded(_ raw: String) -> String {
        raw.addingPercentEncoding(withAllowedCharacters: .urlFragmentAllowed.union(CharacterSet(charactersIn: "%#"))) ?? raw
    }

    private static func decode(_ text: Substring) -> String {
        let spaced = text.replacingOccurrences(of: "+", with: " ")
        return spaced.removingPercentEncoding ?? spaced
    }
}
