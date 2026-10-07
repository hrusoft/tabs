import AppKit

/// Which key events make up one keystroke — the rules `key` and `type` share.
/// A `WKWebView` takes `NSEvent`s, and the character comes *with* the key-down:
/// the web view hands it to the text input system, which inserts it. Measured on
/// a real page (an event-logging fixture, in a window that was never shown):
///
/// - **A key-down alone produces `keydown`, `keypress`, `beforeinput`, `input`**
///   for a printable key, so a text input gets exactly one character and there
///   is no separate character event to send (sending one too would type it twice).
/// - **Enter is the same**: a key-down with the return character submits a plain
///   form exactly once (from Enter's `keypress`) and gives a textarea exactly one
///   line break.
/// - **A capital arrives with Shift** only if the event says so: `H` with the
///   shift flag reports `key: "H", shiftKey: true`. Symbols that need Shift on a
///   US keyboard (`!`, `+`) get it here too, since the event is what a keyboard
///   would send.
/// - **A key with no character** (F5, an arrow, Escape) is a key-down with the
///   key's own function-key code point: `keydown`/`keyup` only, and arrows keep
///   `key`/`code` intact under every modifier, alt included.
/// - **A chord with meta or control** reaches the page as `keydown`/`keyup`
///   with the flag set and inserts nothing.
/// - **A character with no key behind it** (é, 日, an emoji) is delivered as
///   text alone (`beforeinput`/`input` with the text, no `keydown`), the way an
///   IME or the character palette delivers it.
///
/// So a keystroke is `keyDown` then `keyUp`, and text without a key is one
/// `text` event. `PageInput` turns each into the `NSEvent` (or text insertion)
/// that carries it.
struct KeystrokeEvent: Equatable {
    enum Kind: Equatable {
        case keyDown, keyUp
        /// Text inserted with no key behind it.
        case text
    }

    var kind: Kind
    /// A DOM `key` value (`Enter`, `ArrowLeft`, `a`); for `text`, the text.
    var key: String
    var modifiers: [KeyModifier]

    init(_ kind: Kind, _ key: String, _ modifiers: [KeyModifier] = []) {
        self.kind = kind
        self.key = key
        self.modifiers = modifiers
    }
}

/// The events for one press of `key` (a DOM key name or a single character)
/// with `modifiers` held.
func keystrokeEvents(_ key: String, modifiers: [KeyModifier] = []) -> [KeystrokeEvent] {
    let name = USKeyboard.canonicalName(key)
    // A character with no key behind it can only be typed as text.
    if name.count == 1, !USKeyboard.isPrintableASCII(name) { return [KeystrokeEvent(.text, name)] }
    var held = modifiers
    if USKeyboard.needsShift(name), !held.contains(.shift) { held.append(.shift) }
    return [KeystrokeEvent(.keyDown, name, held), KeystrokeEvent(.keyUp, name, held)]
}

/// The events for typing `text`, character by character: a full keystroke for
/// printable ASCII, text alone for anything else. Control characters never
/// reach here — `type` refuses them first.
func typingEvents(_ text: String) -> [KeystrokeEvent] {
    var events: [KeystrokeEvent] = []
    for character in text {
        let string = String(character)
        if USKeyboard.isPrintableASCII(string) {
            events += keystrokeEvents(string)
        } else {
            events.append(KeystrokeEvent(.text, string))
        }
    }
    return events
}

/// What a US keyboard sends for a key: the virtual key code (which is what
/// gives the page its `code`), and the characters an `NSEvent` carries.
struct PhysicalKey: Equatable {
    var keyCode: UInt16
    var characters: String
    var charactersIgnoringModifiers: String
    /// Flags the keyboard itself sets for the key (function and keypad keys).
    var flags: NSEvent.ModifierFlags = []
}

enum USKeyboard {
    /// Named keys → the DOM name they answer to (`Return` is Enter's other name).
    static func canonicalName(_ key: String) -> String {
        switch key {
        case "Return": "Enter"
        case "Space": " "
        default: key
        }
    }

    static func isPrintableASCII(_ text: String) -> Bool {
        guard text.unicodeScalars.count == 1, let scalar = text.unicodeScalars.first else { return false }
        return scalar.value >= 0x20 && scalar.value <= 0x7e
    }

    private static let shiftedSymbols: [Character: Character] = [
        "~": "`", "!": "1", "@": "2", "#": "3", "$": "4", "%": "5", "^": "6", "&": "7", "*": "8", "(": "9", ")": "0", "_": "-", "+": "=",
        "{": "[", "}": "]", "|": "\\", ":": ";", "\"": "'", "<": ",", ">": ".", "?": "/",
    ]

    /// Whether a US keyboard needs Shift for this character: a capital letter,
    /// or one of the symbols on a number row or punctuation key's shifted side.
    static func needsShift(_ key: String) -> Bool {
        guard key.count == 1, let character = key.first, isPrintableASCII(key) else { return false }
        return (character.isASCII && character.isUppercase) || shiftedSymbols[character] != nil
    }

    private static let characterKeyCodes: [Character: UInt16] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9, "b": 11, "q": 12, "w": 13, "e": 14, "r": 15,
        "y": 16, "t": 17, "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23, "=": 24, "9": 25, "7": 26, "-": 27, "8": 28, "0": 29,
        "]": 30, "o": 31, "u": 32, "[": 33, "i": 34, "p": 35, "l": 37, "j": 38, "'": 39, "k": 40, ";": 41, "\\": 42, ",": 43, "/": 44,
        "n": 45, "m": 46, ".": 47, "`": 50, " ": 49,
    ]

    /// A function key's private-use character, as AppKit reports it.
    private static func functionCharacter(_ code: Int) -> String { String(UnicodeScalar(UInt32(code))!) }

    private static let namedKeys: [String: PhysicalKey] = {
        var keys: [String: PhysicalKey] = [
            "Enter": PhysicalKey(keyCode: 36, characters: "\r", charactersIgnoringModifiers: "\r"),
            "Tab": PhysicalKey(keyCode: 48, characters: "\t", charactersIgnoringModifiers: "\t"),
            "Escape": PhysicalKey(keyCode: 53, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}"),
            "Backspace": PhysicalKey(keyCode: 51, characters: "\u{7f}", charactersIgnoringModifiers: "\u{7f}"),
        ]
        let function: NSEvent.ModifierFlags = [.function]
        let arrow: NSEvent.ModifierFlags = [.function, .numericPad]
        for (name, code, character, flags) in [
            ("ArrowUp", 126, NSUpArrowFunctionKey, arrow), ("ArrowDown", 125, NSDownArrowFunctionKey, arrow),
            ("ArrowLeft", 123, NSLeftArrowFunctionKey, arrow), ("ArrowRight", 124, NSRightArrowFunctionKey, arrow),
            ("Delete", 117, NSDeleteFunctionKey, function), ("Home", 115, NSHomeFunctionKey, function),
            ("End", 119, NSEndFunctionKey, function), ("PageUp", 116, NSPageUpFunctionKey, function),
            ("PageDown", 121, NSPageDownFunctionKey, function),
        ] {
            let text = functionCharacter(character)
            keys[name] = PhysicalKey(keyCode: UInt16(code), characters: text, charactersIgnoringModifiers: text, flags: flags)
        }
        let functionKeyCodes: [UInt16] = [122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111, 105, 107, 113, 106, 64, 79, 80, 90]
        for (index, code) in functionKeyCodes.enumerated() {
            let text = functionCharacter(NSF1FunctionKey + index)
            keys["F\(index + 1)"] = PhysicalKey(keyCode: code, characters: text, charactersIgnoringModifiers: text, flags: function)
        }
        return keys
    }()

    /// The key event data for a DOM key name or a printable ASCII character, or
    /// nil for a name this keyboard doesn't have.
    static func physicalKey(for key: String) -> PhysicalKey? {
        if let named = namedKeys[key] { return named }
        guard isPrintableASCII(key), let character = key.first else { return nil }
        let base = shiftedSymbols[character] ?? Character(String(character).lowercased())
        guard let code = characterKeyCodes[base] else { return nil }
        return PhysicalKey(keyCode: code, characters: key, charactersIgnoringModifiers: String(base))
    }

    /// Whether `key` is a key name or character this keyboard can press.
    static func isKnown(_ key: String) -> Bool { physicalKey(for: canonicalName(key)) != nil }
}
