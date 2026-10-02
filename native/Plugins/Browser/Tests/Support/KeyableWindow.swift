import AppKit

/// A window that can be the key window without ever being shown, so a test can
/// see what a page does in the window the user has in front of them: WebKit
/// delivers a pointer move only there (`PageInput`). WebKit reads `isKeyWindow`
/// when the window says it became key, which is how its own tests do it
/// (`TestWKWebViewHostWindow`).
@MainActor
final class KeyableWindow: NSWindow {
    private var forcedKey = false

    override var isKeyWindow: Bool { forcedKey || super.isKeyWindow }

    /// Makes the window key (or not) in the page's eyes, as the user bringing it
    /// to the front (or leaving it) would. WebKit hands the change to the page at
    /// the end of a run loop turn, so this waits for it to have gone out: input
    /// sent before then still meets the old state.
    func setKey(_ key: Bool) async {
        guard key != forcedKey else { return }
        forcedKey = key
        NotificationCenter.default.post(
            name: key ? NSWindow.didBecomeKeyNotification : NSWindow.didResignKeyNotification, object: self)
        try? await Task.sleep(for: .milliseconds(100))
    }
}
