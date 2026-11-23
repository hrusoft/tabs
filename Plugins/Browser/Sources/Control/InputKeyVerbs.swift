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
        let target = try InputTarget.parse(invocation["target"]).orThrow()
        let text = invocation["text"]?.stringValue ?? ""
        if let untypeable = untypeableCharError(text) { throw ControlVerbError(untypeable) }
        let input = PageInput(page: pane.page)
        return try await mounted {
            try await input.withHostFocusRestored {
                if let failure = try await TargetingInput(page: pane.page).focusTypingTarget(target) {
                    throw ControlVerbError(failure.message)
                }
                // One undo step, the Enter's line break included (a textarea's).
                try await pane.page.asOneUndoStep {
                    try await input.send(typingEvents(text))
                    if invocation["submit"] == true { try await input.send(keystrokeEvents("Enter")) }
                }
                return .null
            }
        }
    }

    /// Letters whose Command chord is an Edit-menu command (select all, undo, redo, cut, copy, paste). A
    /// synthesized chord never runs one: WebKit hands a key its page didn't handle back to the app to try
    /// as a shortcut, and the app drops a key the system didn't deliver (`TabsApplication`). So the chord
    /// is delivered faithfully and does nothing to the selection, the clipboard or the undo stack, which
    /// is the silent-corruption trap this note exists to break: the verb answered `ok: true`, a follow-up
    /// Backspace also answered `ok: true`, and between them a field lost one character instead of all of
    /// them. Control chords get no note: ⌃A, ⌃V and ⌃Y are the text system's own bindings (line start,
    /// page down, yank), which act in the page as on a keyboard.
    ///
    /// The chord is **not refused**. A page's own JS shortcut handlers do fire for it — measured — so
    /// refusing would break the legitimate case (an app that binds Cmd+K) to protect the illegitimate
    /// one. Reporting alongside the success is what makes the answer honest without taking a capability
    /// away.
    private static let editingChordKeys: Set<String> = ["a", "c", "v", "x", "z", "y"]

    static func editingChordNote(key: String, modifiers: [KeyModifier]) -> String? {
        guard modifiers.contains(.meta), editingChordKeys.contains(key.lowercased()) else { return nil }
        return
            "the page's own handlers saw the keystroke, but a synthesized chord never runs the browser's Edit-menu commands (select all, undo, redo, cut, copy, paste) — the selection, the clipboard and the undo stack are unchanged. Use --command (select-all, undo, redo, delete) for those, or form-input to replace a field's value"
    }

    /// One key (or a chord), or one of the browser's own editing commands: exactly one of the two.
    static let key = ControlVerbContribution(
        name: "browser.key",
        summary:
            "Send one key (Enter, Escape, Tab, ArrowLeft, a), or run one of the browser's own editing commands with --command. A Command chord cannot reach those — see --command.",
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
                    "Run an editing command through the browser itself, which a synthesized Cmd+A/Cmd+Z never reaches. Acts on whatever the page has focused. Clipboard commands are deliberately not offered.",
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
        // Refused before anything reaches the page: a key the keyboard doesn't have would send nothing.
        if let keyName, named, !canSendKeystroke(keyName) { throw ControlVerbError(unknownKeyError(keyName)) }
        let input = PageInput(page: pane.page)
        return try await mounted {
            try await input.withHostFocusRestored {
                if commanded { return try await run(command: invocation["command"], in: pane) }
                let held = modifiers(of: invocation["modifiers"])
                let pressed = keyName ?? ""
                try await pane.page.asOneUndoStep { try await input.send(keystrokeEvents(pressed, modifiers: held)) }
                guard let note = editingChordNote(key: pressed, modifiers: held) else { return .null }
                return .object(["note": .string(note)])
            }
        }
    }

    /// Why `key` refuses a key it can't send (`canSendKeystroke`), and every key it takes.
    static func unknownKeyError(_ key: String) -> String {
        "unknown key \(jsonQuoted(key)) — one of \(USKeyboard.keyNames) (names are case-sensitive), or a single character such as a, A, ! or é"
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
        // Asked of the pane's undo history itself: the page's `execCommand('undo')` answers true with
        // nothing to undo. The history is the page's whole one — the last edit anywhere on it — and a
        // navigation clears it.
        if command == .undo || command == .redo {
            let manager = pane.page.webView.undoManager
            if (command == .undo ? manager?.canUndo : manager?.canRedo) != true {
                throw ControlVerbError("there is nothing to \(command.rawValue) on this page")
            }
        }
        // An edit (delete) is one undo step of its own; undo and redo run outside any group, as they must.
        let script = editingCommandScript(command.execName)
        let outcome =
            command == .undo || command == .redo
            ? try await VerbSupport.evalOutcomeInGuest(pane.page, script).orThrow()
            : try await pane.page.asOneUndoStep { try await VerbSupport.evalOutcomeInGuest(pane.page, script).orThrow() }
        guard outcome["applied"] == true else {
            let focused = InputTarget.description(of: outcome["focused"])
            let place = focused.map { " on \(Targeting.describeForError($0))" } ?? " (nothing is focused)"
            throw ControlVerbError("the page refused the \(command.rawValue) command\(place)")
        }
        var result: [String: JSONValue] = ["command": .string(command.rawValue)]
        // What the command changed: for an undo or a redo, the field whose edit it stepped, which needn't be the
        // focused one (`editingCommandScript`).
        if let element = InputTarget.description(of: outcome["element"]) { result["element"] = InputTarget.json(element) }
        return .object(result)
    }
}
