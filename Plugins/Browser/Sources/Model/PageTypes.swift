import Foundation

/// The page-semantics types the browser's verbs speak in: how an input verb
/// names an element and reports one, and the keys a chord holds.

/// How `click` reports the element involved, derived with the same
/// `roleFor`/`nameFor` `read-page` uses so the vocabulary matches its elements'.
struct ElementDescription: Equatable, Sendable {
    var role: String
    var name: String
    var tag: String
}

/// The semantic form of an `ElementTarget`: matched inside the page against the
/// same role/accessible-name derivation `read-page` reports, and/or a CSS
/// selector, then acted on in the same pass. Criteria AND-combine: `selector`
/// defines the candidate pool and `role`/`name` filter it. At least one of
/// `role`/`name`/`selector` must be present, enforced where the target is
/// resolved (what arrives over the socket is untyped).
struct SemanticTarget: Equatable, Sendable {
    var role: String?
    var name: String?
    var selector: String?
    var nth: Int?

    init(role: String? = nil, name: String? = nil, selector: String? = nil, nth: Int? = nil) {
        self.role = role
        self.name = name
        self.selector = selector
        self.nth = nth
    }
}

/// What an input verb aims at: an opaque `ref` handed out by a previous
/// `read-page` on the *current* page, a raw viewport coordinate, or semantic
/// criteria matched at act time. Ref and coordinate resolve to the same
/// CSS-pixel space — the page's own viewport.
enum ElementTarget: Equatable, Sendable {
    case ref(String)
    case point(x: Double, y: Double)
    case semantic(SemanticTarget)
}

enum KeyModifier: String, CaseIterable, Sendable {
    case shift, control, alt, meta
}

/// The editing commands `key --command` exposes, run in the page through
/// `document.execCommand` (`select-all` → `selectAll`). Deliberately not the
/// clipboard trio: `copy`/`cut`/`paste` cross into the user's own system
/// clipboard, which an agent driving a page must not do as an invisible side
/// effect.
enum EditingCommand: String, CaseIterable, Sendable {
    case selectAll = "select-all"
    case undo, redo, delete

    /// `document.execCommand`'s own spelling.
    var execName: String {
        switch self {
        case .selectAll: "selectAll"
        case .undo: "undo"
        case .redo: "redo"
        case .delete: "delete"
        }
    }
}
