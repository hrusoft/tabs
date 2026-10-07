import Foundation
import TabsPluginSDK

/// Settings ▸ Keyboard's text: how a chord reads, the search box's little
/// grammar, and which rows a query shows. Chords are the characters keys make
/// rather than physical keys.
package enum ShortcutText {
    /// How `chord` reads — "⌘T", "⌥⌘←", "⌘Enter" — its modifiers in the
    /// order macOS itself shows them, regardless of the order they were pressed.
    package static func formatBinding(_ chord: KeyChord?, unbound: String = "Not set") -> String {
        guard let chord else { return unbound }
        return formatModifiers(chord.modifiers) + displayKey(chord.key)
    }

    /// Modifiers alone ("⌃⌥"): the recorder's preview while a combination is
    /// still forming.
    package static func formatModifiers(_ modifiers: KeyChord.Modifiers) -> String {
        (modifiers.contains(.control) ? "⌃" : "") + (modifiers.contains(.option) ? "⌥" : "")
            + (modifiers.contains(.shift) ? "⇧" : "") + (modifiers.contains(.command) ? "⌘" : "")
    }

    /// How the key reads on the page — '←', 'Space', ','.
    private static func displayKey(_ key: KeyChord.Key) -> String {
        switch key {
        case .character(let character): String(character).uppercased()
        case .return: "Enter"
        case .space: "Space"
        case .delete: "⌫"
        case .tab: "⇥"
        case .escape: "⎋"
        case .arrow(.left): "←"
        case .arrow(.right): "→"
        case .arrow(.up): "↑"
        case .arrow(.down): "↓"
        case .function(let number): "F\(number)"
        }
    }

    /// Whether a key can be a shortcut at all. AppKit gives Home, End, Page
    /// Up/Down, forward Delete and their like as private-use characters that
    /// no menu can show; those are refused.
    package static func isRecordable(_ key: KeyChord.Key) -> Bool {
        guard case .character(let character) = key else { return true }
        return !character.unicodeScalars.contains {
            [.privateUse, .control, .unassigned].contains($0.properties.generalCategory) || $0.properties.isWhitespace
        }
    }

    /// A real modifier held — ⌘, ⌃ or ⌥; ⇧ alone is ordinary typing (a capital
    /// letter). What makes a keystroke in the search field a combination
    /// rather than text.
    package static func hasRequiredModifier(_ chord: KeyChord) -> Bool {
        !chord.modifiers.isDisjoint(with: [.command, .control, .option])
    }

    /// ⌃ and a letter, with neither ⌘ nor ⌥. Pure key shape: whether it's
    /// worth a warning, and the words, are the page's.
    package static func isBareCtrlLetterChord(_ chord: KeyChord) -> Bool {
        guard chord.modifiers.contains(.control), !chord.modifiers.contains(.command), !chord.modifiers.contains(.option),
            case .character(let character) = chord.key
        else { return false }
        return character.isASCII && character.isLetter
    }

    // MARK: The search box

    /// The `+`-joined, case-insensitive modifier words a query may use.
    private static let modifierWords: [String: KeyChord.Modifiers] = [
        "cmd": .command, "command": .command, "mod": .command, "ctrl": .control, "control": .control, "alt": .option,
        "opt": .option, "option": .option, "shift": .shift,
    ]

    /// Named keys a query may use, the stored names (`delete`, `tab`, `escape`)
    /// included.
    private static let namedKeys: [String: KeyChord.Key] = [
        "left": .arrow(.left), "right": .arrow(.right), "up": .arrow(.up), "down": .arrow(.down), "space": .space,
        "return": .return, "backspace": .delete, "delete": .delete, "tab": .tab, "escape": .escape, "esc": .escape,
    ]

    /// Reverse of `queryKey`: the key portion of a query → a key.
    private static func parseKeyToken(_ token: String) -> KeyChord.Key? {
        if let key = namedKeys[token] { return key }
        if token.count == 1, let character = token.first, isRecordable(.character(character)) { return .character(character) }
        if token.hasPrefix("f"), let number = Int(token.dropFirst()), (1...20).contains(number) { return .function(number) }
        return nil
    }

    /// A query as a key combination, or nil when it isn't one — including
    /// ordinary text that happens to contain a `+`. It needs at least one
    /// modifier word and exactly one other token that is a key (a combination
    /// without a modifier couldn't match a binding anyway). Token order doesn't
    /// matter: "shift+cmd+n" and "cmd+shift+n" are the same.
    package static func parseSearchChord(_ query: String) -> KeyChord? {
        let tokens = query.split(separator: "+").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }.filter { !$0.isEmpty }
        var modifiers: KeyChord.Modifiers = []
        var sawModifier = false
        var keyTokens: [String] = []
        for token in tokens {
            guard let modifier = modifierWords[token] else {
                keyTokens.append(token)
                continue
            }
            sawModifier = true
            modifiers.insert(modifier)
        }
        guard sawModifier, keyTokens.count == 1, let key = parseKeyToken(keyTokens[0]) else { return nil }
        return KeyChord(key, modifiers)
    }

    /// The inverse of `parseSearchChord`: the query text for a pressed
    /// combination — "cmd+shift+t" — what the search field gets when the
    /// combination is pressed there, so it finds the same binding again. Nil
    /// for a key with no spelling.
    package static func formatChordAsQuery(_ chord: KeyChord) -> String? {
        guard let key = queryKey(chord.key) else { return nil }
        var parts: [String] = []
        if chord.modifiers.contains(.command) { parts.append("cmd") }
        if chord.modifiers.contains(.control) { parts.append("ctrl") }
        if chord.modifiers.contains(.option) { parts.append("alt") }
        if chord.modifiers.contains(.shift) { parts.append("shift") }
        parts.append(key)
        return parts.joined(separator: "+")
    }

    private static func queryKey(_ key: KeyChord.Key) -> String? {
        switch key {
        case .character(let character): isRecordable(key) ? String(character).lowercased() : nil
        case .return: "return"
        case .space: "space"
        case .delete: "backspace"
        case .tab: "tab"
        case .escape: "escape"
        case .arrow(.left): "left"
        case .arrow(.right): "right"
        case .arrow(.up): "up"
        case .arrow(.down): "down"
        case .function(let number): "f\(number)"
        }
    }

    /// The rows `query` shows, grouped in order of first appearance: empty
    /// matches everything; a combination matches the command bound to it now,
    /// exactly; otherwise a case-insensitive substring of the label, the
    /// description or the group. Fixed commands are never shown.
    package static func visibleGroups(_ query: String, in bindings: [Shortcuts.Binding]) -> [(
        group: String, bindings: [Shortcuts.Binding]
    )] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let needle = trimmed.lowercased()
        let chord = trimmed.isEmpty ? nil : parseSearchChord(trimmed)
        var groups: [(group: String, bindings: [Shortcuts.Binding])] = []
        for binding in bindings where !binding.isFixed {
            let matches =
                trimmed.isEmpty || (chord != nil && chord == binding.chord) || binding.label.lowercased().contains(needle)
                || (binding.summary ?? "").lowercased().contains(needle) || binding.group.lowercased().contains(needle)
            guard matches else { continue }
            if let index = groups.firstIndex(where: { $0.group == binding.group }) {
                groups[index].bindings.append(binding)
            } else {
                groups.append((binding.group, [binding]))
            }
        }
        return groups
    }
}
