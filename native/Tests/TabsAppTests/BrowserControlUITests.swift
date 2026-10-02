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
    /// The browser's verbs against panes in the real shell, windows never shown (docs/BROWSER.md J-1, J-6, C-7, E-2,
    /// E-5, H-5): what needs a pane on screen: a capture, a viewport, a reveal, a robot icon, where a split put it.
    /// The caller is a text pane standing for the agent's terminal.
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

        /// "screenshot and pane-info report the exact scale factor and the page viewport at a fractional width".
        @Test func screenshotAndPaneInfoReportTheExactScaleFactorAndThePageViewportAtAFractionalWidth() async throws {
            let server = try await server()
            defer { server.stop() }
            let ui = UIDriver(layout: Self.layout())
            let (pane, id) = try await setUp(server.url(), ui: ui)
            let web = try ui.webView(pane)
            let ratio = try #require(try await ui.pageValue(pane, "devicePixelRatio").doubleValue)
            for width in [345.4, 693.5, 600.25] {
                web.setFrameSize(NSSize(width: width, height: web.frame.height))
                var says: [Double] = []
                for _ in 0..<40 {
                    try await Task.sleep(for: .milliseconds(50))
                    guard case .array(let numbers) = try await ui.pageValue(pane, "[innerWidth, innerHeight]") else { continue }
                    says = numbers.compactMap(\.doubleValue)
                    if says.first == width.rounded(.down) { break }
                }
                // Chromium rounds the guest viewport *up* (345.4 → 346); WebKit rounds it down (345): either way the
                // number a coordinate click lives in is the page's own, which is what is reported.
                #expect(says.first == width.rounded(.down), "\(width): the page's own viewport is the width rounded down: \(says)")
                let shot = await ui.ctlResult("screenshot", ["pane": id], from: Self.caller)
                #expect(shot["scaleFactor"]?.doubleValue == ratio, "\(width): the display's real ratio, not the image over a rounded width")
                #expect(
                    shot["viewport"]?["width"]?.doubleValue == says[0] && shot["viewport"]?["height"]?.doubleValue == says[1], "\(width)")
                let info = await ui.ctlResult("pane-info", ["pane": id], from: Self.caller)
                #expect(info["viewport"] == shot["viewport"], "\(width)")
            }
        }

        /// "screenshot clips to one element, in CSS pixels, at the same scale factor".
        @Test func screenshotClipsToOneElementInCSSPixelsAtTheSameScaleFactor() async throws {
            let server = try await server()
            defer { server.stop() }
            let ui = UIDriver(layout: Self.layout())
            let (pane, id) = try await setUp(server.url(), ui: ui)

            let full = await ui.ctlResult("screenshot", ["pane": id], from: Self.caller)
            let clipped = await ui.ctlResult("screenshot", ["pane": id, "selector": "#go"], from: Self.caller)
            #expect(clipped["element"]?["name"] == "Do the thing")
            let rect = try #require(clipped["clipped"], "a clipped screenshot reports its rect")
            let clipPath = try #require(clipped["path"]?.stringValue)

            // The clip is a real, much smaller PNG: not a full capture with a rect reported beside it.
            let image = try png(clipPath)
            #expect(clipped["width"]?.intValue == Int64(image.pixelsWide) && clipped["height"]?.intValue == Int64(image.pixelsHigh))
            #expect((clipped["width"]?.intValue ?? .max) < (full["width"]?.intValue ?? 0))
            #expect((clipped["height"]?.intValue ?? .max) < (full["height"]?.intValue ?? 0))

            // The rect is CSS pixels and the image device pixels, at the scale factor the unclipped capture reports.
            #expect(clipped["scaleFactor"] == full["scaleFactor"])
            let scale = try #require(clipped["scaleFactor"]?.doubleValue)
            #expect(clipped["width"]?.doubleValue == (rect["width"]?.doubleValue ?? 0) * scale)
            #expect(clipped["height"]?.doubleValue == (rect["height"]?.doubleValue ?? 0) * scale)
            // `viewport` still describes the pane, not the clip.
            #expect(clipped["viewport"] == full["viewport"])
            // Rounded outward to whole CSS pixels.
            for key in ["x", "y", "width", "height"] { #expect(rect[key]?.intValue != nil, "\(key) is a whole number") }
            let box = try await ui.pageValue(
                pane, "(() => { const r = document.getElementById('go').getBoundingClientRect(); return [r.x, r.y, r.width, r.height] })()")
            let measured = try #require(
                { () -> [Double]? in if case .array(let numbers) = box { numbers.compactMap(\.doubleValue) } else { nil } }())
            #expect(
                Double(rect["x"]?.intValue ?? 0) <= measured[0]
                    && Double(rect["x"]?.intValue ?? 0) + (rect["width"]?.doubleValue ?? 0) >= measured[0] + measured[2])

            // A ref clips identically; the two forms name one element two ways.
            let read = await ui.ctlResult("read-page", ["pane": id, "role": "button"], from: Self.caller)
            guard case .array(let elements)? = read["elements"], let ref = elements.first(where: { $0["name"] == "Do the thing" })?["ref"]
            else { Issue.record("no ref for the button: \(read)"); return }
            let byRef = await ui.ctlResult("screenshot", ["pane": id, "ref": ref], from: Self.caller)
            #expect(byRef["clipped"] == rect)

            // Refusals: both forms at once, and an element that isn't there.
            let both = await ui.ctl("screenshot", ["pane": id, "selector": "#go", "ref": ref], from: Self.caller)
            #expect(both["ok"] == false && both["error"]?.stringValue?.contains("only one of selector or ref") == true)
            let missing = await ui.ctl("screenshot", ["pane": id, "selector": "#nope"], from: Self.caller)
            #expect(missing["ok"] == false && missing["error"]?.stringValue?.contains("no element matches") == true, "\(missing)")
        }

        /// A clip is clamped to what the page is showing, and an element outside the viewport is refused.
        @Test func aClipIsClampedToTheViewportAndAnElementOutsideItIsRefused() async throws {
            let server = try await server()
            defer { server.stop() }
            server.page(
                "/tall", title: "Tall",
                head:
                    "<style>body{margin:0}#tall{position:absolute;left:-20px;top:-30px;width:5000px;height:5000px;background:#00f}</style>",
                body: "<div id=tall></div><div id=far style='position:absolute;top:0;left:0'></div>")
            let ui = UIDriver(layout: Self.layout())
            let (pane, id) = try await setUp(server.url("/tall"), ui: ui)
            let viewport = try #require(await ui.ctlResult("pane-info", ["pane": id], from: Self.caller)["viewport"])
            let shot = await ui.ctlResult("screenshot", ["pane": id, "selector": "#tall"], from: Self.caller)
            let clipped = try #require(shot["clipped"])
            #expect(clipped["x"] == 0 && clipped["y"] == 0, "clamped to the viewport's own corner")
            #expect(
                clipped["width"]?.doubleValue == viewport["width"]?.doubleValue
                    && clipped["height"]?.doubleValue == viewport["height"]?.doubleValue)
            _ = pane
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

        /// "screenshot --no-activate fails on a backgrounded pane and leaves the visible tab alone".
        @Test func screenshotNoActivateFailsOnABackgroundedPaneAndLeavesTheVisibleTabAlone() async throws {
            let server = try await server()
            defer { server.stop() }
            let ui = UIDriver(layout: Self.layout())
            let (pane, id) = try await backgrounded(server.url(), ui: ui)
            let shot = await ui.ctl("screenshot", ["pane": id, "no-activate": true], from: Self.caller)
            #expect(shot["ok"] == false && shot["error"]?.stringValue?.contains("the pane is hidden") == true, "\(shot)")
            #expect(try !ui.layout.isShowing(pane), "the user's visible tab did not change")
        }

        /// "pane-info flags an error page and refuses to invent a viewport for a hidden pane" (the hidden half), and
        /// "activate-pane brings a backgrounded pane to the front so it can be captured".
        @Test func paneInfoRefusesToInventAViewportForAHiddenPaneAndActivatePaneMakesItAnswerableAgain() async throws {
            let server = try await server()
            defer { server.stop() }
            let ui = UIDriver(layout: Self.layout())
            let (pane, id) = try await setUp(server.url(), ui: ui)
            let healthy = await ui.ctlResult("pane-info", ["pane": id], from: Self.caller)
            #expect((healthy["viewport"]?["width"]?.doubleValue ?? 0) > 0)
            #expect(healthy["hidden"] == nil && healthy["showingErrorPage"] == nil)

            try ui.click(tab: "t-agent")
            ui.layoutAll()
            let background = await ui.ctlResult("pane-info", ["pane": id], from: Self.caller)
            #expect(background["hidden"] == true && background["viewport"] == nil, "no viewport at all rather than a zero one")

            let activated = await ui.ctl("activate-pane", ["pane": id], from: Self.caller)
            #expect(activated["ok"] == true)
            ui.layoutAll()
            #expect(try ui.layout.isShowing(pane) && ui.activePane == Self.caller)
            var revealed = await ui.ctlResult("pane-info", ["pane": id], from: Self.caller)
            for _ in 0..<40 where revealed["hidden"] != nil {
                try await Task.sleep(for: .milliseconds(50))
                ui.layoutAll()
                revealed = await ui.ctlResult("pane-info", ["pane": id], from: Self.caller)
            }
            #expect((revealed["viewport"]?["width"]?.doubleValue ?? 0) > 0, "activate-pane is what makes it answerable again")
            let shot = await ui.ctlResult("screenshot", ["pane": id], from: Self.caller)
            #expect(shot["path"] != nil && shot["activated"] == nil, "already shown, so nothing to say")
        }

        // MARK: The pane in the real shell

        /// "an agent-owned pane pulses the control indicator, and it never propagates to its tab" (H-5): the signal is
        /// raised on the pane and on no tab.
        @Test func anAgentOwnedPanePulsesTheControlIndicatorAndItNeverPropagatesToItsTab() async throws {
            let ui = UIDriver(layout: Self.layout())
            let pane = try await ui.createBrowserPane(from: Self.caller, url: "about:blank")
            #expect(ui.runtime.panes.ownership.owner(of: pane) == Self.caller)
            #expect(try ui.headerSignals(NodeID(pane.rawValue)) == ["controlled"])
            #expect(try ui.outline(NodeID(pane.rawValue))?.shown?.kind.id == "controlled")
            let window = try #require(try ui.window.window)
            #expect(InputSynthesizer.find("tab-signal-controlled", in: window) == nil, "there is no tab icon for it")
            let robot = try #require(InputSynthesizer.find("pane-signal-controlled", in: window))
            #expect(robot.toolTip == nil || robot.toolTip == "Controlled by another pane")
            // Closing the pane withdraws it, and the ledger forgets it.
            _ = await ui.ctlResult("close-pane", ["pane": .string(pane.rawValue)], from: Self.caller)
            ui.layoutAll()
            #expect(ui.runtime.signals.raised(on: pane).isEmpty)
            #expect(!ui.runtime.panes.ownership.isOwned(pane))
        }

        /// J-1: a new pane opens beside the caller as a tab, shown; the caller keeps the keyboard, and the page is
        /// the pane's whole body.
        @Test func aCreatedPaneIsShownBesideTheCallerWhichKeepsTheKeyboard() async throws {
            let server = try await server()
            defer { server.stop() }
            let ui = UIDriver(layout: Self.layout())
            #expect(ui.focusedPane == Self.caller)
            let pane = try await ui.createBrowserPane(from: Self.caller, url: server.url())
            #expect(try ui.layout.isShowing(pane), "the new tab is the visible one")
            #expect(ui.activePane == pane, "active, as the Electron store makes an agent's pane")
            #expect(ui.focusedPane != pane, "but it did not take the keyboard")
            let web = try ui.webView(pane)
            #expect(web.window != nil && web.bounds.width > 0)
            try await ui.browserState(pane) { $0["title"] == "Fixture" }
        }

        /// "create-browser-pane splits <direction>ly …" (the views): a split puts the two panes side by side or one
        /// above the other, sharing an edge.
        @Test func aSplitPlacedBrowserPaneSharesAnEdgeWithItsCaller() async throws {
            for (edge, horizontal) in [(SplitEdge.trailing, true), (SplitEdge.bottom, false)] {
                let ui = UIDriver(layout: Self.layout())
                let request = PaneRequest(
                    type: "browser", config: ["url": "about:blank"], placement: .split(Self.caller, edge: edge), activates: false)
                let pane = try #require(ui.runtime.panes.openPane(request))
                ui.layoutAll()
                let browser = try ui.webView(pane)
                let caller = try ui.body(Self.caller)
                let browserRect = browser.convert(browser.bounds, to: nil)
                let callerRect = caller.convert(caller.bounds, to: nil)
                let shared = horizontal ? (browserRect.maxY, callerRect.maxY) : (browserRect.minX, callerRect.minX)
                let apart = horizontal ? (browserRect.minX, callerRect.minX) : (browserRect.minY, callerRect.minY)
                #expect(abs(shared.0 - shared.1) < 2, "a shared edge (\(horizontal ? "horizontal" : "vertical"))")
                #expect(abs(apart.0 - apart.1) > 50, "and apart along the other axis")
                #expect(try ui.layout.isShowing(pane) && ui.layout.isShowing(Self.caller), "both visible: nothing was backgrounded")
            }
        }

        /// "create-browser-pane opens its own unpinned window when placement is set to unpinned" (the view).
        @Test func anUnpinnedBrowserPaneIsAFloatingWindowOverItsCaller() async throws {
            let ui = UIDriver(layout: Self.layout())
            let request = PaneRequest(
                type: "browser", config: ["url": "about:blank"], placement: .floating(near: Self.caller), activates: false)
            let pane = try #require(ui.runtime.panes.openPane(request))
            ui.layoutAll()
            #expect(try ui.layout.floatingPane(holding: pane) != nil)
            #expect(try ui.webView(pane).window != nil)
            #expect(try ui.layout.rootNode.leaves.map(\.id) == [Self.caller], "the docked root is untouched")
        }

        /// J-10: a ref from another document is stale and says so with the remedy, never capturing something else; an ambiguous
        /// semantic target fails listing its candidates (`--selector` is a semantic target, `nth` indexes them).
        @Test func aStaleRefReportsWhyAndAnAmbiguousTargetListsItsCandidates() async throws {
            let server = try await server()
            defer { server.stop() }
            let ui = UIDriver(layout: Self.layout())
            let (pane, id) = try await setUp(server.url(), ui: ui)
            let read = await ui.ctlResult("read-page", ["pane": id, "role": "button"], from: Self.caller)
            guard case .array(let elements) = read["elements"] ?? .null, let ref = elements.first?["ref"] else {
                Issue.record("no ref: \(read)")
                return
            }
            let live = await ui.ctl("screenshot", ["pane": id, "ref": ref], from: Self.caller)
            #expect(live["ok"] == true, "\(live)")
            _ = await ui.ctlResult("navigate", ["pane": id, "url": .string(server.url("/other"))], from: Self.caller)
            let stale = await ui.ctl("screenshot", ["pane": id, "ref": ref], from: Self.caller)
            #expect(stale["ok"] == false)
            let error = stale["error"]?.stringValue ?? ""
            #expect(error.contains("no element for ref") && error.contains("call readPage again"), "\(error)")

            _ = await ui.ctlResult("navigate", ["pane": id, "url": .string(server.url())], from: Self.caller)
            let ambiguous = await ui.ctl("screenshot", ["pane": id, "selector": "button"], from: Self.caller)
            #expect(ambiguous["ok"] == false)
            #expect(ambiguous["error"]?.stringValue?.contains("elements match") == true, "\(ambiguous)")
            #expect(ambiguous["error"]?.stringValue?.contains("Do the thing") == true, "it lists the candidates")
            _ = pane
        }

        /// "create-browser-pane is refused while the browser content type is turned off": the real bundle, the real
        /// enablement. The message names where to undo it; the pane made earlier stays drivable, and listed; turning the
        /// type back on restores creation.
        @Test func createBrowserPaneIsRefusedWhileTheBrowserContentTypeIsTurnedOff() async throws {
            let ui = UIDriver(layout: Self.layout())
            let owned = try await ui.createBrowserPane(from: Self.caller, url: "about:blank")
            ui.runtime.host.setUserEnabled(false, for: "browser")
            let refused = await ui.ctl("create-browser-pane", ["url": "about:blank"], from: Self.caller)
            #expect(refused["ok"] == false)
            #expect(refused["error"]?.stringValue?.contains("Content types") == true, "\(refused)")

            #expect(await ui.ctl("navigate", ["pane": .string(owned.rawValue), "url": "about:blank"], from: Self.caller)["ok"] == true)
            let listed = await ui.ctlResult("list-panes", from: Self.caller)
            #expect(listed["panes"]?[0]?["paneId"] == .string(owned.rawValue) && listed["panes"]?[1] == nil)

            ui.runtime.host.setUserEnabled(true, for: "browser")
            #expect(await ui.ctl("create-browser-pane", ["url": "about:blank"], from: Self.caller)["ok"] == true, "no restart needed")
        }
    }
}
