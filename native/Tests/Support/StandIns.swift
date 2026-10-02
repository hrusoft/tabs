import AppKit
import TabsPluginSDK

@testable import TabsCore

/// Content for the tests whose subject is core or the shell, not a shipped
/// plugin: a pane to lay out, focus, type into and drag about, and the
/// contributions a plugin makes that no shipped plugin makes (a checked menu
/// command, a steady pane signal). Two in-process plugins:
///
/// - `text`: a focusable text view. Its config is `{text}`, its title the first
///   line; a command (⇧⌘D, Edit ▸ Insert Marker) applies only to it, and a
///   checked one (View ▸ Wrap Lines) keeps a setting.
/// - `inert`: a pane that takes no keyboard and does nothing, and a steady
///   pane signal (`inert.status`).
///
/// `UIDriver` runs them beside the shipped plugins when a layout uses either
/// type (or when asked to), and a test using its own in-process plugins adds
/// `StandIns.candidates()` itself if it wants these too.
@MainActor
enum StandIns {
    /// The text pane's marker command inserts this.
    static let marker = "[marker]"

    static func candidates() -> [PluginCandidate] {
        [
            TestSupport.candidate(TestSupport.manifest("text", contentTypes: ["text"])) { TextPlugin() },
            TestSupport.candidate(TestSupport.manifest("inert", contentTypes: ["inert"])) { InertPlugin() },
        ]
    }
}

struct TextSettings: PluginSettingsValue {
    var wrapsLines = true
}

@MainActor
final class TextPlugin: NSObject, TabsPlugin {
    func activate(_ context: any PluginContext) throws {
        let settings = context.settings(TextSettings.self)
        context.register(
            ContentTypeContribution(id: "text", displayName: "Text", icon: .symbol("text.alignleft")) { pane in TextPane(pane: pane) })
        context.register(
            CommandContribution(
                id: "text.insertMarker", title: "Insert Marker", summary: "Insert a marker at the cursor.", menu: .edit,
                defaultChord: KeyChord("d", [.command, .shift]), appliesTo: "text"
            ) { invocation in
                invocation.pane(as: TextPane.self)?.insert(StandIns.marker)
            })
        context.register(
            CommandContribution(
                id: "text.toggleWrap", title: "Wrap Lines", summary: "Switch line wrapping.", menu: .view,
                isChecked: { settings.value.wrapsLines },
                perform: { _ in settings.update { $0.wrapsLines.toggle() } }
            ))
    }
}

@MainActor
final class InertPlugin: NSObject, TabsPlugin {
    func activate(_ context: any PluginContext) throws {
        context.register(TestSupport.contentType("inert"))
        context.register(
            PaneSignalContribution(
                id: "inert.status", label: "Status", icon: .symbol("circle"), color: .accent, pulse: nil, lifetime: .untilWithdrawn,
                tooltip: "A status",
                setting: .init(title: "Status indicator", detail: "Show a status icon on a pane while it has one.")))
    }
}

/// A focusable text view as a pane: what a person types into.
@MainActor
final class TextPane: NSObject, PaneController, NSTextViewDelegate {
    let view: NSView
    private let textView: NSTextView
    private let pane: any PaneContext

    init(pane: any PaneContext) {
        self.pane = pane
        let scroll = NSTextView.scrollableTextView()
        textView = scroll.documentView as! NSTextView
        view = scroll
        super.init()
        textView.string = pane.initialConfig["text"]?.stringValue ?? ""
        textView.isRichText = false
        textView.delegate = self
        retitle()
    }

    func insert(_ text: String) {
        textView.insertText(text, replacementRange: textView.selectedRange())
    }

    func focus() {
        view.window?.makeFirstResponder(textView)
    }

    func currentConfig() -> JSONValue {
        ["text": .string(textView.string)]
    }

    func textDidChange(_ notification: Notification) {
        retitle()
        pane.configDidChange()
    }

    private func retitle() {
        pane.setTitle(textView.string.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? "Untitled")
    }
}
