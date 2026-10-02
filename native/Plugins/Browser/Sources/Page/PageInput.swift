import AppKit
import TabsPluginSDK
import WebKit

/// Trusted input into the page (`inputVerbs.ts`'s `clickAt` and `send`,
/// `targeting.ts`'s `clickAt`): `NSEvent`s handed straight to the web view, the way
/// `sendInputEvent` injects into a `<webview>` guest. They reach the page as
/// real events (`isTrusted`), which is the whole reason for not dispatching DOM
/// events from script. Measured, in a window that was never shown:
///
/// - **A click** (`mouseDown`/`mouseUp` sent to the view) arrives as trusted
///   `mousedown`, `mouseup` and `click`, and a keystroke as trusted
///   `keydown`/`keypress`/`input`/`keyup`.
/// - **A move** is not a responder message: `WKWebView` hears real moves through
///   its tracking areas, and a `mouseMoved` sent to the view (or to their owners)
///   reaches no page in any window. It goes in through `_simulateMouseMove:`
///   instead (WebKit's own SPI for its tests, macOS 13+), and arrives as a
///   trusted `mousemove` that hovers what it lands on, **in the key window only**:
///   a button-less move in a page whose window isn't key (`FocusController::isActive`,
///   which follows `isKeyWindow`) only updates scrollbars, so `:hover` stays frozen
///   and no event fires (`WebFrame::handleMouseEvent`). That is WebKit's design and no
///   API turns it off, so `move` refuses a window that isn't key rather than send a
///   move that does nothing.
///
/// Injected input never goes through the app's event monitors, so it cannot
/// activate the pane the way a user's click does (the Electron app needed a
/// counter, `suppressGuestActivation`, to keep its own injected press from being
/// mistaken for the user's).
///
/// All of it needs the page on screen: a view outside a window has no window
/// number to address an event to, and a pane that is not mounted is refused the
/// way the verbs refuse it.
@MainActor
struct PageInput {
    let page: BrowserPage

    enum Failure: Error, Equatable {
        /// The page has no window: the pane isn't mounted.
        case notMounted
        /// The page's window isn't the key one, where WebKit delivers no pointer move.
        case windowNotActive
        /// This WebKit has no way in for a pointer move (`_simulateMouseMove:` is gone).
        case cannotMovePointer
    }

    private var webView: BrowserWebView { page.webView }

    private func window() throws -> NSWindow {
        guard let window = webView.window else { throw Failure.notMounted }
        return window
    }

    // MARK: Pointer

    /// Moves the pointer onto a point (CSS pixels of the page): a `mouseMoved`
    /// and nothing else. Chromium holds the hovered element until the next pointer
    /// event reaches the page, and so does WebKit, so a follow-up read needn't hover again.
    /// Refused in a window that isn't key (see the type's doc); otherwise returns
    /// once the page has seen the move (see `settle`).
    func move(x: Double, y: Double) async throws {
        let window = try window()
        guard window.isKeyWindow else { throw Failure.windowNotActive }
        let before = await page.inputCounts()
        guard sendMove(x: x, y: y, in: window) else { throw Failure.cannotMovePointer }
        await settle(from: before, InputCounts(mousemove: 1))
    }

    /// A left click at a point (CSS pixels of the page): a move first, so a page
    /// that only reveals a control on hover has seen the pointer arrive before
    /// the press lands on it, then press and release.
    /// Returns once the page has processed the click (see `settle`).
    func click(x: Double, y: Double) async throws {
        let window = try window()
        let before = await page.inputCounts()
        sendMove(x: x, y: y, in: window)
        if let down = mouseEvent(.leftMouseDown, x: x, y: y, in: window) { webView.mouseDown(with: down) }
        if let up = mouseEvent(.leftMouseUp, x: x, y: y, in: window) { webView.mouseUp(with: up) }
        await settle(from: before, InputCounts(mouseup: 1))
    }

    /// Hands a move to the page (see the type's doc). It has an effect only in the key window.
    /// False when it couldn't be sent: `_simulateMouseMove:` is SPI, and a WebKit without it
    /// has no other way in.
    @discardableResult
    private func sendMove(x: Double, y: Double, in window: NSWindow) -> Bool {
        let selector = NSSelectorFromString("_simulateMouseMove:")
        guard webView.responds(to: selector), let event = mouseEvent(.mouseMoved, x: x, y: y, in: window) else { return false }
        webView.perform(selector, with: event)
        return true
    }

    private func mouseEvent(_ type: NSEvent.EventType, x: Double, y: Double, in window: NSWindow) -> NSEvent? {
        // The web view is flipped: its coordinates are the page's, top-left origin.
        let location = webView.convert(NSPoint(x: x, y: y), to: nil)
        return NSEvent.mouseEvent(
            with: type, location: location, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1,
            pressure: type == .leftMouseUp || type == .mouseMoved ? 0 : 1)
    }

    // MARK: Keys

    /// Delivers keystroke events (`keystrokeEvents`, `typingEvents`) to the page.
    /// Returns once the page has processed them (see `settle`).
    func send(_ events: [KeystrokeEvent]) async throws {
        let window = try window()
        // Measured: keys sent to a page whose view isn't the window's first responder
        // go nowhere (the page doesn't consider itself focused), so the page takes
        // the keyboard for the keystrokes. `withHostFocusRestored` gives it back.
        if !isPageResponder(window.firstResponder) { window.makeFirstResponder(webView) }
        let before = await page.inputCounts()
        var keyups = 0
        var inputs = 0
        // Keys queue, each behind the page's acknowledgement of the one before, while inserted
        // text applies at once (in order with other inserts): unpaced, `café` lands as `céaf`.
        // So an insert waits for the keys sent since the last wait. A page whose counters can't
        // see the keys (focus in a frame, where the counting script doesn't run) would make every
        // wait run out, so the first that does ends the pacing for the rest of the call.
        var settledKeyups = 0
        var pacing = true
        for event in events {
            switch event.kind {
            case .keyDown:
                if let key = keyEvent(.keyDown, event, in: window) { webView.keyDown(with: key) }
            case .keyUp:
                if let key = keyEvent(.keyUp, event, in: window) { webView.keyUp(with: key) }
                keyups += 1
            case .text:
                if pacing && keyups > settledKeyups {
                    pacing = await settle(from: before, InputCounts(keyup: keyups))
                    settledKeyups = keyups
                }
                insertText(event.key)
                inputs += 1
            }
        }
        await settle(from: before, InputCounts(keyup: keyups, input: inputs))
    }

    /// Waits until the page has processed the events just sent, as it says by
    /// the gestures it completed (`InputAcknowledgement`), for at most half a
    /// second: a page that can't say (one that runs no script), an event a page
    /// swallowed, or text no field took never blocks a verb for longer. What
    /// each event does in the page is the page's own business; this is only
    /// that a read straight after sees the events' effects.
    /// True when the page acknowledged everything expected; false when it couldn't say or the
    /// wait ran out.
    @discardableResult
    private func settle(from before: InputCounts?, _ expected: InputCounts) async -> Bool {
        guard let before else { return false }
        let deadline = Date().addingTimeInterval(0.5)
        while Date() < deadline {
            guard let now = await page.inputCounts() else { return false }
            if now.mouseup - before.mouseup >= expected.mouseup && now.keyup - before.keyup >= expected.keyup
                && now.input - before.input >= expected.input && now.mousemove - before.mousemove >= expected.mousemove
            {
                return true
            }
            await delay(milliseconds: 5)
        }
        return false
    }

    private func keyEvent(_ type: NSEvent.EventType, _ event: KeystrokeEvent, in window: NSWindow) -> NSEvent? {
        guard let physical = USKeyboard.physicalKey(for: event.key) else { return nil }
        var flags = physical.flags
        for modifier in event.modifiers {
            switch modifier {
            case .shift: flags.insert(.shift)
            case .control: flags.insert(.control)
            case .alt: flags.insert(.option)
            case .meta: flags.insert(.command)
            }
        }
        var characters = physical.characters
        // What a keyboard sends with Control held: the control character; with
        // Command, the key itself. Neither inserts text.
        if event.modifiers.contains(.control), let scalar = physical.charactersIgnoringModifiers.unicodeScalars.first,
            physical.charactersIgnoringModifiers.unicodeScalars.count == 1, scalar.isASCII, scalar.properties.isAlphabetic
        {
            characters = String(UnicodeScalar(scalar.value & 0x1f)!)
        } else if event.modifiers.contains(.meta) || event.modifiers.contains(.control) || event.modifiers.contains(.alt) {
            characters = physical.charactersIgnoringModifiers
        }
        return NSEvent.keyEvent(
            with: type, location: .zero, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil, characters: characters,
            charactersIgnoringModifiers: physical.charactersIgnoringModifiers, isARepeat: false, keyCode: physical.keyCode)
    }

    /// Text with no key behind it (é, 日, an emoji), delivered the way the
    /// character palette or an input method delivers it: as inserted text
    /// (`beforeinput`/`input`, no `keydown`). `WKWebView` answers to
    /// `NSTextInputClient`'s `insertText:replacementRange:` without declaring the
    /// conformance, so it is called by selector.
    private func insertText(_ text: String) {
        let selector = NSSelectorFromString("insertText:replacementRange:")
        guard webView.responds(to: selector) else { return }
        typealias Insert = @convention(c) (AnyObject, Selector, Any, NSRange) -> Void
        let insert = unsafeBitCast(webView.method(for: selector), to: Insert.self)
        insert(webView, selector, text as NSString, NSRange(location: NSNotFound, length: 0))
    }

    // MARK: Focus

    /// Runs an input verb, then puts the window's keyboard focus back where it
    /// was. None of the verbs focus the page themselves, but the page pulls
    /// focus onto its view anyway when a script inside it calls `el.focus()` or
    /// a synthesized click lands, which would yank the keyboard away from the
    /// terminal the user is typing in every time an agent drives the pane. The
    /// page's own idea of what is focused survives the change of first
    /// responder, so later verbs still land where they should (and the caret
    /// in a field with it: `activeCaret`). A window in which nothing had the
    /// keyboard is left that way.
    func withHostFocusRestored<T>(_ action: () async throws -> T) async rethrows -> T {
        let window = webView.window
        let previous = window?.firstResponder
        // Named before the action: a field editor stops standing for its field the
        // moment something else takes the keyboard.
        let owner = previous.flatMap(ownerOf)
        let result = try await action()
        // The pull can land a tick after the last injected event.
        await delay(milliseconds: 50)
        guard let window, window.firstResponder !== previous, isPageResponder(window.firstResponder) else { return result }
        let caret = await activeCaret()
        if let owner, owner.window === window {
            window.makeFirstResponder(owner)
        } else if previous == nil || previous === window {
            // Nothing had the keyboard: nothing has it again.
            window.makeFirstResponder(nil)
        }
        await restoreCaret(caret)
        return result
    }

    /// The caret (or selection) of the text field the page has focused, as `[start, end, direction]`. WebKit
    /// throws it away when the page gives up the keyboard (the field's selection reads 0-0 again, so a `type`
    /// after a `form-input`, or a second `type`, would land in front of what is there), where Chromium's guest
    /// keeps it however the host's focus moves: the page's own idea of its focus survives the change of first
    /// responder, and so must this.
    private func activeCaret() async -> [JSONValue]? {
        let script =
            "(() => { const el = document.activeElement; try { return typeof el.selectionStart === 'number' ? [el.selectionStart, el.selectionEnd, el.selectionDirection] : null } catch (error) { return null } })()"
        if case .success(.array(let caret)) = await page.evaluate(script) { return caret }
        return nil
    }

    private func restoreCaret(_ caret: [JSONValue]?) async {
        guard let caret, caret.count == 3, caret[0].intValue != nil, caret[1].intValue != nil else { return }
        _ = await page.evaluate(
            "(() => { try { document.activeElement.setSelectionRange(\(jsLiteral(caret[0])), \(jsLiteral(caret[1])), \(jsLiteral(caret[2]))) } catch (error) {} return true })()"
        )
    }

    private func isPageResponder(_ responder: NSResponder?) -> Bool {
        guard let view = responder as? NSView else { return false }
        return view === webView || view.isDescendant(of: webView)
    }

    /// What to make first responder to give `responder` back: a text field's
    /// shared field editor stands in for the field that is being edited.
    private func ownerOf(_ responder: NSResponder) -> NSView? {
        if let text = responder as? NSText, let field = text.delegate as? NSView { return field }
        return responder as? NSView
    }
}
