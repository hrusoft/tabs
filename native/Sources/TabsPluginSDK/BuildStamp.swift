import Foundation

/// The build stamp every image carries in `Resources/TabsBuildStamp.plist`
/// (written by Scripts/stamp-build-info.sh), and how core reads it. Reading a
/// stamp never loads the image's code.
///
/// The loaded SDK's stamp is the ground truth: an image whose fingerprint
/// differs was compiled against different shared modules (or with different
/// settings, or another compiler), and in a lockstep build without library
/// evolution that is undefined behavior, not an error dyld can report.
package struct BuildStamp: Equatable, Sendable {
    package static let resourceName = "TabsBuildStamp"

    package enum Role: String, Sendable {
        case sdk, core, app, plugin
    }

    package let role: Role
    package let configuration: String
    package let fingerprint: String
    /// App only: the plugin ids the app ships.
    package let bundledPlugins: [PluginID]?

    package init(role: Role, configuration: String, fingerprint: String, bundledPlugins: [PluginID]? = nil) {
        self.role = role
        self.configuration = configuration
        self.fingerprint = fingerprint
        self.bundledPlugins = bundledPlugins
    }

    /// The stamp of a bundle, or nil if it has none (or an unreadable one).
    package init?(of bundle: Bundle) {
        guard let url = bundle.url(forResource: Self.resourceName, withExtension: "plist"),
            let data = try? Data(contentsOf: url),
            let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
            let role = (plist["role"] as? String).flatMap(Role.init(rawValue:)),
            let configuration = plist["configuration"] as? String,
            let fingerprint = plist["fingerprint"] as? String
        else { return nil }
        self.init(
            role: role, configuration: configuration, fingerprint: fingerprint,
            bundledPlugins: (plist["bundledPlugins"] as? [String])?.map(PluginID.init(_:)))
    }

    /// The property list `init?(of:)` reads — for tests that build bundles by hand.
    package var propertyList: [String: Any] {
        var plist: [String: Any] = ["role": role.rawValue, "configuration": configuration, "fingerprint": fingerprint]
        if let bundledPlugins { plist["bundledPlugins"] = bundledPlugins.map(\.rawValue) }
        return plist
    }

    /// The stamp of the SDK image loaded in this process.
    package static var loaded: BuildStamp? { BuildStamp(of: Bundle(for: SDKBundleToken.self)) }
    package static var loadedFingerprint: String? { loaded?.fingerprint }
}

private final class SDKBundleToken: NSObject {}

/// A symbol only the SDK image may define. The packaging gate
/// (Scripts/verify-app.sh) fails if any other image in the app exports it —
/// the signature of a plugin that statically linked its own copy of the SDK,
/// which makes every `as? TabsPlugin` cast across images fail.
@_cdecl("tabs_plugin_sdk_sentinel")
public func tabsPluginSDKSentinel() {}
