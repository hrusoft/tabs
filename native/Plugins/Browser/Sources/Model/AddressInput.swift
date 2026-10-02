import Foundation

/// What Enter in the address bar should navigate to (`addressInput.ts`) — the
/// same three-way split a real browser's omnibox makes: a URL with an explicit
/// scheme passes through unchanged, something that looks like a bare domain
/// gets `https://` prepended, and everything else becomes a search-engine
/// query (Google: the search engine is not a setting). nil for
/// blank/whitespace-only input (a no-op, not a navigation to an empty search).
func resolveAddressInput(_ raw: String) -> String? {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.isEmpty { return nil }
    // Checked first: "localhost:3000" would otherwise also match the scheme
    // rule (a bare word followed by ":" is indistinguishable from a URI scheme).
    if looksLikeBareDomain(trimmed) { return "https://\(trimmed)" }
    if trimmed.firstMatch(of: /^[a-zA-Z][a-zA-Z0-9+.-]*:/) != nil { return trimmed }
    return "https://www.google.com/search?q=\(encodeURIComponent(trimmed))"
}

/// True when `trimmed` (no surrounding whitespace) is plausibly a bare domain:
/// `localhost` (with an optional port/path), or a dot before its first slash
/// suggesting a domain — and no internal whitespace either way, since a real
/// URL never has one.
private func looksLikeBareDomain(_ trimmed: String) -> Bool {
    if trimmed.contains(where: \.isWhitespace) { return false }
    return trimmed.firstMatch(of: /^(?i:localhost)(:[0-9]+)?(\/|$)/) != nil
        || trimmed.firstMatch(of: /^[^\/\s]+\.[^\/\s]+/) != nil
}

/// JavaScript's `encodeURIComponent`: everything but letters, digits and
/// `-_.!~*'()` is percent-encoded (as UTF-8).
func encodeURIComponent(_ text: String) -> String {
    text.addingPercentEncoding(withAllowedCharacters: uriComponentAllowed) ?? text
}

private let uriComponentAllowed: CharacterSet = {
    var allowed = CharacterSet.alphanumerics
    allowed.insert(charactersIn: "-_.!~*'()")
    // `alphanumerics` includes non-ASCII letters, which must still be encoded.
    return allowed.intersection(CharacterSet(charactersIn: Unicode.Scalar(0)...Unicode.Scalar(0x7f)))
}()
