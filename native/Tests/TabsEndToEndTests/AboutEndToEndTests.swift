import AppKit
import Foundation
import TabsPluginSDK
import Testing

/// The About window in the running app (docs/ABOUT.md): what only exists with the real app behind it, that the
/// application menu opens it at all, that the version is the built app's own, and that Copy reaches the
/// real system pasteboard. What it renders from its data, and how it reacts to presses, is the UI tier's
/// (`UITests/About`). The app is hidden, so the window is built but never shown; the URL a tier or a credit
/// opens is not pressed here, since it would launch the developer's real browser.
extension LaunchedApp {
    /// About Tabs ▸ as the menu would, then the window as built.
    func openAbout() async throws -> JSONValue {
        try await call("tabs.test.menu", ["title": "About Tabs"])
        return try await call("tabs.test.about")
    }

    /// The version in the built app's own Info.plist.
    static var builtVersion: String? {
        Bundle(url: appURL)?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
    }

    var workspaceWindowCount: Int {
        get async throws {
            guard case .array(let windows) = try await call("tabs.test.windows") else { return 0 }
            return windows.count
        }
    }
}

@Suite(.serialized, .sharedApp, .timeLimit(.minutes(2))) struct AboutEndToEndTests {
    @Test func theApplicationMenuOpensARealAboutWindow() async throws {  // A-1
        let app = try await SharedApp.fresh()
        #expect(try await app.call("tabs.test.about") == .null, "not before it is asked for")
        let workspaces = try await app.workspaceWindowCount
        let about = try await app.openAbout()
        #expect(about["title"] == "About Tabs")
        #expect(about["windows"] == 1, "a window of its own")
        #expect(try await app.workspaceWindowCount == workspaces, "not a view inside a workspace window, nor a new one")
    }

    @Test func itIsAFixedSizeIndependentWindowThatIsNeverShownWhenHidden() async throws {  // A-3, A-9
        let app = try await SharedApp.fresh()
        let about = try await app.openAbout()
        #expect(about["width"] == 460 && about["height"] == 630)
        #expect(about["resizable"] == false)
        #expect(about["zoomable"] == false)
        #expect(about["fullScreenAllowed"] == false)
        #expect(about["hasParent"] == false)
        #expect(about["visible"] == false, "hidden mode never shows or focuses it")
    }

    @Test func openingItTwiceFocusesTheOneWindowRatherThanMakingASecond() async throws {  // A-2
        let app = try await SharedApp.fresh()
        _ = try await app.openAbout()
        let again = try await app.openAbout()
        #expect(again["windows"] == 1)
    }

    @Test func aResetClosesItSoTheNextOneIsFresh() async throws {  // A-6
        let app = try await SharedApp.fresh()
        _ = try await app.openAbout()
        try await app.call("tabs.test.reset")
        #expect(try await app.call("tabs.test.about") == .null)
        #expect(try await app.openAbout()["windows"] == 1)
    }

    @Test func showsTheBuiltAppsVersionAndEverythingItOffers() async throws {  // B-2…B-5, C-2, D-2, E-3
        let app = try await SharedApp.fresh()
        let version = try #require(LaunchedApp.builtVersion)
        let about = try await app.openAbout()
        guard case .array(let values)? = about["texts"] else {
            Issue.record("no texts")
            return
        }
        let texts = values.compactMap(\.stringValue)
        // The half the UI tier structurally cannot check: the version is the built bundle's, not the test host's.
        #expect(texts.contains("Version \(version)"), "\(texts)")
        for expected in [
            "Tabs", "A fancy terminal with tabs, splits, and nested layouts.", "Copyright © 2026 Hrusoft. All rights reserved.",
            "Buy me a coffee", "$4 USD", "$20 USD", "$200 USD", "Coffee", "Bitcoin BTC", "Ethereum ETH", "Built with", "SwiftTerm", "MIT",
        ] {
            #expect(texts.contains(expected), "\(expected) is missing from \(texts)")
        }
    }

    @Test func aCopyButtonPutsTheAddressOnTheRealSystemPasteboard() async throws {  // D-3, D-4
        let app = try await SharedApp.fresh()
        // The suite runs on a developer's own machine: put back whatever was there.
        let pasteboard = NSPasteboard.general
        let original = pasteboard.string(forType: .string)
        defer {
            pasteboard.clearContents()
            if let original { pasteboard.setString(original, forType: .string) }
        }
        let about = try await app.openAbout()
        let address = try #require(about["addresses"]?["btc"]?.stringValue)
        #expect(!address.isEmpty)
        try await app.call("tabs.test.click", ["window": "about", "identifier": "about-copy-btc"])
        #expect(pasteboard.string(forType: .string) == address, "the address the window shows, and nothing else")
        let after = try await app.call("tabs.test.about")
        #expect(after["copyTitles"]?["btc"] == "Copied", "and it says so, so the user knows the string was taken")
        #expect(after["copyTitles"]?["eth"] == "Copy")
    }
}
