import Foundation
import TabsPluginSDK
import Testing

@testable import TabsCore

/// Settings ▸ Keyboard's text (docs/KEYBOARD.md): the Electron app's
/// packages/plugin-sdk/shared/__tests__/shortcuts.test.ts, ported for native chords, with its
/// test names kept where the case carries over.
@Suite struct ShortcutTextTests {
    // MARK: formatBinding

    @Test func usesMacOSGlyphsInTheOrderMacOSItselfShowsThem() {
        #expect(ShortcutText.formatBinding(KeyChord("t", [.command])) == "⌘T")
        #expect(ShortcutText.formatBinding(KeyChord("t", [.command, .control, .option, .shift])) == "⌃⌥⇧⌘T")
        #expect(ShortcutText.formatBinding(KeyChord(.arrow(.left), [.command])) == "⌘←")
    }

    @Test func namesTheKeysAsTheElectronPageDoes() {
        #expect(ShortcutText.formatBinding(KeyChord(.return, [.command])) == "⌘Enter")
        #expect(ShortcutText.formatBinding(KeyChord(.space, [.control])) == "⌃Space")
        #expect(ShortcutText.formatBinding(KeyChord(.delete, [.command])) == "⌘⌫")
        #expect(ShortcutText.formatBinding(KeyChord(.function(5), [])) == "F5")
        #expect(ShortcutText.formatBinding(KeyChord(",", [.command])) == "⌘,")
    }

    @Test func labelsAnUnboundAction() {
        #expect(ShortcutText.formatBinding(nil) == "Not set")
        #expect(ShortcutText.formatModifiers([.command, .control]) == "⌃⌘", "the recorder's preview")
        #expect(ShortcutText.formatModifiers([]) == "")
    }

    // MARK: Validation helpers

    @Test func requiresARealModifierSoABareKeyIsntASearchCombination() {
        #expect(!ShortcutText.hasRequiredModifier(KeyChord("t", [])))
        #expect(!ShortcutText.hasRequiredModifier(KeyChord("t", [.shift])))
        #expect(ShortcutText.hasRequiredModifier(KeyChord("t", [.command])))
        #expect(ShortcutText.hasRequiredModifier(KeyChord("t", [.option])))
        #expect(ShortcutText.hasRequiredModifier(KeyChord("t", [.control])))
    }

    @Test func recognisesABareCtrlLetterChord() {
        #expect(ShortcutText.isBareCtrlLetterChord(KeyChord("c", [.control])))
        #expect(!ShortcutText.isBareCtrlLetterChord(KeyChord("c", [.control, .command])))
        #expect(!ShortcutText.isBareCtrlLetterChord(KeyChord("c", [.control, .option])))
        #expect(!ShortcutText.isBareCtrlLetterChord(KeyChord(.arrow(.left), [.control])))
        #expect(!ShortcutText.isBareCtrlLetterChord(KeyChord("1", [.control])))
    }

    /// V-1: AppKit's private-use function-key characters (Home, End, Page Up, forward Delete)
    /// have no shortcut form.
    @Test func keysWithNoShortcutFormAreRefused() {
        for scalar in [0xF729, 0xF72B, 0xF72C, 0xF728] {
            #expect(!ShortcutText.isRecordable(.character(Character(UnicodeScalar(scalar)!))), "\(scalar)")
        }
        #expect(ShortcutText.isRecordable(.character("t")))
        #expect(ShortcutText.isRecordable(.character("?")))
        #expect(ShortcutText.isRecordable(.function(5)))
    }

    // MARK: parseSearchChord

    @Test func parsesAModifierWordPlusASingleLetterCaseInsensitively() {
        #expect(ShortcutText.parseSearchChord("cmd+t") == KeyChord("t", [.command]))
        #expect(ShortcutText.parseSearchChord("CMD+T") == KeyChord("t", [.command]))
        #expect(ShortcutText.parseSearchChord("command+t") == KeyChord("t", [.command]))
    }

    @Test func doesNotCareAboutTokenOrder() {
        #expect(ShortcutText.parseSearchChord("shift+cmd+n") == KeyChord("n", [.command, .shift]))
        #expect(ShortcutText.parseSearchChord("cmd+shift+n") == KeyChord("n", [.command, .shift]))
    }

    @Test func foldsMultipleModifierWordsTogether() {
        #expect(ShortcutText.parseSearchChord("cmd+alt+t") == KeyChord("t", [.command, .option]))
        #expect(ShortcutText.parseSearchChord("cmd+option+t") == KeyChord("t", [.command, .option]))
        #expect(ShortcutText.parseSearchChord("cmd+opt+t") == KeyChord("t", [.command, .option]))
    }

    @Test func ctrlIsTheControlKey() {
        #expect(ShortcutText.parseSearchChord("ctrl+t") == KeyChord("t", [.control]))
        #expect(ShortcutText.parseSearchChord("control+t") == KeyChord("t", [.control]))
    }

    @Test func parsesDigitsFKeysAndNamedKeys() {
        #expect(ShortcutText.parseSearchChord("cmd+1") == KeyChord("1", [.command]))
        #expect(ShortcutText.parseSearchChord("cmd+f5") == KeyChord(.function(5), [.command]))
        #expect(ShortcutText.parseSearchChord("cmd+left") == KeyChord(.arrow(.left), [.command]))
        #expect(ShortcutText.parseSearchChord("cmd+,") == KeyChord(",", [.command]))
        #expect(ShortcutText.parseSearchChord("cmd+return") == KeyChord(.return, [.command]))
        #expect(ShortcutText.parseSearchChord("cmd+backspace") == KeyChord(.delete, [.command]))
        #expect(ShortcutText.parseSearchChord("cmd+?") == KeyChord("?", [.command]), "a native chord is the character keys make")
    }

    @Test func refusesABareKeyWithNoModifier() {
        #expect(ShortcutText.parseSearchChord("t") == nil)
    }

    @Test func refusesMoreThanOneNonModifierToken() {
        #expect(ShortcutText.parseSearchChord("cmd+t+w") == nil)
    }

    @Test func refusesAnUnrecognizedKeyTokenAndOrdinaryTextWithNoPlusAtAll() {
        #expect(ShortcutText.parseSearchChord("cmd+nonsense") == nil)
        #expect(ShortcutText.parseSearchChord("new tab") == nil)
        #expect(ShortcutText.parseSearchChord("") == nil)
    }

    // MARK: formatChordAsQuery

    @Test func spellsThePlatformModifierAsAWordLowercased() {
        #expect(ShortcutText.formatChordAsQuery(KeyChord("t", [.command])) == "cmd+t")
        #expect(ShortcutText.formatChordAsQuery(KeyChord("t", [.control])) == "ctrl+t")
    }

    @Test func ordersModifiersCmdCtrlAltShift() {
        #expect(ShortcutText.formatChordAsQuery(KeyChord("t", [.command, .option, .shift])) == "cmd+alt+shift+t")
        #expect(ShortcutText.formatChordAsQuery(KeyChord("t", [.shift, .control, .command])) == "cmd+ctrl+shift+t")
    }

    @Test func formatsNamedAndPunctuationKeysLowercased() {
        #expect(ShortcutText.formatChordAsQuery(KeyChord(.arrow(.left), [.command])) == "cmd+left")
        #expect(ShortcutText.formatChordAsQuery(KeyChord(",", [.command])) == "cmd+,")
        #expect(ShortcutText.formatChordAsQuery(KeyChord(.delete, [.command])) == "cmd+backspace")
    }

    @Test func returnsNilForAKeyWithNoSpelling() {
        #expect(ShortcutText.formatChordAsQuery(KeyChord(.character(Character(UnicodeScalar(0xF729)!)), [.command])) == nil)
    }

    /// What the search field does with a pressed chord: text, then parsed back.
    @Test @MainActor func roundTripsThroughParseSearchChordForEveryShippedDefault() {
        for command in CoreCommands.all {
            guard let chord = command.defaultChord else { continue }
            let text = ShortcutText.formatChordAsQuery(chord)
            #expect(text != nil, "\(command.id)")
            #expect(text.flatMap(ShortcutText.parseSearchChord) == chord, "\(command.id)")
        }
    }

    // MARK: visibleGroups

    @MainActor private func bindings() -> [Shortcuts.Binding] {
        let runtime = TestSupport.runtime(dataDirectory: TestSupport.temporaryDirectory())
        runtime.startPlugins(
            from: nil,
            inProcess: [
                TestSupport.candidate(TestSupport.manifest("term", contentTypes: ["term"])) { context in
                    context.register(TestSupport.contentType("term"))
                    context.register(
                        CommandContribution(
                            id: "term.clear", title: "Clear Buffer", summary: "Clear the terminal.", menu: .edit,
                            defaultChord: KeyChord("k", [.command]), appliesTo: "term"
                        ) { _ in })
                }
            ])
        return runtime.shortcuts.bindings
    }

    @Test @MainActor func anEmptyQueryShowsEveryRebindableCommandInItsGroups() {
        let groups = ShortcutText.visibleGroups("", in: bindings())
        #expect(groups.map(\.group) == ["Application", "Panes & Tabs", "Navigation", "Term"])
        #expect(!groups.flatMap(\.bindings).contains { $0.isFixed }, "K-5: the fixed items aren't listed")
    }

    @Test @MainActor func typingTextFiltersToMatchingLabelsDescriptionsAndGroups() {
        let bindings = bindings()
        #expect(
            ShortcutText.visibleGroups("split", in: bindings).flatMap(\.bindings).map(\.command) == [
                "tabs.splitHorizontal", "tabs.splitVertical",
            ])
        #expect(ShortcutText.visibleGroups("SCROLL", in: bindings).isEmpty)
        #expect(
            ShortcutText.visibleGroups("the terminal", in: bindings).flatMap(\.bindings).map(\.command) == ["term.clear"], "a description")
        #expect(ShortcutText.visibleGroups("navigation", in: bindings).map(\.group) == ["Navigation"], "a group's name")
        #expect(ShortcutText.visibleGroups("zzzzz", in: bindings).isEmpty)
    }

    @Test @MainActor func aCombinationMatchesTheCommandBoundToItExactly() {
        let bindings = bindings()
        #expect(ShortcutText.visibleGroups("cmd+t", in: bindings).flatMap(\.bindings).map(\.command) == ["tabs.newTab"])
        #expect(ShortcutText.visibleGroups("shift+cmd+t", in: bindings).flatMap(\.bindings).map(\.command) == ["tabs.splitHorizontal"])
        #expect(ShortcutText.visibleGroups("cmd+k", in: bindings).flatMap(\.bindings).map(\.command) == ["term.clear"])
        #expect(ShortcutText.visibleGroups("cmd+c", in: bindings).isEmpty, "a fixed item's chord shows nothing")
    }
}
