import Foundation
import TabsPluginSDK

/// An element rect in the page's CSS-pixel viewport space.
struct PageRect: Equatable, Sendable {
    var x: Double
    var y: Double
    var width: Double
    var height: Double
}

/// One element from a `read-page` extraction, as a test reads it back (the verb itself passes the page's
/// JSON through). `rect` is in the page's CSS-pixel viewport space.
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

/// `find`'s ranking, over elements a test makes.
extension PageElement: Scorable {}
