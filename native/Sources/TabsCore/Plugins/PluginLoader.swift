import Foundation
import TabsPluginSDK

/// Maps a plugin bundle's code and instantiates its entry class.
package enum PluginLoader {
    package enum LoadError: Error, CustomStringConvertible, Equatable {
        case loadFailed(String)
        case noPrincipalClass
        case foreignClass(className: String)
        case notNSObject(className: String)
        case notAPlugin(className: String)

        package var description: String {
            switch self {
            case .loadFailed(let detail): "could not load the bundle's code: \(detail)"
            case .noPrincipalClass: "Info.plist's NSPrincipalClass names no class in the bundle"
            case .foreignClass(let name): "principal class \(name) is not defined in the plugin's own bundle"
            case .notNSObject(let name): "principal class \(name) is not an NSObject subclass"
            case .notAPlugin(let name):
                "principal class \(name) does not conform to the loaded SDK's TabsPlugin (a plugin that embeds its own copy of the SDK fails exactly like this)"
            }
        }
    }

    @MainActor
    package static func load(_ bundle: Bundle) throws(LoadError) -> any TabsPlugin {
        do {
            try bundle.loadAndReturnError()
        } catch {
            throw .loadFailed((error as NSError).localizedDescription)
        }
        return try instantiate(principalClass: bundle.principalClass, expectedBundle: bundle)
    }

    /// Separate from `load` so tests can exercise every rejection with classes
    /// they define, without building a bundle per failure mode.
    @MainActor
    package static func instantiate(principalClass: AnyClass?, expectedBundle: Bundle) throws(LoadError) -> any TabsPlugin {
        guard let principalClass else { throw .noPrincipalClass }
        let name = NSStringFromClass(principalClass)
        guard canonical(Bundle(for: principalClass).bundleURL) == canonical(expectedBundle.bundleURL) else {
            throw .foreignClass(className: name)
        }
        guard let objectClass = principalClass as? NSObject.Type else { throw .notNSObject(className: name) }
        guard objectClass is any TabsPlugin.Type, let plugin = objectClass.init() as? any TabsPlugin else {
            throw .notAPlugin(className: name)
        }
        return plugin
    }

    private static func canonical(_ url: URL) -> String {
        url.resolvingSymlinksInPath().standardizedFileURL.path
    }
}
