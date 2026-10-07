import AppKit
import TabsPluginSDK

/// Between `KeyChord` (plain data in the SDK) and AppKit's menus and events.
package extension KeyChord {
    /// The `NSMenuItem.keyEquivalent` string for the key.
    var menuKeyEquivalent: String {
        func scalar(_ value: Int) -> String { String(Character(UnicodeScalar(UInt32(value))!)) }
        switch key {
        case .character(let character): return String(character)
        case .return: return "\r"
        case .tab: return "\t"
        case .escape: return "\u{1b}"
        case .delete: return "\u{8}"
        case .space: return " "
        case .arrow(.left): return scalar(NSLeftArrowFunctionKey)
        case .arrow(.right): return scalar(NSRightArrowFunctionKey)
        case .arrow(.up): return scalar(NSUpArrowFunctionKey)
        case .arrow(.down): return scalar(NSDownArrowFunctionKey)
        case .function(let number): return scalar(NSF1FunctionKey + number - 1)
        }
    }

    var eventModifierFlags: NSEvent.ModifierFlags {
        var flags: NSEvent.ModifierFlags = []
        if modifiers.contains(.command) { flags.insert(.command) }
        if modifiers.contains(.shift) { flags.insert(.shift) }
        if modifiers.contains(.option) { flags.insert(.option) }
        if modifiers.contains(.control) { flags.insert(.control) }
        return flags
    }

    /// The chord modifiers among `flags` (⌘ ⇧ ⌥ ⌃; not Caps Lock or fn).
    static func modifiers(of flags: NSEvent.ModifierFlags) -> Modifiers {
        var modifiers: Modifiers = []
        if flags.contains(.command) { modifiers.insert(.command) }
        if flags.contains(.shift) { modifiers.insert(.shift) }
        if flags.contains(.option) { modifiers.insert(.option) }
        if flags.contains(.control) { modifiers.insert(.control) }
        return modifiers
    }

    /// The chord a key event is, as chords are declared: shifted letters
    /// lowercase with `.shift`; other shifted keys as the character they make,
    /// without it (⇧⌘/ is "?" with ⌘).
    init?(event: NSEvent) {
        guard event.type == .keyDown || event.type == .keyUp, let characters = event.charactersIgnoringModifiers,
            let scalar = characters.unicodeScalars.first
        else { return nil }
        var modifiers = Self.modifiers(of: event.modifierFlags)
        let value = Int(scalar.value)
        let key: Key
        switch value {
        case NSLeftArrowFunctionKey: key = .arrow(.left)
        case NSRightArrowFunctionKey: key = .arrow(.right)
        case NSUpArrowFunctionKey: key = .arrow(.up)
        case NSDownArrowFunctionKey: key = .arrow(.down)
        case NSF1FunctionKey...(NSF1FunctionKey + 19): key = .function(value - NSF1FunctionKey + 1)
        case 0x0D, 0x03: key = .return
        case 0x09, 0x19: key = .tab
        case 0x1B: key = .escape
        case 0x7F, 0x08: key = .delete
        case 0x20: key = .space
        default:
            guard let character = characters.first else { return nil }
            if character.isLetter {
                key = .character(Character(character.lowercased()))
            } else {
                key = .character(character)
                modifiers.remove(.shift)
            }
        }
        self.init(key, modifiers)
    }
}
