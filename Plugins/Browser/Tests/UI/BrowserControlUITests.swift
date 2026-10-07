import AppKit
import TabsPluginSDK
import Testing
import WebKit

@testable import Tabs
@testable import TabsCore

extension UIDriver {
    /// What `tabs-ctl <command> …flags` sends from the shell in `caller`: the whole response.
    func ctl(_ command: String, _ flags: [String: JSONValue] = [:], from caller: PaneID) async -> JSONValue {
        await runtime.control.handle(
            .init(command: command, arguments: .object(flags), targetPane: caller, cwd: URL(filePath: "/tmp", directoryHint: .isDirectory)))
    }

    /// A verb's `result`, failing the test with the whole response when it isn't `ok`.
    func ctlResult(
        _ command: String, _ flags: [String: JSONValue] = [:], from caller: PaneID, sourceLocation: SourceLocation = #_sourceLocation
    ) async -> JSONValue {
        let response = await ctl(command, flags, from: caller)
        #expect(response["ok"] == true, "\(command): \(response)", sourceLocation: sourceLocation)
        return response["result"] ?? .null
    }

    /// `create-browser-pane` from `caller`: the new pane's id (the window laid out again).
    func createBrowserPane(from caller: PaneID, url: String) async throws -> PaneID {
        let created = await ctlResult("create-browser-pane", ["url": .string(url)], from: caller)
        let pane = PaneID(try #require(created["paneId"]?.stringValue, "\(created)"))
        layoutAll()
        return pane
    }
}

extension UITests {
    /// The browser's verbs against panes in the real shell, windows never shown (docs/BROWSER.md J-1, J-6, E-5, J-27):
    /// what needs the shell around a pane: a new pane placed and shown without the keyboard, a capture of what it shows,
    /// a backgrounded pane revealed. The verbs' logic, a clip included, is the plugin tier's. The caller is a text pane
    /// standing for the agent's terminal.
    @MainActor
    @Suite struct BrowserControlUITests {
        static let caller: PaneID = "agent"

        static func layout() -> SavedLayout {
            Fixture.saved(Fixture.tabsWindow("w", [Fixture.leaf("agent", "text")]))
        }

        private func server() async throws -> FixtureServer {
            try await FixtureServer.startStandard()
        }

        private func png(_ path: String) throws -> NSBitmapImageRep {
            let data = try Data(contentsOf: URL(filePath: path))
            #expect(data.prefix(8) == Data([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]), "a PNG on disk")
            return try #require(NSBitmapImageRep(data: data))
        }

        // MARK: Capture

        /// "an agent can read back a pane it owns: info, text, and a real PNG on disk".
        @Test func anAgentCanReadBackAPaneItOwnsInfoTextAndARealPNGOnDisk() async throws {
            let server = try await server()
            defer { server.stop() }
            let ui = UIDriver(layout: Self.layout())
            defer { ui.discardWebData() }
            let pane = try await ui.createBrowserPane(from: Self.caller, url: server.url())
            let id = JSONValue.string(pane.rawValue)
            let text = await ui.ctlResult("get-page-text", ["pane": id], from: Self.caller)
            #expect(text["text"]?.stringValue?.contains("Hello from the fixture") == true)
            let info = await ui.ctlResult("pane-info", ["pane": id], from: Self.caller)
            #expect(info["title"] == "Fixture")
            #expect((info["viewport"]?["width"]?.doubleValue ?? 0) > 0)

            let shot = await ui.ctlResult("screenshot", ["pane": id], from: Self.caller)
            let path = try #require(shot["path"]?.stringValue, "\(shot)")
            #expect(shot["activated"] == nil, "a pane that was visible all along reports no `activated` key")
            let image = try png(path)
            // The two coordinate spaces stay honestly distinct: `width`/`height` describe the PNG (device pixels),
            // `viewport` the space a coordinate lives in (CSS pixels), and `scaleFactor` converts between them.
            #expect(shot["width"]?.intValue == Int64(image.pixelsWide) && shot["height"]?.intValue == Int64(image.pixelsHigh))
            #expect(shot["viewport"] == info["viewport"])
            let pageSays = try await ui.pageValue(pane, "[innerWidth, innerHeight, devicePixelRatio]")
            let width = try #require(pageSays[0]?.doubleValue), ratio = try #require(pageSays[2]?.doubleValue)
            #expect(
                shot["viewport"]?["width"]?.doubleValue == width && shot["viewport"]?["height"]?.doubleValue == pageSays[1]?.doubleValue)
            #expect(shot["scaleFactor"]?.doubleValue == ratio)
            #expect(abs(Double(image.pixelsWide) - width * ratio) <= ratio)
            #expect(shot["pngBytes"] == nil, "the bytes never come back over the socket, only a path")
        }

        /// A pane's page and view, as the layout holds them.
        private func setUp(_ url: String, ui: UIDriver) async throws -> (pane: PaneID, id: JSONValue) {
            let pane = try await ui.createBrowserPane(from: Self.caller, url: url)
            return (pane, .string(pane.rawValue))
        }

        // MARK: Hidden panes (E-5)

        /// The agent's tab and the browser's, the browser's shown (a new tab beside the caller), then the user back on the caller's.
        private func backgrounded(_ url: String, ui: UIDriver) async throws -> (pane: PaneID, id: JSONValue) {
            let made = try await setUp(url, ui: ui)
            #expect(try ui.layout.isShowing(made.pane))
            try ui.click(tab: "t-agent")
            ui.layoutAll()
            #expect(try !ui.layout.isShowing(made.pane), "backgrounded, as the user leaves it")
            return made
        }

        /// "screenshot reveals a backgrounded pane itself and says so with activated: true".
        @Test func screenshotRevealsABackgroundedPaneItselfAndSaysSoWithActivatedTrue() async throws {
            let server = try await server()
            defer { server.stop() }
            let ui = UIDriver(layout: Self.layout())
            defer { ui.discardWebData() }
            let (pane, id) = try await backgrounded(server.url(), ui: ui)
            #expect(ui.activePane == Self.caller)

            let shot = await ui.ctlResult("screenshot", ["pane": id], from: Self.caller)
            #expect(shot["activated"] == true)
            let image = try png(try #require(shot["path"]?.stringValue))
            #expect(image.pixelsWide > 0 && image.pixelsHigh > 0)
            #expect(try ui.layout.isShowing(pane), "the reveal is the verb's own, and the tab is visible now")
            // The reveal rides the same revealPane as activate-pane: what's visible changed, the keyboard didn't move.
            #expect(ui.activePane == Self.caller, "never activated")
            #expect(ui.focusedPane != pane)
        }

        // MARK: The pane in the real shell

        /// J-1: a new pane opens beside the caller as a tab, shown; the caller keeps the keyboard, and the page is
        /// the pane's whole body.
        @Test func aCreatedPaneIsShownBesideTheCallerWhichKeepsTheKeyboard() async throws {
            let server = try await server()
            defer { server.stop() }
            let ui = UIDriver(layout: Self.layout())
            defer { ui.discardWebData() }
            #expect(ui.focusedPane == Self.caller)
            let pane = try await ui.createBrowserPane(from: Self.caller, url: server.url())
            #expect(try ui.layout.isShowing(pane), "the new tab is the visible one")
            #expect(ui.activePane == pane, "active")
            #expect(ui.focusedPane != pane, "but it did not take the keyboard")
            let web = try ui.webView(pane)
            #expect(web.window != nil && web.bounds.width > 0)
            try await ui.browserState(pane) { $0["title"] == "Fixture" }
        }
    }
}
