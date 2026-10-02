import Foundation
import TabsPluginSDK

/// Decides, from manifests alone, which plugins to load and in what order.
/// Pure: no bundles, no I/O.
///
/// Plugins are isolated from each other, so there are no dependencies to
/// order by: a plugin loads if the user enabled it, or — since disabling is a
/// creation gate, not an uninstall — if a restored pane shows one of its
/// content types. Order is (sortOrder, id).
package enum PluginResolver {
    package struct Input {
        package var manifests: [PluginManifest]
        package var disabled: Set<PluginID> = []
        /// Content types that restored panes need.
        package var requiredContentTypes: Set<ContentTypeID> = []

        package init(manifests: [PluginManifest], disabled: Set<PluginID> = [], requiredContentTypes: Set<ContentTypeID> = []) {
            self.manifests = manifests
            self.disabled = disabled
            self.requiredContentTypes = requiredContentTypes
        }
    }

    package struct Output: Equatable {
        /// In (sortOrder, id) order.
        package var activationOrder: [PluginID] = []
        /// Disabled plugins that won't be loaded.
        package var disabled: [PluginID] = []
        /// Disabled plugins that load anyway, and why.
        package var loadedWhileDisabled: [PluginID: String] = [:]
    }

    package static func resolve(_ input: Input) -> Output {
        var output = Output()
        let ordered = input.manifests.sorted { ($0.sortOrder, $0.id.rawValue) < ($1.sortOrder, $1.id.rawValue) }
        for manifest in ordered {
            guard manifest.canDisable, input.disabled.contains(manifest.id) else {
                output.activationOrder.append(manifest.id)
                continue
            }
            if let type = manifest.contentTypes.first(where: input.requiredContentTypes.contains) {
                output.activationOrder.append(manifest.id)
                output.loadedWhileDisabled[manifest.id] = "an open pane shows its content type \"\(type)\""
            } else {
                output.disabled.append(manifest.id)
            }
        }
        return output
    }
}
