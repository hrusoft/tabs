import Foundation

/// A typed string identifier. The phantom `Tag` keeps a `PluginID` from being
/// passed where a `ContentTypeID` is expected; on the wire (JSON, Info.plist)
/// every identifier is a plain string.
public struct Identifier<Tag>: RawRepresentable, Hashable, Comparable, Sendable,
    ExpressibleByStringLiteral, CustomStringConvertible, Codable
{
    public let rawValue: String

    public init(rawValue: String) { self.rawValue = rawValue }
    public init(_ rawValue: String) { self.rawValue = rawValue }
    public init(stringLiteral value: String) { self.rawValue = value }

    public var description: String { rawValue }

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }

    public init(from decoder: any Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(String.self)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

public enum PluginTag {}
public enum ContentTypeTag {}
public enum CommandTag {}
public enum PaneTag {}
public enum WindowTag {}

/// A plugin's identity. Equal to its bundle's name (`<id>.tabsplugin`) and the
/// namespace for everything it contributes (`<id>.<name>`).
public typealias PluginID = Identifier<PluginTag>
public typealias ContentTypeID = Identifier<ContentTypeTag>
public typealias CommandID = Identifier<CommandTag>
public typealias PaneID = Identifier<PaneTag>
public typealias WindowID = Identifier<WindowTag>

public extension Identifier where Tag == PaneTag {
    static func make() -> Self { Self(UUID().uuidString.lowercased()) }
}

public extension Identifier where Tag == WindowTag {
    static func make() -> Self { Self(UUID().uuidString.lowercased()) }
}

/// Syntax rules shared by manifests and contributions.
public enum IdentifierRules {
    /// Plugin ids double as file names: lowercase letters, digits and dashes.
    public static func isValidPluginID(_ id: String) -> Bool {
        id.wholeMatch(of: /[a-z][a-z0-9-]*/) != nil
    }

    /// Everything else: dot-separated segments of letters, digits and dashes,
    /// starting with a letter (`terminal`, `terminal.clearBuffer`).
    public static func isValidQualifiedName(_ name: String) -> Bool {
        name.wholeMatch(of: /[A-Za-z][A-Za-z0-9-]*(\.[A-Za-z0-9-]+)*/) != nil
    }

    /// Ids core keeps for itself; no plugin may use them.
    public static let reservedPluginIDs: Set<String> = ["tabs", "core", "sdk"]

    /// Whether `name` lives in `plugin`'s namespace: the id itself or `<id>.<rest>`.
    public static func isNamespaced(_ name: String, under plugin: PluginID) -> Bool {
        name == plugin.rawValue || name.hasPrefix(plugin.rawValue + ".")
    }
}
