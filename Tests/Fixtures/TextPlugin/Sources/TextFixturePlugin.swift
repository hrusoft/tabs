import AppKit
import TabsPluginSDK

/// Test fixture: a well-behaved plugin bundle for the tests whose subject is
/// core or the shell across a real image boundary, so none of them needs a
/// shipped plugin. A text pane (config `{text}`, titled by its first line), a
/// command for it with a default chord, and a verb that reads it.
///
/// The end-to-end tests launch the app with it (`TABS_E2E_PLUGINS`); the app
/// tier loads it from its fixtures directory.
@MainActor
final class TextFixturePlugin: NSObject, TabsPlugin {
    func activate(_ context: any PluginContext) throws {
        context.register(
            ContentTypeContribution(id: "fixture-text", displayName: "Fixture Text", icon: .symbol("text.alignleft")) { pane in
                FixtureTextPane(pane: pane)
            })
        context.register(
            CommandContribution(
                id: "fixture-text.insertMarker", title: "Insert Marker", summary: "Insert a marker at the cursor.", menu: .edit,
                defaultChord: KeyChord("d", [.command, .shift]), appliesTo: "fixture-text"
            ) { invocation in
                invocation.pane(as: FixtureTextPane.self)?.insert("[marker]")
            })
        context.register(
            ControlVerbContribution(
                name: "fixture-text.text", summary: "The pane's text, as its own controller holds it",
                target: .pane(ofTypes: ["fixture-text"])
            ) { invocation in
                guard let pane = invocation.pane(as: FixtureTextPane.self) else { throw ControlVerbError("not a fixture-text pane") }
                return ["text": .string(pane.text)]
            })
    }
}

/// A focusable text view as a pane: what a person types into.
@MainActor
final class FixtureTextPane: NSObject, PaneController, NSTextViewDelegate {
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
        textView.setAccessibilityIdentifier("fixture-text-view")
        retitle()
    }

    var text: String { textView.string }

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
