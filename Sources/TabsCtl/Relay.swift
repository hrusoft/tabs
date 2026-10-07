import Foundation

/// What `tabs-ctl` does besides moving bytes: argv into a request, a response into an exit
/// code. It knows no command — no flag types, no wire shapes, no validation beyond reading
/// argv. The app resolves the command, coerces the flags, validates the request and answers
/// (`ControlEnvelope.swift`, `ControlDispatcher.swift` in TabsCore). `tabs-ctl capabilities`
/// lists the commands and `tabs-ctl describe --capability <name>` documents one; both are
/// ordinary commands, answered by the app like any other.
///
/// The relay ships inside the app it talks to (Contents/Helpers/tabs-ctl), so the two always
/// come from the same build: nothing here guards against a different app's wire shape.
enum Relay {
    /// A flag's value: the text after it, or `true` for a bare flag.
    enum Value: Equatable {
        case text(String)
        case present
    }

    /// `--flag value`, `--flag=value` (the only way to pass a value that itself starts with
    /// `--`, e.g. typing "--help" into a page), or a bare `--flag` (`true`). A word that is
    /// neither a flag nor a flag's value is ignored; a repeated flag keeps its last value.
    static func flags(_ arguments: [String]) -> [String: Value] {
        var flags: [String: Value] = [:]
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            index += 1
            guard argument.hasPrefix("--") else { continue }
            let name = argument.dropFirst(2)
            if let equals = name.firstIndex(of: "=") {
                flags[String(name[..<equals])] = .text(String(name[name.index(after: equals)...]))
            } else if index < arguments.count, !arguments[index].hasPrefix("--") {
                flags[String(name)] = .text(arguments[index])
                index += 1
            } else {
                flags[String(name)] = .present
            }
        }
        return flags
    }

    /// The request line: `{command, args, paneId, cwd}`. `cwd` lets the app resolve a
    /// path-typed flag (`--out`, …) against this shell's directory: the app runs elsewhere,
    /// and only its spec for the command knows which flags are paths.
    static func envelope(command: String, flags: [String: Value], paneId: String, cwd: String) throws -> Data {
        let args = flags.mapValues { value -> Any in
            switch value {
            case .text(let text): text
            case .present: true
            }
        }
        let object: [String: Any] = ["command": command, "args": args, "paneId": paneId, "cwd": cwd]
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
    }

    /// The exit code for a response: 0 only for `ok: true` with nothing inside it failed.
    ///
    /// A batch answers `ok: true` as long as it ran, so that the transcript it collected
    /// survives alongside a failed step; a failed step still fails the exit code, under
    /// `--continue-on-error` too, so `&&` in a shell means what it looks like (skipped steps
    /// carry no `ok` and only ever follow a failed one). The same for a verb reporting
    /// per-part failures on an `ok: true` answer (form-input's `errors`): a non-empty
    /// `errors` fails the exit code, so `&&` means every part landed.
    static func exitCode(for response: Any) -> Int32 {
        guard let object = response as? [String: Any], isTrue(object["ok"]) else { return 1 }
        let result = object["result"] as? [String: Any]
        if let steps = result?["steps"] as? [Any], steps.contains(where: { isFalse(($0 as? [String: Any])?["ok"]) }) { return 1 }
        if let errors = result?["errors"] as? [Any], !errors.isEmpty { return 1 }
        return 0
    }

    /// The first line of what the app sent, or all of it when the connection closed before a
    /// newline. The app answers on that line: its socket serves any number of requests per
    /// connection and closes only when the client does, so waiting for the close would hang.
    static func firstLine(_ data: Data) -> Data {
        guard let newline = data.firstIndex(of: UInt8(ascii: "\n")) else { return data }
        return data[data.startIndex..<newline]
    }

    /// `{"ok":false,"error":…}`, the answer for anything that goes wrong before the app does.
    static func failure(_ message: String) -> Data {
        let object: [String: Any] = ["ok": false, "error": message]
        return (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes]))
            ?? Data(#"{"error":"tabs-ctl failed","ok":false}"#.utf8)
    }

    /// JSON's `true` or `false`, not a number that bridges to one.
    private static func boolean(_ value: Any?) -> Bool? {
        guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { return nil }
        return number.boolValue
    }

    private static func isTrue(_ value: Any?) -> Bool { boolean(value) == true }
    private static func isFalse(_ value: Any?) -> Bool { boolean(value) == false }
}
