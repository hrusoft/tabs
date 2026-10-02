import Foundation

/// Ranks `read-page`'s extracted elements against a plain-language description
/// (`findElements.ts`).
///
/// Explicitly a heuristic — substring and token matching over the accessible
/// name, with small nudges from role and tag — not a model-backed semantic
/// search. It exists so a caller can say "the submit button" instead of
/// eyeballing a 200-element list, and it will happily miss an element whose
/// visible wording shares no tokens with the description. When precision
/// matters, read the list from `read-page` and pick a ref directly.
///
/// Free of page and AppKit on purpose: this is the one genuinely fiddly piece of
/// `find`, so it lives where a unit test can reach it.

/// What scoring reads off an element: its accessible name, role and tag, the
/// part of a `PageElement` that exists before any ref is minted.
protocol Scorable {
    var name: String { get }
    var role: String { get }
    var tag: String { get }
}

extension PageElement: Scorable {}

/// A match, carrying the element plus why it scored. Score is 0–1, higher is better.
struct ElementMatch<Element: Scorable> {
    var element: Element
    var score: Double
}

private let defaultMaxResults = 10

/// Words too common to carry signal — they'd otherwise let any element token-match anything.
private let stopWords: Set<String> = ["the", "a", "an", "of", "for", "to", "on", "in", "and", "or"]

private func normalize(_ text: String) -> String {
    text.lowercased().replacing(/\s+/, with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
}

private func tokenize(_ text: String) -> [String] {
    normalize(text).split(whereSeparator: { !($0.isASCII && ($0.isLetter || $0.isNumber)) })
        .map(String.init).filter { !$0.isEmpty && !stopWords.contains($0) }
}

/// How well one element answers `description`, 0 (no match) to 1 (exact).
///
/// The tiers are ordered by how much the match tells you: an exact name is
/// unambiguous, a prefix nearly so, a substring likely, and a scattering of
/// shared tokens only suggestive. Role and tag contribute a small bonus rather
/// than a tier of their own — "button" in a description usually qualifies a
/// name rather than replacing it.
func scoreElement(_ element: some Scorable, description: String) -> Double {
    let query = normalize(description)
    // An empty query matches nothing — which also means the comparisons below
    // need no guard for an element with an empty name, since none of them can
    // be true against a non-empty query.
    if query.isEmpty { return 0 }
    let name = normalize(element.name)
    let queryTokens = tokenize(description)

    var score = 0.0
    if name == query {
        score = 1
    } else if name.hasPrefix(query) {
        score = 0.9
    } else if name.contains(query) {
        score = 0.75
    } else if !queryTokens.isEmpty {
        let nameTokens = Set(tokenize(element.name))
        let hits = queryTokens.filter { nameTokens.contains($0) }.count
        if hits > 0 { score = 0.3 + 0.3 * (Double(hits) / Double(queryTokens.count)) }
    }

    // A role or tag named in the description corroborates a weak name match,
    // but can't manufacture one on its own — otherwise "button" would return
    // every button on the page ranked above the one actually named.
    let corroborates = queryTokens.contains(normalize(element.role)) || queryTokens.contains(normalize(element.tag))
    if score > 0 && corroborates { score = min(1, score + 0.1) }
    return score
}

/// The best `maxResults` matches for `description`, strongest first. Unmatched
/// elements are dropped.
func findElements<Element: Scorable>(
    _ elements: [Element], description: String, maxResults: Int = defaultMaxResults
) -> [ElementMatch<Element>] {
    let matches = elements.enumerated().map {
        (index: $0.offset, match: ElementMatch(element: $0.element, score: scoreElement($0.element, description: description)))
    }
    .filter { $0.match.score > 0 }
    // Stable, as the source's sort is: equal scores keep page order.
    let ranked = matches.sorted { $0.match.score != $1.match.score ? $0.match.score > $1.match.score : $0.index < $1.index }
    return ranked.prefix(max(0, maxResults)).map(\.match)
}
