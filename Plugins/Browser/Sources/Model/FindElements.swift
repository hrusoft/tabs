import Foundation

/// Ranks `read-page`'s extracted elements against a plain-language description.
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
/// part of a `read-page` element that exists before any ref is minted, and
/// whether it submits a form (what "the submit button" means).
protocol Scorable {
    var name: String { get }
    var role: String { get }
    var tag: String { get }
    var submits: Bool { get }
}

extension Scorable {
    var submits: Bool { false }
}

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

/// The text fields a description's "field", "input" or "box" can mean.
private let textFieldRoles: Set<String> = ["textbox", "searchbox", "combobox", "spinbutton"]

/// Words that name a kind of control rather than a control's own words — "the email field", "the colour
/// dropdown" — and the roles each can mean. They hint the role; they're never matched against names, or
/// "button" in "Covered button" would make it a match for any "… button".
private let roleWords: [String: Set<String>] = [
    "button": ["button"], "link": ["link"], "field": textFieldRoles, "input": textFieldRoles, "box": textFieldRoles,
    "textbox": textFieldRoles, "textfield": textFieldRoles, "dropdown": ["combobox", "listbox"], "select": ["combobox", "listbox"],
    "picker": ["combobox", "listbox"], "combobox": ["combobox"], "listbox": ["listbox"], "checkbox": ["checkbox", "switch"],
    "radio": ["radio"], "switch": ["switch", "checkbox"], "toggle": ["switch", "checkbox", "button"], "slider": ["slider"],
    "tab": ["tab"], "heading": ["heading"], "image": ["img"], "img": ["img"],
]

/// A word as both sides compare it: British spellings and plurals fold (colour → color, buttons →
/// button), the same way for a description and a name, so neither has to match the other's spelling.
private func fold(_ word: String) -> String {
    var word = word
    if word.count > 4, word.hasSuffix("our") { word = String(word.dropLast(3)) + "or" }
    if word.count > 3, word.hasSuffix("s"), !word.hasSuffix("ss") { word = String(word.dropLast()) }
    return word
}

private func tokenize(_ text: String) -> [String] {
    normalize(text).split(whereSeparator: { !($0.isASCII && ($0.isLetter || $0.isNumber)) })
        .map(String.init).filter { !$0.isEmpty && !stopWords.contains($0) }.map(fold)
}

/// How well one element answers `description`, 0 (no match) to 1 (exact).
///
/// The tiers are ordered by how much the match tells you: an exact name is
/// unambiguous, a prefix nearly so, a substring likely, the description's own
/// words being the whole name nearly as likely ("the save profile button" for
/// "Save profile"), and a scattering of shared words only suggestive. Role words
/// are not those words: they say which roles fit (`roleWords`) and contribute a
/// small bonus rather than a tier of their own — "button" in a description
/// qualifies a name rather than replacing it. "submit" also matches a control
/// that submits its form, whatever it is called.
func scoreElement(_ element: some Scorable, description: String) -> Double {
    let query = normalize(description)
    // An empty query matches nothing — which also means the comparisons below
    // need no guard for an element with an empty name, since none of them can
    // be true against a non-empty query.
    if query.isEmpty { return 0 }
    let name = normalize(element.name)
    let queryTokens = tokenize(description)
    let hinted = roleHints(queryTokens)
    let words = queryTokens.filter { roleWords[$0] == nil }
    // Role words alone name no control — "button" isn't the name of the one called "Covered
    // button" — unless a control is called exactly that ("Select").
    if words.isEmpty && !hinted.isEmpty { return name == query ? 1 : 0 }

    var score = 0.0
    if name == query {
        score = 1
    } else if name.hasPrefix(query) {
        score = 0.9
    } else if name.contains(query) {
        score = 0.75
    } else if !words.isEmpty {
        let nameWords = tokenize(element.name)
        if words == nameWords && words.count < queryTokens.count {
            score = 0.85
        } else {
            let said = Set(nameWords).union(element.submits ? ["submit"] : [])
            let hits = words.filter { said.contains($0) }.count
            if hits > 0 { score = 0.3 + 0.3 * (Double(hits) / Double(words.count)) }
        }
    }

    // A role or tag named in the description corroborates a weak name match,
    // but can't manufacture one on its own — otherwise "button" would return
    // every button on the page ranked above the one actually named.
    if score > 0 && fits(element, hinted: hinted, queryTokens: queryTokens) { score = min(1, score + 0.1) }
    return score
}

/// The roles a description's role words say fit (`roleWords`).
private func roleHints(_ queryTokens: [String]) -> Set<String> {
    queryTokens.reduce(into: Set<String>()) { $0.formUnion(roleWords[$1] ?? []) }
}

/// Whether the element is of a kind the description names: by its role, or by its tag ("select").
private func fits(_ element: some Scorable, hinted: Set<String>, queryTokens: [String]) -> Bool {
    hinted.contains(normalize(element.role)) || queryTokens.contains(normalize(element.tag))
}

/// The best `maxResults` matches for `description`, strongest first. Unmatched
/// elements are dropped, and so are those of another kind than the description
/// names ("save button" and a heading called "Save") whenever one of that kind
/// matches: only when none does do the others come back, since a page's "button"
/// is routinely a `<div>` with some other role. An element the whole description
/// names (exactly, or as its name's start: "copy link" and a button "Copy link") is
/// kept whatever its kind: the role word is then part of its name.
func findElements<Element: Scorable>(
    _ elements: [Element], description: String, maxResults: Int = defaultMaxResults
) -> [ElementMatch<Element>] {
    var matches = elements.enumerated().map {
        (index: $0.offset, match: ElementMatch(element: $0.element, score: scoreElement($0.element, description: description)))
    }
    .filter { $0.match.score > 0 }
    let queryTokens = tokenize(description)
    let hinted = roleHints(queryTokens)
    if !hinted.isEmpty, matches.contains(where: { fits($0.match.element, hinted: hinted, queryTokens: queryTokens) }) {
        matches.removeAll { $0.match.score < 0.9 && !fits($0.match.element, hinted: hinted, queryTokens: queryTokens) }
    }
    // Stable, as the source's sort is: equal scores keep page order.
    let ranked = matches.sorted { $0.match.score != $1.match.score ? $0.match.score > $1.match.score : $0.index < $1.index }
    return ranked.prefix(max(0, maxResults)).map(\.match)
}
