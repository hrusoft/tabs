import AppKit
import Foundation
import TabsPluginSDK
import Testing

@testable import TabsCore

/// Core's shortcut table: defaults, scopes, the user's bindings, persistence.
@MainActor
@Suite struct ShortcutsTests {
    let directory = TestSupport.temporaryDirectory()

    private func runtime(_ plugins: PluginCandidate...) -> CoreRuntime {
        let runtime = TestSupport.runtime(dataDirectory: directory)
        runtime.startPlugins(from: nil, inProcess: plugins)
        return runtime
    }

    /// A plugin with one content type and one command on it (or everywhere).
    private func plugin(_ id: String, command: String, chord: KeyChord?, scoped: Bool = true, order: Int = 100) -> PluginCandidate {
        TestSupport.candidate(TestSupport.manifest(id, contentTypes: [id], sortOrder: order)) { context in
            context.register(TestSupport.contentType(id))
            context.register(
                CommandContribution(
                    id: CommandID("\(id).\(command)"), title: command, menu: .view, defaultChord: chord,
                    appliesTo: scoped ? ContentTypeID(id) : nil
                ) { _ in })
        }
    }

    private let cmdK = KeyChord("k", [.command])

    @Test func panesOfDifferentTypesShareAChordAndTheActiveTypeDecides() {
        let runtime = runtime(plugin("term", command: "clear", chord: cmdK), plugin("web", command: "find", chord: cmdK))
        let shortcuts = runtime.shortcuts
        #expect(shortcuts.chord(for: "term.clear") == cmdK)
        #expect(shortcuts.chord(for: "web.find") == cmdK)
        #expect(shortcuts.command(for: cmdK, activeType: "term") == "term.clear")
        #expect(shortcuts.command(for: cmdK, activeType: "web") == "web.find")
        #expect(shortcuts.command(for: cmdK, activeType: nil) == nil, "an empty pane: nothing armed")
    }

    @Test func aChordForEveryPaneClashesWithAnyScopedOne() {
        let runtime = runtime(
            plugin("term", command: "clear", chord: cmdK, order: 1), plugin("tool", command: "run", chord: cmdK, scoped: false, order: 2))
        #expect(runtime.shortcuts.chord(for: "term.clear") == cmdK)
        #expect(runtime.shortcuts.chord(for: "tool.run") == nil)
        #expect(runtime.shortcuts.binding(for: "tool.run")?.note == "⌘K is taken by term.clear, so it's unbound")
    }

    @Test func theUsersBindingsComeFirstAndPersist() throws {
        let runtime = runtime(plugin("term", command: "clear", chord: cmdK))
        let shortcuts = runtime.shortcuts
        // The user gives the command ⌘T, taking it from core's New Tab, and unbinds New Window.
        try shortcuts.bind("term.clear", to: KeyChord("t", [.command]))
        #expect(shortcuts.chord(for: "term.clear") == KeyChord("t", [.command]))
        #expect(shortcuts.binding(for: "term.clear")?.source == .user)
        #expect(shortcuts.chord(for: "tabs.newTab") == nil, "the user's choice wins over core's default")
        #expect(shortcuts.binding(for: "tabs.newTab")?.note == "⌘T is taken by term.clear, so it's unbound")
        #expect(shortcuts.binding(for: "tabs.newTab")?.reason == .takenBy("term.clear", KeyChord("t", [.command])))
        #expect(shortcuts.binding(for: "tabs.newTab")?.isOverridden == false, "it gets ⌘T back once the chord is free")
        try shortcuts.bind("tabs.newWindow", to: nil)
        #expect(shortcuts.chord(for: "tabs.newWindow") == nil)
        #expect(shortcuts.binding(for: "tabs.newWindow")?.note == "unbound by the user")
        #expect(shortcuts.binding(for: "tabs.newWindow")?.isOverridden == true)

        // A new launch on the same data reads them back.
        let relaunched = self.runtime(plugin("term", command: "clear", chord: cmdK))
        #expect(relaunched.shortcuts.chord(for: "term.clear") == KeyChord("t", [.command]))
        #expect(relaunched.shortcuts.chord(for: "tabs.newWindow") == nil)
        #expect(
            TestSupport.readJSON(relaunched.paths.settingsFile)?["core"]?["shortcuts"] == ["term.clear": "cmd+t", "tabs.newWindow": nil])

        try relaunched.shortcuts.reset("term.clear")
        #expect(relaunched.shortcuts.chord(for: "term.clear") == cmdK)
        #expect(relaunched.shortcuts.chord(for: "tabs.newTab") == KeyChord("t", [.command]))
    }

    @Test func theCommandPaletteIsCommandPAndItsChordIsRebindableAndUnbindable() throws {
        let runtime = runtime()
        let shortcuts = runtime.shortcuts
        #expect(CoreCommands.commandPalette.title == "New Content…")
        #expect(shortcuts.chord(for: "tabs.commandPalette") == KeyChord("p", [.command]))
        #expect(shortcuts.binding(for: "tabs.commandPalette")?.source == .default)
        try shortcuts.bind("tabs.commandPalette", to: KeyChord("j", [.command]))
        #expect(shortcuts.chord(for: "tabs.commandPalette") == KeyChord("j", [.command]))
        try shortcuts.bind("tabs.commandPalette", to: nil)
        #expect(shortcuts.chord(for: "tabs.commandPalette") == nil)
        try shortcuts.reset("tabs.commandPalette")
        #expect(shortcuts.chord(for: "tabs.commandPalette") == KeyChord("p", [.command]))
    }

    @Test func aPluginsDefaultForCommandPLeavesTheCommandPaletteItsChord() {
        let runtime = runtime(plugin("tool", command: "print", chord: KeyChord("p", [.command]), scoped: false))
        #expect(runtime.shortcuts.chord(for: "tabs.commandPalette") == KeyChord("p", [.command]), "core's defaults come first")
        #expect(runtime.shortcuts.chord(for: "tool.print") == nil)
    }

    @Test func theLatestBindingOfAChordWins() throws {
        let runtime = runtime(
            plugin("first", command: "a", chord: nil, scoped: false), plugin("second", command: "b", chord: nil, scoped: false))
        let shortcuts = runtime.shortcuts
        try shortcuts.bind("second.b", to: cmdK)
        try shortcuts.bind("first.a", to: cmdK)
        #expect(shortcuts.chord(for: "first.a") == cmdK)
        #expect(shortcuts.chord(for: "second.b") == nil)
        #expect(runtime.settings.shortcutOverrides["second.b"] == nil, "its binding is gone, not waiting to come back")
        try shortcuts.bind("second.b", to: cmdK)
        #expect(shortcuts.chord(for: "second.b") == cmdK, "whichever order the ids sort in")
    }

    @Test func bindingsThatCantWorkAreRefused() {
        let runtime = runtime(plugin("tool", command: "run", chord: nil, scoped: false))
        #expect(throws: Shortcuts.Refusal("no command nope.x")) { try runtime.shortcuts.bind("nope.x", to: cmdK) }
        #expect(throws: Shortcuts.Refusal.self) { try runtime.shortcuts.bind("tool.run", to: KeyChord("r", [.control])) }
    }

    @Test func aStoredBindingThatDoesntParseIsKeptButTheDefaultApplies() {
        TestSupport.writeJSON(
            ["version": 1, "core": ["shortcuts": ["term.clear": "cmd+", "tabs.quit": 7]]], to: directory.appending(path: "settings.json"))
        let runtime = runtime(plugin("term", command: "clear", chord: cmdK))
        #expect(runtime.shortcuts.chord(for: "term.clear") == cmdK)
        #expect(
            runtime.shortcuts.binding(for: "term.clear")?.note == "the user's shortcut \"cmd+\" isn't usable here, so it has its default")
        #expect(runtime.shortcuts.chord(for: "tabs.quit") == KeyChord("q", [.command]))
        #expect(runtime.persistenceNotes == ["settings.json: dropped the shortcut for tabs.quit: not a string or null"])
    }

    @Test func theControlVerbsListAndRebind() async throws {
        let runtime = runtime(plugin("term", command: "clear", chord: cmdK))
        let set = await runtime.control.handle(
            ControlDispatcher.Envelope(command: "tabs.setShortcut", arguments: ["command": "term.clear", "chord": "ctrl+opt+k"]))
        #expect(set == ["ok": true, "result": ["chord": "ctrl+opt+k", "note": nil]])
        let refused = await runtime.control.handle(
            ControlDispatcher.Envelope(command: "tabs.setShortcut", arguments: ["command": "term.clear", "chord": "k"]))
        #expect(refused["error"] == "tabs.setShortcut: k: needs ⌘ or ⌃")
        let list = await runtime.control.handle(ControlDispatcher.Envelope(command: "tabs.shortcuts"))
        guard case .array(let rows)? = list["result"] else {
            Issue.record("expected rows")
            return
        }
        #expect(
            rows.first { $0["command"] == "term.clear" }
                == [
                    "command": "term.clear", "owner": "term", "title": "clear", "appliesTo": "term", "default": "cmd+k",
                    "chord": "ctrl+opt+k", "source": "user", "fixed": false, "note": nil,
                ])
        #expect(rows.first { $0["command"] == "tabs.copy" }?["fixed"] == true, "M-6")
    }

    // MARK: Settings ▸ Keyboard's rules (docs/KEYBOARD.md)

    /// K-5, M-5: the stock items keep their chords. Rebinding or resetting one is refused, and a
    /// binding stored for one anyway is ignored.
    @Test func theFixedCommandsCantBeRebound() throws {
        let runtime = runtime()
        let shortcuts = runtime.shortcuts
        let fixed = shortcuts.bindings.filter(\.isFixed).map(\.command)
        #expect(
            fixed == [
                "tabs.hide", "tabs.hideOthers", "tabs.quit", "tabs.undo", "tabs.redo", "tabs.cut", "tabs.copy", "tabs.paste",
                "tabs.selectAll", "tabs.minimize",
            ])
        #expect(throws: Shortcuts.Refusal("tabs.copy is fixed: its shortcut is the system's")) {
            try shortcuts.bind("tabs.copy", to: KeyChord("j", [.command]))
        }
        #expect(throws: Shortcuts.Refusal("tabs.quit is fixed: its shortcut is the system's")) { try shortcuts.bind("tabs.quit", to: nil) }
        #expect(throws: Shortcuts.Refusal.self) { try shortcuts.reset("tabs.quit") }

        TestSupport.writeJSON(
            ["version": 1, "core": ["shortcuts": ["tabs.quit": nil, "tabs.copy": "cmd+j"]]], to: directory.appending(path: "settings.json"))
        let stored = self.runtime().shortcuts
        #expect(stored.chord(for: "tabs.quit") == KeyChord("q", [.command]))
        #expect(stored.chord(for: "tabs.copy") == KeyChord("c", [.command]))
        #expect(stored.binding(for: "tabs.copy")?.reason == .fixed)
        #expect(stored.binding(for: "tabs.copy")?.note == "fixed by the system, so the user's shortcut is ignored")
        #expect(stored.command(for: KeyChord("j", [.command]), activeType: nil) == nil)
    }

    /// V-5: a fixed item's chord, or ⌃⌘F, can't be the user's for anything else — not recorded, and
    /// not used if stored.
    @Test func reservedChordsAreRefusedAndAStoredOneIsUnusable() throws {
        let runtime = runtime(plugin("term", command: "clear", chord: cmdK))
        let shortcuts = runtime.shortcuts
        for chord in [
            KeyChord("c", [.command]), KeyChord("q", [.command]), KeyChord("h", [.command, .option]), KeyChord("f", [.control, .command]),
        ] {
            #expect(Shortcuts.userProblem(with: chord, scope: nil) == .reserved, "\(chord)")
            #expect(throws: Shortcuts.Refusal("\(chord.stringValue): reserved by the system")) {
                try shortcuts.bind("tabs.newTab", to: chord)
            }
        }
        // Close Pane and Refresh are the app's own, so ⌘W and ⌘R aren't reserved.
        for chord in [
            KeyChord("w", [.command]), KeyChord("r", [.command]), KeyChord("r", [.command, .shift]), KeyChord("c", [.command, .option]),
        ] {
            #expect(Shortcuts.userProblem(with: chord, scope: nil) == nil, "\(chord)")
        }
        TestSupport.writeJSON(
            ["version": 1, "core": ["shortcuts": ["term.clear": "cmd+c"]]], to: directory.appending(path: "settings.json"))
        let stored = self.runtime(plugin("term", command: "clear", chord: cmdK)).shortcuts
        #expect(stored.chord(for: "tabs.copy") == KeyChord("c", [.command]), "Copy keeps ⌘C")
        #expect(stored.chord(for: "term.clear") == cmdK)
        #expect(stored.binding(for: "term.clear")?.reason == .unusable("cmd+c"))
        #expect(stored.binding(for: "term.clear")?.isOverridden == true, "K-8: Reset takes the stored binding away")
    }

    /// V-2, V-3, V-4, V-6: native core's rules for what the user may record.
    @Test func whatTheUserMayRecordFollowsCoresRules() {
        let letter = { (modifiers: KeyChord.Modifiers) in KeyChord("t", modifiers) }
        #expect(Shortcuts.userProblem(with: letter([]), scope: nil) == .needsModifier)
        #expect(Shortcuts.userProblem(with: letter([.shift]), scope: nil) == .needsModifier)
        #expect(Shortcuts.userProblem(with: letter([.option]), scope: nil) == .needsModifier, "⌥ alone is typing")
        #expect(Shortcuts.userProblem(with: KeyChord(.arrow(.left), [.option]), scope: "term") == .needsModifier)
        #expect(Shortcuts.userProblem(with: letter([.control]), scope: nil) == .needsCommand, "⌃ alone is the pane's")
        #expect(Shortcuts.userProblem(with: letter([.control]), scope: "term") == nil, "…but a pane type's command may have it")
        #expect(Shortcuts.userProblem(with: letter([.command]), scope: nil) == nil)
        #expect(Shortcuts.userProblem(with: letter([.command, .option]), scope: nil) == nil)
        #expect(Shortcuts.userProblem(with: KeyChord(.function(5), []), scope: nil) == nil, "a bare function key")
        #expect(
            Shortcuts.userProblem(with: KeyChord("T", [.command]), scope: nil)
                == .malformed("use a lowercase key with .shift instead of \"T\""))
    }

    /// C-1, C-4: the commands holding a chord where another command would use it, scopes
    /// respected (the Electron page's `findConflict`).
    @Test func holdersAreTheCommandsWithTheChordInAnOverlappingScope() throws {
        let runtime = runtime(
            plugin("term", command: "clear", chord: cmdK, order: 1), plugin("web", command: "find", chord: cmdK, order: 2))
        let shortcuts = runtime.shortcuts
        #expect(shortcuts.holders(of: KeyChord("w", [.command]), for: "tabs.newTab").map(\.command) == ["tabs.closePane"])
        #expect(shortcuts.holders(of: KeyChord("t", [.command]), for: "tabs.newTab").isEmpty, "not itself")
        #expect(shortcuts.holders(of: KeyChord("j", [.command, .option]), for: "tabs.newTab").isEmpty, "a free chord")
        #expect(shortcuts.holders(of: cmdK, for: "term.clear").isEmpty, "another pane type's command doesn't hold it here")
        #expect(shortcuts.holders(of: cmdK, for: "tabs.newTab").map(\.command) == ["term.clear", "web.find"], "every pane type's")

        // The chord a binding moved to, not the default it left behind.
        try shortcuts.bind("term.clear", to: KeyChord("j", [.command, .option]))
        #expect(shortcuts.holders(of: KeyChord("j", [.command, .option]), for: "tabs.newTab").map(\.command) == ["term.clear"])
        #expect(shortcuts.holders(of: cmdK, for: "tabs.newTab").map(\.command) == ["web.find"])
        // An unbound command holds nothing.
        try shortcuts.bind("web.find", to: nil)
        #expect(shortcuts.holders(of: cmdK, for: "tabs.newTab").isEmpty)
    }

    /// C-1, C-2: under core's rules the loser isn't stored as unbound. One that held the chord by
    /// default gives way until the chord is free; one that held it by the user's binding goes
    /// back to its default.
    @Test func theLoserGivesWayOrGoesBackToItsDefault() throws {
        let runtime = runtime(plugin("term", command: "clear", chord: cmdK))
        let shortcuts = runtime.shortcuts
        try shortcuts.bind("tabs.newTab", to: cmdK)
        #expect(shortcuts.chord(for: "term.clear") == nil)
        #expect(shortcuts.binding(for: "term.clear")?.reason == .takenBy("tabs.newTab", cmdK))
        #expect(runtime.settings.shortcutOverrides["term.clear"] == nil, "nothing stored for the loser")
        try shortcuts.bind("tabs.newTab", to: KeyChord("n", [.command, .option]))
        #expect(shortcuts.chord(for: "term.clear") == cmdK, "the chord is free again, and so is its default")

        try shortcuts.bind("term.clear", to: KeyChord("l", [.command, .option]))
        try shortcuts.bind("tabs.splitVertical", to: KeyChord("l", [.command, .option]))
        #expect(shortcuts.chord(for: "term.clear") == cmdK, "the user's own binding gave way: back to its default")
        #expect(runtime.settings.shortcutOverrides["term.clear"] == nil)
    }

    /// C-5: bound back onto its own default, a command has no binding of the user's left — as long
    /// as its default then holds.
    @Test func bindingACommandBackToItsDefaultDropsTheOverride() throws {
        let runtime = runtime(plugin("tool", command: "print", chord: KeyChord("j", [.command]), scoped: false))
        let shortcuts = runtime.shortcuts
        try shortcuts.bind("tabs.newTab", to: KeyChord("n", [.command, .option]))
        #expect(shortcuts.binding(for: "tabs.newTab")?.isOverridden == true)
        try shortcuts.bind("tabs.newTab", to: KeyChord("t", [.command]))
        #expect(runtime.settings.shortcutOverrides.isEmpty)
        #expect(shortcuts.binding(for: "tabs.newTab")?.isOverridden == false)
        #expect(shortcuts.binding(for: "tabs.newTab")?.source == .default)

        // Core's New Window takes ⌘J by the user; the plugin's command takes it back with its
        // own default, which then holds.
        try shortcuts.bind("tabs.newWindow", to: KeyChord("j", [.command]))
        #expect(shortcuts.chord(for: "tool.print") == nil)
        try shortcuts.bind("tool.print", to: KeyChord("j", [.command]))
        #expect(shortcuts.chord(for: "tool.print") == KeyChord("j", [.command]))
        #expect(shortcuts.binding(for: "tool.print")?.isOverridden == false)
        #expect(shortcuts.chord(for: "tabs.newWindow") == KeyChord("n", [.command]))

        // A default that loses to an earlier default stays the user's: core's Settings… has ⌘,.
        let clash = self.runtime(plugin("tool", command: "print", chord: KeyChord(",", [.command]), scoped: false)).shortcuts
        #expect(clash.chord(for: "tool.print") == nil)
        try clash.bind("tool.print", to: KeyChord(",", [.command]))
        #expect(clash.chord(for: "tool.print") == KeyChord(",", [.command]))
        #expect(clash.binding(for: "tool.print")?.source == .user)
        #expect(clash.chord(for: "tabs.settings") == nil)
    }

    /// E-3: Restore Defaults forgets every binding the user stored, those of commands that aren't
    /// here this launch too.
    @Test func resetAllForgetsEveryBinding() throws {
        TestSupport.writeJSON(
            ["version": 1, "core": ["shortcuts": ["tabs.newTab": "cmd+opt+n", "tabs.navLeft": nil, "gone.command": "cmd+g"]]],
            to: directory.appending(path: "settings.json"))
        let runtime = runtime()
        #expect(runtime.shortcuts.chord(for: "tabs.newTab") == KeyChord("n", [.command, .option]))
        try runtime.shortcuts.resetAll()
        #expect(runtime.settings.shortcutOverrides.isEmpty)
        #expect(runtime.shortcuts.chord(for: "tabs.newTab") == KeyChord("t", [.command]))
        #expect(runtime.shortcuts.chord(for: "tabs.navLeft") == KeyChord(.arrow(.left), [.command]))
        #expect(TestSupport.readJSON(runtime.paths.settingsFile)?["core"]?["shortcuts"] == [:])
    }

    /// K-1: the page's words for every command, and its groups.
    @Test func everyCommandHasItsLabelDescriptionAndGroup() {
        let runtime = runtime(plugin("term", command: "clear", chord: cmdK))
        let rows = runtime.shortcuts.bindings.filter { !$0.isFixed }
        #expect(
            rows.map(\.label) == [
                "Open Settings", "Open Plugins", "New Window", "Caffeinate…", "New Content…", "New Tab", "New Horizontal Split",
                "New Vertical Split",
                "New Unpinned Pane", "Close Pane", "Focus Pane Left", "Focus Pane Right", "Focus Pane Up", "Focus Pane Down", "clear",
            ])
        #expect(
            rows.map(\.group) == Array(repeating: "Application", count: 4) + Array(repeating: "Panes & Tabs", count: 6)
                + Array(repeating: "Navigation", count: 4) + ["Term"])
        #expect(rows.first { $0.command == "tabs.newTab" }?.summary == "Open a new tab in the active pane.")
        // CAFFEINATE.md M-5: opt-in, no default chord.
        let caffeinate = rows.first { $0.command == "tabs.caffeinate" }
        #expect(caffeinate?.summary == "Open the Caffeinate dialog to keep the Mac awake, or turn it off if already running.")
        #expect(caffeinate?.defaultChord == nil && caffeinate?.chord == nil)
        #expect(rows.first { $0.command == "term.clear" }?.scopeName == "Term")
        #expect(rows.allSatisfy { $0.owner != "tabs" || !($0.summary ?? "").isEmpty })
    }
}

@Suite struct KeyChordFormTests {
    @Test(arguments: [
        (KeyChord("d", [.command, .shift]), "shift+cmd+d"),
        (KeyChord(.arrow(.left), [.control, .option]), "ctrl+opt+left"),
        (KeyChord(.function(5), []), "f5"),
        (KeyChord("+", [.command]), "cmd++"),
        (KeyChord(.return, [.command]), "cmd+return"),
    ])
    func roundTripsThroughItsStoredForm(chord: KeyChord, stored: String) throws {
        #expect(chord.stringValue == stored)
        #expect(KeyChord(string: stored) == chord)
        #expect(try JSONValue(encoding: chord) == .string(stored))
    }

    @Test func shiftedSymbolsAreTheCharacterTheyMake() throws {
        #expect(KeyChord("1", [.command, .shift]).problem == "use the character shift makes (\"?\" rather than ⇧/) without .shift")
        #expect(KeyChord("?", [.command]).problem == nil)
        func chord(_ characters: String, _ flags: NSEvent.ModifierFlags) throws -> KeyChord? {
            let event = try #require(
                NSEvent.keyEvent(
                    with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0, context: nil,
                    characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: 0))
            return KeyChord(event: event)
        }
        #expect(try chord("?", [.command, .shift]) == KeyChord("?", [.command]), "⇧⌘/ is ⌘?")
        #expect(try chord("D", [.command, .shift]) == KeyChord("d", [.command, .shift]), "letters keep their shift")
    }

    @Test func parsingIsForgivingAboutModifierSpelling() {
        #expect(KeyChord(string: "Command+Shift+d") == KeyChord("d", [.command, .shift]))
        #expect(KeyChord(string: "alt+control+f12") == KeyChord(.function(12), [.option, .control]))
        for bad in ["", "cmd+", "cmd+shift", "cmd+return2", "f21"] { #expect(KeyChord(string: bad) == nil, "\(bad)") }
    }
}
