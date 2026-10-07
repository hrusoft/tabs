import Foundation
import TabsPluginSDK

/// `type` and `key`: real keystrokes into the page (which events a keystroke is lives in
/// `Keystrokes`).
extension InputVerbs {
    /// Characters `type` cannot deliver: a key-less control character (every C0 control, newline
    /// included, and DEL) has no keystroke to carry it, so `type` refuses such text up front rather than
    /// silently sending fewer keystrokes than asked. The error names the exact character and where
    /// multiline values should go instead. Indexed in UTF-16 code units.
    static func untypeableCharError(_ text: String) -> String? {
        for (index, unit) in text.utf16.enumerated() {
            if unit >= 0x20 && unit != 0x7f { continue }
            let described: String
            switch unit {
            case 10: described = "a newline"
            case 13: described = "a carriage return"
            case 9: described = "a tab"
            default:
                let hex = String(unit, radix: 16)
                described = "control character 0x\(String(repeating: "0", count: max(0, 2 - hex.count)))\(hex)"
            }
            return
                "text contains \(described) at index \(index), which keystrokes cannot enter — use form-input to set a multiline value verbatim, or key (e.g. --key Enter, --key Tab) to press the key itself"
        }
        return nil
    }

    /// Types `text` at the target, then optionally presses Enter (a full key press: a plain form submits
    /// once, a textarea gains one line break). Refused text is refused before anything is focused.
    static let type = ControlVerbContribution(
        name: "browser.type", summary: "Type text at the target. Appends — use form-input to replace a value.",
        arguments: [
            ControlArgument(
                "text", .string, required: true,
                summary:
                    "Printable text only — a newline/tab/control character is refused (keystrokes cannot carry it); use form-input for multiline values."
            ),
            ControlArgument(
                "submit", .bool,
                summary:
                    "Press Enter after the text — a full keydown/keypress/keyup, so a plain form submits as it would for a physical Enter."
            ),
        ], target: .ownedPane(ofTypes: ["browser"]), timeout: read, command: "type", wireType: "type",
        composition: .elementTarget
    ) { invocation in
        let pane = try VerbSupport.pane(invocation)
        let target = try elementTarget(invocation["target"])
        let text = invocation["text"]?.stringValue ?? ""
        if let untypeable = untypeableCharError(text) { throw ControlVerbError(untypeable) }
        let input = PageInput(page: pane.page)
        return try await mounted {
            try await input.withHostFocusRestored {
                if let failure = try await TargetingInput(page: pane.page).focusTypingTarget(target) {
                    throw ControlVerbError(failure.message)
                }
                try await input.send(typingEvents(text))
                if invocation["submit"] == true { try await input.send(keystrokeEvents("Enter")) }
                return .null
            }
        }
    }

    /// Letters the browser claims for its own editing commands under meta/control. A chord naming one is
    /// delivered faithfully and still does nothing to the selection or the clipboard, which is the
    /// silent-corruption trap this note exists to break: the verb answered `ok: true`, a follow-up
    /// Backspace also answered `ok: true`, and between them a field lost one character instead of all of
    /// them.
    ///
    /// The chord is **not refused**. A page's own JS shortcut handlers do fire for it — measured — so
    /// refusing would break the legitimate case (an app that binds Cmd+K) to protect the illegitimate
    /// one. Reporting alongside the success is what makes the answer honest without taking a capability
    /// away. (Measured on WebKit too: a synthesized ⌘A reaches the page as a keydown with `metaKey` and
    /// leaves the selection alone, so the premise holds.)
    private static let editingChordKeys: Set<String> = ["a", "c", "v", "x", "z", "y"]

    static func editingChordNote(key: String, modifiers: [KeyModifier]) -> String? {
        guard modifiers.contains(.meta) || modifiers.contains(.control), editingChordKeys.contains(key.lowercased()) else { return nil }
        return
            "the keystroke was delivered and the page's own handlers saw it, but the browser's built-in editing commands do not respond to a synthesized chord — the selection and clipboard are unchanged. Use --command (select-all, undo, redo, delete) for those, or form-input to replace a field's value"
    }

    /// One key (or a chord), or one of the browser's own editing commands: exactly one of the two.
    static let key = ControlVerbContribution(
        name: "browser.key",
        summary:
            "Send one key (Enter, Escape, Tab, ArrowLeft, a), or run one of the browser's own editing commands with --command. A modifier chord cannot reach those — see --command.",
        arguments: [
            ControlArgument("key", .string, summary: "The key to press, e.g. Enter, Escape, Tab, ArrowLeft, a."),
            ControlArgument(
                "modifiers", .csv,
                summary:
                    "Keys held during the press. With meta or control held no keypress is sent — the chord produces no character, as best measured of a physical keyboard on macOS.",
                placeholder: "shift,control,alt,meta",
                schema: ["type": "array", "items": ["enum": .array(KeyModifier.allCases.map { .string($0.rawValue) })]]),
            ControlArgument(
                "command", .string,
                summary:
                    "Run an editing command through the browser itself, which a synthesized Cmd+A/Cmd+Z cannot reach. Acts on whatever the page has focused. Clipboard commands are deliberately not offered.",
                enumValues: EditingCommand.allCases.map(\.rawValue)),
        ], target: .ownedPane(ofTypes: ["browser"]), timeout: quick, command: "key", wireType: "key",
        resultShape: ["command": "string", "element": elementShape, "note": "string"]
    ) { invocation in
        let pane = try VerbSupport.pane(invocation)
        let keyName = invocation["key"]?.stringValue
        let named = keyName.map { !$0.isEmpty } ?? false
        let commanded = invocation["command"] != nil
        if named == commanded {
            throw ControlVerbError(
                named
                    ? "pass only one of key or command — a keystroke and an editing command are different things"
                    : "key needs one of key (a keystroke) or command (\(EditingCommand.allCases.map(\.rawValue).joined(separator: ", ")))")
        }
        let input = PageInput(page: pane.page)
        return try await mounted {
            try await input.withHostFocusRestored {
                if commanded { return try await run(command: invocation["command"], in: pane) }
                let held = modifiers(of: invocation["modifiers"])
                let pressed = keyName ?? ""
                try await input.send(keystrokeEvents(pressed, modifiers: held))
                guard let note = editingChordNote(key: pressed, modifiers: held) else { return .null }
                return .object(["note": .string(note)])
            }
        }
    }

    /// The modifiers of a request (the schema admits only the four).
    private static func modifiers(of wire: JSONValue?) -> [KeyModifier] {
        guard case .array(let items)? = wire else { return [] }
        return items.compactMap { $0.stringValue.flatMap(KeyModifier.init(rawValue:)) }
    }

    /// Runs an editing command in the page, on whatever it has focused, exactly as the menu item would
    /// (`document.execCommand`: it acts on the page's own idea of what is focused, so the page needn't
    /// hold the window's keyboard).
    private static func run(command wire: JSONValue?, in pane: BrowserPane) async throws -> JSONValue {
        guard let name = wire?.stringValue, let command = EditingCommand(rawValue: name) else {
            throw ControlVerbError(
                "unknown command \(jsonQuoted(wire?.stringValue ?? "")) — one of \(EditingCommand.allCases.map(\.rawValue).joined(separator: ", "))"
            )
        }
        let outcome: [String: JSONValue]
        switch await VerbSupport.evalOutcomeInGuest(pane.page, editingCommandScript(command.execName)) {
        case .failure(let failure): throw ControlVerbError(failure.message)
        case .success(let value): outcome = value
        }
        let element = InputTarget.description(of: outcome["element"])
        guard outcome["applied"] == true else {
            let place = element.map { " on \(Targeting.describeForError($0))" } ?? " (nothing is focused)"
            throw ControlVerbError("the page refused the \(command.rawValue) command\(place)")
        }
        var result: [String: JSONValue] = ["command": .string(command.rawValue)]
        if let element { result["element"] = InputTarget.json(element) }
        return .object(result)
    }
}
