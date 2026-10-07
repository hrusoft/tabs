import Foundation
import TabsPluginSDK

/// `scroll` and `form-input`: the input verbs that work on the page by script rather than by events.
extension InputVerbs {
    /// Scrolls the document and reports where it landed: the *settled* position, not a snapshot taken
    /// mid-animation. See `scrollScript` for both halves of why that used to be wrong (a smooth page's
    /// animation, and a zero-sized step on a backgrounded pane); neither needs anything from the host.
    ///
    /// Not under `withHostFocusRestored`: a script scroll pulls no focus.
    static let scroll = ControlVerbContribution(
        name: "browser.scroll",
        summary:
            "Scroll the page and report where it landed. Instantaneous even on a smooth-scrolling page, so the reported position is the settled one. Does not scroll a nested scrollable container.",
        arguments: [
            // The wire requires it (the flag's default is the CLI's business), so a wire request
            // without one is refused in the handler in the schema's own words.
            ControlArgument("direction", .string, enumValues: ScrollDirection.allCases.map(\.rawValue), defaultValue: "down"),
            ControlArgument("amount", .number, summary: "Defaults to about one screen.", minimum: 1, placeholder: "px"),
        ], target: .ownedPane(ofTypes: ["browser"]), timeout: quick, command: "scroll", wireType: "scroll",
        resultShape: ["position": ["x": "number", "y": "number"]]
    ) { invocation in
        let pane = try VerbSupport.pane(invocation)
        guard let name = invocation["direction"]?.stringValue, let direction = ScrollDirection(rawValue: name) else {
            throw ControlVerbError("request is missing required field \"direction\"")
        }
        switch await VerbSupport.evalInGuest(pane.page, scrollScript(direction: direction, amount: invocation["amount"]?.doubleValue)) {
        case .failure(let error): throw ControlVerbError(error.message)
        case .success(let position): return .object(["position": position])
        }
    }

    // MARK: form-input

    /// What `fillFocusedScript` reports back; see its doc in PageScripts.swift.
    private enum FillOutcome {
        case none
        case unfillable(ElementDescription?)
        case select(matched: Bool, options: [(value: String, label: String)], length: Int?)
        case set(length: Int, tag: String)
        case editable(length: Int)
        case error(String)

        init(_ fields: [String: JSONValue]) {
            let length = fields["length"]?.intValue.map { Int($0) }
            switch fields["mode"]?.stringValue {
            case "unfillable": self = .unfillable(InputTarget.description(of: fields["element"]))
            case "select":
                var options: [(value: String, label: String)] = []
                if case .array(let listed)? = fields["options"] {
                    options = listed.map { ($0["value"]?.stringValue ?? "", $0["label"]?.stringValue ?? "") }
                }
                self = .select(matched: fields["matched"] == true, options: options, length: length)
            case "set": self = .set(length: length ?? 0, tag: fields["tag"]?.stringValue ?? "")
            case "editable": self = .editable(length: length ?? 0)
            case "error": self = .error(fields["error"]?.stringValue ?? "")
            default: self = .none
            }
        }
    }

    /// `ElementTarget`'s wire shape, for the targets inside `fields`: a ref, a coordinate, or a semantic
    /// match (role, name and selector, at least one, plus an optional nth). Core's own is not visible to a
    /// plugin, and the top-level `target` of the other verbs is composed by core.
    private static let targetSchema: JSONValue = [
        "oneOf": [
            ["type": "object", "properties": ["ref": ["type": "string"]], "required": ["ref"], "additionalProperties": false],
            [
                "type": "object", "properties": ["x": ["type": "number"], "y": ["type": "number"]], "required": ["x", "y"],
                "additionalProperties": false,
            ],
            [
                "type": "object",
                "properties": [
                    "role": ["type": "string"], "name": ["type": "string"], "selector": ["type": "string"], "nth": ["type": "number"],
                ],
                "anyOf": [
                    ["type": "object", "required": ["role"]], ["type": "object", "required": ["name"]],
                    ["type": "object", "required": ["selector"]],
                ],
                "additionalProperties": false,
            ],
        ]
    ]

    /// Fills fields in order, replacing whatever each already contains. Sequential rather than parallel
    /// because focus is a single shared resource — filling two fields at once would race for it — and a
    /// field that fails is reported and skipped rather than aborting the rest of the form.
    ///
    /// Every value is written in-script by `fillFocusedScript`: nothing here types characters, because
    /// a keystroke can't carry `\n` or any other key-less character (`type` keeps the keystrokes because
    /// its contract is keystrokes, and it refuses such text).
    ///
    /// The response reports what each element actually holds after its fill: `fields` carries
    /// `{index, length}` per filled field, read back from the element itself, so a caller can check
    /// `length` against the value it sent in one glance. An `<input>`/`<textarea>` whose read-back length
    /// differs from the requested value's goes to `errors` instead of counting as filled: the engine
    /// sanitizes on write (a single-line `<input>` strips newlines), and "the field doesn't hold what
    /// you sent" must never report as success. Contenteditable is exempt from that strict check: its
    /// `length` is measured on `innerText`, which normalizes blank lines, so a byte-exact comparison
    /// would fail legitimate fills. Lengths are JavaScript's, UTF-16 code units, as the page reads them.
    static let formInput = ControlVerbContribution(
        name: "browser.formInput",
        summary: "Set field values verbatim (multiline safe), replacing existing contents. Exits non-zero when any field failed.",
        arguments: [
            ControlArgument(
                "fields", .json, required: true, summary: "A JSON array of {target, value} pairs.",
                schema: [
                    "type": "array",
                    "items": [
                        "type": "object", "properties": ["target": targetSchema, "value": ["type": "string"]],
                        "required": ["target", "value"], "additionalProperties": false,
                    ],
                ])
        ], target: .ownedPane(ofTypes: ["browser"]), timeout: read, command: "form-input", wireType: "formInput",
        resultShape: [
            "filled": "number", "fields": [["index": "number", "length": "number"]], "errors": [["index": "number", "error": "string"]],
        ]
    ) { invocation in
        let pane = try VerbSupport.pane(invocation)
        guard case .array(let requested)? = invocation["fields"] else { throw ControlVerbError("request.fields must be an array") }
        let input = PageInput(page: pane.page)
        let targeting = TargetingInput(page: pane.page)
        return try await mounted {
            try await input.withHostFocusRestored {
                var filled = 0
                var fields: [JSONValue] = []
                var errors: [JSONValue] = []
                func fail(_ index: Int, _ message: String) {
                    errors.append(.object(["index": .int(Int64(index)), "error": .string(message)]))
                }
                for (index, field) in requested.enumerated() {
                    let value = field["value"]?.stringValue ?? ""
                    let target: ElementTarget
                    switch InputTarget.parse(field["target"]) {
                    case .success(let parsed): target = parsed
                    case .failure(let failure): fail(index, failure.message); continue
                    }
                    if let failure = try await targeting.focusTypingTarget(target) {
                        fail(index, failure.message)
                        continue
                    }
                    // The script catches its own throws; an error here means the page couldn't
                    // run script at all (navigated away mid-fill, an error page).
                    let outcome: [String: JSONValue]
                    switch await VerbSupport.evalOutcomeInGuest(pane.page, fillFocusedScript(value)) {
                    case .failure(let failure): fail(index, failure.message); continue
                    case .success(let run): outcome = run
                    }
                    let sent = value.utf16.count
                    func filledField(_ length: Int) {
                        filled += 1
                        fields.append(.object(["index": .int(Int64(index)), "length": .int(Int64(length))]))
                    }
                    switch FillOutcome(outcome) {
                    case .select(matched: true, _, let length): filledField(length ?? sent)
                    case .select(matched: false, let options, _):
                        // Both halves of each option, since both are accepted: its visible label, and its value
                        // where that differs: `"Red" (r)`. Listing values alone named none of the words a
                        // caller actually sees.
                        let listed =
                            options.isEmpty
                            ? ""
                            : " (options: "
                                + options.map { option in
                                    !option.label.isEmpty && option.label != option.value
                                        ? "\(jsonQuoted(option.label)) (\(option.value))" : jsonQuoted(option.value)
                                }.joined(separator: ", ") + ")"
                        fail(index, "no option matching \(jsonQuoted(value))\(listed)")
                    case .set(let length, let tag):
                        if length == sent {
                            filledField(length)
                        } else {
                            let why =
                                tag == "input" && value.unicodeScalars.contains(where: { $0 == "\n" || $0 == "\r" })
                                ? "a single-line <input> cannot hold newlines; target a <textarea> instead"
                                : "the element rewrote or refused part of the value"
                            fail(index, "the field holds \(length) of the \(sent) characters sent — \(why)")
                        }
                    case .editable(let length): filledField(length)
                    case .unfillable(let element):
                        fail(
                            index,
                            "\(Targeting.describeForError(element)) is not a fillable field — use click for buttons, checkboxes and radios"
                        )
                    case .error(let message): fail(index, "could not set the value: \(message)")
                    case .none: fail(index, "the target did not leave a field focused, so there is nothing to fill")
                    }
                }
                var result: [String: JSONValue] = ["filled": .int(Int64(filled))]
                if !fields.isEmpty { result["fields"] = .array(fields) }
                if !errors.isEmpty { result["errors"] = .array(errors) }
                return .object(result)
            }
        }
    }
}
