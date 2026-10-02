import Foundation

/// The layout operations a plugin may perform — phrased as requests, not
/// access to core's model (a tree of tab groups, splits and floating panes),
/// so the model can change without breaking a plugin. In headless mode there are no
/// windows: queries come back empty and `openPane` returns nil.
///
/// A plugin manages only its own panes: `panes(ofType:)`, `openPane` and
/// `focusPane` accept only the plugin's own content types (anything else is
/// refused and shows up among its ignored calls). Other plugins' panes are
/// visible only as core facts — the active pane's id and type, core's events —
/// and through the capabilities core defines.
@MainActor
public protocol Workspace: AnyObject {
    var activePaneID: PaneID? { get }
    func contentType(of pane: PaneID) -> ContentTypeID?
    func panes(ofType type: ContentTypeID) -> [PaneID]
    /// Creates and places a pane. nil when the type isn't available for
    /// creation (unknown, its plugin disabled) or there is nowhere to put it.
    @discardableResult
    func openPane(_ request: PaneRequest) -> PaneID?
    func focusPane(_ pane: PaneID)
    /// Makes one of your panes visible without making it active or giving it
    /// the keyboard: every tab above it is shown and its floating window
    /// raised (the Electron app's `revealPane`). For a pane that must be on
    /// screen to be captured while the user keeps typing where they were.
    func revealPane(_ pane: PaneID)
    /// What a live pane currently offers (see `PaneCapability`), or nil. Core's
    /// copy: reading it never runs the offering plugin's code.
    func capability<Value>(_ capability: PaneCapability<Value>, of pane: PaneID) -> Value?
}

public extension Workspace {
    @discardableResult
    func openPane(ofType type: ContentTypeID, config: JSONValue? = nil) -> PaneID? {
        openPane(PaneRequest(type: type, config: config))
    }
}

/// A request for a new pane. A struct so it can grow without breaking callers.
public struct PaneRequest: Sendable, Equatable {
    public var type: ContentTypeID
    /// nil: the type's `initialConfig` decides.
    public var config: JSONValue?
    public var placement: PanePlacement
    /// The pane this one is created from, if any — handed to the new type's
    /// `initialConfig`, which may ask it for capabilities (a directory to open in).
    public var origin: PaneID?
    /// Whether the new pane takes the keyboard when it becomes the active
    /// pane (it does, as placed, in the layout: shown, outlined). False is the
    /// Electron app's `agentCreated`: the pane is placed and active as usual
    /// but the keyboard stays where it was — a pane another pane opens must
    /// never pull typing away from it. The exemption is spent once: the user
    /// activating the pane later focuses it as always.
    public var activates: Bool
    /// The pane that controls the new one (an agent's terminal), from the
    /// instant the pane exists — before it is placed or built, so what its
    /// first load does already knows it is controlled. Core keeps it in the
    /// ownership ledger and raises the controlled signal. A plugin may name
    /// only the caller of one of its own control verbs still running
    /// (`ControlInvocation.callerPane`); anything else is refused and the
    /// pane isn't created.
    public var controlledBy: PaneID?

    public init(
        type: ContentTypeID, config: JSONValue? = nil, placement: PanePlacement = .automatic, origin: PaneID? = nil,
        activates: Bool = true, controlledBy: PaneID? = nil
    ) {
        self.type = type
        self.config = config
        self.placement = placement
        self.origin = origin
        self.activates = activates
        self.controlledBy = controlledBy
    }
}

/// Where a new pane should go. A request, not a command: core places it as
/// the user's own actions would, and never evicts what a pane already shows.
public enum PanePlacement: Sendable, Equatable {
    /// Core's choice: at the frontmost window's active pane — into it if it's
    /// empty, else a tab beside it.
    case automatic
    /// A tab next to `near` (into it if it's an empty pane); nil: as `.automatic`.
    case tab(near: PaneID?)
    /// Split `pane`, putting the new one on `edge`.
    case split(PaneID, edge: SplitEdge)
    /// A window of its own.
    case window
    /// A floating (unpinned) pane over `near` — nil: over the frontmost
    /// window's active pane — in the section of it the user's "new unpinned
    /// pane position" setting names, in the window holding `near`.
    case floating(near: PaneID?)
}

public enum SplitEdge: String, Sendable, Equatable {
    case leading, trailing, top, bottom
}

/// Something core lets any pane offer and any plugin ask for, without either
/// plugin knowing the other: a terminal offers its working directory, a git
/// view asks the pane it was opened from for one. The vocabulary is core's —
/// only core defines and declares capabilities — so this is core-mediated
/// exposure of specific facts, not a channel between plugins. A new one is a
/// core change.
///
/// Values are pushed, not pulled: a pane offers a value through its
/// `PaneContext` whenever it changes, core keeps it, and readers get core's
/// copy (`Workspace.capability(_:of:)`) — they never run the offering plugin's
/// code — and can follow changes with `EventChannel.capabilityChanged(_:)`.
public struct PaneCapability<Value: Sendable & Equatable>: Hashable, Sendable {
    public let id: String
    package init(_ id: String) { self.id = id }
}

public extension PaneCapability where Value == URL {
    /// The directory a pane is "in" (a shell's cwd, a repository's root).
    static var workingDirectory: Self { Self("tabs.workingDirectory") }
}
