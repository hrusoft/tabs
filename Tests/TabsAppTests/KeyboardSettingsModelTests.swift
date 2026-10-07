import AppKit
import Foundation
import TabsPluginSDK
import Testing

@testable import Tabs
@testable import TabsCore

/// Settings ▸ Keyboard's model without the page (docs/KEYBOARD.md): what a recording, a notice and a
/// query do, on core's shortcut table. Clicking a chip is `startCapture`, a combination pressed into
/// it `commit`, as the page's keyboard calls them (`UITests.KeyboardSettingsKeyHandling`); the page
/// itself is `UITests.KeyboardSettings`. The plugins are the stand-ins (`StandIns`):
/// `text.insertMarker` (⇧⌘D) and `inert.refresh` (⌘R) are commands for two pane types.
@MainActor
@Suite struct KeyboardSettingsModelTests {
    @MainActor final class Page {
        let runtime: CoreRuntime
        let model: KeyboardSettingsModel

        /// `stored`: the user's shortcuts in settings.json before the page opens.
        init(stored: [String: String?] = [:]) {
            runtime = TestSupport.runtime()
            runtime.startPlugins(from: nil, inProcess: StandIns.candidates())
            runtime.settings.setShortcuts(stored)
            runtime.shortcuts.rebuild()
            model = KeyboardSettingsModel(shortcuts: runtime.shortcuts)
        }

        var stored: [String: String?] { runtime.settings.shortcutOverrides }

        /// Clicks `command`'s chip and presses `chord` into it.
        func record(_ command: CommandID, _ chord: KeyChord) {
            model.startCapture(command)
            model.commit(command, chord)
        }

        func binding(_ command: CommandID) throws -> Shortcuts.Binding { try #require(model.binding(command), "no row \(command)") }

        /// What a chip reads.
        func chip(_ command: CommandID) throws -> String { model.chipTitle(try binding(command)) }

        /// The line under a row's title: its notice, else its description.
        func detail(_ command: CommandID) throws -> String { model.detail(of: try binding(command)).text }

        /// Every row the page shows, as command ids.
        var listed: [String] { model.groups.flatMap(\.bindings).map(\.command.rawValue) }
    }

    // MARK: Recording

    /// R-5, R-6 · "clicking the armed chip again cancels"; clicking another moves the recording.
    @Test func clickingTheArmedChipAgainCancelsAndAnotherMovesTheRecording() throws {
        let page = Page()
        page.model.startCapture("tabs.newTab")
        #expect(page.model.capturing == "tabs.newTab")
        #expect(try page.chip("tabs.newTab") == "Press keys…")
        page.model.startCapture("tabs.newTab")
        #expect(page.model.capturing == nil)
        #expect(try page.chip("tabs.newTab") == "⌘T")

        page.model.startCapture("tabs.newTab")
        page.model.startCapture("tabs.closePane")
        #expect(page.model.capturing == "tabs.closePane")
        #expect(try page.chip("tabs.newTab") == "⌘T")
        #expect(try page.chip("tabs.closePane") == "Press keys…")
    }

    // MARK: What may be recorded

    /// V-2, R-11, R-13 · "a modifier-less combination is refused, so no bare key is taken from a terminal".
    @Test func aCombinationWithoutCommandOrControlIsRefused() throws {
        let page = Page()
        page.record("tabs.newTab", KeyChord("j", []))
        #expect(page.stored.isEmpty)
        #expect(try page.detail("tabs.newTab") == "Add ⌘ or ⌃ to the combination.")
        #expect(page.model.notice?.tone == .error)
        // Still armed: a refused press is a correction, not a cancel.
        #expect(page.model.capturing == "tabs.newTab")
        #expect(try page.chip("tabs.newTab") == "Press keys…")
        page.model.commit("tabs.newTab", KeyChord("j", [.option]))
        #expect(page.stored.isEmpty, "⌥ alone is typing")
        page.model.commit("tabs.newTab", KeyChord("j", [.shift]))
        #expect(page.stored.isEmpty)
        #expect(page.model.capturing == "tabs.newTab")
    }

    /// V-3: ⌃ without ⌘ is refused for a command that works in every pane.
    @Test func controlAloneIsLeftToThePaneForCommandsThatWorkEverywhere() throws {
        let page = Page()
        page.record("tabs.newTab", KeyChord("j", [.control]))
        #expect(page.stored.isEmpty)
        #expect(try page.detail("tabs.newTab") == "Add ⌘ to the combination: ⌃ alone is left to the pane you’re typing in.")
    }

    /// V-4: a bare function key is a shortcut.
    @Test func aBareFunctionKeyIsAccepted() throws {
        let page = Page()
        page.record("tabs.newTab", KeyChord(.function(5), []))
        #expect(page.stored == ["tabs.newTab": "f5"])
        #expect(try page.chip("tabs.newTab") == "F5")
        #expect(page.model.capturing == nil)
    }

    /// V-6: ⌃ and a letter on a pane type's command is recorded, with a word about that type's panes.
    @Test func controlLetterOnAPaneTypesCommandWarns() throws {
        let page = Page()
        page.record("text.insertMarker", KeyChord("l", [.control]))
        #expect(page.stored == ["text.insertMarker": "ctrl+l"])
        #expect(try page.detail("text.insertMarker") == "⌃L is also used inside Text panes.")
        #expect(page.model.notice?.tone == .info)
    }

    // MARK: Conflicts

    /// C-3: commands for different pane types may share a chord.
    @Test func commandsForDifferentPaneTypesShareAChord() throws {
        let page = Page()
        page.record("inert.refresh", KeyChord("d", [.command, .shift]))
        #expect(try page.chip("inert.refresh") == "⇧⌘D")
        #expect(try page.chip("text.insertMarker") == "⇧⌘D")
        #expect(page.model.notice == nil)
    }

    /// C-4: a chord for every pane takes it from every pane type's command holding it.
    @Test func aChordForEveryPaneTakesItFromEveryPaneTypesCommand() throws {
        let page = Page()
        page.record("inert.refresh", KeyChord("d", [.command, .shift]))
        page.record("tabs.newTab", KeyChord("d", [.command, .shift]))
        #expect(try page.detail("tabs.newTab") == "Taken from Refresh and Insert Marker.")
        #expect(try page.chip("text.insertMarker") == "Not set")
        #expect(try page.chip("inert.refresh") == "⌘R", "the user's own binding gave way: back to its default (C-2)")
    }

    /// C-5 · "recording an action back onto its own default drops the override".
    @Test func recordingACommandBackOntoItsDefaultDropsTheOverride() throws {
        let page = Page(stored: ["tabs.newTab": "opt+cmd+n"])
        #expect(try page.binding("tabs.newTab").isOverridden, "the row offers Reset")
        page.record("tabs.newTab", KeyChord("t", [.command]))
        #expect(page.stored.isEmpty)
        #expect(try !page.binding("tabs.newTab").isOverridden, "and no longer does")
        #expect(page.model.notice == nil, "nothing was taken from anything")
    }

    // MARK: Clear, Reset, Restore Defaults

    /// E-2, R-10 · "resetting a row removes its override entirely" — that row's only, and it settles
    /// the recorder.
    @Test func resettingARowRemovesItsOverrideEntirely() throws {
        let page = Page(stored: ["tabs.newTab": "opt+cmd+n", "tabs.closePane": nil])
        page.record("tabs.navLeft", KeyChord("j", []))
        #expect(page.model.notice != nil)
        page.model.reset("tabs.newTab")
        #expect(page.stored == ["tabs.closePane": nil])
        #expect(try page.chip("tabs.newTab") == "⌘T")
        #expect(page.model.capturing == nil)
        #expect(page.model.notice == nil)
    }

    /// E-4 · "a second rebind keeps the first, rather than writing a stale record".
    @Test func aSecondRebindKeepsTheFirst() throws {
        let page = Page()
        page.record("tabs.newTab", KeyChord("n", [.command, .option]))
        page.record("tabs.navLeft", KeyChord("j", [.command, .option]))
        #expect(page.stored == ["tabs.newTab": "opt+cmd+n", "tabs.navLeft": "opt+cmd+j"])
    }

    /// R-12, R-13: a notice sits under its own row only, until the next recording starts.
    @Test func aNoticeIsItsRowsUntilTheNextRecording() throws {
        let page = Page()
        page.record("tabs.newTab", KeyChord("w", [.command]))
        #expect(try page.detail("tabs.newTab") == "Taken from Close Pane.")
        #expect(try page.detail("tabs.closePane") == "Close the active pane, confirming first if it still has work running.")
        page.model.startCapture("tabs.navLeft")
        #expect(try page.detail("tabs.newTab") == "Open a new tab in the active pane.")
    }

    // MARK: Search

    /// S-5 · "a combination query follows a rebind, not the shipped default".
    @Test func aCombinationQueryFollowsARebind() {
        let page = Page(stored: ["tabs.newTab": "opt+cmd+n"])
        page.model.query = "cmd+t"
        #expect(page.listed.isEmpty)
        page.model.query = "alt+cmd+n"
        #expect(page.listed == ["tabs.newTab"])
    }
}

extension UITests {
    /// Settings ▸ Keyboard's keyboard (`KeyboardSettingsKeys`, docs/KEYBOARD.md) without the page: each
    /// key handed to it as its monitor hands it one, in a plain window it's attached to, with a search
    /// field there for the cases that type into one. The page's own wiring (its chips and search field,
    /// the monitor among the app's keys) is `KeyboardSettings`'.
    @MainActor
    @Suite struct KeyboardSettingsKeyHandling {
        @MainActor final class Bench {
            let page: KeyboardSettingsModelTests.Page
            let keys: KeyboardSettingsKeys
            let window: NSWindow
            let searchField = NSSearchField(frame: NSRect(x: 10, y: 10, width: 300, height: 22))

            init(stored: [String: String?] = [:]) {
                page = KeyboardSettingsModelTests.Page(stored: stored)
                keys = KeyboardSettingsKeys(model: page.model)
                window = NSWindow(
                    contentRect: NSRect(x: 0, y: 0, width: 320, height: 42), styleMask: [.titled], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                window.contentView?.addSubview(searchField)
                keys.searchField = searchField
                keys.attach(to: window)
            }

            isolated deinit {
                keys.detach()
                window.close()
            }

            var model: KeyboardSettingsModel { page.model }

            /// Presses `chord` as the page's monitor gets it. Returns whether the page used it up (else it goes
            /// on to the menu, or to whatever has the keyboard).
            @discardableResult
            func press(_ chord: KeyChord) throws -> Bool {
                keys.handle(try #require(InputSynthesizer.chordEvent(.keyDown, chord, in: window)))
            }

            /// Holds (or releases to) `modifiers`.
            func hold(_ modifiers: NSEvent.ModifierFlags) throws {
                _ = keys.handle(try #require(InputSynthesizer.modifiersEvent(modifiers, in: window)))
            }

            /// Gives the search field the keyboard, as clicking into it does.
            func focusSearch() {
                window.makeFirstResponder(searchField)
            }

            /// Types into whatever has the keyboard, one key at a time, through the page's keyboard first.
            func type(_ text: String) throws {
                for character in text {
                    let string = String(character)
                    let down = try #require(
                        InputSynthesizer.keyEvent(.keyDown, characters: string, ignoringModifiers: string, modifiers: [], window: window))
                    if !keys.handle(down) { window.sendEvent(down) }
                }
            }

            var searchText: String { searchField.stringValue }
        }

        // MARK: Recording

        /// R-1: while recording, a chord the menu holds goes to the chip, not the menu.
        @Test func aChordTheMenuHoldsIsRecordedNotPerformed() throws {
            let bench = Bench()
            bench.keys.startCapture("tabs.newWindow")
            #expect(try bench.press(KeyChord("t", [.command])), "used up: the menu never sees it")
            #expect(try bench.page.chip("tabs.newWindow") == "⌘T")
            #expect(bench.page.stored == ["tabs.newWindow": "cmd+t"])
            #expect(bench.model.capturing == nil)
        }

        /// R-4 · "Escape cancels capture, leaving the binding untouched" — with any modifiers.
        @Test func escapeCancelsLeavingTheBindingUntouched() throws {
            let bench = Bench()
            for modifiers: KeyChord.Modifiers in [[], [.command], [.shift]] {
                bench.keys.startCapture("tabs.newTab")
                #expect(try bench.press(KeyChord(.escape, modifiers)))
                #expect(try bench.page.chip("tabs.newTab") == "⌘T")
                #expect(bench.page.stored.isEmpty)
                #expect(bench.model.capturing == nil)
            }
        }

        /// R-7: Tab (⇧Tab too) ends the recording, and goes on to move focus; it's never recorded.
        @Test func tabEndsTheRecordingAndIsNeverRecorded() throws {
            let bench = Bench()
            for modifiers: KeyChord.Modifiers in [[.control], [.shift], []] {
                bench.keys.startCapture("tabs.newTab")
                #expect(try !bench.press(KeyChord(.tab, modifiers)), "Tab goes on to the window")
                #expect(bench.model.capturing == nil)
                #expect(bench.page.stored.isEmpty)
            }
        }

        /// R-2: held modifiers show in the chip as they're pressed and released.
        @Test func heldModifiersShowInTheChip() throws {
            let bench = Bench()
            bench.keys.startCapture("tabs.newTab")
            try bench.hold([.control])
            #expect(try bench.page.chip("tabs.newTab") == "⌃")
            try bench.hold([.control, .option])
            #expect(try bench.page.chip("tabs.newTab") == "⌃⌥")
            try bench.hold([])
            #expect(try bench.page.chip("tabs.newTab") == "Press keys…")
        }

        /// R-8: the Settings window losing focus ends the recording.
        @Test func theWindowLosingFocusEndsTheRecording() throws {
            let bench = Bench()
            bench.keys.startCapture("tabs.newTab")
            NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: bench.window)
            runLoopTurns()
            #expect(bench.model.capturing == nil)
            #expect(try bench.page.chip("tabs.newTab") == "⌘T")
        }

        // MARK: What may be recorded

        /// V-5, R-14 · "a combination the stock role menus own is refused" — and it isn't performed.
        @Test func aCombinationTheSystemOwnsIsRefused() throws {
            let bench = Bench()
            bench.keys.startCapture("tabs.newTab")
            #expect(try bench.press(KeyChord("c", [.command])))
            #expect(bench.page.stored.isEmpty)
            #expect(try bench.page.detail("tabs.newTab") == "⌘C is reserved by the system.")
            #expect(try bench.press(KeyChord("q", [.command])), "used up by the page: nothing quits")
            #expect(try bench.page.detail("tabs.newTab") == "⌘Q is reserved by the system.")
            try bench.press(KeyChord("f", [.control, .command]))
            #expect(try bench.page.detail("tabs.newTab") == "⌃⌘F is reserved by the system.")
        }

        /// V-1: a key with no shortcut form.
        @Test func aKeyWithNoShortcutFormIsRefused() throws {
            let bench = Bench()
            bench.keys.startCapture("tabs.newTab")
            let home = String(Character(UnicodeScalar(NSHomeFunctionKey)!))
            let down = try #require(
                InputSynthesizer.keyEvent(
                    .keyDown, characters: home, ignoringModifiers: home, modifiers: [.command], window: bench.window, keyCode: 115))
            #expect(bench.keys.handle(down))
            #expect(bench.page.stored.isEmpty)
            #expect(try bench.page.detail("tabs.newTab") == "That key cannot be used as a shortcut.")
        }

        // MARK: Search

        /// S-9 · "pressing a nav combination while searching types it as text too, without moving anything".
        @Test func pressingANavCombinationWhileSearchingTypesItToo() throws {
            let bench = Bench()
            bench.focusSearch()
            #expect(try bench.press(KeyChord(.arrow(.left), [.command])), "used up: it reaches neither the panes nor the caret")
            #expect(bench.searchText == "cmd+left")
        }

        /// S-10 · "pressing a combination inserts it at the cursor, not always at the end".
        @Test func pressingACombinationInsertsItAtTheCursor() throws {
            let bench = Bench()
            bench.focusSearch()
            try bench.type("foobar")
            let editor = try #require(bench.keys.searchEditor)
            editor.setSelectedRange(NSRange(location: 3, length: 0))
            try bench.press(KeyChord("t", [.control]))
            #expect(bench.searchText == "fooctrl+tbar")
            #expect(editor.selectedRange() == NSRange(location: 9, length: 0))
        }

        /// S-11 · "bare typing in the search box is untouched — no interception without a real modifier".
        @Test func bareTypingInTheSearchFieldIsUntouched() throws {
            let bench = Bench()
            bench.focusSearch()
            try bench.type("Close Pane")
            #expect(bench.searchText == "Close Pane")
            #expect(try !bench.press(KeyChord("p", [.shift])), "⇧ alone is typing")
        }

        /// S-12: a fixed item's chord keeps its meaning in the field — the page leaves it to the menu.
        @Test func aFixedItemsChordKeepsItsMeaningInTheField() throws {
            let bench = Bench()
            bench.focusSearch()
            for chord in [KeyChord("a", [.command]), KeyChord("v", [.command]), KeyChord("c", [.command]), KeyChord("z", [.command])] {
                #expect(try !bench.press(chord), "\(chord)")
            }
            #expect(bench.searchText == "")
        }
    }
}
