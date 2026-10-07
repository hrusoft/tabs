import Foundation

/// The roles a `--role` filter can name: every non-abstract WAI-ARIA 1.2 role,
/// plus the 1.3 additions pages already use. `read-page --role` and the
/// semantic targets of click/hover/type/form-input compare against an
/// element's explicit `role` attribute or the role derived from its tag
/// (`roleFor` in `PageScripts`), so a name outside this vocabulary can never
/// match anything — and `read-page --role nonsense` used to answer `total: 0`,
/// which reads as "this page has none" rather than "that isn't a role".
///
/// The DPUB (`doc-*`) and Graphics (`graphics-*`) module roles are accepted by
/// prefix rather than listed: they are real roles pages use, and listing both
/// modules in every refusal would bury the common ones.
let ariaRoles: [String] = [
    "alert",
    "alertdialog",
    "application",
    "article",
    "banner",
    "blockquote",
    "button",
    "caption",
    "cell",
    "checkbox",
    "code",
    "columnheader",
    "combobox",
    "comment",
    "complementary",
    "contentinfo",
    "definition",
    "deletion",
    "dialog",
    "directory",
    "document",
    "emphasis",
    "feed",
    "figure",
    "form",
    "generic",
    "grid",
    "gridcell",
    "group",
    "heading",
    "image",
    "img",
    "insertion",
    "link",
    "list",
    "listbox",
    "listitem",
    "log",
    "main",
    "mark",
    "marquee",
    "math",
    "menu",
    "menubar",
    "menuitem",
    "menuitemcheckbox",
    "menuitemradio",
    "meter",
    "navigation",
    "none",
    "note",
    "option",
    "paragraph",
    "presentation",
    "progressbar",
    "radio",
    "radiogroup",
    "region",
    "row",
    "rowgroup",
    "rowheader",
    "scrollbar",
    "search",
    "searchbox",
    "separator",
    "slider",
    "spinbutton",
    "status",
    "strong",
    "subscript",
    "suggestion",
    "superscript",
    "switch",
    "tab",
    "table",
    "tablist",
    "tabpanel",
    "term",
    "textbox",
    "time",
    "timer",
    "toolbar",
    "tooltip",
    "tree",
    "treegrid",
    "treeitem",
]

private let knownRoles = Set(ariaRoles)
private let moduleRolePrefixes = ["doc-", "graphics-"]

/// Refusal message for a `--role` that names no ARIA role, or nil when it does.
/// Compared case-insensitively, like the match itself (`roleMatcher` in
/// `PageScripts`).
func roleFilterError(_ role: String) -> String? {
    let wanted = role.lowercased()
    if knownRoles.contains(wanted) { return nil }
    if moduleRolePrefixes.contains(where: { wanted.hasPrefix($0) && wanted.count > $0.count }) { return nil }
    return
        "unknown role \(jsonQuoted(role)) — role must be a WAI-ARIA role, one of: \(ariaRoles.joined(separator: ", ")) (or a doc-*/graphics-* module role)"
}
