import AppKit
import Foundation
import SwiftUI
import TabsPluginSDK
import Testing

@testable import Tabs
@testable import TabsCore

extension UITests {
    // MARK: - Settings ▸ Keyboard (docs/KEYBOARD.md)

    /// The Electron app's settings/__tests__/keyboardSettings.test.tsx and e2e/keyboard-shortcuts.spec.ts, ported: the
    /// real page in a Settings window beside a real workspace, its menu installed as the app's.
    @MainActor
    @Suite struct KeyboardSettings {
        @MainActor final class Fixture {
            let ui: UIDriver
            let controller: NSWindowController
            let window: NSWindow

            /// `stored`: the user's shortcuts in settings.json before the window opens.
            init(stored: [String: String?] = [:]) throws {
                ui = UIDriver()
                ui.runtime.settings.setShortcuts(stored)
                ui.runtime.shortcuts.rebuild()
                controller = makeSettingsWindow(for: ui.runtime)
                window = try #require(controller.window)
                let tabs = try #require(controller.contentViewController as? NSTabViewController)
                tabs.selectedTabViewItemIndex = try #require(tabs.tabViewItems.firstIndex { $0.label == "Keyboard" })
                fitWindow()
                settle()
            }

            /// Sizes the window to the selected page's size, as the tab controller does for a window
            /// on screen: the list scrolls, as it does for a user.
            func fitWindow() {
                guard let tabs, tabs.selectedTabViewItemIndex >= 0 else { return }
                let page = tabs.tabViewItems[tabs.selectedTabViewItemIndex].viewController
                if let size = page?.preferredContentSize, size.width > 0, size.height > 0 { window.setContentSize(size) }
                window.contentView?.layoutSubtreeIfNeeded()
            }

            isolated deinit {
                controller.close()
            }

            var tabs: NSTabViewController? { controller.contentViewController as? NSTabViewController }
            var hosting: KeyboardSettingsHostingView? {
                window.contentView?.allSubviews.lazy.compactMap { $0 as? KeyboardSettingsHostingView }.first
            }
            var keys: KeyboardSettingsKeys { get throws { try #require(hosting?.rootView.keys) } }
            var model: KeyboardSettingsModel { get throws { try keys.model } }
            var stored: [String: String?] { ui.runtime.settings.shortcutOverrides }

            func settle() {
                RunLoop.main.run(until: Date().addingTimeInterval(0.15))
                window.contentView?.layoutSubtreeIfNeeded()
            }

            func find(_ identifier: String) -> NSView? { InputSynthesizer.find(identifier, in: window) }

            func button(_ identifier: String) throws -> NSButton {
                try #require(find(identifier) as? NSButton, "no button \(identifier)")
            }

            func chip(_ command: String) throws -> NSButton { try button("settings-shortcut-\(command)") }

            /// What a chip reads.
            func chipText(_ command: String) throws -> String { try chip(command).title }

            func isListed(_ command: String) -> Bool { find("settings-shortcut-\(command)") != nil }

            /// Clicks a button as a user would, scrolling it into view first.
            func click(_ identifier: String) throws {
                let view = try #require(find(identifier), "no \(identifier)")
                if let scrollView = view.enclosingScrollView, let document = scrollView.documentView {
                    let rect = view.convert(view.bounds, to: document).insetBy(dx: 0, dy: -12)
                    document.scrollToVisible(rect)
                    scrollView.reflectScrolledClipView(scrollView.contentView)
                }
                settle()
                try InputSynthesizer.click(identifier, in: window)
                settle()
            }

            /// Presses `chord` in the Settings window as AppKit delivers a key: the page's key monitor
            /// first, then the window's and the menu's key equivalents, then the first responder.
            @discardableResult
            func press(_ chord: KeyChord) throws -> Bool {
                let down = try #require(InputSynthesizer.chordEvent(.keyDown, chord, in: window))
                if try keys.handle(down) {
                    settle()
                    return true
                }
                let handled = InputSynthesizer.press(chord, in: window)
                settle()
                return handled
            }

            /// A key the chord model has no case for (Home, a dead key): its raw characters.
            func press(characters: String, keyCode: UInt16) throws {
                let down = try #require(
                    InputSynthesizer.keyEvent(
                        .keyDown, characters: characters, ignoringModifiers: characters, modifiers: [.command], window: window,
                        keyCode: keyCode))
                if try !keys.handle(down) { window.sendEvent(down) }
                settle()
            }

            /// Holds (or releases to) `modifiers`.
            func hold(_ modifiers: NSEvent.ModifierFlags) throws {
                let event = try #require(InputSynthesizer.modifiersEvent(modifiers, in: window))
                _ = try keys.handle(event)
                settle()
            }

            var searchField: NSSearchField { get throws { try #require(find("settings-shortcut-search") as? NSSearchField) } }

            /// Gives the search field the keyboard, as clicking into it does.
            func focusSearch() throws {
                window.makeFirstResponder(try searchField)
                settle()
            }

            /// Types into whatever has the keyboard, one key at a time, through the page's monitor.
            func type(_ text: String) throws {
                for character in text {
                    let string = String(character)
                    let down = try #require(
                        InputSynthesizer.keyEvent(.keyDown, characters: string, ignoringModifiers: string, modifiers: [], window: window))
                    if try !keys.handle(down) { window.sendEvent(down) }
                }
                settle()
            }

            var searchText: String { (try? searchField.stringValue) ?? "" }

            /// Every row the page shows, as command ids.
            var listed: [String] { ((try? model.groups) ?? []).flatMap(\.bindings).map(\.command.rawValue) }

            func detail(_ command: String) throws -> String {
                let binding = try #require(try model.binding(CommandID(command)))
                return try model.detail(of: binding).text
            }

            func menuChord(_ command: String) -> (String, NSEvent.ModifierFlags)? {
                func search(_ menu: NSMenu) -> NSMenuItem? {
                    for item in menu.items {
                        if item.identifier?.rawValue == command { return item }
                        if let submenu = item.submenu, let found = search(submenu) { return found }
                    }
                    return nil
                }
                guard let item = NSApp.mainMenu.flatMap(search) else { return nil }
                return (item.keyEquivalent, item.keyEquivalentModifierMask)
            }
        }

        // MARK: The list

        /// K-1, K-2, K-4, K-9 · "lists every action at its default binding".
        @Test func listsEveryCommandAtItsDefaultBinding() throws {
            let box = try Fixture()
            let labels = try #require(box.tabs?.tabViewItems.map(\.label))
            #expect(labels.prefix(2) == ["Panes & Tabs", "Keyboard"])
            #expect(labels.last == "AI")
            #expect(try box.chipText("tabs.newTab") == "⌘T")
            #expect(try box.chipText("tabs.closePane") == "⌘W")
            #expect(try box.chipText("tabs.navLeft") == "⌘←")
            #expect(try box.chipText("terminal.clearBuffer") == "⌘K")
            #expect(try box.detail("tabs.newTab") == "Open a new tab in the active pane.")
            // Nothing is overridden, so no row offers a Reset.
            #expect(box.find("settings-shortcut-reset-tabs.newTab") == nil)
            let groups = try box.model.groups.map(\.id)
            #expect(Array(groups.prefix(3)) == ["Application", "Panes & Tabs", "Navigation"])
            #expect(groups.contains("Terminal") && groups.contains("Git tree"), "\(groups)")
            // Every row is on the page, not only in the model.
            for command in box.listed { #expect(box.isListed(command), "\(command) has no chip") }
            try snapshot(box, "settings-keyboard")
        }

        /// K-5: the fixed items aren't listed.
        @Test func theFixedItemsAreNotListed() throws {
            let box = try Fixture()
            for command in ["tabs.quit", "tabs.copy", "tabs.paste", "tabs.undo", "tabs.selectAll", "tabs.minimize", "tabs.hide"] {
                #expect(!box.listed.contains(command))
                #expect(!box.isListed(command))
            }
        }

        // MARK: Recording

        /// R-1, R-3 · "recording a combination writes it and disarms capture".
        @Test func recordingACombinationWritesItAndDisarms() throws {
            let box = try Fixture()
            try box.click("settings-shortcut-tabs.newTab")
            #expect(try box.chipText("tabs.newTab") == "Press keys…")
            #expect(try box.model.capturing == "tabs.newTab")
            #expect(try box.chip("tabs.newTab").bezelColor == .controlAccentColor)
            try box.hold([.command, .option])
            try snapshot(box, "settings-keyboard-recording")

            #expect(try box.press(KeyChord("n", [.command, .option])))

            #expect(box.stored == ["tabs.newTab": "opt+cmd+n"])
            #expect(try box.chipText("tabs.newTab") == "⌥⌘N")
            #expect(try box.model.capturing == nil)
            #expect(try box.chip("tabs.newTab").bezelColor == nil)
        }

        /// R-1: while recording, a chord the menu holds goes to the chip, not the menu.
        @Test func aChordTheMenuHoldsIsRecordedNotPerformed() throws {
            let box = try Fixture()
            let panes = try box.ui.layout.leaves.count
            try box.click("settings-shortcut-tabs.newWindow")
            #expect(try box.press(KeyChord("t", [.command])))
            #expect(try box.chipText("tabs.newWindow") == "⌘T")
            #expect(try box.ui.layout.leaves.count == panes, "no tab opened")
            #expect(box.menuChord("tabs.newWindow")?.0 == "t")
        }

        /// R-4 · "Escape cancels capture, leaving the binding untouched".
        @Test func escapeCancelsLeavingTheBindingUntouched() throws {
            let box = try Fixture()
            try box.click("settings-shortcut-tabs.newTab")
            #expect(try box.press(KeyChord(.escape, [])))
            #expect(try box.chipText("tabs.newTab") == "⌘T")
            #expect(box.stored.isEmpty)
            #expect(try box.model.capturing == nil)
        }

        /// R-5, R-6 · "clicking the armed chip again cancels".
        @Test func clickingTheArmedChipAgainCancelsAndAnotherMovesTheRecording() throws {
            let box = try Fixture()
            try box.click("settings-shortcut-tabs.newTab")
            try box.click("settings-shortcut-tabs.newTab")
            #expect(try box.model.capturing == nil)
            #expect(try box.chipText("tabs.newTab") == "⌘T")

            try box.click("settings-shortcut-tabs.newTab")
            try box.click("settings-shortcut-tabs.closePane")
            #expect(try box.model.capturing == "tabs.closePane")
            #expect(try box.chipText("tabs.newTab") == "⌘T")
            #expect(try box.chipText("tabs.closePane") == "Press keys…")
        }

        /// R-7: Tab ends the recording, and goes on to move focus; it's never recorded.
        @Test func tabEndsTheRecordingAndIsNeverRecorded() throws {
            let box = try Fixture()
            try box.click("settings-shortcut-tabs.newTab")
            let down = try #require(InputSynthesizer.chordEvent(.keyDown, KeyChord(.tab, [.control]), in: box.window))
            #expect(try !box.keys.handle(down), "Tab goes on to the window")
            #expect(try box.model.capturing == nil)
            #expect(box.stored.isEmpty)
        }

        /// R-2: held modifiers show in the chip as they're pressed and released.
        @Test func heldModifiersShowInTheChip() throws {
            let box = try Fixture()
            try box.click("settings-shortcut-tabs.newTab")
            try box.hold([.control])
            #expect(try box.chipText("tabs.newTab") == "⌃")
            try box.hold([.control, .option])
            #expect(try box.chipText("tabs.newTab") == "⌃⌥")
            try box.hold([])
            #expect(try box.chipText("tabs.newTab") == "Press keys…")
        }

        /// R-8: the Settings window losing focus ends the recording.
        @Test func theWindowLosingFocusEndsTheRecording() throws {
            let box = try Fixture()
            try box.click("settings-shortcut-tabs.newTab")
            NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: box.window)
            box.settle()
            #expect(try box.model.capturing == nil)
            #expect(try box.chipText("tabs.newTab") == "⌘T")
        }

        /// R-9 · e2e "closing the Settings window mid-capture restores the accelerators".
        @Test func closingTheSettingsWindowMidRecordingLetsGoOfTheKeyboard() throws {
            let box = try Fixture()
            let keys = try box.keys
            try box.click("settings-shortcut-tabs.newTab")
            box.controller.close()
            box.settle()
            #expect(keys.model.capturing == nil)
            // ⌘T reaches the menu again.
            let panes = try box.ui.layout.leaves.count
            #expect(try box.ui.press(KeyChord("t", [.command])))
            #expect(try box.ui.layout.leaves.count == panes + 1)
            // Settings opens the same window again, and the page records as before.
            #expect(keys.isMonitoring)
            try box.click("settings-shortcut-tabs.newTab")
            try box.press(KeyChord("j", [.command, .option]))
            #expect(box.stored == ["tabs.newTab": "opt+cmd+j"])
        }

        /// The page's monitor goes with it: a Settings window rebuilt (plugins changed) leaves none behind.
        @Test func thePagesMonitorGoesWithThePage() throws {
            weak var released: KeyboardSettingsKeys?
            weak var window: NSWindow?
            weak var hosting: KeyboardSettingsHostingView?
            weak var controller: NSWindowController?
            try autoreleasepool {
                let box = try Fixture()
                released = try box.keys
                window = box.window
                hosting = box.hosting
                controller = box.controller
                #expect(released?.isMonitoring == true)
            }
            RunLoop.main.run(until: Date().addingTimeInterval(0.5))
            #expect(controller == nil && window == nil && hosting == nil, "the window and the page are gone")
            #expect(released == nil, "and so is the page's keyboard, its monitor removed as it goes")
        }

        /// A chip takes the keyboard from the search field, as the Electron chip (a button) takes focus: after
        /// recording, a combination performs again instead of being typed as a search.
        @Test func clickingAChipTakesTheKeyboardFromTheSearchField() throws {
            let box = try Fixture()
            try box.focusSearch()
            #expect(try box.keys.searchEditor != nil)
            try box.click("settings-shortcut-tabs.newTab")
            #expect(try box.keys.searchEditor == nil)
            try box.press(KeyChord("n", [.command, .option]))
            #expect(box.searchText == "")
            #expect(box.stored == ["tabs.newTab": "opt+cmd+n"])
        }

        /// R-9 · "…unmounting releases capture": leaving the page for another ends the recording.
        @Test func leavingThePageEndsTheRecording() throws {
            let box = try Fixture()
            let keys = try box.keys
            try box.click("settings-shortcut-tabs.newTab")
            box.tabs?.selectedTabViewItemIndex = 0
            box.settle()
            #expect(!keys.isMonitoring)
            #expect(keys.model.capturing == nil)
            box.tabs?.selectedTabViewItemIndex = 1
            box.fitWindow()
            box.settle()
            #expect(keys.isMonitoring, "back on the page, it has the keyboard again")
        }

        /// The page's monitor is a real local monitor: a key the app dispatches reaches it first.
        @Test func theMonitorGetsTheAppsKeysFirst() throws {
            let box = try Fixture()
            try box.click("settings-shortcut-tabs.newTab")
            let down = try #require(InputSynthesizer.chordEvent(.keyDown, KeyChord("j", [.command, .option]), in: box.window))
            NSApp.sendEvent(down)
            box.settle()
            #expect(box.stored == ["tabs.newTab": "opt+cmd+j"])
        }

        // MARK: What may be recorded

        /// V-2, R-11 · "a modifier-less combination is refused, so no bare key is taken from a terminal".
        @Test func aCombinationWithoutCommandOrControlIsRefused() throws {
            let box = try Fixture()
            try box.click("settings-shortcut-tabs.newTab")
            try box.press(KeyChord("j", []))
            #expect(box.stored.isEmpty)
            #expect(try box.detail("tabs.newTab") == "Add ⌘ or ⌃ to the combination.")
            #expect(try box.model.notice?.tone == .error)
            try snapshot(box, "settings-keyboard-refused")
            // Still armed: a refused press is a correction, not a cancel.
            #expect(try box.chipText("tabs.newTab") == "Press keys…")
            try box.press(KeyChord("j", [.option]))
            #expect(box.stored.isEmpty, "⌥ alone is typing")
            try box.press(KeyChord("j", [.shift]))
            #expect(box.stored.isEmpty)
        }

        /// V-3: ⌃ without ⌘ is refused for a command that works in every pane.
        @Test func controlAloneIsLeftToThePaneForCommandsThatWorkEverywhere() throws {
            let box = try Fixture()
            try box.click("settings-shortcut-tabs.newTab")
            try box.press(KeyChord("j", [.control]))
            #expect(box.stored.isEmpty)
            #expect(try box.detail("tabs.newTab") == "Add ⌘ to the combination: ⌃ alone is left to the pane you’re typing in.")
        }

        /// V-4: a bare function key is a shortcut.
        @Test func aBareFunctionKeyIsAccepted() throws {
            let box = try Fixture()
            try box.click("settings-shortcut-tabs.newTab")
            try box.press(KeyChord(.function(5), []))
            #expect(box.stored == ["tabs.newTab": "f5"])
            #expect(try box.chipText("tabs.newTab") == "F5")
        }

        /// V-5, R-14 · "a combination the stock role menus own is refused" — and it isn't performed.
        @Test func aCombinationTheSystemOwnsIsRefused() throws {
            let box = try Fixture()
            try box.click("settings-shortcut-tabs.newTab")
            #expect(try box.press(KeyChord("c", [.command])))
            #expect(box.stored.isEmpty)
            #expect(try box.detail("tabs.newTab") == "⌘C is reserved by the system.")
            #expect(try box.press(KeyChord("q", [.command])), "used up by the page: nothing quits")
            #expect(try box.detail("tabs.newTab") == "⌘Q is reserved by the system.")
            try box.press(KeyChord("f", [.control, .command]))
            #expect(try box.detail("tabs.newTab") == "⌃⌘F is reserved by the system.")
        }

        /// V-1: a key with no shortcut form.
        @Test func aKeyWithNoShortcutFormIsRefused() throws {
            let box = try Fixture()
            try box.click("settings-shortcut-tabs.newTab")
            try box.press(characters: String(Character(UnicodeScalar(NSHomeFunctionKey)!)), keyCode: 115)
            #expect(box.stored.isEmpty)
            #expect(try box.detail("tabs.newTab") == "That key cannot be used as a shortcut.")
        }

        /// V-6: ⌃ and a letter on a pane type's command is recorded, with a word about that type's panes.
        @Test func controlLetterOnAPaneTypesCommandWarns() throws {
            let box = try Fixture()
            try box.click("settings-shortcut-terminal.clearBuffer")
            try box.press(KeyChord("l", [.control]))
            #expect(box.stored == ["terminal.clearBuffer": "ctrl+l"])
            #expect(try box.detail("terminal.clearBuffer") == "⌃L is also used inside Terminal panes.")
            #expect(try box.model.notice?.tone == .info)
        }

        // MARK: Conflicts

        /// C-1 · "recording a combination another action holds reassigns it" — under core's rules
        /// the loser gives way until the chord is free, rather than being stored as unset.
        @Test func recordingAChordAnotherCommandHoldsTakesIt() throws {
            let box = try Fixture()
            try box.click("settings-shortcut-tabs.newTab")
            try box.press(KeyChord("w", [.command]))
            #expect(box.stored == ["tabs.newTab": "cmd+w"])
            #expect(try box.chipText("tabs.newTab") == "⌘W")
            #expect(try box.detail("tabs.newTab") == "Taken from Close Pane.")
            #expect(try box.chipText("tabs.closePane") == "Not set")
            let closePane = try #require(try box.model.binding("tabs.closePane"))
            #expect(try box.model.explanation(of: closePane) == "⌘W is taken by New Tab.")
            #expect(box.find("settings-shortcut-reset-tabs.closePane") == nil, "nothing of the user's to reset")
            try snapshot(box, "settings-keyboard-taken")

            try box.click("settings-shortcut-tabs.newTab")
            try box.press(KeyChord("n", [.command, .option]))
            #expect(try box.chipText("tabs.closePane") == "⌘W", "free again, so it has its default back")
        }

        /// C-3: commands for different pane types may share a chord.
        @Test func commandsForDifferentPaneTypesShareAChord() throws {
            let box = try Fixture()
            try box.click("settings-shortcut-git-tree.refresh")
            try box.press(KeyChord("k", [.command]))
            #expect(try box.chipText("git-tree.refresh") == "⌘K")
            #expect(try box.chipText("terminal.clearBuffer") == "⌘K")
            #expect(try box.model.notice == nil)
        }

        /// C-4: a chord for every pane takes it from every pane type's command holding it.
        @Test func aChordForEveryPaneTakesItFromEveryPaneTypesCommand() throws {
            let box = try Fixture()
            try box.click("settings-shortcut-git-tree.refresh")
            try box.press(KeyChord("k", [.command]))
            try box.click("settings-shortcut-tabs.newTab")
            try box.press(KeyChord("k", [.command]))
            #expect(try box.detail("tabs.newTab") == "Taken from Clear Buffer and Refresh.")
            #expect(try box.chipText("terminal.clearBuffer") == "Not set")
            #expect(try box.chipText("git-tree.refresh") == "⌘R", "the user's own binding gave way: back to its default (C-2)")
        }

        /// C-5 · "recording an action back onto its own default drops the override".
        @Test func recordingACommandBackOntoItsDefaultDropsTheOverride() throws {
            let box = try Fixture(stored: ["tabs.newTab": "opt+cmd+n"])
            #expect(box.find("settings-shortcut-reset-tabs.newTab") != nil)
            try box.click("settings-shortcut-tabs.newTab")
            try box.press(KeyChord("t", [.command]))
            #expect(box.stored.isEmpty)
            #expect(box.find("settings-shortcut-reset-tabs.newTab") == nil)
        }

        // MARK: Clear, Reset, Restore Defaults

        /// E-1, K-3 · "clearing a binding stores an explicit unbinding, not an absent key".
        @Test func clearingStoresAnExplicitUnbinding() throws {
            let box = try Fixture()
            try box.click("settings-shortcut-clear-tabs.newTab")
            #expect(box.stored == ["tabs.newTab": nil])
            #expect(try box.chipText("tabs.newTab") == "Not set")
            let title = try box.chip("tabs.newTab").attributedTitle
            #expect(title.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor == .secondaryLabelColor, "dimmed")
            // An unbound command is still overridden, so Reset is how you get it back.
            #expect(box.find("settings-shortcut-reset-tabs.newTab") != nil)
            #expect(try !box.button("settings-shortcut-clear-tabs.newTab").isEnabled)
        }

        /// E-2 · "resetting a row removes its override entirely".
        @Test func resettingARowRemovesItsOverrideEntirely() throws {
            let box = try Fixture(stored: ["tabs.newTab": "opt+cmd+n", "tabs.closePane": nil])
            try box.click("settings-shortcut-reset-tabs.newTab")
            #expect(box.stored == ["tabs.closePane": nil])
            #expect(try box.chipText("tabs.newTab") == "⌘T")
        }

        /// E-3, R-10 · "Restore Defaults clears every override at once" — and settles the recorder.
        @Test func restoreDefaultsClearsEveryOverrideAtOnce() throws {
            let box = try Fixture(stored: ["tabs.newTab": "opt+cmd+n", "tabs.navLeft": nil])
            try box.click("settings-shortcut-tabs.closePane")
            try box.press(KeyChord("j", []))
            #expect(try box.model.notice != nil)
            try box.click("settings-shortcuts-restore-defaults")
            #expect(box.stored.isEmpty)
            #expect(try box.model.capturing == nil)
            #expect(try box.model.notice == nil)
            #expect(try box.chipText("tabs.navLeft") == "⌘←")
        }

        /// E-4 · "a second rebind keeps the first, rather than writing a stale record".
        @Test func aSecondRebindKeepsTheFirst() throws {
            let box = try Fixture()
            try box.click("settings-shortcut-tabs.newTab")
            try box.press(KeyChord("n", [.command, .option]))
            try box.click("settings-shortcut-tabs.navLeft")
            try box.press(KeyChord("j", [.command, .option]))
            #expect(box.stored == ["tabs.newTab": "opt+cmd+n", "tabs.navLeft": "opt+cmd+j"])
        }

        /// R-12, R-13: a notice sits under its own row only, until the next recording starts.
        @Test func aNoticeIsItsRowsUntilTheNextRecording() throws {
            let box = try Fixture()
            try box.click("settings-shortcut-tabs.newTab")
            try box.press(KeyChord("w", [.command]))
            #expect(try box.detail("tabs.newTab") == "Taken from Close Pane.")
            #expect(try box.detail("tabs.closePane") == "Close the active pane, confirming first if it still has work running.")
            try box.click("settings-shortcut-tabs.navLeft")
            #expect(try box.detail("tabs.newTab") == "Open a new tab in the active pane.")
        }

        // MARK: Search

        /// S-1, S-2, S-3 · "typing text filters the list…", "a group with no matches drops its own heading".
        @Test func typingTextFiltersTheListAndDropsEmptyGroups() throws {
            let box = try Fixture()
            #expect(try box.searchField.placeholderString == "Search shortcuts, or press a combination…")
            try box.focusSearch()
            try box.type("split")
            #expect(box.searchText == "split")
            #expect(box.listed == ["tabs.splitHorizontal", "tabs.splitVertical"])
            #expect(box.isListed("tabs.splitHorizontal") && box.isListed("tabs.splitVertical"))
            #expect(!box.isListed("tabs.newTab") && !box.isListed("tabs.navLeft"))
            #expect(try box.model.groups.map(\.id) == ["Panes & Tabs"])
        }

        /// S-4 · "typing a bound key combination filters to the shortcut bound to it, exactly".
        @Test func typingABoundCombinationFiltersToItExactly() throws {
            let box = try Fixture()
            try box.focusSearch()
            try box.type("cmd+t")
            #expect(box.listed == ["tabs.newTab"])
        }

        /// S-5 · "a combination query follows a rebind, not the shipped default".
        @Test func aCombinationQueryFollowsARebind() throws {
            let box = try Fixture(stored: ["tabs.newTab": "opt+cmd+n"])
            try box.focusSearch()
            try box.type("cmd+t")
            #expect(box.listed.isEmpty)
            try box.searchField.stringValue = ""
            try box.model.query = ""
            try box.type("alt+cmd+n")
            #expect(box.listed == ["tabs.newTab"])
        }

        /// S-6 · "the clear button empties the field and restores the full list".
        @Test func theClearButtonEmptiesTheFieldAndRestoresTheList() throws {
            let box = try Fixture()
            try box.focusSearch()
            try box.type("split")
            #expect(!box.isListed("tabs.newTab"))
            let field = try box.searchField
            let cell = try #require(field.cell as? NSSearchFieldCell)
            let cancel = try #require(cell.cancelButtonCell)
            // The clear button does what its cell's action says, the way a click sends it.
            _ = NSApp.sendAction(try #require(cancel.action), to: cancel.target, from: field)
            box.settle()
            #expect(box.searchText == "")
            #expect(box.isListed("tabs.newTab") && box.isListed("tabs.splitHorizontal"))
        }

        /// S-7 · "a query matching nothing shows the empty-state placeholder instead of a blank page".
        @Test func aQueryMatchingNothingShowsTheEmptyState() throws {
            let box = try Fixture()
            try box.focusSearch()
            try box.type("zzzzz")
            // The view shows "No shortcuts match your search." exactly when no group is left.
            #expect(try box.model.groups.isEmpty)
            let chips = box.window.contentView?.allSubviews.filter {
                $0 is NSButton && $0.accessibilityIdentifier().hasPrefix("settings-shortcut-")
            }
            #expect(chips?.isEmpty == true)
            try snapshot(box, "settings-keyboard-empty")
        }

        /// S-8 · "focusing the search box arms capture, and pressing a bound combination types it as text".
        @Test func pressingABoundCombinationInTheSearchFieldTypesIt() throws {
            let box = try Fixture()
            let panes = try box.ui.layout.leaves.count
            try box.focusSearch()
            #expect(try box.press(KeyChord("t", [.command])))
            #expect(box.searchText == "cmd+t")
            #expect(box.listed == ["tabs.newTab"])
            #expect(box.stored.isEmpty, "a search, not a recording")
            #expect(try box.ui.layout.leaves.count == panes, "nothing ran")
        }

        /// S-9 · "pressing a nav combination while searching types it as text too, without moving anything".
        @Test func pressingANavCombinationWhileSearchingTypesItToo() throws {
            let box = try Fixture()
            try box.focusSearch()
            try box.press(KeyChord(.arrow(.left), [.command]))
            #expect(box.searchText == "cmd+left")
        }

        /// S-10 · "pressing a combination inserts it at the cursor, not always at the end".
        @Test func pressingACombinationInsertsItAtTheCursor() throws {
            let box = try Fixture()
            try box.focusSearch()
            try box.type("foobar")
            let editor = try #require(try box.keys.searchEditor)
            editor.setSelectedRange(NSRange(location: 3, length: 0))
            try box.press(KeyChord("t", [.control]))
            #expect(box.searchText == "fooctrl+tbar")
            #expect(editor.selectedRange() == NSRange(location: 9, length: 0))
        }

        /// S-11 · "bare typing in the search box is untouched — no interception without a real modifier".
        @Test func bareTypingInTheSearchFieldIsUntouched() throws {
            let box = try Fixture()
            try box.focusSearch()
            try box.type("Close Pane")
            #expect(box.searchText == "Close Pane")
            let shifted = try #require(InputSynthesizer.chordEvent(.keyDown, KeyChord("p", [.shift]), in: box.window))
            #expect(try !box.keys.handle(shifted), "⇧ alone is typing")
        }

        /// S-12: a fixed item's chord keeps its meaning in the field — the page leaves it to the menu.
        @Test func aFixedItemsChordKeepsItsMeaningInTheField() throws {
            let box = try Fixture()
            try box.focusSearch()
            for chord in [KeyChord("a", [.command]), KeyChord("v", [.command]), KeyChord("c", [.command]), KeyChord("z", [.command])] {
                let down = try #require(InputSynthesizer.chordEvent(.keyDown, chord, in: box.window))
                #expect(try !box.keys.handle(down), "\(chord)")
            }
            #expect(box.searchText == "")
        }

        /// S-13 · "focusing the search box ends a chip recording rather than fighting it".
        @Test func focusingTheSearchFieldEndsARecording() throws {
            let box = try Fixture()
            try box.click("settings-shortcut-tabs.newTab")
            #expect(try box.chipText("tabs.newTab") == "Press keys…")
            try box.focusSearch()
            #expect(try box.chipText("tabs.newTab") == "⌘T")
            try box.type("split")
            #expect(box.searchText == "split")
            #expect(box.stored.isEmpty)
        }

        // MARK: Effects and persistence

        /// M-1 · e2e "rebinding an action rebuilds the real menu, and the item still works".
        @Test func aRebindChangesTheMenuAtOnceAndTheItemStillWorks() throws {
            let box = try Fixture()
            #expect(box.menuChord("tabs.closePane")?.0 == "w")
            try box.click("settings-shortcut-tabs.closePane")
            try box.press(KeyChord("n", [.command, .option]))
            let chord = try #require(box.menuChord("tabs.closePane"))
            #expect(chord.0 == "n")
            #expect(chord.1 == [.command, .option])

            let first = try #require(box.ui.activePane)
            try box.ui.choose("File", "New Horizontal Split")
            let panes = try box.ui.layout.leaves.count
            #expect(panes == 2)
            try box.ui.choose("File", "Close Pane")
            #expect(try box.ui.layout.leaves.map(\.id) == [first])
        }

        /// M-2 · e2e "clearing a binding leaves the item in the menu with no accelerator".
        @Test func aClearedCommandKeepsItsMenuItemWithNoKeyEquivalent() throws {
            let box = try Fixture()
            try box.click("settings-shortcut-clear-tabs.newWindow")
            #expect(box.menuChord("tabs.newWindow")?.0 == "")
            let windows = box.ui.renderer.windows.count
            try box.ui.choose("File", "New Window")
            #expect(box.ui.renderer.windows.count == windows + 1, "still there, still works")
        }

        /// M-3 · e2e "a rebound navigation shortcut moves pane focus in the real app".
        @Test func aReboundNavigationChordMovesPaneFocus() throws {
            let box = try Fixture()
            try box.click("settings-shortcut-tabs.navRight")
            try box.press(KeyChord("l", [.command, .option]))
            #expect(try box.model.capturing == nil)

            let first = try #require(box.ui.activePane)
            try box.ui.choose("File", "New Horizontal Split")
            let second = try #require(box.ui.activePane)
            #expect(second != first)
            try box.ui.engine.perform(in: box.ui.window.windowID) { layout, _ in layout.setActivePane(first) }
            box.ui.layoutAll()
            // The old combination does nothing now…
            #expect(try !box.ui.press(KeyChord(.arrow(.right), [.command])))
            #expect(box.ui.activePane == first)
            // …and the new one navigates.
            #expect(try box.ui.press(KeyChord("l", [.command, .option])))
            #expect(box.ui.activePane == second)
        }

        /// M-4, K-8 · e2e "a rebinding survives a relaunch, in the menu and in the Settings list".
        @Test func storedBindingsShowOnThePageAndInTheMenu() throws {
            let box = try Fixture(stored: ["tabs.newTab": "opt+cmd+n", "terminal.clearBuffer": nil, "tabs.navLeft": "cmd+c"])
            #expect(try box.chipText("tabs.newTab") == "⌥⌘N")
            #expect(box.menuChord("tabs.newTab")?.0 == "n")
            #expect(try box.chipText("terminal.clearBuffer") == "Not set")
            #expect(try box.chipText("tabs.navLeft") == "⌘←", "a stored chord that can't be used: its default")
            let navLeft = try #require(try box.model.binding("tabs.navLeft"))
            #expect(try box.model.explanation(of: navLeft) == "Your shortcut “cmd+c” can’t be used here, so it has its default.")
            #expect(box.find("settings-shortcut-reset-tabs.navLeft") != nil)
        }

        /// A picture of the page, for looking at (TABS_SNAPSHOT_DIR).
        private func snapshot(_ box: Fixture, _ name: String) throws {
            guard let directory = ProcessInfo.processInfo.environment["TABS_SNAPSHOT_DIR"], let view = box.window.contentView else {
                return
            }
            view.layoutSubtreeIfNeeded()
            let image = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: image)
            try image.representation(using: .png, properties: [:])?.write(to: URL(filePath: directory).appending(path: "\(name).png"))
        }
    }
}
