import AppKit

/// A window that is never shown but tells AppKit, and so WebKit, that it is on screen and unoccluded: its page runs
/// at the pace of a page someone is looking at. A page in a never-shown window is one nobody can see, and WebKit runs
/// it at its background pace (docs/BROWSER.md, Implementation notes): a repeating 100 ms timer fires about once a
/// second, and on a busy machine the page's own timers can stay held for 10 s and more between script calls. Browser
/// tests drive active pages (docs/BROWSER.md, Testing), so every page they make is in one of these: `PageBed`'s,
/// `InputVerbBed`'s, and each browser pane the harness's layout shows (`PluginHarness.browser`).
@MainActor
final class OnScreenWindow: KeyableWindow {
    override var isVisible: Bool { true }
    override var occlusionState: NSWindow.OcclusionState { .visible }

    static func make(width: CGFloat = 400, height: CGFloat = 300) -> OnScreenWindow {
        let window = OnScreenWindow(
            contentRect: NSRect(x: 0, y: 0, width: width, height: height), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        return window
    }
}
