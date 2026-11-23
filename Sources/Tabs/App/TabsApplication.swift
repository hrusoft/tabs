import AppKit
import OSLog

/// The app's `NSApplication` (the Info.plist's principal class): it acts only on keyboard input the
/// system delivered (docs/BROWSER.md D-3).
///
/// A `WKWebView` hands a keystroke its page didn't handle back to the app, through `sendEvent`, to be
/// tried as a shortcut: the same event object it was given. For a key from the keyboard that is the
/// event this app took from its queue, and it carries on to the monitors and the menu as usual (⌘W in a
/// focused page closes the pane). For a key a plugin synthesized into its own view (a browser verb
/// typing into its page) it is an event the system never delivered, and `sendEvent` would treat it as
/// the user's: an injected ⌘W ran the menu's Close Pane on the window's active pane, and an injected
/// key routes by key window, to wherever the user is typing. Such an event is dropped, so injected
/// input reaches only the view it was sent to.
@objc(TabsApplication)
final class TabsApplication: NSApplication {
    private let delivered = DeliveredKeys()

    override func nextEvent(
        matching mask: NSEvent.EventTypeMask, until expiration: Date?, inMode mode: RunLoop.Mode, dequeue deqFlag: Bool
    ) -> NSEvent? {
        let event = super.nextEvent(matching: mask, until: expiration, inMode: mode, dequeue: deqFlag)
        if let event, deqFlag { delivered.note(event) }
        return event
    }

    override func sendEvent(_ event: NSEvent) {
        guard delivered.admits(event) else {
            Self.log.debug("dropped a key event the system didn't deliver: \(event.keyCode)")
            return
        }
        super.sendEvent(event)
    }

    private static let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Tabs", category: "input")
}

/// The key events the app took from its queue, by identity, for as long as each is alive: what
/// `TabsApplication.sendEvent` lets through. A view handing a key back holds it until it does (a web view
/// keeps the event until its page has answered, however far behind the page is), so no number of keys
/// typed in between can push it out, as a fixed-size memory could; every other kind of event passes.
final class DeliveredKeys {
    private let delivered = NSHashTable<NSEvent>(options: [.weakMemory, .objectPointerPersonality])

    func note(_ event: NSEvent) {
        if Self.isKey(event) { delivered.add(event) }
    }

    func admits(_ event: NSEvent) -> Bool {
        !Self.isKey(event) || delivered.contains(event)
    }

    private static func isKey(_ event: NSEvent) -> Bool { event.type == .keyDown || event.type == .keyUp }
}
