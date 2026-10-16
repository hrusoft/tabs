import AppKit
import SwiftUI
import TabsCore
import TabsPluginSDK

@MainActor
@Observable
final class PluginsModel {
    private(set) var records: [PluginRecord]
    let fingerprint: String
    private let host: PluginHost
    private let enabledAtLaunch: [PluginID: Bool]

    init(host: PluginHost, fingerprint: String?) {
        self.host = host
        self.records = host.records
        self.fingerprint = fingerprint ?? "none"
        self.enabledAtLaunch = Dictionary(host.records.map { ($0.id, $0.userEnabled) }, uniquingKeysWith: { a, _ in a })
    }

    func setEnabled(_ enabled: Bool, for id: PluginID) {
        host.setUserEnabled(enabled, for: id)
        records = host.records
    }

    var needsRelaunch: Bool {
        records.contains { enabledAtLaunch[$0.id] != $0.userEnabled }
    }
}

struct PluginsView: View {
    @Bindable var model: PluginsModel
    @Environment(\.appTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Table(model.records) {
                TableColumn("Plugin") { record in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(record.displayName).fontWeight(.medium)
                        Text(record.id.rawValue).font(.caption).foregroundStyle(.secondary)
                    }
                }
                .width(min: 110, ideal: 130)
                TableColumn("State") { record in
                    VStack(alignment: .leading, spacing: 2) {
                        Label(record.state.label, systemImage: symbol(for: record.state))
                            .foregroundStyle(
                                record.state.isProblem ? AnyShapeStyle(Color(nsColor: theme.bellAlert)) : AnyShapeStyle(.primary))
                        if let detail = record.state.detail {
                            Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(4)
                        }
                        ForEach(record.notes, id: \.self) { note in
                            Text(note).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                        }
                    }
                }
                .width(min: 200, ideal: 300)
                TableColumn("Contributes") { record in
                    Text(summary(record.contributionCounts)).font(.caption).foregroundStyle(.secondary)
                }
                .width(min: 120, ideal: 180)
                TableColumn("Enabled") { record in
                    Toggle(
                        "",
                        isOn: Binding(
                            get: { record.userEnabled },
                            set: { model.setEnabled($0, for: record.id) }
                        )
                    )
                    .labelsHidden()
                    .disabled(!record.canDisable)
                }
                .width(60)
            }
            Divider()
            HStack {
                Text("Shared-ABI fingerprint \(model.fingerprint)").font(.caption.monospaced()).foregroundStyle(.secondary)
                Spacer()
                if model.needsRelaunch {
                    Text("Creation buttons updated now; loading changes apply at next launch.")
                        .font(.caption).foregroundStyle(Color(nsColor: theme.accent))
                }
            }
            .padding(8)
        }
        .frame(minWidth: 640, minHeight: 240)
    }

    private func symbol(for state: PluginState) -> String {
        switch state {
        case .active: "checkmark.circle"
        case .disabled: "pause.circle"
        case .failed, .rejected: "exclamationmark.triangle"
        }
    }

    private func summary(_ counts: [String: Int]) -> String {
        counts.sorted { $0.key < $1.key }
            .map { "\($0.value) \($0.key.replacingOccurrences(of: "tabs.", with: ""))" }
            .joined(separator: ", ")
    }
}

/// The Plugins window, in the app's theme (`themes`).
@MainActor
func makePluginsWindow(model: PluginsModel, themes: Themes) -> NSWindowController {
    let window = NSWindow(contentViewController: NSHostingController(rootView: ThemedRoot(themes) { PluginsView(model: model) }))
    window.paint(with: themes)
    window.title = "Plugins"
    window.setContentSize(NSSize(width: 760, height: 300))
    window.isReleasedWhenClosed = false
    return NSWindowController(window: window)
}
