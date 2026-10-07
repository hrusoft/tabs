import AppKit

/// An icon a plugin hands core to draw in its chrome — a signal's, a header
/// action's — in the color that place calls for, in a box of that place's
/// size (a signal's 16×16, a header button's 13×13), fitted and centered.
public enum PaneIcon {
    /// An SF Symbol (one that exists).
    case symbol(String)
    /// A template image: only its alpha counts. An image with a drawing
    /// handler stays sharp at every scale. Draw it the way the chrome's own
    /// icons are: a 16×16 box, a 1.2pt stroke, round caps.
    case image(NSImage)
}

/// A button in a pane's header, among core's own controls (a terminal's Clear
/// scrollback). Core draws it as one of the header's buttons — leftmost in
/// the controls a hover reveals, in the chrome's colors, with its hover and
/// press states — so it looks like the header's own; `label` is its tooltip,
/// and pressing it calls `perform`.
@MainActor
public struct PaneHeaderAction {
    /// Its accessibility identifier, which UI tests find it by (the
    /// terminal's is `pane-terminal-clear-scrollback-button`). Unique among
    /// the pane's actions.
    public let id: String
    public var label: String
    public var icon: PaneIcon
    public var perform: @MainActor () -> Void

    public init(id: String, label: String, icon: PaneIcon, perform: @escaping @MainActor () -> Void) {
        self.id = id
        self.label = label
        self.icon = icon
        self.perform = perform
    }
}
