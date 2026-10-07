import Foundation
import TabsPluginSDK

/// The verbs that read a page without driving it: `get-page-text`, `read-page` and `find`,
/// plus the readiness fields each read reports.
@MainActor
enum ReadPage {
    /// The readiness-and-shape fields every read verb folds into its result, so a caller can
    /// tell "the page doesn't have it" from "the page hasn't finished saying it" or "it's one
    /// level down from where this verb can see":
    ///
    /// - `isLoading` from the page host-side; `readyState`/`settled` from the page script's
    ///   answer (`settled` is the persistent tracker's "no mutation for `waitIdleQuietMs`", the
    ///   same quiet `wait-for --idle` waits for);
    /// - `frames`/`shadowRoots`: always-present integers, 0 included, counting content one
    ///   level below the top document that these verbs structurally cannot see into
    ///   (`querySelectorAll` and `innerText` don't descend into a frame or a shadow tree). A
    ///   nonzero count next to missing or incomplete content is the cue that it may live there
    ///   rather than not exist.
    ///
    /// The whole guest pair is passed through only when it has the shape our scripts produce:
    /// a page that rewrote the answer gets its fields dropped, never fabricated into document state.
    static func readinessFields(_ page: BrowserPage, _ guest: [String: JSONValue]?) -> [String: JSONValue] {
        var fields: [String: JSONValue] = ["isLoading": .bool(page.isLoading)]
        if let readyState = guest?["readyState"]?.stringValue { fields["readyState"] = .string(readyState) }
        if let settled = guest?["settled"]?.boolValue { fields["settled"] = .bool(settled) }
        if let frames = number(guest?["frames"]) { fields["frames"] = frames }
        if let shadowRoots = number(guest?["shadowRoots"]) { fields["shadowRoots"] = shadowRoots }
        return fields
    }

    private static func object(_ value: JSONValue) -> [String: JSONValue] {
        if case .object(let object) = value { object } else { [:] }
    }

    private static func array(_ value: JSONValue?) -> [JSONValue] {
        if case .array(let values)? = value { values } else { [] }
    }

    private static func number(_ value: JSONValue?) -> JSONValue? {
        switch value {
        case .int?, .double?: value
        default: nil
        }
    }

    // MARK: get-page-text

    static func getPageText(_ invocation: ControlInvocation) async throws -> JSONValue {
        let page = try VerbSupport.pane(invocation).page
        let requested = invocation["maxLength"]?.doubleValue.map { Int($0.rounded(.down)) } ?? BrowserLimits.defaultPageTextMax
        let limit = min(requested, BrowserLimits.pageTextHardMax)
        let answer: [String: JSONValue]
        switch await VerbSupport.evalInGuest(page, pageTextScript) {
        case .failure(let error): throw ControlVerbError(error.message)
        case .success(let value): answer = object(value)
        }
        // Lengths are the page's own: UTF-16 code units, as `String.length` counts them.
        let units = Array((answer["text"]?.stringValue ?? "").utf16)
        var result = readinessFields(page, answer)
        result["text"] = .string(String(decoding: units.prefix(max(limit, 0)), as: UTF16.self))
        result["truncated"] = .bool(units.count > limit)
        return .object(result)
    }

    // MARK: read-page

    /// Why this `read-page` request cannot run as it stands, or nil if it can. Host-side
    /// because what arrives over the socket is untyped wire input, so the optional-but-typed
    /// fields are a promise this check keeps rather than one the compiler does. A blank string
    /// counts as absent: `role=""` matches nothing and would read as "the page has no
    /// controls", the least intended reading there is.
    static func readPageFilterError(_ arguments: [String: JSONValue]) -> String? {
        for key in ["selector", "role"] {
            if let value = arguments[key], !VerbSupport.namedString(value) { return "\(key) must be a non-empty string" }
        }
        // A role outside the ARIA vocabulary can never match: refused rather than answered with
        // an empty list that reads as "none here".
        if let role = arguments["role"]?.stringValue, let unknown = roleFilterError(role) { return unknown }
        if let offset = arguments["offset"] {
            guard let value = offset.doubleValue, value >= 0, value == value.rounded(), value.isFinite else {
                return "offset must be a non-negative integer (it is a 0-based index into the matching elements)"
            }
        }
        return nil
    }

    static func readPage(_ invocation: ControlInvocation) async throws -> JSONValue {
        let page = try VerbSupport.pane(invocation).page
        if let invalid = readPageFilterError(invocation.arguments) { throw ControlVerbError(invalid) }
        let filter = ReadPageFilter(
            selector: invocation["selector"]?.stringValue, role: invocation["role"]?.stringValue,
            offset: invocation["offset"]?.doubleValue.map { Int($0) })
        let raw: [String: JSONValue]
        switch await VerbSupport.evalInGuest(page, readPageScript(filter)) {
        case .failure(let error): throw ControlVerbError(error.message)
        case .success(let value): raw = object(value)
        }
        // Only the selector branch can report one, and only for a selector the page's own
        // `querySelectorAll` refused: surfaced rather than degraded to an empty list, which
        // would read as "nothing on this page matches".
        if let error = raw["error"]?.stringValue { throw ControlVerbError(error) }
        let elements = raw["elements"] ?? .array([])
        var result = readinessFields(page, raw)
        result["elements"] = elements
        result["total"] = number(raw["total"]) ?? .int(Int64(array(elements).count))
        result["offset"] = number(raw["offset"]) ?? .int(0)
        result["truncated"] = .bool(raw["truncated"] == true)
        return .object(result)
    }

    // MARK: find

    /// One element `findCandidatesScript` described, before any ref exists for it.
    private struct Candidate: Scorable {
        var json: JSONValue
        var name: String
        var role: String
        var tag: String
        var index: Int
    }

    /// Ranks the page's elements against a description and returns the best, minting refs for
    /// those alone: see `findCandidatesScript` for why the two halves are separate page calls
    /// rather than read-page's extraction.
    static func find(_ invocation: ControlInvocation) async throws -> JSONValue {
        let page = try VerbSupport.pane(invocation).page
        let description = invocation["description"]?.stringValue ?? ""
        let token = UUID().uuidString.lowercased()
        let described: [String: JSONValue]
        switch await VerbSupport.evalOutcomeInGuest(page, findCandidatesScript(token: token)) {
        case .failure(let failure): throw ControlVerbError(failure.message)
        case .success(let object): described = object
        }
        let candidates = (array(described["candidates"])).enumerated().map { index, json in
            Candidate(
                json: json, name: json["name"]?.stringValue ?? "", role: json["role"]?.stringValue ?? "",
                tag: json["tag"]?.stringValue ?? "", index: index)
        }
        let ranked = findElements(
            candidates, description: description, maxResults: invocation["maxResults"]?.doubleValue.map { Int($0) } ?? 10)
        var refs: [JSONValue] = []
        if !ranked.isEmpty {
            let minted: [String: JSONValue]
            switch await VerbSupport.evalOutcomeInGuest(page, mintFindRefsScript(token: token, indices: ranked.map(\.element.index))) {
            case .failure(let failure): throw ControlVerbError(failure.message)
            case .success(let object): minted = object
            }
            if let error = minted["error"]?.stringValue { throw ControlVerbError(error) }
            refs = array(minted["refs"])
        }
        // A match whose element left the page between the two halves has no ref, and is
        // dropped rather than reported with one that could only fail.
        let matches: [JSONValue] = ranked.enumerated().compactMap { position, match in
            guard position < refs.count, case .string(let ref) = refs[position] else { return nil }
            let element = match.element
            return .object([
                "ref": .string(ref), "name": .string(element.name), "role": .string(element.role), "tag": .string(element.tag),
                "rect": element.json["rect"] ?? .null, "score": .double(match.score),
            ])
        }
        var result = readinessFields(page, described)
        result["matches"] = .array(matches)
        return .object(result)
    }
}
