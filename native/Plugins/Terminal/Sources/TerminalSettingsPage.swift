import AppKit
import SwiftUI
import TabsPluginSDK

/// Settings ▸ Terminal — `TerminalSettingsPage.tsx`: behaviour, then the
/// font, cursor and colors of every terminal pane, laid out as Terminal.app's
/// profile editor has them (a row per color, the cursor's color with the
/// cursor). Every change applies to open panes at once, except GPU rendering
/// (new panes).
struct TerminalSettingsPage: View {
    let settings: PluginSettings<TerminalSettings>
    @State private var colorEditor = ColorPanelEditor()

    var body: some View {
        Form {
            Section {
                Toggle(isOn: settings.binding(\.enableMetalRendering)) {
                    Text("GPU rendering (Metal)")
                    Text("Draw terminal panes with Metal. Applies to newly opened panes only.")
                }
                .accessibilityIdentifier("settings-metal-rendering-checkbox")
                Toggle(isOn: settings.binding(\.inheritCwdOnNewPane)) {
                    Text("Inherit working directory")
                    Text("New splits and tabs start in the current terminal's directory.")
                }
                .accessibilityIdentifier("settings-inherit-cwd-checkbox")
                LabeledContent {
                    HStack(spacing: 6) {
                        TextField("Scrollback", value: scrollback, format: .number)
                            .labelsHidden()
                            .textFieldStyle(.roundedBorder)
                            .multilineTextAlignment(.trailing)
                            .monospacedDigit()
                            .frame(width: 80)
                            .accessibilityIdentifier("settings-terminal-scrollback-input")
                        Stepper("Scrollback", value: scrollback, in: 0...TerminalSettings.maxScrollback, step: 100).labelsHidden()
                    }
                } label: {
                    Text("Scrollback")
                    Text("Lines of history kept above the visible screen, per pane, up to 100,000. 0 keeps none.")
                }
            }
            Section("Font") {
                Picker("Font family", selection: settings.binding(\.appearance.fontFamily)) {
                    ForEach(fontFamilies, id: \.self) { Text($0).tag($0) }
                }
                .accessibilityIdentifier("settings-terminal-font-family-select")
                stepperRow(
                    "Font size", value: "\(Int(settings.value.appearance.fontSize)) pt", settings.binding(\.appearance.fontSize),
                    in: TerminalAppearance.fontSizes, step: 1)
                stepperRow(
                    "Line height", value: String(format: "%.2f", settings.value.appearance.lineHeight),
                    settings.binding(\.appearance.lineHeight), in: TerminalAppearance.lineHeights, step: 0.05)
            }
            Section("Cursor") {
                Picker("Cursor style", selection: settings.binding(\.appearance.cursorStyle)) {
                    ForEach(TerminalCursorStyle.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                Toggle("Cursor blink", isOn: settings.binding(\.appearance.cursorBlink))
                LabeledContent("Cursor color") { swatch(\.appearance.cursorColor, "Cursor color") }
            }
            Section("Colors") {
                LabeledContent("Background") { swatch(\.appearance.background, "Background") }
                LabeledContent("Foreground") { swatch(\.appearance.foreground, "Foreground") }
                LabeledContent("Selection") { swatch(\.appearance.selectionBackground, "Selection") }
                ansiRow("Normal", TerminalAnsiColors.slots.prefix(8))
                ansiRow("Bright", TerminalAnsiColors.slots.suffix(8))
            }
        }
        .onDisappear { colorEditor.stop() }
    }

    /// A number the user steps through: the value, then its stepper, both flush right.
    private func stepperRow(
        _ title: String, value: String, _ binding: Binding<Double>, in range: ClosedRange<Double>, step: Double
    ) -> some View {
        LabeledContent(title) {
            HStack(spacing: 6) {
                Text(value).monospacedDigit()
                Stepper(title, value: binding, in: range, step: step).labelsHidden()
            }
        }
    }

    /// Installed families, the current one always among them (typed by hand,
    /// or not installed).
    private var fontFamilies: [String] {
        let installed = NSFontManager.shared.availableFontFamilies.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        let current = settings.value.appearance.fontFamily
        return installed.contains(current) ? installed : [current] + installed
    }

    /// Whole lines, never negative, at most `maxScrollback` (a larger number
    /// is taken as the most); a negative one leaves it as it was.
    private var scrollback: Binding<Int> {
        Binding(
            get: { TerminalSettings.scrollbackLines(settings.value.scrollback) },
            set: { value in
                if value >= 0 { settings.update { $0.scrollback = TerminalSettings.scrollbackLines(value) } }
            })
    }

    private func ansiRow(_ label: String, _ slots: ArraySlice<(key: WritableKeyPath<TerminalAnsiColors, String>, label: String)>)
        -> some View
    {
        let palette: WritableKeyPath<TerminalSettings, TerminalAnsiColors> = \.appearance.ansi
        return LabeledContent(label) {
            HStack(spacing: 4) {
                ForEach(Array(slots.enumerated()), id: \.offset) { _, slot in
                    swatch(palette.appending(path: slot.key), slot.label)
                }
            }
        }
    }

    /// A color chip; clicking it edits the color in the shared color panel.
    private func swatch(_ key: WritableKeyPath<TerminalSettings, String>, _ label: String) -> some View {
        let color = NSColor(hex: settings.value[keyPath: key]) ?? .black
        return Button {
            colorEditor.edit(color) { chosen in settings.update { $0[keyPath: key] = chosen.hexString } }
        } label: {
            RoundedRectangle(cornerRadius: 3)
                .fill(Color(nsColor: color))
                .frame(width: 24, height: 18)
                .padding(2)
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.secondary.opacity(0.5)))
        }
        .buttonStyle(.plain)
        .help(label)
        .accessibilityLabel(label)
    }
}

/// One color panel for every chip: many live `NSColorWell`s in one window
/// break unrelated views, so the chips are plain buttons that point the
/// shared panel at themselves.
@MainActor
@Observable
final class ColorPanelEditor: NSObject {
    @ObservationIgnored private var onChange: (@MainActor (NSColor) -> Void)?
    /// The panel's own `showsAlpha` before this page took it, while it has it.
    @ObservationIgnored private var previousShowsAlpha: Bool?

    func edit(_ color: NSColor, onChange: @escaping @MainActor (NSColor) -> Void) {
        self.onChange = nil
        let panel = NSColorPanel.shared
        if previousShowsAlpha == nil { previousShowsAlpha = panel.showsAlpha }
        panel.showsAlpha = false
        panel.color = color
        panel.setTarget(self)
        panel.setAction(#selector(colorChanged(_:)))
        self.onChange = onChange
        panel.orderFront(nil)
    }

    /// Gives the shared panel back as it was (the page is going away): the
    /// panel is every window's, not this page's.
    func stop() {
        onChange = nil
        let panel = NSColorPanel.shared
        if let previousShowsAlpha {
            panel.setTarget(nil)
            panel.setAction(nil)
            panel.showsAlpha = previousShowsAlpha
        }
        previousShowsAlpha = nil
    }

    @objc private func colorChanged(_ sender: NSColorPanel) {
        onChange?(sender.color)
    }
}
