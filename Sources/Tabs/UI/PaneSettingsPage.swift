import AppKit
import SwiftUI
import TabsCore
import TabsPluginSDK

/// Settings ▸ Panes & Tabs: core's own page — the pane settings (theme, the
/// direction overlay, dimming, each kind of pane signal's switch, separator
/// snapping, where a new unpinned pane appears), Restore layout on relaunch
/// and whether tab titles follow panes, stored in `core.panes`. Grouped as the
/// page shows them: Appearance, Startup, Tabs, Navigation and layout, then
/// Indicators (the signals' switches).
@MainActor
@Observable
final class PaneSettingsModel {
    /// A kind of pane signal's switch, as the page lists it.
    struct SignalSwitch: Identifiable {
        let id: String
        let title: String
        let detail: String
    }

    /// A choice in the Theme menu: the title it shows and the value it stores (`colorTheme`).
    struct ThemeChoice: Identifiable {
        let title: String
        let value: String
        var id: String { value }
    }

    /// The Theme menu's choices, in the order it lists them: System, then every theme the app
    /// ships (`ThemeCatalog.entries`: Light, Dark, then the rest by name), each storing its id.
    let themes: [ThemeChoice]
    private(set) var settings: SettingsStore.PaneSettings
    /// Every kind's switch, in the kinds' order (`PaneSignals.settingKinds`).
    let signalSwitches: [SignalSwitch]
    @ObservationIgnored private let store: SettingsStore
    @ObservationIgnored private let catalog: ThemeCatalog
    @ObservationIgnored private var subscription: Subscription?

    init(store: SettingsStore, signals: [SignalKind] = [], themes catalog: ThemeCatalog = .empty) {
        self.store = store
        self.catalog = catalog
        settings = store.panes
        signalSwitches = signals.map { SignalSwitch(id: $0.id, title: $0.value.setting.title, detail: $0.value.setting.detail) }
        themes =
            [ThemeChoice(title: "System", value: ThemeCatalog.system)] + catalog.entries.map { ThemeChoice(title: $0.name, value: $0.id) }
        subscription = store.observePanes { [weak self] settings in self?.settings = settings }
    }

    /// A subscription outlives what dropped it: every Settings window rebuilt would leave one behind.
    isolated deinit {
        subscription?.cancel()
    }

    /// The Theme menu's selection: the stored theme, or Dark — what is drawn instead — while no
    /// file by that name loads. Only choosing another changes what is stored.
    var theme: Binding<String> {
        Binding(get: { self.catalog.choice(for: self.settings.colorTheme) }, set: { id in self.update { $0.colorTheme = id } })
    }

    /// On unless the user switched it off (`disabledSignals`, kept sorted).
    func signalBinding(_ id: String) -> Binding<Bool> {
        Binding(
            get: { !self.settings.disabledSignals.contains(id) },
            set: { on in
                self.update { settings in
                    var disabled = Set(settings.disabledSignals)
                    if on { disabled.remove(id) } else { disabled.insert(id) }
                    settings.disabledSignals = disabled.sorted()
                }
            })
    }

    func update(_ change: (inout SettingsStore.PaneSettings) -> Void) {
        var next = settings
        change(&next)
        store.setPanes(next)
    }

    func binding<Value>(_ keyPath: WritableKeyPath<SettingsStore.PaneSettings, Value>) -> Binding<Value> {
        Binding(get: { self.settings[keyPath: keyPath] }, set: { value in self.update { $0[keyPath: keyPath] = value } })
    }
}

struct PaneSettingsView: View {
    @Bindable var model: PaneSettingsModel

    var body: some View {
        Form {
            Section("Appearance") {
                Picker("Theme", selection: model.theme) {
                    ForEach(model.themes) { Text($0.title).tag($0.value) }
                }
                row(
                    "Dim inactive panes", "Fade inactive panes' content so the active pane stands out.",
                    isOn: model.binding(\.dimInactivePanes))
                LabeledContent {
                    Slider(value: model.binding(\.dimInactivePanesIntensity), in: 0...1) { Text("Dimming intensity") }.labelsHidden()
                        .frame(width: 200)
                } label: {
                    Text("Dimming intensity")
                    Text("How strongly inactive panes are desaturated and darkened.").foregroundStyle(.secondary)
                }
                // The whole row, so its label greys out with the slider.
                .disabled(!model.settings.dimInactivePanes)
            }
            Section("Startup") {
                row(
                    "Restore layout on relaunch", "Reopen your tabs and panes, and what each was showing, when relaunching.",
                    isOn: model.binding(\.persistLayoutOnExit)
                )
                .accessibilityIdentifier("settings-persist-layout-checkbox")
            }
            Section("Tabs") {
                row(
                    "Tab titles follow the active pane",
                    "Each tab shows the title of the pane last active in it, as that title changes. A tab you rename keeps your name; clear it to follow again.",
                    isOn: model.binding(\.tabTitlesFollowPanes)
                )
                .accessibilityIdentifier("settings-tab-titles-follow-checkbox")  // TT-2
            }
            Section("Navigation and layout") {
                row(
                    "Direction overlay", "Show a brief overlay indicating direction when navigating panes with the keyboard.",
                    isOn: model.binding(\.showNavFlash))
                row(
                    "Snap resize to aligned separators",
                    "While dragging a pane divider, snap to other dividers' positions when close, to line up pane edges exactly.",
                    isOn: model.binding(\.snapResizeSeparators))
                LabeledContent {
                    SpawnPositionPicker(selection: model.binding(\.newUnpinnedPanePosition))
                } label: {
                    Text("New unpinned pane position")
                    Text(
                        "Where a new unpinned pane appears within the pane it was created from. Unpinning an existing pane still lifts it off in place."
                    )
                    .foregroundStyle(.secondary)
                }
            }
            if !model.signalSwitches.isEmpty {
                Section("Indicators") {
                    ForEach(model.signalSwitches) { signal in
                        row(signal.title, signal.detail, isOn: model.signalBinding(signal.id))
                            .accessibilityIdentifier("settings-signal-\(signal.id)-checkbox")
                    }
                }
            }
        }
        .settingsPageLayout()
    }

    /// A switch, its title and its description, as the form lays out a row (the description
    /// marked secondary: under the theme's styles a row's label is all primary otherwise).
    private func row(_ title: String, _ detail: String, isOn: Binding<Bool>) -> some View {
        Toggle(isOn: isOn) {
            Text(title)
            Text(detail).foregroundStyle(.secondary)
        }
    }
}

/// The nine spawn positions as a 3×3 grid of cells, the chosen one filled.
struct SpawnPositionPicker: View {
    @Binding var selection: String

    var body: some View {
        Grid(horizontalSpacing: 3, verticalSpacing: 3) {
            ForEach(0..<3) { row in
                GridRow {
                    ForEach(0..<3) { column in
                        let position = SpawnPosition.allCases[row * 3 + column]
                        let chosen = (SpawnPosition(rawValue: selection) ?? .default) == position
                        Button {
                            selection = position.rawValue
                        } label: {
                            RoundedRectangle(cornerRadius: 2)
                                .fill(chosen ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary.opacity(0.25)))
                                .frame(width: 18, height: 12)
                        }
                        .buttonStyle(.plain)
                        .help(Self.name(of: position))
                        .accessibilityLabel(Self.name(of: position))
                        .accessibilityAddTraits(chosen ? .isSelected : [])
                    }
                }
            }
        }
        .padding(4)
        .overlay(RoundedRectangle(cornerRadius: 4).stroke(.secondary.opacity(0.4)))
    }

    /// "Top left", for the tooltip and VoiceOver.
    private static func name(of position: SpawnPosition) -> String {
        let words = position.rawValue.replacingOccurrences(of: "-", with: " ")
        return words.prefix(1).uppercased() + words.dropFirst()
    }
}
