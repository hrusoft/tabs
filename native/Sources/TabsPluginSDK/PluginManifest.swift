import Foundation

/// What a plugin declares about itself without running any code. Lives in the
/// plugin bundle's Info.plist under the `TabsPlugin` key, so core can decide
/// whether and in what order to load a plugin — and draw placeholders for its
/// panes if it can't — before a single instruction of it executes.
///
/// ```xml
/// <key>TabsPlugin</key>
/// <dict>
///     <key>id</key>            <string>terminal</string>
///     <key>displayName</key>   <string>Terminal</string>
///     <key>contentTypes</key>  <array><string>terminal</string></array>
///     <key>canDisable</key>    <true/>
///     <key>sortOrder</key>     <integer>10</integer>
/// </dict>
/// ```
public struct PluginManifest: Codable, Hashable, Sendable {
    public static let infoPlistKey = "TabsPlugin"

    /// Equal to the bundle's name without `.tabsplugin`.
    public var id: PluginID
    public var displayName: String
    public var summary: String
    /// Every content type this plugin registers — declared up front so core can
    /// keep a disabled plugin's panes alive and name the plugin behind a pane
    /// it can't show. Namespaced like everything a plugin contributes
    /// (`<id>` or `<id>.<name>`), so two plugins can never claim the same type.
    /// Reconciled at activation: registering an undeclared type, or declaring
    /// one and not registering it, fails the plugin.
    public var contentTypes: [ContentTypeID]
    public var canDisable: Bool
    /// UI order among plugins (creation buttons, settings pages); ties break by id.
    public var sortOrder: Int

    public init(
        id: PluginID, displayName: String, summary: String = "",
        contentTypes: [ContentTypeID] = [], canDisable: Bool = true, sortOrder: Int = 100
    ) {
        self.id = id
        self.displayName = displayName
        self.summary = summary
        self.contentTypes = contentTypes
        self.canDisable = canDisable
        self.sortOrder = sortOrder
    }

    private enum CodingKeys: String, CodingKey {
        case id, displayName, summary, contentTypes, canDisable, sortOrder
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(PluginID.self, forKey: .id)
        displayName = try c.decode(String.self, forKey: .displayName)
        summary = try c.decodeIfPresent(String.self, forKey: .summary) ?? ""
        contentTypes = try c.decodeIfPresent([ContentTypeID].self, forKey: .contentTypes) ?? []
        canDisable = try c.decodeIfPresent(Bool.self, forKey: .canDisable) ?? true
        sortOrder = try c.decodeIfPresent(Int.self, forKey: .sortOrder) ?? 100
    }

    /// Reads the manifest out of a bundle's Info.plist. Never loads code.
    public init(infoDictionary: [String: Any]) throws {
        guard let raw = infoDictionary[Self.infoPlistKey] else {
            throw ManifestError.missing
        }
        guard PropertyListSerialization.propertyList(raw, isValidFor: .binary) else {
            throw ManifestError.malformed("the \(Self.infoPlistKey) entry is not a property list")
        }
        do {
            let data = try PropertyListSerialization.data(fromPropertyList: raw, format: .binary, options: 0)
            self = try PropertyListDecoder().decode(PluginManifest.self, from: data)
        } catch {
            throw ManifestError.malformed(Self.describe(error))
        }
    }

    /// Every rule a manifest breaks, as human-readable sentences.
    public func problems() -> [String] {
        var problems: [String] = []
        if !IdentifierRules.isValidPluginID(id.rawValue) {
            problems.append("id \"\(id)\" must be lowercase letters, digits and dashes, starting with a letter")
        }
        if IdentifierRules.reservedPluginIDs.contains(id.rawValue) {
            problems.append("id \"\(id)\" is reserved for core")
        }
        if displayName.trimmingCharacters(in: .whitespaces).isEmpty {
            problems.append("displayName is empty")
        }
        for type in contentTypes {
            if !IdentifierRules.isValidQualifiedName(type.rawValue) {
                problems.append("content type \"\(type)\" is not a valid name")
            } else if !IdentifierRules.isNamespaced(type.rawValue, under: id) {
                problems.append("content type \"\(type)\" must be \"\(id)\" or start with \"\(id).\"")
            }
        }
        if Set(contentTypes).count != contentTypes.count {
            problems.append("contentTypes lists a type twice")
        }
        return problems
    }

    private static func describe(_ error: any Error) -> String {
        switch error {
        case DecodingError.keyNotFound(let key, _): "missing key \"\(key.stringValue)\""
        case DecodingError.typeMismatch(_, let context), DecodingError.valueNotFound(_, let context):
            "wrong type at \(context.codingPath.map(\.stringValue).joined(separator: "."))"
        default: String(describing: error)
        }
    }
}

public enum ManifestError: Error, Equatable, CustomStringConvertible {
    case missing
    case malformed(String)

    public var description: String {
        switch self {
        case .missing: "Info.plist has no \(PluginManifest.infoPlistKey) manifest"
        case .malformed(let detail): "malformed manifest: \(detail)"
        }
    }
}
