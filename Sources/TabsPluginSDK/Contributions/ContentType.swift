import AppKit

/// A kind of pane content: what the empty pane's creation buttons offer, and
/// the factory core calls for every pane of this type — created fresh or
/// restored from a saved layout.
public struct ContentTypeContribution: Contribution {
    public let id: ContentTypeID
    public var displayName: String
    /// The icon of the creation button and the command palette's row: an SF
    /// Symbol, or a template image of your own (see `PaneIcon`).
    public var icon: PaneIcon
    /// The creation button's tooltip and accessibility label. Nil: "New
    /// \(displayName)".
    public var creationLabel: String?
    /// Config for a new pane created without one. `creation.origin` is the
    /// pane it was created from, if any — ask it for capabilities (e.g. its
    /// working directory) through `context.workspace`.
    public var initialConfig: @MainActor (_ creation: PaneCreation) -> JSONValue
    /// Builds the pane for `context.initialConfig`. Throw when the pane can't
    /// be built from that config (it doesn't decode, it names something that
    /// no longer exists): core then keeps the saved pane verbatim, shown as
    /// unavailable with your error, instead of replacing the user's state with
    /// an empty pane's.
    public var makePane: @MainActor (any PaneContext) throws -> any PaneController

    public var contributionID: String { id.rawValue }

    public init(
        id: ContentTypeID,
        displayName: String,
        icon: PaneIcon,
        creationLabel: String? = nil,
        initialConfig: @escaping @MainActor (_ creation: PaneCreation) -> JSONValue = { _ in .emptyObject },
        makePane: @escaping @MainActor (any PaneContext) throws -> any PaneController
    ) {
        self.id = id
        self.displayName = displayName
        self.icon = icon
        self.creationLabel = creationLabel
        self.initialConfig = initialConfig
        self.makePane = makePane
    }
}

public extension ContentTypeContribution {
    /// The creation button's label: `creationLabel`, else "New \(displayName)".
    var resolvedCreationLabel: String { creationLabel ?? "New \(displayName)" }
}

/// Why a pane is being created.
public struct PaneCreation: Sendable, Equatable {
    /// The pane the user (or a plugin) created this one from, if any.
    public let origin: PaneID?

    public init(origin: PaneID?) {
        self.origin = origin
    }
}

/// One live pane, owned by the plugin that made it. Core owns its placement,
/// chrome and persistence; the plugin owns what's inside.
///
/// The pane is more than its view: `currentConfig()`, `closeWarning` and the
/// capabilities it offers work before the view exists and while it's hidden.
@MainActor
public protocol PaneController: AnyObject {
    /// The pane's content. Core asks for it the first time the pane is shown
    /// (a restored background tab may never be), so it can be built lazily.
    ///
    /// Core may move it — to another superview, or another window — while the
    /// pane is open: when the layout splits, floats or moves panes. AppKit
    /// views (web and terminal views included) keep their state across a move;
    /// react to the window changing in `viewDidMoveToWindow` if you must.
    var view: NSView { get }
    /// Extra control for the pane's header bar, trailing the title. Asked for
    /// with `view`.
    var headerAccessory: NSView? { get }
    /// A view that takes the place of the pane's title in its header bar, when
    /// the pane's subject is better shown as controls than as text (a path
    /// bar, a filter). Core lays it out in the title's slot: after the grip and
    /// the pane's signal icons, before the header's own controls, as wide as
    /// what is left (it can shrink to nothing) and as tall as the bar. The
    /// default title is not drawn, and Edit title is not offered, since the
    /// pane has no title to edit. Asked for with `view`.
    ///
    /// A press on one of its controls activates the pane but never starts a
    /// pane drag; a press on its empty space does, as the rest of the bar
    /// does. Adopt `PaneHeaderTitleView` to hear the slot's geometry.
    var headerTitle: NSView? { get }
    /// Buttons core draws in the pane's header, leftmost among its controls
    /// and looking like them (see `PaneHeaderAction`). Asked for with `view`.
    var headerActions: [PaneHeaderAction] { get }
    /// Called when the pane becomes active in a key window.
    func focus()
    /// The pane became the visible tab of its window (its view is in a window,
    /// and not hidden). The place to start work only worth doing while seen,
    /// and to size things to the view — never size to a hidden view.
    func paneDidShow()
    /// The pane is no longer visible (another tab was selected).
    func paneDidHide()
    /// The app's theme, or the pane's depth in the layout, is now different —
    /// and once, before the pane's view is first shown, with what it starts
    /// with (the view may not exist yet). `theme` is the app's color tokens;
    /// `depth` counts the tab groups above the pane, the outermost being 0 (the
    /// pane's header is painted with `theme.surface(depth:)`). Also readable
    /// as `PaneContext.theme` and `depth`, which are already current when this
    /// is called. Content with its own colors ignores it.
    func paneAppearanceDidChange(theme: PaneTheme, depth: Int)
    /// The user is looking at the pane: it is the active pane of a window that
    /// has the focus (a tab group being active doesn't count for the panes in
    /// it). Told on the change only — a pane created active in a focused
    /// window, its window gaining the focus, the pane becoming active, or a
    /// move that leaves it so — never twice in a row. The place for work worth
    /// doing only when someone is watching (a refresh on coming back).
    func paneDidBecomeAttended()
    /// The user stopped looking at the pane: another pane became active, its
    /// window lost the focus, or the pane is closing (told before
    /// `paneWillClose`). Only follows `paneDidBecomeAttended`.
    func paneDidLoseAttention()
    /// The plugin-owned state to persist. Core asks at every save point (after
    /// `PaneContext.configDidChange()`, and at quit) and stores it opaquely. A
    /// value that isn't representable as JSON (a NaN) is refused: core keeps
    /// the pane's last good config and logs the fault, so one pane can never
    /// stop the whole layout from saving.
    func currentConfig() -> JSONValue
    /// Non-nil when closing loses work; core asks the user with this text.
    var closeWarning: String? { get }
    /// Called once, just before the pane goes away for good. Not called at
    /// quit — panes outlive the process through `currentConfig()`; release
    /// process-wide resources in `TabsPlugin.deactivate()`.
    func paneWillClose()
    /// What `list-panes` shows for this pane, beyond its id, type and title
    /// (`{url: …}`): the fields of one object, which override those three when
    /// they clash. Read from core's live pane, so it must work before the view
    /// exists and while the pane is hidden. nil: the pane is not listed (the
    /// default) — a control-plane pane that agents can create lists itself.
    var controlSummary: JSONValue? { get }
    /// What `pane-info` shows for this pane: its live fields, or why it can't
    /// say. Core adds `paneId`, `type` and `title`. The default says the type
    /// can't be inspected.
    func controlDescription() async -> PaneControlDescription
}

/// A pane's answer to `pane-info`.
public enum PaneControlDescription: Sendable, Equatable {
    /// The pane's live state, an object's fields.
    case fields([String: JSONValue])
    /// It can't answer now (`browser pane is not currently mounted`): the
    /// message is the caller's error.
    case error(String)
    /// This kind of pane can't be inspected: core answers `<type> panes cannot
    /// be inspected with getPaneInfo`.
    case unsupported
}

public extension PaneController {
    var controlSummary: JSONValue? { nil }
    func controlDescription() async -> PaneControlDescription { .unsupported }
    var headerAccessory: NSView? { nil }
    var headerTitle: NSView? { nil }
    var headerActions: [PaneHeaderAction] { [] }
    var closeWarning: String? { nil }
    func paneWillClose() {}
    func paneDidShow() {}
    func paneDidHide() {}
    func paneAppearanceDidChange(theme: PaneTheme, depth: Int) {}
    func paneDidBecomeAttended() {}
    func paneDidLoseAttention() {}
    func focus() { view.window?.makeFirstResponder(view) }
}

/// Where core put a pane's `headerTitle`, told to a view that adopts
/// `PaneHeaderTitleView` whenever the slot changes.
public struct PaneHeaderSlot: Equatable, Sendable {
    /// The width of the header bar's content box (the bar less its padding),
    /// which the slot is a part of: the basis for a percentage of the bar.
    public var barContentWidth: Double
    /// Core lays the bar out at fractional positions and puts the view's frame
    /// on whole points; this is how far the slot's true origin is from its
    /// frame's (each of x and y is between -0.5 and 0.5). A view that wants
    /// its boxes where the layout would put them adds it to what it lays out.
    public var fractionalOffset: CGPoint

    public init(barContentWidth: Double, fractionalOffset: CGPoint = .zero) {
        self.barContentWidth = barContentWidth
        self.fractionalOffset = fractionalOffset
    }
}

/// A `headerTitle` that wants the slot's geometry beyond its own frame.
@MainActor
public protocol PaneHeaderTitleView: NSView {
    func paneHeaderSlotDidChange(_ slot: PaneHeaderSlot)
}

/// Core's side of one pane, handed to `makePane`.
@MainActor
public protocol PaneContext: AnyObject {
    var paneID: PaneID { get }
    /// The window the pane is in now; it changes when the pane moves.
    var windowID: WindowID { get }
    var contentType: ContentTypeID { get }
    /// The config this pane was created or restored with.
    var initialConfig: JSONValue { get }
    /// The app's color tokens as of now (`paneAppearanceDidChange` says when
    /// they change). Before core first tells the pane, the dark theme.
    var theme: PaneTheme { get }
    /// How many tab groups are above the pane (the outermost is 0): which
    /// shade its header is painted with (`theme.surface(depth:)`). It changes
    /// when the pane is moved.
    var depth: Int { get }
    /// The pane that owns this one right now — the pane whose shell created it
    /// through a control verb (`PaneRequest.controlledBy`) — or nil. Live: it
    /// ends when this pane closes. What a plugin's guards read (an owned pane
    /// may not open windows or be steered outside http and https).
    var controller: PaneID? { get }
    /// Sets the tab title (a note's first line, a shell's cwd).
    func setTitle(_ title: String)
    /// Tells core the pane's state changed; core will call `currentConfig()`
    /// at its next (debounced) save.
    func configDidChange()
    /// Asks core to close this pane (e.g. a shell exited). Asynchronous: the
    /// close happens after the current call returns, never inside it, and core
    /// still asks the user first if `closeWarning` is set.
    func requestClose()
    /// Offers a core-defined capability to other plugins — a shell's working
    /// directory, say — or withdraws it (nil). Call it whenever the value
    /// changes; it's cheap, and nobody calls back into the pane to read it.
    /// Readers see the new value at once; `capabilityChanged` is announced on
    /// the next turn of the main actor, once per burst of changes.
    func offer<Value>(_ capability: PaneCapability<Value>, _ value: Value?)
    /// Puts a signal on this pane — one of the kinds your plugin registered
    /// (`PaneSignalContribution`): its icon before the title, the pane's
    /// content outlined in its color. Raising one it already carries changes
    /// nothing (a Dock bounce aside). Another plugin's kind is refused.
    func raise(_ signal: PaneSignal)
    /// Takes a signal off this pane; nothing if it doesn't carry it.
    func withdraw(_ signal: PaneSignal)
    /// The whole environment for a process the pane starts (a shell): the
    /// app's own without its launch settings, plus how a CLI inside reaches the
    /// app (`TABS_CONTROL_SOCKET`) and which pane it's in (`TABS_PANE_ID`).
    /// Add your own (`TERM`) on top, and pass it and the working directory to
    /// the spawn — never `setenv`/`chdir`.
    var childEnvironment: [String: String] { get }
    /// Whether `event` is a shortcut the app has bound right now, for this
    /// pane (core's, or a command's). A view that takes raw keys — a terminal,
    /// a web view — should let these through (return false from
    /// `performKeyEquivalent`) and may keep everything else.
    func isAppShortcut(_ event: NSEvent) -> Bool
    /// Shows core's context menu (the one the chrome's right-click uses, so
    /// it looks and behaves the same in every pane) with `items`, its top-left
    /// corner at `point` in `view`'s coordinates — kept inside the window. It
    /// closes on a click outside, Escape, or a click on an enabled row, which
    /// runs its action. Asynchronous to the user, not to you: it returns at
    /// once. Nothing is shown for no items.
    func showContextMenu(_ items: [PaneMenuItem], at point: NSPoint, in view: NSView)
    /// Asks the user a yes/no question in core's dialog card, over this
    /// pane's window. Returns true for the confirm button, false for Cancel,
    /// Escape or a click outside the card. The rest of the app stays live
    /// meanwhile. With no window to ask in (headless, or under test) it
    /// answers true, the default button.
    func confirm(_ dialog: PaneConfirm) async -> Bool
    /// Asks the user to pick one of the options: a select on the first, with
    /// Cancel and confirm below. Returns the index picked, or nil for Cancel,
    /// Escape or a click outside the card (and for no options). With no window
    /// to ask in it answers the first option.
    func choose(_ dialog: PaneChoose) async -> Int?
    /// Tells the user something they must acknowledge, with one button;
    /// returns when it is dismissed — by the button, Return, Escape or a click
    /// outside the card. With no window to show it in it returns at once.
    func alert(_ dialog: PaneAlert) async
    /// Asks the user for a directory or a file in the system's open panel, a
    /// sheet on this pane's window. Returns nil when cancelled — and always
    /// with no window to sheet on.
    func pick(_ picker: PanePicker) async -> URL?
}

public extension PaneContext {
    var controller: PaneID? { nil }

    /// A directory, chosen in the open panel starting at `startingAt`.
    func chooseDirectory(title: String, startingAt: URL? = nil) async -> URL? {
        await pick(PanePicker(kind: .directory, title: title, startingAt: startingAt))
    }

    /// A file, chosen in the open panel starting at `startingAt`.
    func chooseFile(title: String, startingAt: URL? = nil) async -> URL? {
        await pick(PanePicker(kind: .file, title: title, startingAt: startingAt))
    }
}

/// A yes/no question (`PaneContext.confirm`): a title over a message whose
/// line breaks are kept, then the cancel and confirm buttons (confirm is the
/// default, on Return).
public struct PaneConfirm: Equatable, Sendable {
    public var title: String
    public var message: String
    public var confirmLabel: String
    public var cancelLabel: String

    public init(title: String, message: String, confirmLabel: String = "OK", cancelLabel: String = "Cancel") {
        self.title = title
        self.message = message
        self.confirmLabel = confirmLabel
        self.cancelLabel = cancelLabel
    }
}

/// A pick of one option (`PaneContext.choose`).
public struct PaneChoose: Equatable, Sendable {
    public var title: String
    public var message: String
    /// What the select lists, in this order, the first chosen to begin with.
    public var options: [String]
    public var confirmLabel: String
    public var cancelLabel: String

    public init(title: String, message: String, options: [String], confirmLabel: String = "OK", cancelLabel: String = "Cancel") {
        self.title = title
        self.message = message
        self.options = options
        self.confirmLabel = confirmLabel
        self.cancelLabel = cancelLabel
    }
}

/// Something to acknowledge (`PaneContext.alert`): one button.
public struct PaneAlert: Equatable, Sendable {
    public var title: String
    public var message: String
    public var buttonLabel: String

    public init(title: String, message: String, buttonLabel: String = "OK") {
        self.title = title
        self.message = message
        self.buttonLabel = buttonLabel
    }
}

/// A file or directory to choose in the system's open panel (`PaneContext.pick`).
public struct PanePicker: Equatable, Sendable {
    public enum Kind: Equatable, Sendable { case directory, file }
    public var kind: Kind
    public var title: String
    /// The directory the panel opens in (a file's own directory), when given.
    public var startingAt: URL?

    public init(kind: Kind, title: String, startingAt: URL? = nil) {
        self.kind = kind
        self.title = title
        self.startingAt = startingAt
    }
}

/// One row of a context menu a pane shows (`PaneContext.showContextMenu`).
public struct PaneMenuItem {
    public var title: String
    /// A disabled row is drawn dim and does nothing when clicked.
    public var isEnabled: Bool
    public var action: @MainActor () -> Void

    public init(_ title: String, isEnabled: Bool = true, action: @escaping @MainActor () -> Void) {
        self.title = title
        self.isEnabled = isEnabled
        self.action = action
    }
}
