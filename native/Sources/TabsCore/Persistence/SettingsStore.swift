import Foundation
import TabsPluginSDK

/// settings.json: core's own settings plus one opaque blob per plugin.
///
/// Blobs of plugins that aren't loaded this launch (disabled, removed from the
/// build, failed) are carried through every save untouched.
@MainActor
package final class SettingsStore: SettingsBackend {
    /// How panes look and behave — the Electron app's pane settings, same
    /// names and defaults. Each field decodes on its own; one that doesn't
    /// takes its default.
    package struct PaneSettings: Codable, Equatable, Sendable {
        /// `dark`, `light` or `system`.
        package var colorTheme = "dark"
        package var showNavFlash = true
        package var dimInactivePanes = true
        /// 0 (no effect) to 1.
        package var dimInactivePanesIntensity = 0.34
        package var snapResizeSeparators = true
        /// Where a new unpinned pane spawns over the pane it comes from.
        package var newUnpinnedPanePosition = SpawnPosition.default.rawValue
        /// Whether every window's layout is saved to layout.json and restored
        /// at the next launch (the Electron app's `persistLayoutOnExit`). Off,
        /// launch starts fresh and nothing is written, but nothing is deleted.
        package var persistLayoutOnExit = true
        /// Kinds of pane signal the user switched off, by id (sorted). Sparse:
        /// every kind is on unless listed, like the Electron app's
        /// `enableBellIndicator` / `enableControlIndicator` defaults.
        package var disabledSignals: [String] = []

        package init() {}

        private enum CodingKeys: String, CodingKey, CaseIterable {
            case colorTheme, showNavFlash, dimInactivePanes, dimInactivePanesIntensity, snapResizeSeparators, newUnpinnedPanePosition
            case disabledSignals, persistLayoutOnExit
        }

        package init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let defaults = PaneSettings()
            colorTheme = (try? container.decodeIfPresent(String.self, forKey: .colorTheme)) ?? defaults.colorTheme
            showNavFlash = (try? container.decodeIfPresent(Bool.self, forKey: .showNavFlash)) ?? defaults.showNavFlash
            dimInactivePanes = (try? container.decodeIfPresent(Bool.self, forKey: .dimInactivePanes)) ?? defaults.dimInactivePanes
            dimInactivePanesIntensity =
                (try? container.decodeIfPresent(Double.self, forKey: .dimInactivePanesIntensity)) ?? defaults.dimInactivePanesIntensity
            snapResizeSeparators =
                (try? container.decodeIfPresent(Bool.self, forKey: .snapResizeSeparators)) ?? defaults.snapResizeSeparators
            newUnpinnedPanePosition =
                (try? container.decodeIfPresent(String.self, forKey: .newUnpinnedPanePosition)) ?? defaults.newUnpinnedPanePosition
            disabledSignals = (try? container.decodeIfPresent([String].self, forKey: .disabledSignals)) ?? defaults.disabledSignals
            persistLayoutOnExit =
                (try? container.decodeIfPresent(Bool.self, forKey: .persistLayoutOnExit)) ?? defaults.persistLayoutOnExit
        }

        /// A stored position that isn't one of the nine spawns at the default.
        package var spawnPosition: SpawnPosition { SpawnPosition(rawValue: newUnpinnedPanePosition) ?? .default }
    }

    package struct CoreSettings: Codable, Equatable {
        package var disabledPlugins: [PluginID] = []
        package var panes = PaneSettings()
        /// The user's shortcuts, by command id: a chord in `KeyChord`'s stored
        /// form, or nil (JSON null) for unbound. Sparse: absent means the
        /// command's default. One that doesn't parse is kept but not used.
        package var shortcuts: [String: String?] = [:]
        /// Fields a newer build wrote, carried through every save.
        package var unknown: [String: JSONValue] = [:]

        package init() {}

        private enum CodingKeys: String, CodingKey, CaseIterable { case disabledPlugins, shortcuts, panes }

        /// Field by field, so one bad field never costs the others.
        package init(from decoder: any Decoder) throws {
            unknown = Self.unknownFields(in: decoder, known: CodingKeys.allCases.map(\.rawValue))
            let container = try decoder.container(keyedBy: CodingKeys.self)
            do {
                disabledPlugins = try container.decodeIfPresent([PluginID].self, forKey: .disabledPlugins) ?? []
            } catch {
                decoder.diagnostics?.drop("disabledPlugins did not decode and was reset")
            }
            panes = (try? container.decodeIfPresent(PaneSettings.self, forKey: .panes)) ?? PaneSettings()
            let raw = (try? container.decodeIfPresent([String: JSONValue].self, forKey: .shortcuts)) ?? [:]
            for (command, value) in raw.sorted(by: { $0.key < $1.key }) {
                switch value {
                case .string(let chord): shortcuts[command] = .some(chord)
                case .null: shortcuts.updateValue(nil, forKey: command)
                default: decoder.diagnostics?.drop("dropped the shortcut for \(command): not a string or null")
                }
            }
            if container.contains(.shortcuts), (try? container.decode([String: JSONValue].self, forKey: .shortcuts)) == nil {
                decoder.diagnostics?.drop("shortcuts did not decode and were reset")
            }
        }

        package func encode(to encoder: any Encoder) throws {
            try Self.encode(unknown, to: encoder)
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(disabledPlugins, forKey: .disabledPlugins)
            try container.encode(shortcuts, forKey: .shortcuts)
            try container.encode(panes, forKey: .panes)
        }
    }

    struct Document: PersistedDocument {
        static let currentVersion = 1
        var core = CoreSettings()
        var plugins: [String: JSONValue] = [:]
        /// Top-level fields a newer build wrote, carried through every save.
        var unknown: [String: JSONValue] = [:]

        init() {}

        init(from decoder: any Decoder) throws {
            unknown = CoreSettings.unknownFields(in: decoder, known: ["core", "plugins", "version"])
            let container = try decoder.container(keyedBy: CodingKeys.self)
            do {
                core = try container.decodeIfPresent(CoreSettings.self, forKey: .core) ?? CoreSettings()
            } catch {
                decoder.diagnostics?.drop("core settings did not decode and were reset")
            }
            do {
                plugins = try container.decodeIfPresent([String: JSONValue].self, forKey: .plugins) ?? [:]
            } catch {
                decoder.diagnostics?.drop("plugin settings did not decode and were reset")
            }
        }

        func encode(to encoder: any Encoder) throws {
            try CoreSettings.encode(unknown, to: encoder)
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(core, forKey: .core)
            try container.encode(plugins, forKey: .plugins)
        }

        private enum CodingKeys: String, CodingKey { case core, plugins }
    }

    private let store: DocumentStore<Document>
    private var document: Document
    package private(set) var loadNotes: [String] = []

    package init(file: URL, readOnly: Bool = false) {
        store = DocumentStore(file: file, readOnly: readOnly)
        switch store.load() {
        case .missing:
            document = Document()
        case .loaded(let loaded):
            document = loaded
        case .recovered(let loaded, let notes):
            document = loaded
            loadNotes = notes
        case .unreadable(let reason):
            document = Document()
            loadNotes = ["settings.json \(reason)"]
        }
    }

    package var core: CoreSettings { document.core }
    package var disabledPlugins: Set<PluginID> { Set(document.core.disabledPlugins) }

    package var isReadOnly: Bool { store.readOnly }

    package func setDisabled(_ disabled: Bool, for plugin: PluginID) {
        var set = disabledPlugins
        if disabled { set.insert(plugin) } else { set.remove(plugin) }
        document.core.disabledPlugins = set.sorted()
        store.save(document)
    }

    package var panes: PaneSettings { document.core.panes }

    private var paneObservers: [Int: @MainActor (PaneSettings) -> Void] = [:]
    private var nextPaneObserver = 0

    package func setPanes(_ panes: PaneSettings) {
        guard panes != document.core.panes else { return }
        document.core.panes = panes
        store.save(document)
        for observer in paneObservers.values { observer(panes) }
    }

    /// Calls `handler` whenever the pane settings change.
    package func observePanes(_ handler: @escaping @MainActor (PaneSettings) -> Void) -> Subscription {
        let token = nextPaneObserver
        nextPaneObserver += 1
        paneObservers[token] = handler
        return Subscription(onCancel: { [weak self] in self?.paneObservers[token] = nil })
    }

    package var shortcutOverrides: [String: String?] { document.core.shortcuts }

    /// Records the user's shortcut for `command`: a chord's stored form, nil
    /// (unbound), or — with `remove` — back to the command's default.
    package func setShortcut(_ chord: String?, for command: String, remove: Bool = false) {
        if remove {
            document.core.shortcuts[command] = nil
        } else {
            document.core.shortcuts.updateValue(chord, forKey: command)
        }
        store.save(document)
    }

    /// Replaces every shortcut the user stored at once (empty: Restore Defaults).
    package func setShortcuts(_ shortcuts: [String: String?]) {
        document.core.shortcuts = shortcuts
        store.save(document)
    }

    package func storedSettings(for plugin: PluginID) -> JSONValue? {
        document.plugins[plugin.rawValue]
    }

    package func store(_ value: JSONValue, for plugin: PluginID) {
        guard value.isRepresentableInJSON else {
            Log.persistence.fault("refused settings for \(plugin.rawValue, privacy: .public): not representable as JSON")
            return
        }
        document.plugins[plugin.rawValue] = value
        store.save(document)
    }
}

extension SettingsStore.CoreSettings {
    private struct AnyKey: CodingKey {
        let stringValue: String
        var intValue: Int? { nil }
        init(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }

    /// The object's fields other than `known`.
    static func unknownFields(in decoder: any Decoder, known: [String]) -> [String: JSONValue] {
        guard case .object(let fields)? = try? JSONValue(from: decoder) else { return [:] }
        return fields.filter { !known.contains($0.key) }
    }

    static func encode(_ fields: [String: JSONValue], to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: AnyKey.self)
        for (key, value) in fields { try container.encode(value, forKey: AnyKey(stringValue: key)) }
    }
}
