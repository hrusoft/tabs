import Foundation

/// What a plugin's control-plane verbs are, as an agent reads it: the
/// `capabilities` command lists one entry per capability with its commands,
/// and `describe --capability <id>` prints this guide and these limits with
/// every command's flags, wire schema and result shape.
///
/// A plugin that declares control-plane verbs (`ControlVerbContribution` with a
/// `command`) declares exactly one capability, whose id is the plugin's own —
/// `browser` — since that is what an agent passes to `describe`. The
/// capability is *enabled* while the plugin is (the same gate as creating its
/// panes); a disabled one is still listed and its verbs still answer for panes
/// that exist.
public struct ControlCapabilityContribution: Contribution {
    /// The plugin's id.
    public let id: String
    /// Shown by `capabilities`.
    public var displayName: String
    /// The prose that explains *when* and *how* to use the commands well —
    /// readiness semantics, targeting rules, what commonly goes wrong. Read by
    /// an agent before it first uses the capability; the flag lists say what a
    /// command accepts, this says what isn't obvious from that.
    public var guide: String
    /// Numbers an agent needs (caps, waits, defaults), by name.
    public var limits: [String: JSONValue]

    public var contributionID: String { id }

    public init(id: String, displayName: String, guide: String = "", limits: [String: JSONValue] = [:]) {
        self.id = id
        self.displayName = displayName
        self.guide = guide
        self.limits = limits
    }
}

public extension ExtensionPoint where C == ControlCapabilityContribution {
    /// The id must be the contributing plugin's own.
    static var controlCapabilities: Self { Self("tabs.controlCapabilities") }
}

public extension PluginContext {
    func register(_ contribution: ControlCapabilityContribution) { contribute(contribution, to: .controlCapabilities) }
}
