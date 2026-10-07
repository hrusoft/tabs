import AppKit
import Testing

@testable import TabsCore

/// J-14, J-15: for the AppKit event model, a keystroke is a key-down and a key-up
/// (the character rides the key-down, and inserts once), text with no key behind
/// it is one `text`. What the page then sees is measured against a real page in
/// `BrowserInputTests`.
@Suite struct KeystrokesTests {
    private func kinds(_ events: [KeystrokeEvent]) -> [KeystrokeEvent.Kind] { events.map(\.kind) }

    @Test func pressesEnterAsAKeyDownAndAKeyUpWhichIsWhatSubmitsAForm() {
        // The key-down carries the return character: it is what the page sees as
        // `keydown` then `keypress`, and a form submits from Enter's keypress, exactly
        // once. A separate text event would type it twice.
        #expect(keystrokeEvents("Enter") == [KeystrokeEvent(.keyDown, "Enter"), KeystrokeEvent(.keyUp, "Enter")])
        #expect(keystrokeEvents("Return") == keystrokeEvents("Enter"))
        #expect(keystrokeEvents("Space") == [KeystrokeEvent(.keyDown, " "), KeystrokeEvent(.keyUp, " ")])
    }

    @Test func givesAPrintableKeyItsCharacterAndShiftToACapitalLetter() {
        #expect(kinds(keystrokeEvents("a")) == [.keyDown, .keyUp])
        #expect(keystrokeEvents("A") == [KeystrokeEvent(.keyDown, "A", [.shift]), KeystrokeEvent(.keyUp, "A", [.shift])])
        // Not doubled when the caller already holds it.
        #expect(keystrokeEvents("A", modifiers: [.shift])[0].modifiers == [.shift])
        // A symbol on a shifted key gets its shift as a keyboard would send it.
        #expect(keystrokeEvents("!")[0].modifiers == [.shift])
        #expect(keystrokeEvents("1")[0].modifiers == [])
    }

    @Test func sendsNoCharacterForANamedKeyThatProducesNone() {
        // A key-down for F5 carries a function-key code point, which inserts nothing.
        for key in ["F5", "Tab", "Escape", "Backspace", "Delete", "Home", "ArrowLeft"] {
            #expect(kinds(keystrokeEvents(key)) == [.keyDown, .keyUp], "\(key)")
            let physical = USKeyboard.physicalKey(for: key)
            #expect(physical != nil, "\(key)")
        }
        #expect(!USKeyboard.isKnown("Bogus"))
    }

    @Test func aChordWithMetaOrControlStaysAKeyDownAndKeyUpWithTheFlagSet() {
        for modifier in [KeyModifier.meta, .control] {
            #expect(kinds(keystrokeEvents("Enter", modifiers: [modifier])) == [.keyDown, .keyUp], "\(modifier)")
            #expect(kinds(keystrokeEvents("k", modifiers: [modifier])) == [.keyDown, .keyUp], "\(modifier)")
            #expect(keystrokeEvents("k", modifiers: [modifier])[0].modifiers == [modifier])
        }
        // Shift and alt: shift+Enter is a line break in a textarea.
        #expect(kinds(keystrokeEvents("Enter", modifiers: [.shift])) == [.keyDown, .keyUp])
        #expect(kinds(keystrokeEvents("a", modifiers: [.alt])) == [.keyDown, .keyUp])
    }

    @Test func keepsTheDOMArrowNamesAndTheirModifiers() {
        #expect(
            keystrokeEvents("ArrowLeft", modifiers: [.alt]) == [
                KeystrokeEvent(.keyDown, "ArrowLeft", [.alt]), KeystrokeEvent(.keyUp, "ArrowLeft", [.alt]),
            ])
        let arrow = USKeyboard.physicalKey(for: "ArrowDown")
        #expect(arrow?.keyCode == 125)
        #expect(arrow?.flags.contains(.function) == true)
    }

    @Test func typesEachPrintableASCIICharacterAsAFullKeystroke() {
        let events = typingEvents("Hi!")
        #expect(
            events.map { "\($0.kind):\($0.key)" } == [
                "keyDown:H", "keyUp:H", "keyDown:i", "keyUp:i", "keyDown:!", "keyUp:!",
            ])
        // Exactly one key-down per character: nothing can double.
        #expect(events.filter { $0.kind == .keyDown }.count == 3)
    }

    @Test func sendsACharacterWithNoKeyBehindItAsTextAlone() {
        #expect(typingEvents("é日") == [KeystrokeEvent(.text, "é"), KeystrokeEvent(.text, "日")])
        // By character, so an astral one stays whole.
        #expect(typingEvents("😀") == [KeystrokeEvent(.text, "😀")])
        #expect(keystrokeEvents("é") == [KeystrokeEvent(.text, "é")])
    }

    @Test func aUSKeyboardKnowsEveryPrintableASCIICharacter() {
        for scalar in 0x20...0x7e {
            let key = String(UnicodeScalar(UInt8(scalar)))
            #expect(USKeyboard.physicalKey(for: key) != nil, "\(key)")
        }
        // The key code is the key's, not the character's: `!` is the `1` key.
        #expect(USKeyboard.physicalKey(for: "!")?.keyCode == USKeyboard.physicalKey(for: "1")?.keyCode)
        #expect(USKeyboard.physicalKey(for: "!")?.charactersIgnoringModifiers == "1")
        #expect(USKeyboard.physicalKey(for: "H")?.charactersIgnoringModifiers == "h")
    }
}
