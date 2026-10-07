import Foundation

/// Something a plugin adds to one of core's extension points. `contributionID`
/// must be unique within the point; unless the point says otherwise it must
/// also sit in the contributing plugin's namespace (`<pluginID>` or
/// `<pluginID>.<name>`).
public protocol Contribution {
    var contributionID: String { get }
}

/// A typed slot in core that plugins contribute to. Only core defines points
/// (the initializer is core-only): plugins add to core, never to each other.
///
/// Inside core, adding a kind of contribution never touches the loader, the
/// context or the rollback machinery: define a `Contribution` type and a
/// point, declare it in `CoreExtensionPoints`, and read it where it's used.
public struct ExtensionPoint<C: Contribution>: Hashable, Sendable {
    public let id: String

    package init(_ id: String) { self.id = id }
}

/// A contribution with the plugin that made it (core-only).
package struct Owned<C> {
    package let owner: PluginID
    package let value: C

    package init(owner: PluginID, value: C) {
        self.owner = owner
        self.value = value
    }
}

// Core's extension points. Ids under `tabs.` are core's; no plugin can own that
// namespace because "tabs" is a reserved plugin id.
public extension ExtensionPoint where C == ContentTypeContribution {
    /// Ids are namespaced like any contribution, and must be declared in the
    /// manifest's `contentTypes`.
    static var contentTypes: Self { Self("tabs.contentTypes") }
}

public extension ExtensionPoint where C == CommandContribution {
    static var commands: Self { Self("tabs.commands") }
}

public extension ExtensionPoint where C == SettingsPageContribution {
    static var settingsPages: Self { Self("tabs.settingsPages") }
}

public extension ExtensionPoint where C == ControlVerbContribution {
    static var controlVerbs: Self { Self("tabs.controlVerbs") }
}
