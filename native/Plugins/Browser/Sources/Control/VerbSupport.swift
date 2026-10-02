import TabsPluginSDK

/// Shared plumbing for the browser's control verbs (`renderer/verbSupport.ts`,
/// `targeting.ts`'s pure half): reaching a verb's pane and its page, and the
/// wording every targeting error shares.
@MainActor
enum VerbSupport {
    /// The pane an owned-pane verb acts on. Core has already checked ownership,
    /// that the pane is open and that it is a browser; what is left is the plugin's
    /// own view of it.
    static func pane(_ invocation: ControlInvocation) throws -> BrowserPane {
        guard let pane = invocation.pane(as: BrowserPane.self) else { throw ControlVerbError(paneNotMountedError) }
        return pane
    }

    /// A wire string that names something: present, a string, and not blank.
    static func namedString(_ value: JSONValue?) -> Bool {
        guard let text = value?.stringValue else { return false }
        return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// `evalInGuest`: a script's value, or the error a caller reads. A rejection is
    /// turned into one sentence (`pageScriptUnavailableMessage`), never the engine's
    /// plumbing; a caller for whom the answer is optional (reporting, never a gate)
    /// degrades on the failure.
    static func evalInGuest(_ page: BrowserPage, _ script: String) async -> Result<JSONValue, PageScriptError> {
        await page.evaluate(script)
    }

    /// `evalOutcomeInGuest`: a script that answers with an outcome object of its own
    /// making, which the caller then reads fields off. A non-object answer (a page
    /// that replaced a built-in the script relies on) is refused as such.
    static func evalOutcomeInGuest(_ page: BrowserPage, _ script: String) async -> Result<[String: JSONValue], VerbFailure> {
        switch await page.evaluate(script) {
        case .failure(let error): return .failure(VerbFailure(error.message))
        case .success(.object(let object)): return .success(object)
        case .success:
            return .failure(
                VerbFailure(
                    "the page's answer was not the shape this verb expects — the page may have replaced a built-in the verb relies on"))
        }
    }
}

/// A failure with the message the verb answers with.
struct VerbFailure: Error, Equatable {
    let message: String
    init(_ message: String) { self.message = message }
}

/// The guest expression and the words for naming one element by ref or by semantic
/// criteria (`namedTargetResolver`): shared by every verb that names an element
/// rather than restated per verb, because the caller-facing text is the part that
/// drifts. The `{x, y}` form has nothing to resolve; callers branch on it first.
struct NamedTarget: Equatable {
    var resolver: String
    var described: String
    /// The message for a resolver that answered `null` without saying why.
    var notResolved: String
}

enum Targeting {
    /// The ref-or-semantic half of naming an element. A semantic target's shape is
    /// validated host-side, before any round trip: what arrives over the socket is
    /// untyped wire input.
    static func namedTargetResolver(_ target: ElementTarget) -> Result<NamedTarget, VerbFailure> {
        switch target {
        case .ref(let ref):
            return .success(
                // A semantic resolver always states its own reason; only a ref can miss
                // silently (the registry died with the page), so this fallback is in
                // practice the ref-shaped one.
                NamedTarget(resolver: refResolverExpression(ref), described: "ref \(ref)", notResolved: staleRefError(ref)))
        case .semantic(let semantic):
            if let invalid = semanticTargetError(semantic) { return .failure(VerbFailure(invalid)) }
            let described = describeSemanticTarget(semantic)
            return .success(
                NamedTarget(
                    resolver: semanticResolverExpression(semantic), described: described, notResolved: "no element matches \(described)"))
        case .point:
            return .failure(VerbFailure("a coordinate names no element"))
        }
    }

    /// Why a semantic target can't be resolved as it stands, or nil if it can. A
    /// criterion present but blank counts as absent: matching `name=""` exactly would
    /// select every unlabeled control, the least intended reading there is.
    static func semanticTargetError(_ target: SemanticTarget) -> String? {
        let named = [target.role, target.name, target.selector].contains {
            $0.map { !$0.trimmingCharacters(in: .whitespaces).isEmpty } ?? false
        }
        if !named { return "a semantic target needs at least one of role, name, selector" }
        if let nth = target.nth, nth < 0 { return "nth must be a non-negative integer (it is a 0-based index into the matches)" }
        // The same vocabulary read-page's --role is held to: a role that is not a
        // role can match nothing, and says so rather than failing as a miss.
        if let role = target.role, !role.trimmingCharacters(in: .whitespaces).isEmpty { return roleFilterError(role) }
        return nil
    }

    /// A hit description as prose for the mismatch error, naming what a caller can act on.
    static func describeForError(_ described: ElementDescription?) -> String {
        guard let described else { return "no element at all (the point falls outside the document)" }
        return described.name.isEmpty ? "<\(described.tag)> (role \(described.role))" : "<\(described.tag)> \"\(described.name)\""
    }
}
