import Foundation
import JavaScriptCore

/// A bounded, sequence-numbered log: the shape of the console buffer, and of
/// any capture buffer that follows.
///
/// Two properties matter for how it's used:
///
/// - **Bounded, and old entries are the ones that go.** A page in a redirect
///   loop or a chatty `console.log` in a `setInterval` must not grow the
///   buffer without limit, and what a caller wants when that happens is the
///   most recent activity.
/// - **`seq` keeps increasing across eviction and is never reused.** That's
///   what makes `sinceSeq` polling correct: a caller that read up to seq 40
///   asks for everything after 40 and gets exactly the entries it hasn't seen,
///   whether or not older ones have since been evicted. `clear()` (a new
///   document) deliberately does *not* reset it, so a stale `sinceSeq` from
///   the previous page returns the new page's entries rather than replaying
///   everything.
protocol Sequenced {
    var seq: Int { get set }
}

final class RingLog<Entry: Sequenced> {
    private let capacity: Int
    private var entries: [Entry] = []
    private var nextSeq = 1

    init(capacity: Int) {
        self.capacity = capacity
    }

    /// Appends an entry, assigning it the next `seq`. Returns the stored value
    /// (for a reference type, the very object stored, so a caller can keep
    /// completing it; mutating an entry that has since been evicted is
    /// harmless: it is simply no longer in the log).
    @discardableResult
    func add(_ entry: Entry) -> Entry {
        var stored = entry
        stored.seq = nextSeq
        nextSeq += 1
        entries.append(stored)
        // Adds are one at a time, so at most one entry is ever over.
        if entries.count > capacity { entries.removeFirst() }
        return stored
    }

    /// Removes the entry carrying `seq`, reporting whether it was still
    /// present: false means it was already evicted, cleared, or never existed.
    @discardableResult
    func remove(seq: Int) -> Bool {
        guard let index = entries.firstIndex(where: { $0.seq == seq }) else { return false }
        entries.remove(at: index)
        return true
    }

    /// Drops every entry, e.g. because the pane started loading a new document.
    func clear() {
        entries = []
    }

    /// Entries with `seq` greater than `sinceSeq`, oldest first.
    func list(sinceSeq: Int? = nil) -> [Entry] {
        guard let sinceSeq else { return entries }
        return entries.filter { $0.seq > sinceSeq }
    }
}

/// Compiles a caller-supplied `--pattern` into a text predicate, so filtering a
/// whole log compiles it once rather than per entry. Callers refuse an
/// unparseable pattern first (`patternFilterError`), so this never sees one
/// (an unparseable one matches nothing).
///
/// The pattern is a JavaScript regular expression, so it is run by
/// JavaScriptCore rather than translated to ICU: the two dialects differ in
/// small ways an agent's pattern shouldn't have to know.
@MainActor
func compilePattern(_ pattern: String?) -> (String) -> Bool {
    guard let pattern, !pattern.isEmpty else { return { _ in true } }
    guard let context = JSContext() else { return { _ in false } }
    context.setObject(pattern, forKeyedSubscript: "pattern" as NSString)
    guard let test = context.evaluateScript("(function (re) { return function (text) { return re.test(text) } })(new RegExp(pattern))"),
        context.exception == nil
    else { return { _ in false } }
    return { text in test.call(withArguments: [text])?.toBool() ?? false }
}

/// Refusal message for a `--pattern` value that doesn't parse as a regular
/// expression, or nil when it does (or is absent). An unparseable pattern is
/// refused rather than searched for as literal text: an unterminated `[` is a
/// typo far more often than an intentional literal.
@MainActor
func patternFilterError(_ pattern: String?) -> String? {
    guard let pattern, !pattern.isEmpty else { return nil }
    guard let context = JSContext() else { return nil }
    context.setObject(pattern, forKeyedSubscript: "pattern" as NSString)
    context.evaluateScript("new RegExp(pattern)")
    guard let exception = context.exception else { return nil }
    // The engine's own reason, not a generic "invalid pattern": JavaScriptCore
    // words it "SyntaxError: Invalid regular expression: missing terminating ]
    // for character class".
    var detail = exception.toString() ?? "invalid"
    if let range = detail.range(of: "Invalid regular expression: ") { detail = String(detail[range.upperBound...]) }
    return "invalid --pattern regex \(jsonQuoted(pattern)): \(detail)"
}

/// `JSON.stringify` of a string, for messages that quote what a caller sent.
func jsonQuoted(_ text: String) -> String {
    guard let data = try? JSONSerialization.data(withJSONObject: [text], options: [.withoutEscapingSlashes]),
        let array = String(data: data, encoding: .utf8)
    else { return "\"\(text)\"" }
    return String(array.dropFirst().dropLast())
}
