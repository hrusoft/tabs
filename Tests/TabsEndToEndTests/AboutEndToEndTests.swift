import AppKit
import Foundation
import TabsPluginSDK
import Testing

/// The About window in the running app (docs/ABOUT.md): what only exists with the real app behind it, that the
/// application menu opens it at all, and that Copy reaches the real system pasteboard. What it renders from its
/// data (the running bundle's version and credits too: the UI tier's host is the built app), and how it reacts
/// to presses, is the UI tier's (`UITests/About`). The app is hidden, so the window is built but never shown;
/// the URL a tier or a credit opens is not pressed here, since it would launch the developer's real browser.
extension LaunchedApp {
    /// About Tabs ▸ as the menu would, then the window as built.
    func openAbout() async throws -> JSONValue {
        try await call("tabs.test.menu", ["title": "About Tabs"])
        return try await call("tabs.test.about")
    }
}

/// The window's size and traits, and opening it twice, are the UI tier's (`UITests.About`).
@Suite(.serialized, .sharedApp, .timeLimit(.minutes(2))) struct AboutEndToEndTests {
    @Test func theApplicationMenuOpensARealAboutWindowThatAResetCloses() async throws {  // A-1, A-6, A-9
        let app = try await SharedApp.fresh()
        #expect(try await app.call("tabs.test.about") == .null, "not before it is asked for")
        let workspaces = try await app.workspaceWindowCount
        let about = try await app.openAbout()
        #expect(about["title"] == "About Tabs")
        #expect(about["windows"] == 1, "a window of its own")
        #expect(about["visible"] == false, "hidden mode never shows or focuses it")
        #expect(try await app.workspaceWindowCount == workspaces, "not a view inside a workspace window, nor a new one")

        try await app.call("tabs.test.reset")
        #expect(try await app.call("tabs.test.about") == .null, "the reset closed it")
        #expect(try await app.openAbout()["windows"] == 1, "and the next one is fresh")
    }

    @Test func aCopyButtonPutsTheAddressOnTheRealSystemPasteboard() async throws {  // D-3, D-4
        let app = try await SharedApp.fresh()
        let about = try await app.openAbout()
        let address = try #require(about["addresses"]?["btc"]?.stringValue)
        #expect(!address.isEmpty)
        // The suite runs on a developer's own machine: what was there goes back afterwards.
        let pasteboard = NSPasteboard.general
        let saved = SavedPasteboard(pasteboard)
        defer { saved.restore(unlessReplacedSince: address) }
        try await app.call("tabs.test.click", ["window": "about", "identifier": "about-copy-btc"])
        #expect(pasteboard.string(forType: .string) == address, "the address the window shows, and nothing else")
        let after = try await app.call("tabs.test.about")
        #expect(after["copyTitles"]?["btc"] == "Copied", "and it says so, so the user knows the string was taken")
        #expect(after["copyTitles"]?["eth"] == "Copy")
    }
}

/// A pasteboard's contents — every type of every item, not just its string —
/// to put back after a test that has to write it.
private struct SavedPasteboard {
    let pasteboard: NSPasteboard
    let items: [[NSPasteboard.PasteboardType: Data]]

    init(_ pasteboard: NSPasteboard) {
        self.pasteboard = pasteboard
        items = (pasteboard.pasteboardItems ?? []).map { item in
            Dictionary(item.types.compactMap { type in item.data(forType: type).map { (type, $0) } }) { first, _ in first }
        }
    }

    /// Puts it back if the pasteboard still holds `written`, the test's own
    /// write; anything since — the user copying, another run of this test that
    /// already put its own back — is left alone.
    func restore(unlessReplacedSince written: String) {
        guard pasteboard.pasteboardItems?.count == 1, pasteboard.string(forType: .string) == written else { return }
        pasteboard.clearContents()
        let restored = items.map { types in
            let item = NSPasteboardItem()
            for (type, data) in types { item.setData(data, forType: type) }
            return item
        }
        if !restored.isEmpty { pasteboard.writeObjects(restored) }
    }
}
