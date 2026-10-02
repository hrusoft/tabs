#if DEBUG
import AppKit
import TabsCore
import TabsPluginSDK

/// Synthesized user input for tests — the in-process UI tier and the e2e
/// test verbs share it, so both drive the app the same way.
///
/// It works on windows that are never shown (tests keep windows off screen,
/// like the Electron e2e): events go straight to the window or the main menu,
/// in the order AppKit itself tries them, instead of through `NSApp.sendEvent`,
/// which routes by key window. Debug builds only.
@MainActor
enum InputSynthesizer {
    enum Failure: Error, CustomStringConvertible, Equatable {
        case notFound(String)
        case notHittable(String)
        case notHandled(String)

        var description: String {
            switch self {
            case .notFound(let what): "no view with identifier \(what)"
            case .notHittable(let what): "\(what) is hidden or covered at its center"
            case .notHandled(let what): "nothing handled \(what)"
            }
        }
    }

    /// Types text into `window`'s first responder, one key event per
    /// character; "\n" is the Return key.
    static func type(_ text: String, into window: NSWindow) {
        for character in text {
            let characters = character == "\n" ? "\r" : String(character)
            for type in [NSEvent.EventType.keyDown, .keyUp] {
                if let event = keyEvent(type, characters: characters, ignoringModifiers: characters, modifiers: [], window: window) {
                    window.sendEvent(event)
                }
            }
        }
    }

    /// Physical keys by key code, for what a view reads off `keyCode` (arrows,
    /// Return, Escape, the digit row) rather than off characters.
    enum Key {
        static let escape: UInt16 = 53
        static let `return`: UInt16 = 36
        static let down: UInt16 = 125
        static let up: UInt16 = 126
        /// The main row's digit `n` (1…9); the keypad's are other codes.
        static func digit(_ n: Int) -> UInt16 { [18, 19, 20, 21, 23, 22, 26, 28, 25][n - 1] }
    }

    /// One key, down and up, straight to the window's first responder (no menu:
    /// that is `press`). `characters` matter only to views that read them.
    static func key(_ keyCode: UInt16, characters: String = "", modifiers: NSEvent.ModifierFlags = [], into window: NSWindow) {
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            if let event = keyEvent(
                type, characters: characters, ignoringModifiers: characters, modifiers: modifiers, window: window, keyCode: keyCode)
            {
                window.sendEvent(event)
            }
        }
    }

    /// Presses a chord the way AppKit resolves one: the app's local key
    /// monitor (`input`: pane navigation), the window's key equivalents, then
    /// the main menu's, then an ordinary key down to the first responder.
    /// Returns whether the monitor or a key equivalent handled it.
    ///
    /// The key is made the way the keyboard makes it (`keyboardEvent`) where
    /// the US layout has it, else from the chord's characters.
    @discardableResult
    static func press(_ chord: KeyChord, in window: NSWindow, input: WorkspaceInput? = nil) -> Bool {
        let keyboard = keyboardEvent(chord)
        guard let down = chordEvent(.keyDown, chord, in: window) else { return false }
        if input?.handleKeyDown(down) == true { return true }
        if window.performKeyEquivalent(with: down) || NSApp.mainMenu?.performKeyEquivalent(with: keyboard ?? down) == true {
            return true
        }
        window.sendEvent(down)
        if let up = chordEvent(.keyUp, chord, in: window) { window.sendEvent(up) }
        return false
    }

    /// `chord`'s key down or up for `window`, as `press` delivers it: made the way the keyboard
    /// makes it where the US layout has the key, else from the chord's characters.
    static func chordEvent(_ type: NSEvent.EventType, _ chord: KeyChord, in window: NSWindow) -> NSEvent? {
        let keyboard = keyboardEvent(chord)
        let key = chord.menuKeyEquivalent
        let characters = keyboard?.characters ?? (chord.modifiers.contains(.shift) ? key.uppercased() : key)
        return keyEvent(
            type, characters: characters, ignoringModifiers: keyboard?.charactersIgnoringModifiers ?? characters,
            modifiers: chord.eventModifierFlags, window: window, keyCode: keyboard?.keyCode ?? 0)
    }

    /// The modifier keys held changing to `modifiers` (a `flagsChanged` event) in `window`.
    static func modifiersEvent(_ modifiers: NSEvent.ModifierFlags, in window: NSWindow) -> NSEvent? {
        keyEvent(.flagsChanged, characters: "", ignoringModifiers: "", modifiers: modifiers, window: window, keyCode: 58)
    }

    /// `chord`'s key down as the keyboard delivers it (a `CGEvent`: no
    /// window). Menus match key equivalents on such an event's key code, and
    /// on a synthesized one only on its characters: ⇧⌘T there hits ⌘T's item
    /// or none. nil for a key the US layout doesn't have unshifted.
    private static func keyboardEvent(_ chord: KeyChord) -> NSEvent? {
        guard let code = virtualKeyCode(chord.key),
            let event = CGEvent(keyboardEventSource: CGEventSource(stateID: .privateState), virtualKey: code, keyDown: true)
        else { return nil }
        var flags: CGEventFlags = []
        if chord.modifiers.contains(.command) { flags.insert(.maskCommand) }
        if chord.modifiers.contains(.shift) { flags.insert(.maskShift) }
        if chord.modifiers.contains(.option) { flags.insert(.maskAlternate) }
        if chord.modifiers.contains(.control) { flags.insert(.maskControl) }
        event.flags = flags
        // Another layout puts other characters on these keys.
        guard let made = NSEvent(cgEvent: event), KeyChord(event: made) == chord else { return nil }
        return made
    }

    /// The US layout's virtual key code for `key`, if it's on an unshifted key.
    private static func virtualKeyCode(_ key: KeyChord.Key) -> CGKeyCode? {
        switch key {
        case .character(let character):
            let keys: [Character: CGKeyCode] = [
                "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9, "b": 11, "q": 12, "w": 13, "e": 14,
                "r": 15, "y": 16, "t": 17, "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23, "=": 24, "9": 25, "7": 26, "-": 27,
                "8": 28, "0": 29, "]": 30, "o": 31, "u": 32, "[": 33, "i": 34, "p": 35, "l": 37, "j": 38, "'": 39, "k": 40, ";": 41,
                "\\": 42, ",": 43, "/": 44, "n": 45, "m": 46, ".": 47, "`": 50,
            ]
            return keys[character]
        case .return: return 36
        case .tab: return 48
        case .space: return 49
        case .delete: return 51
        case .escape: return 53
        case .arrow(.left): return 123
        case .arrow(.right): return 124
        case .arrow(.down): return 125
        case .arrow(.up): return 126
        case .function(let number):
            let keys: [CGKeyCode] = [122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111, 105, 107, 113, 106, 64, 79, 80, 90]
            return keys.indices.contains(number - 1) ? keys[number - 1] : nil
        }
    }

    /// Clicks the view with `identifier` — only if a user could: it must be
    /// visible and be what's hit at its center (not hidden, not covered).
    /// A control performs its action (`performClick`); anything else gets
    /// the mouse down and up at its center (see `click(at:in:)`).
    /// `within` narrows the search to one subtree.
    static func click(
        _ identifier: String, in window: NSWindow, within scope: NSView? = nil, input: WorkspaceInput? = nil
    ) throws(Failure) {
        guard let view = find(identifier, in: window, within: scope) else { throw .notFound(identifier) }
        guard !view.isHiddenOrHasHiddenAncestor else { throw .notHittable(identifier) }
        window.contentView?.layoutSubtreeIfNeeded()
        let center = NSPoint(x: view.bounds.midX, y: view.bounds.midY)
        if let control = view as? NSControl {
            guard let hit = hitView(at: view.convert(center, to: nil), in: window), hit === view || hit.isDescendant(of: view) else {
                throw .notHittable(identifier)
            }
            guard control.isEnabled else { throw .notHandled("\(identifier) (disabled)") }
            control.performClick(nil)
            return
        }
        try click(at: center, in: view, input: input, expecting: identifier)
    }

    /// The view under `windowPoint`, as AppKit hit-tests a click there.
    static func hitView(at windowPoint: NSPoint, in window: NSWindow) -> NSView? {
        guard let content = window.contentView else { return nil }
        content.layoutSubtreeIfNeeded()
        return content.hitTest(content.superview?.convert(windowPoint, from: nil) ?? windowPoint)
    }

    /// Clicks at `point` in `view`'s coordinates, as a user would: whatever
    /// is hit there must be `view` or inside it; it takes the keyboard if it
    /// accepts it, and gets the mouse down and up (the up is queued first,
    /// for views that track the mouse themselves). AppKit ignores mouse
    /// events for windows that aren't on screen, so they're delivered to the
    /// view directly, after the app's local monitor (`input`: activating a
    /// pane by its content) has seen the press.
    static func click(
        at point: NSPoint, in view: NSView, count: Int = 1, right: Bool = false, input: WorkspaceInput? = nil, expecting name: String? = nil
    ) throws(Failure) {
        let what = name ?? String(describing: Swift.type(of: view))
        guard let window = view.window, !view.isHiddenOrHasHiddenAncestor else { throw .notHittable(what) }
        let location = view.convert(point, to: nil)
        guard let hit = hitView(at: location, in: window), hit === view || hit.isDescendant(of: view) else { throw .notHittable(what) }
        if right {
            guard let down = mouseEvent(.rightMouseDown, at: location, in: window, count: count) else { throw .notHandled(what) }
            input?.handleMouseDown(down)
            hit.rightMouseDown(with: down)
            if let up = mouseEvent(.rightMouseUp, at: location, in: window, count: count) { hit.rightMouseUp(with: up) }
            return
        }
        guard let down = mouseEvent(.leftMouseDown, at: location, in: window, count: count),
            let up = mouseEvent(.leftMouseUp, at: location, in: window, count: count)
        else { throw .notHandled(what) }
        input?.handleMouseDown(down)
        if hit.acceptsFirstResponder { window.makeFirstResponder(hit) }
        NSApp.postEvent(up, atStart: false)
        hit.mouseDown(with: down)
        // Not taken by a tracking loop: an ordinary click's up.
        if let pending = NSApp.nextEvent(matching: .leftMouseUp, until: .distantPast, inMode: .default, dequeue: true) {
            hit.mouseUp(with: pending)
        }
    }

    /// One part of a synthesized drag after the press.
    enum DragStep {
        /// The pointer travels to a point (in the pressed view's coordinates) in `steps` moves.
        case move(to: NSPoint, steps: Int = 8)
        /// The pointer holds still for a while (timers — spring loading — run meanwhile).
        case wait(TimeInterval)
        /// The button comes up where the pointer is.
        case release
        /// Escape is pressed (the button is still down).
        case escape
    }

    /// Presses at `start` in `view` and plays `steps`: the moves and the
    /// release are queued (a wait delays the rest), then the view gets the
    /// press — the drag controller, a separator or a floating pane tracks
    /// the rest from the queue, as it would from the mouse.
    static func drag(
        from start: NSPoint, in view: NSView, _ steps: [DragStep], input: WorkspaceInput? = nil
    ) throws(Failure) {
        let what = String(describing: Swift.type(of: view))
        guard let window = view.window, !view.isHiddenOrHasHiddenAncestor else { throw .notHittable(what) }
        let origin = view.convert(start, to: nil)
        guard let hit = hitView(at: origin, in: window), hit === view || hit.isDescendant(of: view),
            let down = mouseEvent(.leftMouseDown, at: origin, in: window)
        else { throw .notHittable(what) }
        var batches: [(delay: TimeInterval, events: [NSEvent])] = [(0, [])]
        var at = origin
        var delay: TimeInterval = 0
        for step in steps {
            switch step {
            case .move(let target, let count):
                let end = view.convert(target, to: nil)
                let from = at
                for index in 1...max(count, 1) {
                    let fraction = CGFloat(index) / CGFloat(max(count, 1))
                    let point = NSPoint(x: from.x + (end.x - from.x) * fraction, y: from.y + (end.y - from.y) * fraction)
                    if let event = mouseEvent(.leftMouseDragged, at: point, in: window) { batches[batches.count - 1].events.append(event) }
                }
                at = end
            case .wait(let seconds):
                delay += seconds
                batches.append((delay, []))
            case .release:
                if let event = mouseEvent(.leftMouseUp, at: at, in: window) { batches[batches.count - 1].events.append(event) }
            case .escape:
                let escape = "\u{1b}"
                let event = keyEvent(.keyDown, characters: escape, ignoringModifiers: escape, modifiers: [], window: window, keyCode: 53)
                if let event { batches[batches.count - 1].events.append(event) }
            }
        }
        for event in batches[0].events { NSApp.postEvent(event, atStart: false) }
        /// Events handed to a timer: posted on the main thread only.
        final class Queued: @unchecked Sendable {
            let events: [NSEvent]
            init(_ events: [NSEvent]) { self.events = events }
        }
        for batch in batches.dropFirst() {
            let queued = Queued(batch.events)
            let timer = Timer(timeInterval: batch.delay, repeats: false) { _ in
                MainActor.assumeIsolated { for event in queued.events { NSApp.postEvent(event, atStart: false) } }
            }
            RunLoop.main.add(timer, forMode: .common)
        }
        input?.handleMouseDown(down)
        hit.mouseDown(with: down)
    }

    /// Clicks an empty pane's creation button for `type` (the buttons are
    /// drawn, not views): what filling the pane in place takes.
    static func create(_ type: ContentTypeID, in body: PaneBodyHost, input: WorkspaceInput? = nil) throws(Failure) {
        let what = "create-\(type)"
        guard let empty = body.content as? EmptyPaneView else { throw .notFound(what) }
        guard let index = empty.actions.firstIndex(where: { $0.type == type }) else { throw .notFound(what) }
        body.window?.contentView?.layoutSubtreeIfNeeded()
        let rect = empty.buttonRects[index]
        try click(at: NSPoint(x: rect.midX, y: rect.midY), in: empty, input: input, expecting: what)
    }

    /// The view with `identifier` in `window` (or in `scope`), if any.
    static func find(_ identifier: String, in window: NSWindow, within scope: NSView? = nil) -> NSView? {
        func search(_ view: NSView) -> NSView? {
            if view.accessibilityIdentifier() == identifier { return view }
            for subview in view.subviews { if let found = search(subview) { return found } }
            return nil
        }
        return (scope ?? window.contentView).flatMap(search)
    }

    static func mouseEvent(_ type: NSEvent.EventType, at location: NSPoint, in window: NSWindow, count: Int = 1) -> NSEvent? {
        NSEvent.mouseEvent(
            with: type, location: location, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: count,
            pressure: type == .leftMouseUp || type == .rightMouseUp ? 0 : 1)
    }

    static func keyEvent(
        _ type: NSEvent.EventType, characters: String, ignoringModifiers: String, modifiers: NSEvent.ModifierFlags, window: NSWindow,
        keyCode: UInt16 = 0
    ) -> NSEvent? {
        NSEvent.keyEvent(
            with: type, location: .zero, modifierFlags: modifiers, timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil, characters: characters, charactersIgnoringModifiers: ignoringModifiers,
            isARepeat: false, keyCode: keyCode)
    }
}
#endif
