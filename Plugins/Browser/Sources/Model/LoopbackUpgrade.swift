import Foundation

/// When a page gets `LoopbackExemption` (C-10): an `http` document on a loopback host whose
/// `Content-Security-Policy` header has `upgrade-insecure-requests`. A loopback URL is
/// potentially trustworthy as it is, so the browser never upgrades it; WebKit does, so on this
/// page alone the exemption undoes it.
func wantsLoopbackExemption(url: URL?, contentSecurityPolicy: String?) -> Bool {
    guard let url, url.scheme?.lowercased() == "http", let host = url.host(percentEncoded: false), isLoopbackHost(host),
        let contentSecurityPolicy
    else { return false }
    return upgradesInsecureRequests(contentSecurityPolicy)
}

/// The loopback hosts: `localhost` and its subdomains, `127.0.0.0/8`, and `::1`.
func isLoopbackHost(_ host: String) -> Bool {
    var name = host.lowercased()
    if name.hasSuffix(".") { name.removeLast() }
    if name == "localhost" || name.hasSuffix(".localhost") || name == "::1" || name == "[::1]" { return true }
    let octets = name.split(separator: ".", omittingEmptySubsequences: false)
    return octets.count == 4 && octets[0] == "127" && octets.allSatisfy { UInt8($0) != nil }
}

/// Whether a `Content-Security-Policy` header value has `upgrade-insecure-requests`: several
/// headers arrive joined with commas, each a policy of `;`-separated directives whose name is
/// the first token, matched case-insensitively.
func upgradesInsecureRequests(_ policy: String) -> Bool {
    policy.split(separator: ",").flatMap { $0.split(separator: ";") }.contains { directive in
        directive.split(whereSeparator: \.isWhitespace).first?.lowercased() == "upgrade-insecure-requests"
    }
}
