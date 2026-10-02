import AppKit
import SwiftUI
import TabsCore
import TabsPluginSDK

/// Settings ▸ Panes & Tabs: core's own page — the Electron app's pane
/// settings (theme, the direction overlay, dimming, each kind of pane
/// signal's switch, separator snapping, where a new unpinned pane appears)
/// and General ▸ Startup's Restore layout on relaunch, stored in
/// `core.panes`. Grouped as the page shows them: Appearance, Startup,
/// Navigation and layout, then Indicators (the signals' switches).
@MainActor
@Observable
final class PaneSettingsModel {
    /// A kind of pane signal's switch, as the page lists it.
    struct SignalSwitch: Identifiable {
        let id: String
        let title: String
        let detail: String
    }

    private(set) var settings: SettingsStore.PaneSettings
    /// Every kind's switch, in the kinds' order (`PaneSignals.settingKinds`).
    let signalSwitches: [SignalSwitch]
    @ObservationIgnored private let store: SettingsStore
    @ObservationIgnored private var subscription: Subscription?

    init(store: SettingsStore, signals: [SignalKind] = []) {
        self.store = store
        settings = store.panes
        signalSwitches = signals.map { SignalSwitch(id: $0.id, title: $0.value.setting.title, detail: $0.value.setting.detail) }
        subscription = store.observePanes { [weak self] settings in self?.settings = settings }
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
                Picker("Theme", selection: model.binding(\.colorTheme)) {
                    Text("Dark").tag("dark")
                    Text("Light").tag("light")
                    Text("System").tag("system")
                }
                row("Dim inactive panes", "Fade inactive panes' content so the active pane stands out.", toggle: \.dimInactivePanes)
                LabeledContent {
                    Slider(value: model.binding(\.dimInactivePanesIntensity), in: 0...1) { Text("Dimming intensity") }.labelsHidden()
                        .frame(width: 200)
                } label: {
                    Text("Dimming intensity")
                    Text("How strongly inactive panes are desaturated and darkened.")
                }
                // The whole row, so its label greys out with the slider.
                .disabled(!model.settings.dimInactivePanes)
            }
            // Electron's General ▸ Startup, after General ▸ Appearance as there.
            Section("Startup") {
                row(
                    "Restore layout on relaunch", "Reopen your tabs and panes, and what each was showing, when relaunching.",
                    toggle: \.persistLayoutOnExit
                )
                .accessibilityIdentifier("settings-persist-layout-checkbox")
            }
            Section("Navigation and layout") {
                row(
                    "Direction overlay", "Show a brief overlay indicating direction when navigating panes with the keyboard.",
                    toggle: \.showNavFlash)
                row(
                    "Snap resize to aligned separators",
                    "While dragging a pane divider, snap to other dividers' positions when close, to line up pane edges exactly.",
                    toggle: \.snapResizeSeparators)
                LabeledContent {
                    SpawnPositionPicker(selection: model.binding(\.newUnpinnedPanePosition))
                } label: {
                    Text("New unpinned pane position")
                    Text(
                        "Where a new unpinned pane appears within the pane it was created from. Unpinning an existing pane still lifts it off in place."
                    )
                }
            }
            if !model.signalSwitches.isEmpty {
                Section("Indicators") {
                    ForEach(model.signalSwitches) { signal in
                        Toggle(isOn: model.signalBinding(signal.id)) {
                            Text(signal.title)
                            Text(signal.detail)
                        }
                        .accessibilityIdentifier("settings-signal-\(signal.id)-checkbox")
                    }
                }
            }
        }
        .settingsPageLayout()
    }

    /// A switch, its title and its description, as the form lays out a row.
    private func row(_ title: String, _ detail: String, toggle keyPath: WritableKeyPath<SettingsStore.PaneSettings, Bool>) -> some View {
        Toggle(isOn: model.binding(keyPath)) {
            Text(title)
            Text(detail)
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
                                .fill(chosen ? Color.accentColor : Color.secondary.opacity(0.25))
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
        .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.secondary.opacity(0.4)))
    }

    /// "Top left", for the tooltip and VoiceOver.
    private static func name(of position: SpawnPosition) -> String {
        let words = position.rawValue.replacingOccurrences(of: "-", with: " ")
        return words.prefix(1).uppercased() + words.dropFirst()
    }
}
