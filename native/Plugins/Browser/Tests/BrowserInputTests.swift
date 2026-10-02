import AppKit
import Foundation
import TabsPluginSDK
import Testing
import WebKit

@testable import TabsCore

/// Trusted input into the page (docs/BROWSER.md J-12…J-15, D-7, and the measurements
/// behind `Keystrokes` and `PageInput`), against an event-logging fixture in a
/// window that is never shown. Every line of the log reads
/// `type:key:code:modifiers:trusted[:data]`.
@MainActor
@Suite struct BrowserInputTests {
    private func bed() async throws -> PageBed {
        let bed = try await PageBed(serving: { server in
            server.page("/events", title: "Events", body: PageBed.eventsPage)
            server.page("/submitted", title: "Submitted", body: "done")
        })
        await bed.load("/events")
        return bed
    }

    private func input(_ bed: PageBed) -> PageInput { PageInput(page: bed.page) }

    /// J-12: a click arrives as trusted `mousedown`, `mouseup` and `click`, and focuses what it hits.
    @Test func aClickArrivesAsTrustedMouseEventsAndFocusesTheField() async throws {
        let bed = try await bed()
        try await input(bed).click(x: 50, y: 25)
        let log = await bed.eventLog()
        #expect(log.contains { $0.hasPrefix("mousedown:") && $0.hasSuffix(":::T") || $0 == "mousedown::::T" })
        #expect(log.contains("mouseup::::T") && log.contains("click::::T"), "\(log)")
        #expect(await bed.value("document.activeElement.id") == "a")
        try await input(bed).click(x: 240, y: 30)
        #expect(await bed.eventLog().contains("btn-click"))
    }

    /// J-14: every printable ASCII character is a full keydown, keypress, input, keyup, inserting once (shift for capitals).
    @Test func typingDeliversEachCharacterAsKeydownKeypressInputAndKeyupInsertingOnce() async throws {
        let bed = try await bed()
        try await input(bed).click(x: 50, y: 25)
        _ = await bed.eventLog()
        try await input(bed).send(typingEvents("Hi!"))
        #expect(await bed.value("document.getElementById('a').value") == "Hi!")
        let log = await bed.eventLog()
        #expect(
            log == [
                "keydown:H:KeyH:S:T", "keypress:H:KeyH:S:T", "beforeinput::::T:d=H", "input::::T:d=H", "keyup:H:KeyH:S:T",
                "keydown:i:KeyI::T", "keypress:i:KeyI::T", "beforeinput::::T:d=i", "input::::T:d=i", "keyup:i:KeyI::T",
                "keydown:!:Digit1:S:T", "keypress:!:Digit1:S:T", "beforeinput::::T:d=!", "input::::T:d=!", "keyup:!:Digit1:S:T",
            ], "\(log)")
    }

    /// J-14: Enter from `key` and from `type --submit` submits a plain form, once.
    @Test func enterSubmitsAPlainFormExactlyOnce() async throws {
        let bed = try await bed()
        try await input(bed).click(x: 50, y: 25)
        try await input(bed).send(typingEvents("Hi"))
        _ = await bed.eventLog()
        try await input(bed).send(keystrokeEvents("Enter"))
        #expect(await eventually { bed.page.url == bed.url("/submitted?q=Hi") })
        #expect(bed.server.requests.filter { $0.path == "/submitted" }.count == 1, "exactly once")
    }

    @Test func enterInATextareaAddsOneLineBreak() async throws {
        let bed = try await bed()
        try await input(bed).click(x: 50, y: 90)
        _ = await bed.eventLog()
        try await input(bed).send(keystrokeEvents("Enter"))
        #expect(await bed.value("JSON.stringify(document.getElementById('b').value)") == "\"\\n\"")
        let log = await bed.eventLog()
        #expect(
            log == ["keydown:Enter:Enter::T", "keypress:Enter:Enter::T", "beforeinput::::T", "input::::T", "keyup:Enter:Enter::T"], "\(log)"
        )
    }

    /// J-14: a character with no key behind it arrives as text alone.
    @Test func aCharacterWithNoKeyBehindItArrivesAsTextAlone() async throws {
        let bed = try await bed()
        try await input(bed).click(x: 50, y: 90)
        _ = await bed.eventLog()
        try await input(bed).send(typingEvents("é日😀"))
        #expect(await bed.value("document.getElementById('b').value") == "é日😀")
        let log = await bed.eventLog()
        #expect(log.allSatisfy { $0.hasPrefix("beforeinput:") || $0.hasPrefix("input:") }, "no keydown, no keyup: \(log)")
        #expect(log.count == 6, "\(log)")
    }

    /// J-14: text mixing keys with characters that have none lands in the order given. Inserted text applies at
    /// once while keys queue behind each other's acknowledgement, so an insert sent unpaced overtakes them.
    @Test func textMixingKeysAndCharactersWithNoKeyLandsInOrder() async throws {
        let bed = try await bed()
        try await input(bed).click(x: 50, y: 90)
        try await input(bed).send(typingEvents("café 日本 ok"))
        #expect(await bed.value("document.getElementById('b').value") == "café 日本 ok")
    }

    /// J-15: arrows keep `key` and `code` intact under every modifier, alt included.
    @Test func arrowKeysKeepTheirKeyAndCodeUnderEveryModifier() async throws {
        let bed = try await bed()
        try await input(bed).click(x: 50, y: 90)
        for (modifier, flag) in [(KeyModifier.alt, "A"), (.shift, "S"), (.control, "C"), (.meta, "M")] {
            _ = await bed.eventLog()
            for arrow in ["ArrowLeft", "ArrowRight", "ArrowUp", "ArrowDown"] {
                try await input(bed).send(keystrokeEvents(arrow, modifiers: [modifier]))
                let log = await bed.eventLog()
                #expect(log.contains("keydown:\(arrow):\(arrow):\(flag):T"), "\(arrow) \(modifier): \(log)")
                #expect(log.contains("keyup:\(arrow):\(arrow):\(flag):T"), "\(arrow) \(modifier): \(log)")
            }
        }
    }

    /// J-15: a chord with meta or control produces keydown and keyup with the flag and no character.
    @Test func aChordWithMetaOrControlInsertsNothing() async throws {
        let bed = try await bed()
        try await input(bed).click(x: 50, y: 90)
        try await input(bed).send(typingEvents("abc"))
        _ = await bed.eventLog()
        for (modifier, flag) in [(KeyModifier.meta, "M"), (.control, "C")] {
            try await input(bed).send(keystrokeEvents("j", modifiers: [modifier]))
            let log = await bed.eventLog()
            #expect(log.contains("keydown:j:KeyJ:\(flag):T"), "\(log)")
            #expect(
                !log.contains { $0.hasPrefix("keypress:") || $0.hasPrefix("beforeinput:") && $0.contains("d=j") }, "no character: \(log)")
        }
        #expect(await bed.value("document.getElementById('b').value").stringValue?.contains("j") == false)
    }

    /// J-15: what WebKit does differently from the Electron premise (see docs/BROWSER.md, Known differences): a
    /// synthesized ⌘A is delivered to the page as `keydown` but never reaches the editing layer, exactly as in
    /// Chromium; the responder chain's `selectAll:` (what the Edit menu sends) and `execCommand` do.
    @Test func aSynthesizedCommandAReachesThePageButNotTheEditingLayer() async throws {
        let bed = try await bed()
        try await input(bed).click(x: 50, y: 90)
        try await input(bed).send(typingEvents("hello"))
        _ = await bed.eventLog()
        try await input(bed).send(keystrokeEvents("a", modifiers: [.meta]))
        let log = await bed.eventLog()
        #expect(log.contains("keydown:a:KeyA:M:T"), "\(log)")
        let selection = "document.getElementById('b').selectionStart + '-' + document.getElementById('b').selectionEnd"
        #expect(await bed.value(selection) == "5-5", "the caret didn't move: nothing was selected")
        // The Edit menu's route: the responder chain.
        #expect(bed.page.webView.tryToPerform(#selector(NSText.selectAll(_:)), with: nil))
        #expect(await bed.value(selection) == "0-5")
        // And `--command`'s.
        await bed.value("(document.getElementById('b').setSelectionRange(2, 2), 1)")
        _ = await bed.value(editingCommandScript("selectAll"))
        #expect(await bed.value(selection) == "0-5")
    }

    /// D-9: Edit ▸ Undo and Redo act on the page's own history, not the window's.
    @Test func undoAndRedoAreThePanesOwn() async throws {
        let bed = try await bed()
        try await input(bed).click(x: 50, y: 90)
        let web = bed.page.webView
        #expect(web.undoManager !== bed.window.undoManager)
        try await input(bed).send(typingEvents("hello"))
        #expect(await bed.value("document.getElementById('b').value") == "hello")
        #expect(web.undoManager?.canUndo == true, "typing registered what it did")
        #expect(web.tryToPerform(NSSelectorFromString("undo:"), with: nil))
        #expect(await eventually { web.undoManager?.canRedo == true })
        #expect(await bed.value("document.getElementById('b').value").stringValue != "hello", "undone")
        #expect(web.tryToPerform(NSSelectorFromString("redo:"), with: nil))
        #expect(await eventually { web.undoManager?.canUndo == true })
    }

    /// The delete key edits (a named key with no character is still a key-down the field acts on).
    @Test func backspaceEditsTheField() async throws {
        let bed = try await bed()
        try await input(bed).click(x: 50, y: 90)
        try await input(bed).send(typingEvents("abc"))
        try await input(bed).send(keystrokeEvents("Backspace"))
        #expect(await bed.value("document.getElementById('b').value") == "ab")
    }

    /// J-13: in the key window a move arrives as a trusted `mousemove` and hovers what it lands on, and the hover
    /// holds; in any other window WebKit delivers no move at all, so it is refused rather than sent.
    @Test func aMoveHoversThePageInTheKeyWindowAndIsRefusedInAnyOther() async throws {
        let bed = try await bed()
        let hovered = "getComputedStyle(document.getElementById('hov')).backgroundColor"
        _ = await bed.eventLog()
        await #expect(throws: PageInput.Failure.windowNotActive) { try await input(bed).move(x: 240, y: 120) }
        #expect(await bed.eventLog().isEmpty)
        #expect(await bed.value(hovered) == "rgb(238, 238, 238)")

        await bed.window.setKey(true)
        try await input(bed).move(x: 240, y: 120)
        #expect(await bed.eventLog() == ["mousemove::::T"], "the move has landed by the time move returns")
        #expect(await bed.value(hovered) == "rgb(0, 255, 0)")
        try await Task.sleep(for: .milliseconds(200))
        #expect(await bed.value(hovered) == "rgb(0, 255, 0)", "the hover holds until the next pointer event")
    }

    /// The pane must be mounted to be driven: a page with no window has nowhere to send an event.
    @Test func aPageThatIsNotInAWindowRefusesInput() async throws {
        let bed = try await PageBed(mounted: false)
        let input = PageInput(page: bed.page)
        await #expect(throws: PageInput.Failure.notMounted) { try await input.click(x: 1, y: 1) }
        await #expect(throws: PageInput.Failure.notMounted) { try await input.send(keystrokeEvents("a")) }
        await #expect(throws: PageInput.Failure.notMounted) { try await input.move(x: 1, y: 1) }
    }

    /// D-7: input a verb sends never leaves the window's keyboard focus moved.
    @Test func drivingThePageNeverStealsKeyboardFocusFromWhereItWas() async throws {
        let bed = try await bed()
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 340))
        let field = NSTextField(frame: NSRect(x: 0, y: 300, width: 400, height: 24))
        bed.page.webView.frame = NSRect(x: 0, y: 0, width: 400, height: 300)
        bed.window.contentView = container
        container.addSubview(bed.page.webView)
        container.addSubview(field)
        #expect(bed.window.makeFirstResponder(field))
        let editor = try #require(bed.window.firstResponder)
        #expect((editor as? NSText)?.delegate === field)
        await input(bed).withHostFocusRestored {
            try? await input(bed).click(x: 50, y: 25)
            // The page pulled the keyboard, as `el.focus()` or a click does.
            #expect(bed.window.firstResponder !== editor, "the page took the keyboard: \(String(describing: bed.window.firstResponder))")
        }
        #expect(
            (bed.window.firstResponder as? NSText)?.delegate === field || bed.window.firstResponder === field,
            "focus is where it was: \(String(describing: bed.window.firstResponder))")
        // The page's own idea of what is focused survived, so later input still lands there.
        #expect(await bed.value("document.activeElement.id") == "a")
        await input(bed).withHostFocusRestored { try? await input(bed).send(typingEvents("ok")) }
        #expect(await bed.value("document.getElementById('a').value") == "ok", "and typing reaches the field the page still has focused")
        #expect((bed.window.firstResponder as? NSText)?.delegate === field || bed.window.firstResponder === field)
    }
}
