import Foundation
import TabsPluginSDK

/// The page-semantics types the browser's verbs speak in: an element as
/// `read-page` reports it, how an input verb names one, and the keys a chord
/// holds.

/// An element rect in the page's CSS-pixel viewport space.
struct PageRect: Equatable, Sendable {
    var x: Double
    var y: Double
    var width: Double
    var height: Double
}

/// One element from a `read-page` extraction. `rect` is in the page's CSS-pixel
/// viewport space.
struct PageElement: Equatable, Sendable {
    var ref: String
    var role: String
    var name: String
    var tag: String
    var rect: PageRect
    /// A field's current value. Absent for a checkbox or radio, whose value is
    /// only its submit token.
    var value: String?
    /// A checkbox, radio or switch's state: `true`, `false`, or `"mixed"` for an
    /// indeterminate one. Absent for anything not checkable.
    var checked: JSONValue?

    init(
        ref: String = "", role: String, name: String, tag: String,
        rect: PageRect = PageRect(x: 0, y: 0, width: 10, height: 10), value: String? = nil, checked: JSONValue? = nil
    ) {
        self.ref = ref
        self.role = role
        self.name = name
        self.tag = tag
        self.rect = rect
        self.value = value
        self.checked = checked
    }
}

/// How `click` reports the element involved, derived with the same
/// `roleFor`/`nameFor` `read-page` uses so the vocabulary matches `PageElement`.
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
