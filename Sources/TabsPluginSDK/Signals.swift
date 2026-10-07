import AppKit

/// Names a kind of pane signal: `PaneSignal("terminal.bell")`. The kind itself —
/// how it looks and behaves — is a `PaneSignalContribution`, and
/// `contribution.signal` is its name.
public struct PaneSignal: Hashable, Sendable, CustomStringConvertible {
    public let id: String

    public init(_ id: String) { self.id = id }

    public var description: String { id }
}

/// A kind of signal a pane can carry: a cue that asks for the user's eye
/// without taking focus. Core draws every kind the same way:
///
/// - the icon before the pane's title, in the header;
/// - the pane's content outlined in the kind's color with an inner glow (the
///   active pane's outline gives way to it);
/// - both pulsing together, unless `pulse` is nil;
/// - with `marksTabs`, the icon also on every tab that holds the pane, at any
///   depth, so a pane in a background tab still shows.
///
/// A pane raises its plugin's own kinds on itself (`PaneContext.raise`), and
/// the signal stays with the pane — across splits, tabs and windows — until:
///
/// - `.untilSeen`: the user looks at the pane (it becomes its window's active
///   pane, or its window gains focus while it's active), or the pane withdraws
///   it. A signal raised while the user is already looking at the pane is
///   dropped, like a bell in the pane being typed in.
/// - `.untilWithdrawn`: the pane withdraws it.
///
/// Closing the pane ends its signals. Each kind has an on/off switch in
/// Settings ▸ Panes & Tabs (`setting`): while off, an `.untilSeen` signal is
/// dropped when raised, and every signal already up is hidden but kept.
///
/// When a pane carries several, the icons follow the kinds' order (plugins in
/// UI order, each in registration order), and the outline is the last one's.
public struct PaneSignalContribution: Contribution {
    /// An SF Symbol, or a template image (only its alpha counts), drawn in
    /// the kind's color in a 16×16 box.
    public typealias Icon = PaneIcon

    /// The kind's color, in the current theme.
    public enum Color: Equatable {
        /// The theme's alert red (`PaneTheme.bellAlert`).
        case alert
        /// The theme's automation purple (`PaneTheme.agent`).
        case agent
        /// The theme's accent (`PaneTheme.accent`).
        case accent
        /// Your own, one per theme.
        case custom(dark: NSColor, light: NSColor)
    }

    public enum Lifetime: Sendable, Equatable {
        /// Asks for attention: gone once the user looks at the pane.
        case untilSeen
        /// Describes a state: stays until the pane withdraws it.
        case untilWithdrawn
    }

    /// The kind's switch in Settings ▸ Panes & Tabs (on by default).
    public struct Setting: Equatable, Sendable {
        public var title: String
        public var detail: String

        public init(title: String, detail: String) {
            self.title = title
            self.detail = detail
        }
    }

    /// Namespaced like every contribution: `terminal.bell`.
    public let id: String
    /// What the icon says to accessibility ("Bell").
    public var label: String
    public var icon: Icon
    public var color: Color
    /// Seconds per pulse of the icon and outline (the bell's is 3); nil: steady.
    public var pulse: TimeInterval?
    /// Also show the icon on every tab holding the pane.
    public var marksTabs: Bool
    public var lifetime: Lifetime
    /// Bounce the Dock icon when it's raised while the pane's window isn't
    /// focused (every time, a repeat included).
    public var requestsAttention: Bool
    /// The icon's hover text (the system tooltip); nil: none.
    public var tooltip: String?
    public var setting: Setting

    public var contributionID: String { id }
    /// The kind's name, for `PaneContext.raise`.
    public var signal: PaneSignal { PaneSignal(id) }

    public init(
        id: String, label: String, icon: Icon, color: Color, pulse: TimeInterval? = 3, marksTabs: Bool = false, lifetime: Lifetime,
        requestsAttention: Bool = false, tooltip: String? = nil, setting: Setting
    ) {
        self.id = id
        self.label = label
        self.icon = icon
        self.color = color
        self.pulse = pulse
        self.marksTabs = marksTabs
        self.lifetime = lifetime
        self.requestsAttention = requestsAttention
        self.tooltip = tooltip
        self.setting = setting
    }
}

public extension ExtensionPoint where C == PaneSignalContribution {
    /// Ids are namespaced like any contribution.
    static var paneSignals: Self { Self("tabs.paneSignals") }
}

public extension PluginContext {
    func register(_ contribution: PaneSignalContribution) { contribute(contribution, to: .paneSignals) }
}
