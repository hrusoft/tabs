import Foundation
import TabsPluginSDK

/// Core's keyboard shortcut table: the effective chord of every command,
/// core's and plugins', from their defaults and the user's overrides.
///
/// Conflicts are resolved here, deterministically, and never fail a plugin.
/// Candidates claim chords in priority order — the user's own bindings, then
/// core's defaults, then plugins' defaults in UI order — and a chord already
/// claimed in an overlapping scope leaves the later command unbound, with a
/// note saying which command has it. Scopes overlap unless both commands
/// apply to (different) content types, which is what lets panes of different
/// types share a chord: only the active type's command is armed.
///
/// The fixed commands (Quit, Copy…) keep their chords: the user can't rebind
/// them, and nothing else may take a reserved chord (`reserved`).
@MainActor
package final class Shortcuts {
    package enum Source: String, Sendable {
        case `default`, user
    }

    /// Why a user's binding can't be recorded.
    package struct Refusal: Error, Equatable, CustomStringConvertible {
        package let description: String
        init(_ description: String) { self.description = description }
    }

    /// Why a chord can't be a command's: the rules every chord follows
    /// (`problem(with:scope:)`), and for the user's own, the reserved chords
    /// too (`userProblem(with:scope:)`). Settings ▸ Keyboard words them for
    /// the user; the descriptions are the control verb's.
    package enum Problem: Equatable, CustomStringConvertible {
        /// Not a chord as they're declared: an uppercase letter, a shifted
        /// symbol, F21… (`KeyChord.problem`).
        case malformed(String)
        /// A character, arrow or editing key without ⌘ or ⌃: ordinary typing.
        case needsModifier
        /// A command that works in every pane, with ⌃ and no ⌘: ⌃ keys belong
        /// to whatever pane has focus.
        case needsCommand
        /// A fixed command's chord, or the system's.
        case reserved

        package var description: String {
            switch self {
            case .malformed(let problem): problem
            case .needsModifier: "needs ⌘ or ⌃"
            case .needsCommand: "a shortcut that works in every pane needs ⌘ (give the command appliesTo to use ⌃ alone)"
            case .reserved: "reserved by the system"
            }
        }
    }

    /// Why a command doesn't have the chord it would otherwise have.
    package enum Reason: Equatable {
        /// The user unbound it.
        case unboundByUser
        /// Its chord is `holder`'s, which claimed it first; it's unbound
        /// until that changes.
        case takenBy(CommandID, KeyChord)
        /// The user's stored shortcut can't be used, so it has its default.
        case unusable(String)
        /// A fixed command: the user's stored shortcut for it is ignored.
        case fixed
    }

    package struct Binding: Equatable {
        package let command: CommandID
        /// `tabs` for core's commands.
        package let owner: PluginID
        /// The menu item's title.
        package let title: String
        /// The content type the command applies to; nil: everywhere.
        package let scope: ContentTypeID?
        package let defaultChord: KeyChord?
        /// How Settings ▸ Keyboard names it.
        package let label: String
        /// Settings ▸ Keyboard's line about it, if any.
        package let summary: String?
        /// Its group on Settings ▸ Keyboard: core's (`CoreCommand.Group`),
        /// or the plugin's name.
        package let group: String
        /// A fixed command (`CoreCommand.isFixed`).
        package let isFixed: Bool
        /// The display name of the content type it applies to.
        package let scopeName: String?
        /// The effective chord, or nil.
        package fileprivate(set) var chord: KeyChord?
        /// Where the effective chord came from; nil when unbound.
        package fileprivate(set) var source: Source?
        /// Whether the user stored anything for it (a chord, or unbound):
        /// what Reset takes away.
        package fileprivate(set) var isOverridden = false
        /// Why it isn't bound as its default or the user asked, if so.
        package fileprivate(set) var reason: Reason?

        /// `reason`, as the report, the Plugins window and `tabs.shortcuts` say it.
        package var note: String? {
            switch reason {
            case nil: nil
            case .unboundByUser: "unbound by the user"
            case .takenBy(let holder, let chord): "\(chord) is taken by \(holder), so it's unbound"
            case .unusable(let stored): "the user's shortcut \"\(stored)\" isn't usable here, so it has its default"
            case .fixed: "fixed by the system, so the user's shortcut is ignored"
            }
        }
    }

    /// Chords nothing but their owner may have: the fixed commands', and
    /// AppKit's own Enter Full Screen (⌃⌘F). The Electron app's `RESERVED`, as
    /// far as the native app has those items.
    package static let reserved: Set<KeyChord> = Set(CoreCommands.all.filter(\.isFixed).compactMap(\.defaultChord))
        .union([KeyChord("f", [.control, .command])])

    private let registry: ContributionRegistry
    private let settings: SettingsStore
    private let host: PluginHost
    /// Core commands first, then plugins' in UI order.
    package private(set) var bindings: [Binding] = []
    private var indexByCommand: [CommandID: Int] = [:]
    private var observers: [(token: Int, handler: @MainActor () -> Void)] = []
    private var nextToken = 0

    package init(registry: ContributionRegistry, settings: SettingsStore, host: PluginHost) {
        self.registry = registry
        self.settings = settings
        self.host = host
        rebuild()
    }

    /// Whether `chord` may be bound in `scope`. Every chord must be well formed.
    /// One that works everywhere (no scope) needs ⌘ or is a function key:
    /// ⌃ keys belong to whatever pane has focus.
    package static func problem(with chord: KeyChord, scope: ContentTypeID?) -> String? {
        shapeProblem(with: chord, scope: scope)?.description
    }

    /// Whether the user may bind `chord` in `scope`: the rules every chord
    /// follows, and not a reserved chord.
    package static func userProblem(with chord: KeyChord, scope: ContentTypeID?) -> Problem? {
        shapeProblem(with: chord, scope: scope) ?? (reserved.contains(chord) ? .reserved : nil)
    }

    private static func shapeProblem(with chord: KeyChord, scope: ContentTypeID?) -> Problem? {
        if let problem = chord.problem {
            // Only a missing modifier, if ⌘ would make it a chord.
            return KeyChord(chord.key, chord.modifiers.union(.command)).problem == nil ? .needsModifier : .malformed(problem)
        }
        if scope == nil, !chord.modifiers.contains(.command), !chord.key.isFunctionKey { return .needsCommand }
        return nil
    }

    // MARK: Queries

    package func binding(for command: CommandID) -> Binding? { indexByCommand[command].map { bindings[$0] } }

    package func chord(for command: CommandID) -> KeyChord? { binding(for: command)?.chord }

    /// The command `chord` runs now, with a pane of `activeType` active (nil:
    /// none, or an empty pane).
    package func command(for chord: KeyChord, activeType: ContentTypeID?) -> CommandID? {
        bindings.first { $0.chord == chord && ($0.scope == nil || $0.scope == activeType) }?.command
    }

    /// The commands that have `chord` now where `command` would use it (an
    /// overlapping scope): what binding it to `command` takes it from. The
    /// Electron page's `findConflict`, with scopes.
    package func holders(of chord: KeyChord, for command: CommandID) -> [Binding] {
        guard let binding = binding(for: command) else { return [] }
        return bindings.filter { $0.command != command && $0.chord == chord && Self.overlap($0.scope, binding.scope) }
    }

    /// What the report and the Plugins window say about `owner`'s shortcuts.
    package func notes(for owner: PluginID) -> [String] {
        bindings.filter { $0.owner == owner }.compactMap(\.note)
    }

    /// Called after every rebuild (a rebinding, plugins starting).
    package func observeChanges(_ handler: @escaping @MainActor () -> Void) -> Subscription {
        nextToken += 1
        let token = nextToken
        observers.append((token, handler))
        return Subscription { [weak self] in self?.observers.removeAll { $0.token == token } }
    }

    // MARK: The user's bindings

    /// Binds `command` to `chord` for the user, or unbinds it (nil). Replaces
    /// any earlier binding of theirs. The latest binding wins: a command the
    /// user had bound to the same chord (in an overlapping scope) goes back to
    /// its default, and a default holding the chord gives way. A command bound
    /// back to its own default has no binding of the user's left, as long as
    /// its default then wins.
    package func bind(_ command: CommandID, to chord: KeyChord?) throws(Refusal) {
        let binding = try editable(command)
        if let chord, let problem = Self.userProblem(with: chord, scope: binding.scope) {
            throw Refusal("\(chord.stringValue): \(problem)")
        }
        var overrides = settings.shortcutOverrides
        if let chord {
            for other in bindings where other.command != binding.command && Self.overlap(other.scope, binding.scope) {
                guard case .some(.some(let stored)) = overrides[other.command.rawValue], KeyChord(string: stored) == chord
                else { continue }
                overrides.removeValue(forKey: other.command.rawValue)
            }
        }
        overrides.updateValue(chord?.stringValue, forKey: command.rawValue)
        // Back to the shipped default: no binding of the user's at all, so the
        // command reads as un-overridden again (the Electron page drops the
        // override rather than store a copy of the default). Only if the
        // default then holds: one that loses to an earlier default stays the user's.
        if let chord, chord == binding.defaultChord {
            var candidate = overrides
            candidate.removeValue(forKey: command.rawValue)
            if resolve(candidate).first(where: { $0.command == command })?.chord == chord { overrides = candidate }
        }
        settings.setShortcuts(overrides)
        rebuild()
    }

    /// Back to the command's default.
    package func reset(_ command: CommandID) throws(Refusal) {
        try editable(command)
        settings.setShortcut(nil, for: command.rawValue, remove: true)
        rebuild()
    }

    /// Every command back to its default: Restore Defaults. Forgets bindings
    /// stored for commands that aren't here this launch too, as the Electron
    /// page's `{}` does.
    package func resetAll() throws(Refusal) {
        guard !settings.isReadOnly else { throw Refusal("settings are read-only here (headless): nothing would be stored") }
        settings.setShortcuts([:])
        rebuild()
    }

    /// `command`'s binding, if the user may change it.
    @discardableResult
    private func editable(_ command: CommandID) throws(Refusal) -> Binding {
        guard !settings.isReadOnly else { throw Refusal("settings are read-only here (headless): nothing would be stored") }
        guard let binding = binding(for: command) else { throw Refusal("no command \(command)") }
        guard !binding.isFixed else { throw Refusal("\(command) is fixed: its shortcut is the system's") }
        return binding
    }

    // MARK: Resolution

    /// Recomputes every binding from the current commands and overrides.
    package func rebuild() {
        bindings = resolve(settings.shortcutOverrides)
        indexByCommand = Dictionary(bindings.indices.map { (bindings[$0].command, $0) }, uniquingKeysWith: { first, _ in first })
        for observer in observers { observer.handler() }
    }

    /// Every binding the commands would have with `overrides`.
    private func resolve(_ overrides: [String: String?]) -> [Binding] {
        var table: [Binding] = CoreCommands.all.map {
            Binding(
                command: $0.id, owner: "tabs", title: $0.title, scope: nil, defaultChord: $0.defaultChord, label: $0.label,
                summary: $0.summary, group: $0.group?.rawValue ?? "", isFixed: $0.isFixed, scopeName: nil)
        }
        func order(_ entry: (offset: Int, element: Owned<CommandContribution>)) -> (Int, String, Int) {
            let rank = host.rank(of: entry.element.owner)
            return (rank.0, rank.1, entry.offset)
        }
        let pluginCommands = registry.contributions(to: .commands).enumerated().sorted { order($0) < order($1) }.map(\.element)
        let typeNames = Dictionary(
            registry.contributions(to: .contentTypes).map { ($0.value.id, $0.value.displayName) }, uniquingKeysWith: { first, _ in first })
        table += pluginCommands.map {
            Binding(
                command: $0.value.id, owner: $0.owner, title: $0.value.title, scope: $0.value.appliesTo,
                defaultChord: $0.value.defaultChord, label: $0.value.title, summary: $0.value.summary,
                group: host.record(for: $0.owner)?.displayName ?? $0.owner.rawValue, isFixed: false,
                scopeName: $0.value.appliesTo.flatMap { typeNames[$0] })
        }

        // Claims in priority order: the user's bindings, core's defaults, plugins' defaults.
        var userClaims: [(index: Int, chord: KeyChord)] = []
        var defaultClaims: [(index: Int, chord: KeyChord)] = []
        for index in table.indices {
            let binding = table[index]
            let stored = overrides[binding.command.rawValue]
            table[index].isOverridden = stored != nil
            guard let stored, !binding.isFixed else {
                if stored != nil { table[index].reason = .fixed }
                if let chord = binding.defaultChord { defaultClaims.append((index, chord)) }
                continue
            }
            guard let string = stored else {
                table[index].reason = .unboundByUser
                continue
            }
            if let chord = KeyChord(string: string), Self.userProblem(with: chord, scope: binding.scope) == nil {
                userClaims.append((index, chord))
            } else {
                table[index].reason = .unusable(string)
                if let chord = binding.defaultChord { defaultClaims.append((index, chord)) }
            }
        }
        userClaims.sort { table[$0.index].command < table[$1.index].command }

        var claimed: [(chord: KeyChord, scope: ContentTypeID?, index: Int)] = []
        for (claims, source) in [(userClaims, Source.user), (defaultClaims, .default)] {
            for (index, chord) in claims {
                let scope = table[index].scope
                if let holder = claimed.first(where: { $0.chord == chord && Self.overlap($0.scope, scope) }) {
                    table[index].reason = .takenBy(table[holder.index].command, chord)
                    continue
                }
                claimed.append((chord, scope, index))
                table[index].chord = chord
                table[index].source = source
            }
        }
        return table
    }

    private static func overlap(_ a: ContentTypeID?, _ b: ContentTypeID?) -> Bool {
        a == nil || b == nil || a == b
    }
}
