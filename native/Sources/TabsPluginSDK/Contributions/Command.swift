import Foundation

/// A menu command, optionally with a default keyboard shortcut. Ids are
/// namespaced (`terminal.clearBuffer`).
///
/// Core owns the effective shortcut: the user may rebind or unbind it, and a
/// default chord already taken in the same scope — by core, by the user or by
/// a plugin earlier in UI order — leaves the command unbound. That is
/// reported (the Plugins window, `--plugin-report`, `tabs.shortcuts`), never
/// a failure: one plugin's choice of shortcut can't break another plugin.
public struct CommandContribution: Contribution {
    public let id: CommandID
    public var title: String
    /// One line about what it does, under its title in Settings ▸ Keyboard.
    public var summary: String?
    public var menu: MenuPlacement
    /// The shortcut the command has unless the user changes it.
    ///
    /// Scope decides what's allowed and what clashes. A command with
    /// `appliesTo` has its shortcut armed only while a pane of that type is
    /// active, so commands for different types may share a chord, and it may
    /// use ⌃ without ⌘. A command without one works everywhere, so its chord
    /// needs ⌘ (or is a function key): ⌃ keys belong to whatever pane is
    /// focused (a shell's ⌃R).
    public var defaultChord: KeyChord?
    /// When set (one of the plugin's own types), the command is enabled — and
    /// its shortcut armed — only while the active pane is of this type.
    public var appliesTo: ContentTypeID?
    /// Extra enablement beyond `appliesTo`.
    public var isEnabled: (@MainActor (CommandInvocation) -> Bool)?
    /// Checkmark state, for toggles.
    public var isChecked: (@MainActor () -> Bool)?
    public var perform: @MainActor (CommandInvocation) -> Void

    public var contributionID: String { id.rawValue }

    public init(
        id: CommandID,
        title: String,
        summary: String? = nil,
        menu: MenuPlacement,
        defaultChord: KeyChord? = nil,
        appliesTo: ContentTypeID? = nil,
        isEnabled: (@MainActor (CommandInvocation) -> Bool)? = nil,
        isChecked: (@MainActor () -> Bool)? = nil,
        perform: @escaping @MainActor (CommandInvocation) -> Void
    ) {
        self.id = id
        self.title = title
        self.summary = summary
        self.menu = menu
        self.defaultChord = defaultChord
        self.appliesTo = appliesTo
        self.isEnabled = isEnabled
        self.isChecked = isChecked
        self.perform = perform
    }
}

public enum MenuPlacement: String, Sendable, CaseIterable {
    case file, edit, view, window
}

/// Where a command was invoked: the frontmost window and its active pane, if
/// any. `pane` — the pane's controller — is set only when the active pane is
/// the invoking plugin's own; another plugin's pane is visible only by id and
/// content type.
@MainActor
public struct CommandInvocation {
    public let windowID: WindowID?
    public let paneID: PaneID?
    public let contentType: ContentTypeID?
    public let pane: (any PaneController)?

    public init(windowID: WindowID?, paneID: PaneID?, contentType: ContentTypeID?, pane: (any PaneController)?) {
        self.windowID = windowID
        self.paneID = paneID
        self.contentType = contentType
        self.pane = pane
    }

    /// The active pane as the plugin's own controller type.
    public func pane<T: PaneController>(as type: T.Type) -> T? { pane as? T }
}

/// A keyboard shortcut: a key plus modifiers.
///
/// ```swift
/// KeyChord("d", [.command, .shift])          // ⇧⌘D
/// KeyChord(.arrow(.left), [.command, .option]) // ⌥⌘←
/// KeyChord(.function(5), [])                  // F5
/// ```
///
/// Letter keys are lowercase with shift an explicit modifier (an uppercase
/// letter is refused rather than silently meaning ⇧). Other characters are the
/// character the keys make, without `.shift` — `KeyChord("?", [.command])`
/// for ⌘? — as AppKit menus match them and whatever the keyboard layout. Stored
/// (settings, the control CLI) as a string: `cmd+shift+d`, `ctrl+opt+left`,
/// `f5` — see `stringValue`.
public struct KeyChord: Hashable, Sendable, CustomStringConvertible, Codable {
    public enum Key: Hashable, Sendable {
        case character(Character)
        case `return`, tab, escape, delete, space
        case arrow(Direction)
        /// F1–F20.
        case function(Int)

        public enum Direction: Hashable, Sendable { case left, right, up, down }
    }

    public struct Modifiers: OptionSet, Hashable, Sendable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }

        public static let command = Modifiers(rawValue: 1 << 0)
        public static let shift = Modifiers(rawValue: 1 << 1)
        public static let option = Modifiers(rawValue: 1 << 2)
        public static let control = Modifiers(rawValue: 1 << 3)
    }

    public let key: Key
    public let modifiers: Modifiers

    public init(_ key: Key, _ modifiers: Modifiers) {
        self.key = key
        self.modifiers = modifiers
    }

    public init(_ character: Character, _ modifiers: Modifiers) {
        self.init(.character(character), modifiers)
    }

    /// Why this chord can't be bound, or nil. Character, arrow and editing
    /// keys need ⌘ or ⌃ — without one they are ordinary typing and would be
    /// stolen from text views; function keys may stand alone.
    public var problem: String? {
        switch key {
        case .character(let character):
            if character.isWhitespace || character.isNewline { return "use .space, .return or .tab for whitespace keys" }
            if character.isUppercase { return "use a lowercase key with .shift instead of \"\(character)\"" }
            if !character.isLetter, modifiers.contains(.shift) {
                return "use the character shift makes (\"?\" rather than ⇧/) without .shift"
            }
        case .function(let number):
            if !(1...20).contains(number) { return "function keys are F1–F20" }
            return nil
        case .return, .tab, .escape, .delete, .space, .arrow:
            break
        }
        return modifiers.contains(.command) || modifiers.contains(.control) ? nil : "needs ⌘ or ⌃"
    }

    public var isWellFormed: Bool { problem == nil }

    /// The stored form: modifiers in the order ctrl, opt, shift, cmd, then the
    /// key — a character, `return`, `tab`, `escape`, `delete`, `space`,
    /// `left`/`right`/`up`/`down`, or `f1`–`f20`. E.g. `cmd+shift+d`.
    public var stringValue: String {
        var parts: [String] = []
        if modifiers.contains(.control) { parts.append("ctrl") }
        if modifiers.contains(.option) { parts.append("opt") }
        if modifiers.contains(.shift) { parts.append("shift") }
        if modifiers.contains(.command) { parts.append("cmd") }
        parts.append(key.name)
        return parts.joined(separator: "+")
    }

    /// Parses the stored form. Modifiers may come in any order and also be
    /// spelled `control`, `option`, `alt` or `command`.
    public init?(string: String) {
        let aliases: [(name: String, modifier: Modifiers)] = [
            ("ctrl", .control), ("control", .control), ("opt", .option), ("option", .option), ("alt", .option),
            ("shift", .shift), ("cmd", .command), ("command", .command),
        ]
        var rest = Substring(string)
        var modifiers: Modifiers = []
        scanning: while true {
            for alias in aliases where rest.count > alias.name.count + 1 && rest.lowercased().hasPrefix(alias.name + "+") {
                modifiers.insert(alias.modifier)
                rest = rest.dropFirst(alias.name.count + 1)
                continue scanning
            }
            break
        }
        guard let key = Key(name: String(rest)) else { return nil }
        self.init(key, modifiers)
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let string = try container.decode(String.self)
        guard let chord = KeyChord(string: string) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "not a shortcut: \(string)")
        }
        self = chord
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(stringValue)
    }

    public var description: String {
        var text = ""
        if modifiers.contains(.control) { text += "⌃" }
        if modifiers.contains(.option) { text += "⌥" }
        if modifiers.contains(.shift) { text += "⇧" }
        if modifiers.contains(.command) { text += "⌘" }
        switch key {
        case .character(let character): text += String(character).uppercased()
        case .return: text += "↩"
        case .tab: text += "⇥"
        case .escape: text += "⎋"
        case .delete: text += "⌫"
        case .space: text += "Space"
        case .arrow(.left): text += "←"
        case .arrow(.right): text += "→"
        case .arrow(.up): text += "↑"
        case .arrow(.down): text += "↓"
        case .function(let number): text += "F\(number)"
        }
        return text
    }

}

public extension KeyChord.Key {
    /// The key in `KeyChord.stringValue`.
    var name: String {
        switch self {
        case .character(let character): String(character)
        case .return: "return"
        case .tab: "tab"
        case .escape: "escape"
        case .delete: "delete"
        case .space: "space"
        case .arrow(.left): "left"
        case .arrow(.right): "right"
        case .arrow(.up): "up"
        case .arrow(.down): "down"
        case .function(let number): "f\(number)"
        }
    }

    init?(name: String) {
        let named: [String: KeyChord.Key] = [
            "return": .return, "tab": .tab, "escape": .escape, "esc": .escape, "delete": .delete, "space": .space,
            "left": .arrow(.left), "right": .arrow(.right), "up": .arrow(.up), "down": .arrow(.down),
        ]
        if let key = named[name.lowercased()] {
            self = key
        } else if name.count == 1, let character = name.first {
            self = .character(character)
        } else if name.lowercased().hasPrefix("f"), let number = Int(name.dropFirst()), (1...20).contains(number) {
            self = .function(number)
        } else {
            return nil
        }
    }

    var isFunctionKey: Bool {
        if case .function = self { true } else { false }
    }
}
