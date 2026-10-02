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
    private let onChange: @MainActor () -> Void
    private let enabledAtLaunch: [PluginID: Bool]

    init(host: PluginHost, fingerprint: String?, onChange: @escaping @MainActor () -> Void) {
        self.host = host
        self.records = host.records
        self.fingerprint = fingerprint ?? "none"
        self.onChange = onChange
        self.enabledAtLaunch = Dictionary(host.records.map { ($0.id, $0.userEnabled) }, uniquingKeysWith: { a, _ in a })
    }

    func setEnabled(_ enabled: Bool, for id: PluginID) {
        host.setUserEnabled(enabled, for: id)
        records = host.records
        onChange()
    }

    var needsRelaunch: Bool {
        records.contains { enabledAtLaunch[$0.id] != $0.userEnabled }
    }
}

struct PluginsView: View {
    @Bindable var model: PluginsModel

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
                            .foregroundStyle(record.state.isProblem ? .red : .primary)
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
                        .font(.caption).foregroundStyle(.orange)
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

@MainActor
func makePluginsWindow(model: PluginsModel) -> NSWindowController {
    let window = NSWindow(contentViewController: NSHostingController(rootView: PluginsView(model: model)))
    window.title = "Plugins"
    window.setContentSize(NSSize(width: 760, height: 300))
    window.isReleasedWhenClosed = false
    return NSWindowController(window: window)
}

/// Settings for `runtime`: its pages, every kind of pane signal's switch, and its shortcuts.
@MainActor
func makeSettingsWindow(for runtime: CoreRuntime) -> NSWindowController {
    makeSettingsWindow(
        pages: runtime.settingsPages(), settings: runtime.settings, signals: runtime.signals.settingKinds, shortcuts: runtime.shortcuts)
}

/// Settings: core's Panes & Tabs and Keyboard pages, then every enabled plugin's pages, then
/// core's AI page — the Electron window's order (General, Panes & Tabs and Keyboard first,
/// content types between, AI last). `skills` is where the AI page installs the bundled skill:
/// the running app's, into the real home, unless a test says otherwise.
///
/// A toolbar-tab Settings window, as Safari's and Terminal's: the selected page names the
/// window, and the window takes each page's size (`SettingsPageSizing`) as its tab is chosen.
@MainActor
func makeSettingsWindow(
    pages: [Owned<SettingsPageContribution>], settings: SettingsStore, signals: [SignalKind], shortcuts: Shortcuts,
    skills: SkillInstaller = .standard()
) -> NSWindowController {
    let keyboard = KeyboardSettingsModel(shortcuts: shortcuts)
    var tabs: [(title: String, symbolName: String, view: NSView)] = [
        (
            "Panes & Tabs", "rectangle.split.2x1",
            NSHostingView(rootView: PaneSettingsView(model: PaneSettingsModel(store: settings, signals: signals)))
        ),
        (
            "Keyboard", "keyboard",
            KeyboardSettingsHostingView(rootView: KeyboardSettingsView(model: keyboard, keys: KeyboardSettingsKeys(model: keyboard)))
        ),
    ]
    tabs += pages.map { ($0.value.title, $0.value.symbolName, $0.value.makeView()) }
    tabs.append(("AI", "sparkles", NSHostingView(rootView: AiSettingsView(model: AiSettingsModel(installer: skills)))))

    let controller = NSTabViewController()
    controller.tabStyle = .toolbar
    for tab in tabs {
        let page = NSViewController()
        page.view = tab.view
        page.title = tab.title
        page.preferredContentSize = NSSize(width: SettingsPageContribution.width, height: SettingsPageSizing.height(of: tab.view))
        let item = NSTabViewItem(viewController: page)
        item.label = tab.title
        item.image = NSImage(systemSymbolName: tab.symbolName, accessibilityDescription: nil)
        controller.addTabViewItem(item)
    }
    let window = NSWindow(contentViewController: controller)
    window.styleMask.remove(.resizable)
    window.isReleasedWhenClosed = false
    SettingsPageSizing.fit(controller, in: window)
    window.center()
    return NSWindowController(window: window)
}

/// How big the Settings window is on each tab. Every page is `SettingsPageContribution.width`
/// wide; a page is as tall as its content, up to `maxHeight` or what the screen leaves, and a
/// longer one scrolls in that (its grouped form does). The size is each tab's
/// `preferredContentSize`, which `NSTabViewController` animates the window to on a switch.
@MainActor
enum SettingsPageSizing {
    /// The tallest a page gets on a screen with room for it.
    static let maxHeight: CGFloat = 640
    /// Kept clear above and below the window on a short screen.
    static let screenMargin: CGFloat = 40

    /// Caps every tab's height (each one's content height, from `height(of:)`) to what
    /// `window`'s screen leaves, and gives the window the selected tab's size.
    static func fit(_ controller: NSTabViewController, in window: NSWindow) {
        let chrome = window.frame.height - window.contentLayoutRect.height
        let screen = (window.screen ?? NSScreen.main)?.visibleFrame.height ?? .greatestFiniteMagnitude
        let tallest = max(min(maxHeight, screen - chrome - 2 * screenMargin), 200)
        for item in controller.tabViewItems {
            guard let page = item.viewController else { continue }
            page.preferredContentSize.height = min(page.preferredContentSize.height, tallest)
        }
        let selected = controller.selectedTabViewItemIndex
        if controller.tabViewItems.indices.contains(selected), let page = controller.tabViewItems[selected].viewController {
            window.setContentSize(page.preferredContentSize)
        }
    }

    /// The page's content height at the page width (a SwiftUI page pins that width itself),
    /// measured before it's in a window; a page that can't say (frame-based, no constraints)
    /// takes the most it may.
    static func height(of page: NSView) -> CGFloat {
        let width = page.widthAnchor.constraint(equalToConstant: SettingsPageContribution.width)
        width.isActive = true
        defer { width.isActive = false }
        let fitting = page.fittingSize.height
        return fitting > 0 ? fitting.rounded(.up) : .greatestFiniteMagnitude
    }
}
