import AppKit
import TabsPluginSDK
import Testing
import WebKit

@testable import Tabs
@testable import TabsCore

extension UIDriver {
    /// The page's view of a browser pane (the plugin's own class, in its own bundle: reached as
    /// what it is to AppKit).
    func webView(_ pane: PaneID) throws -> WKWebView {
        try #require(try body(pane).content as? WKWebView, "no browser page in \(pane)")
    }

    /// The header's nav chrome of a browser pane: its title view.
    func toolbar(_ pane: PaneID) throws -> NSView {
        try #require(try paneView(NodeID(pane.rawValue)).header?.titleView, "no browser header on \(pane)")
    }

    /// A control of a browser pane's header, by its accessibility identifier.
    func chrome(_ identifier: String, of pane: PaneID) throws -> NSView {
        try #require(
            InputSynthesizer.find(identifier, in: try window.window!, within: try toolbar(pane)), "no \(identifier) in \(pane)'s header")
    }

    /// The address field of a browser pane.
    func addressField(_ pane: PaneID) throws -> NSTextField {
        try #require(try chrome("browser-address-input", of: pane) as? NSTextField)
    }

    /// Whether the address field has the keyboard.
    func isEditingAddress(_ pane: PaneID) throws -> Bool { try addressField(pane).currentEditor() != nil }

    /// Where the header draws its parts (the Debug verb), `[x, y, width, height]` in the header title's coordinates.
    func geometry(_ pane: PaneID) async throws -> JSONValue { try await call("browser.test.geometry", pane: pane) }

    /// The Debug verb's view of a browser pane.
    func browserState(_ pane: PaneID) async throws -> JSONValue { try await call("browser.test.state", pane: pane) }

    /// Loads a URL through the Debug verb and waits for the load to end.
    @discardableResult
    func browserLoad(_ pane: PaneID, _ url: String) async throws -> JSONValue {
        try await call("browser.test.load", ["url": .string(url)], pane: pane)
    }

    /// Polls the browser's state until `condition` holds; records an issue on timeout.
    @discardableResult
    func browserState(
        _ pane: PaneID, within seconds: Double = 10, sourceLocation: SourceLocation = #_sourceLocation,
        until condition: (JSONValue) -> Bool
    ) async throws -> JSONValue {
        let deadline = Date().addingTimeInterval(seconds)
        var state = try await browserState(pane)
        while !condition(state) {
            guard Date() < deadline else {
                Issue.record("timed out; the browser: \(state)", sourceLocation: sourceLocation)
                return state
            }
            try await Task.sleep(for: .milliseconds(50))
            layoutAll()
            state = try await browserState(pane)
        }
        return state
    }

    /// A script's value in a browser pane's page.
    func pageValue(_ pane: PaneID, _ code: String) async throws -> JSONValue {
        try await call("browser.test.script", ["code": .string(code)], pane: pane)["value"] ?? .null
    }
}

extension UITests {
    /// The browser plugin's real bundle, in the real shell, driven the way a user
    /// drives it (docs/BROWSER.md). Pages come from a loopback fixture server. The
    /// plugin is its own image: what is reached here is AppKit (views by their
    /// accessibility identifiers) and the Debug verbs.
    @MainActor
    @Suite struct BrowserUITests {
        static func one(_ url: String = "about:blank", id: PaneID = "b") -> SavedLayout {
            Fixture.saved(Fixture.window("w", Fixture.leaf(id, "browser", config: ["url": .string(url)])))
        }

        /// Browser "a" beside browser "b", `active` active.
        static func pair(_ a: String = "about:blank", _ b: String = "about:blank", active: NodeID = "a") -> SavedLayout {
            Fixture.sideBySide(
                Fixture.leaf("a", "browser", config: ["url": .string(a)]), Fixture.leaf("b", "browser", config: ["url": .string(b)]),
                active: active)
        }

        private func server() async throws -> FixtureServer {
            let server = try await FixtureServer.start()
            server.page(
                "/a", title: "Page A",
                body: "<input id=q autocomplete=off style='position:absolute;left:10px;top:10px;width:150px;height:30px'>")
            server.page("/b", title: "Page B")
            server.page("/events", title: "Events", body: FixtureServer.eventsPage)
            return server
        }

        private func rect(_ value: JSONValue?) -> CGRect? {
            guard case .array(let numbers)? = value, numbers.count == 4, let x = numbers[0].doubleValue, let y = numbers[1].doubleValue,
                let width = numbers[2].doubleValue, let height = numbers[3].doubleValue
            else { return nil }
            return CGRect(x: x, y: y, width: width, height: height)
        }

        // MARK: Creating

        /// A-1, A-3, B-1, L-8: New browser fills the empty pane in place; the header is the nav chrome
        /// and the body holds the page alone.
        @Test func aNewBrowserIsABlankPageWithNavChromeInItsHeader() async throws {
            let ui = UIDriver()
            defer { ui.discardWebData() }
            let pane = try #require(ui.activePane)
            try ui.create("browser")
            #expect(ui.contentType(of: pane) == "browser", "filled in place")
            let state = try await ui.browserState(pane)
            #expect(state["url"] == "about:blank" && state["addressText"] == "about:blank")
            #expect(try ui.addressField(pane).stringValue == "about:blank")
            let header = try #require(try ui.paneView(NodeID(pane.rawValue)).header)
            let toolbar = try ui.toolbar(pane)
            #expect(header.titleView === toolbar, "the nav chrome is the header's title, and there is no title text to edit")
            let web = try ui.webView(pane)
            #expect(try ui.body(pane).content === web, "the body is the page and nothing else")
            #expect(web.window != nil)
            for identifier in [
                "browser-back-button", "browser-forward-button", "browser-refresh-button", "browser-address-bar", "browser-address-input",
            ] {
                #expect(InputSynthesizer.find(identifier, in: try ui.window.window!) != nil, "\(identifier)")
            }
            #expect(try ui.addressField(pane).accessibilityLabel() == "Address")
        }

        /// A-1: the creation buttons offer "New browser" and the palette lists "Browser", both with the globe.
        @Test func theCreationActionsOfferNewBrowser() throws {
            let ui = UIDriver()
            defer { ui.discardWebData() }
            let active = try #require(ui.activePane)
            let empty = try #require(try ui.body(active).content as? EmptyPaneView)
            #expect(empty.actions.contains { $0.type == "browser" && $0.label == "New browser" })
            try ui.press(KeyChord("p", [.command]))
            let row = try #require(ui.palette?.rows.first { $0.label == "Browser" })
            guard case .type(.image) = row.icon else {
                Issue.record("the palette row has no icon image")
                return
            }
        }

        // MARK: Navigation

        /// B-4: a press on a header button, through the real window, does what it says.
        @Test func refreshReloadsThePage() async throws {
            let server = try await server()
            defer { server.stop() }
            let ui = UIDriver(layout: Self.one(server.url("/a")))
            defer { ui.discardWebData() }
            try await ui.browserState("b") { $0["title"] == "Page A" }
            let before = server.requests.count
            try ui.click(try ui.chrome("browser-refresh-button", of: "b"))
            let deadline = Date().addingTimeInterval(5)
            while server.requests.count == before, Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
            #expect(server.requests.count > before)
        }

        /// B-7, B-8: typing a URL and pressing Return navigates, and the field gives up focus.
        @Test func typingAURLAndPressingReturnNavigates() async throws {
            let server = try await server()
            defer { server.stop() }
            let ui = UIDriver(layout: Self.one())
            defer { ui.discardWebData() }
            try ui.click("browser-address-input")
            #expect(try ui.isEditingAddress("b"))
            try ui.press(KeyChord("a", [.command]))
            try ui.type(server.url("/a"))
            try ui.type("\n")
            try await ui.browserState("b") { $0["url"] == .string(server.url("/a")) && $0["title"] == "Page A" }
            #expect(try !ui.isEditingAddress("b"), "the field gives up focus")
            #expect(try await ui.browserState("b")["addressText"] == .string(server.url("/a")))
        }

        // MARK: The look

        /// B-10: the bar's border turns accent while the field has focus.
        @Test func theBarsBorderTurnsAccentWhileTheFieldHasFocus() async throws {
            let ui = UIDriver(layout: Self.one())
            defer { ui.discardWebData() }
            let toolbar = try ui.toolbar("b")
            let bar = try #require(rect(try await ui.geometry("b")["bar"]))
            let edge = NSPoint(x: bar.minX + 0.5, y: bar.midY)
            let calm = try #require(try Self.paint(toolbar).color(atPoint: edge, in: toolbar.bounds))
            try ui.click("browser-address-input")
            let focused = try #require(try Self.paint(toolbar).color(atPoint: edge, in: toolbar.bounds))
            #expect(calm != focused)
            #expect(focused.blueComponent > focused.redComponent + 0.2, "accent is blue: \(focused)")
            #expect(abs(calm.blueComponent - calm.redComponent) < 0.15, "the border is gray: \(calm)")
        }

        // MARK: Header presses and activation

        /// B-11: a press on a header control activates the pane without starting a pane drag.
        @Test func aPressOnANavButtonActivatesThePaneWithoutStartingADrag() throws {
            let ui = UIDriver(layout: Self.pair(active: "b"))
            defer { ui.discardWebData() }
            #expect(ui.activePane == "b")
            let before = try ui.layout.rootNode
            let refresh = try ui.chrome("browser-refresh-button", of: "a")
            let (pane, target) = try ui.spot("b", 0.9, 0.55)
            try ui.drag(refresh, from: NSPoint(x: 10, y: 8), to: target, in: pane)
            #expect(!ui.renderer.drag.isDragging)
            #expect(try ui.layout.rootNode == before, "nothing moved")
            #expect(ui.activePane == "a", "and the pane is active")
        }

        /// B-11: a press on the bar's title segment (its empty space) drags the pane like the rest of the bar.
        @Test func aPressOnTheTitleSegmentDragsThePaneLikeTheRestOfTheBar() async throws {
            let server = try await server()
            defer { server.stop() }
            let ui = UIDriver(layout: Self.pair(server.url("/a"), active: "b"))
            defer { ui.discardWebData() }
            try await ui.browserState("a") { $0["title"] == "Page A" }
            ui.layoutAll()
            let segment = try ui.chrome("browser-title-segment", of: "a")
            #expect(!segment.isHidden)
            let (edge, _) = try ui.spot("b", 0.9, 0.55)
            let start = NSPoint(x: segment.bounds.midX, y: segment.bounds.midY)
            try ui.drag(segment, from: start, to: NSPoint(x: edge.bounds.width * 0.9, y: edge.bounds.height * 0.55), in: edge)
            #expect(try ui.layout.shownContent?.splitNode?.children.map(\.id) == ["b", "a"], "docked beside B")
        }

        /// B-11, B-12, D-4: a press on the address field activates the pane, and leaves the keyboard in the header.
        @Test func activatingFromTheHeaderDoesNotMoveTheKeyboardOntoThePage() async throws {
            let ui = UIDriver(layout: Self.pair(active: "b"))
            defer { ui.discardWebData() }
            let before = try ui.layout.rootNode
            try ui.click(try ui.addressField("a"))
            #expect(ui.activePane == "a")
            #expect(try ui.layout.rootNode == before, "nothing moved")
            #expect(try ui.isEditingAddress("a"))
            ui.engine.focus("a")
            ui.layoutAll()
            #expect(try ui.isEditingAddress("a"), "core asked the pane to take focus; it stayed in the header")
        }

        /// D-4: activating a pane any other way gives its page the keyboard.
        @Test func activatingAPaneGivesItsPageTheKeyboard() throws {
            let ui = UIDriver(layout: Self.pair(active: "a"))
            defer { ui.discardWebData() }
            ui.engine.focus("b")
            ui.layoutAll()
            #expect(ui.focusedPane == "b")
            let web = try ui.webView("b")
            let responder = try #require(try ui.window.window?.firstResponder as? NSView)
            #expect(responder === web || responder.isDescendant(of: web), "the page holds the keyboard: \(responder)")
        }

        // MARK: Clicking into the page

        /// D-1, D-2: a press inside an inactive browser pane's page makes it the active pane, and still lands in the page.
        @Test func aClickInsideAnInactivePanesPageActivatesItAndStillLandsInThePage() async throws {
            let server = try await server()
            defer { server.stop() }
            let ui = UIDriver(layout: Self.pair(server.url("/b"), server.url("/a"), active: "a"))
            defer { ui.discardWebData() }
            try await ui.browserState("b") { $0["title"] == "Page A" }
            ui.layoutAll()
            #expect(ui.activePane == "a")
            try ui.click(at: NSPoint(x: 50, y: 25), in: try ui.webView("b"))
            #expect(ui.activePane == "b", "a press in the page activates its pane")
            // The click that activated it landed in the page: typing reaches the clicked field.
            try ui.type("typed")
            let deadline = Date().addingTimeInterval(5)
            while try await ui.pageValue("b", "document.getElementById('q').value") != "typed", Date() < deadline {
                try await Task.sleep(for: .milliseconds(50))
            }
            #expect(try await ui.pageValue("b", "document.getElementById('q').value") == "typed")
            #expect(try await ui.pageValue("b", "document.activeElement.id") == "q")
        }

        /// D-1: a right-click activates the pane, and D-10: the page shows no menu of its own. (Core's click monitor sees
        /// the press before the page does: a blank page is page enough.)
        @Test func aRightClickActivatesThePaneAndShowsNoContextMenu() throws {
            let ui = UIDriver(layout: Self.pair(active: "a"))
            defer { ui.discardWebData() }
            try ui.click(at: NSPoint(x: 50, y: 25), in: try ui.webView("b"), right: true)
            #expect(ui.activePane == "b")
            #expect(ui.contextMenu == nil, "core's menu isn't the page's")
        }

        /// D-5, D-6: an app chord pressed in a focused page moves pane focus and never reaches the page.
        @Test func aNavChordPressedInAFocusedPageEscapesItWithoutReachingThePage() async throws {
            let server = try await server()
            defer { server.stop() }
            let ui = UIDriver(layout: Self.pair(server.url("/events"), server.url("/events"), active: "b"))
            defer { ui.discardWebData() }
            try await ui.browserState("a") { $0["title"] == "Events" }
            try await ui.browserState("b") { $0["title"] == "Events" }
            ui.layoutAll()
            ui.engine.focus("b")
            #expect(ui.focusedPane == "b")
            _ = try await ui.pageValue("b", "JSON.stringify(window.__log.splice(0))")
            let chord = try #require(ui.runtime.shortcuts.chord(for: CoreCommands.navLeft.id))
            try ui.press(chord)
            #expect(ui.activePane == "a", "⌘← moved pane focus out of the page")
            #expect(ui.focusedPane == "a")
            let log = try await ui.pageValue("b", "JSON.stringify(window.__log.splice(0))")
            #expect(log.stringValue == "[]", "and the page saw no key: \(String(describing: log.stringValue))")
            // The page's own keys stay its own.
            ui.engine.focus("b")
            ui.layoutAll()
            try ui.type("x")
            let deadline = Date().addingTimeInterval(5)
            var seen = ""
            while !seen.contains("keydown:x"), Date() < deadline {
                seen = try await ui.pageValue("b", "JSON.stringify(window.__log)").stringValue ?? ""
                try await Task.sleep(for: .milliseconds(50))
            }
            #expect(seen.contains("keydown:x:"), "\(seen)")
        }

        /// D-6: every app shortcut is left to the app by a focused page.
        @Test func everyAppShortcutIsLeftToTheAppByAFocusedPage() throws {
            let ui = UIDriver(layout: Self.one())
            defer { ui.discardWebData() }
            let web = try ui.webView("b")
            let window = try #require(web.window)
            for chord in [
                KeyChord("t", [.command]), KeyChord("w", [.command]), KeyChord(.arrow(.left), [.command]), KeyChord("a", [.command]),
            ] {
                let event = try #require(
                    NSEvent.keyEvent(
                        with: .keyDown, location: .zero, modifierFlags: chord.eventModifierFlags, timestamp: 0,
                        windowNumber: window.windowNumber,
                        context: nil, characters: chord.menuKeyEquivalent, charactersIgnoringModifiers: chord.menuKeyEquivalent,
                        isARepeat: false,
                        keyCode: 0))
                #expect(!web.performKeyEquivalent(with: event), "\(chord) is the app's, not the page's")
            }
        }

        /// D-9: the Edit menu's actions are the responder chain's, and the focused page answers them. (The menu itself
        /// can't be *chosen* here: with no key window, AppKit validates every nil-targeted item disabled.)
        @Test func theEditMenusActionsReachTheFocusedPage() async throws {
            let server = try await server()
            defer { server.stop() }
            let ui = UIDriver(layout: Self.one(server.url("/a")))
            defer { ui.discardWebData() }
            try await ui.browserState("b") { $0["title"] == "Page A" }
            ui.layoutAll()
            try ui.click(at: NSPoint(x: 50, y: 25), in: try ui.webView("b"))
            try ui.type("hello")
            let deadline = Date().addingTimeInterval(5)
            while try await ui.pageValue("b", "document.getElementById('q').value") != "hello", Date() < deadline {
                try await Task.sleep(for: .milliseconds(50))
            }
            let item = try ui.menuItem("Edit", "Select All")
            let action = try #require(item.action)
            #expect(item.target == nil, "the responder chain's, not the app's")
            let responder = try #require(try ui.window.window?.firstResponder)
            #expect(responder.tryToPerform(action, with: nil), "the page's own view answers it")
            let selection = "document.getElementById('q').selectionStart + '-' + document.getElementById('q').selectionEnd"
            let selected = Date().addingTimeInterval(5)
            while try await ui.pageValue("b", selection) != "0-5", Date() < selected { try await Task.sleep(for: .milliseconds(50)) }
            #expect(try await ui.pageValue("b", selection) == "0-5")
            var refused: [String] = []
            for title in ["Cut", "Copy", "Paste", "Undo", "Redo"] {
                let edit = try ui.menuItem("Edit", title)
                if edit.target != nil || edit.action == nil || !responder.responds(to: edit.action!) { refused.append(title) }
            }
            #expect(refused.isEmpty, "the page's view doesn't answer: \(refused)")
        }

        /// A-2, A-4: a new tab or split made from a browser (⌘T, ⇧⌘T) is a copy of it, where it is now.
        @Test func aNewTabOrSplitLikeABrowserStartsWhereItIs() async throws {
            let server = try await server()
            defer { server.stop() }
            let ui = UIDriver(layout: Self.one(server.url("/a")))
            defer { ui.discardWebData() }
            try ui.press(KeyChord("t", [.command]))
            let tab = try #require(ui.activePane)
            #expect(tab != "b" && ui.contentType(of: tab) == "browser", "a browser, like the one it was made from")
            try ui.press(KeyChord("t", [.command, .shift]))
            let split = try #require(ui.activePane)
            #expect(split != tab && ui.contentType(of: split) == "browser")
            // Both load at once.
            for copy in [tab, split] {
                let state = try await ui.browserState(copy) { $0["url"] == .string(server.url("/a")) }
                #expect(state["configURL"] == .string(server.url("/a")))
            }
        }

        // MARK: Moving

        /// E-1, E-2, E-6: a pane that is moved keeps its page: history, form state, console, the page itself;
        /// and a sibling split beside it, or closed again, never touches it.
        @Test func aMovedPaneKeepsItsPage() async throws {
            let server = try await server()
            defer { server.stop() }
            server.page(
                "/state", title: "State", head: "<script>console.log('loaded once')</script>",
                body: "<input id=q style='position:absolute;left:10px;top:10px;width:150px;height:30px'>")
            let ui = UIDriver(layout: Self.one())
            defer { ui.discardWebData() }
            try await ui.browserLoad("b", server.url("/a"))
            try await ui.browserLoad("b", server.url("/state"))
            try await ui.browserState("b") { $0["title"] == "State" && $0["console"]?.intValue == 1 }
            _ = try await ui.pageValue("b", "(document.getElementById('q').value = 'filled in', history.pushState({}, '', '/state#in'), 1)")
            let before = try await ui.browserState("b") { $0["url"] == .string(server.url("/state#in")) }
            let web = try ui.webView("b")
            let requests = server.requests.count

            // Splitting beside it: a sibling appears, the page is untouched.
            try ui.choose(.splitHorizontal, of: "b")
            ui.layoutAll()
            #expect(try ui.webView("b") === web)
            // Wrapping it in a tab group moves its view in the layout.
            try ui.choose(.wrapInTabGroup, of: "b")
            ui.layoutAll()
            // Closing the sibling folds the split away around it.
            let sibling = try #require(ui.engine.model.leaves.map(\.id).first { $0 != "b" }, "the split made a sibling")
            ui.engine.close(sibling)
            ui.layoutAll()
            #expect(ui.engine.model.leaves.map(\.id) == ["b"])
            let after = try await ui.browserState("b")
            #expect(after["pageInstance"] == before["pageInstance"], "a move never changes the page's identity")
            #expect(after["url"] == before["url"] && after["console"] == before["console"], "history and console survive: \(after)")
            #expect(after["canGoBack"] == true)
            #expect(try await ui.pageValue("b", "document.getElementById('q').value") == "filled in", "form state survives")
            #expect(try ui.webView("b") === web && web.window != nil && web.superview != nil, "the very same page, in a window")
            #expect(server.requests.count == requests, "no request: the page was not reloaded")
        }

        // MARK: Painting

        private static func paint(_ view: NSView) throws -> Painted {
            view.layoutSubtreeIfNeeded()
            let rep = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
            NSColor(srgbRed: 1, green: 0, blue: 1, alpha: 1).setFill()
            view.bounds.fill()
            NSGraphicsContext.restoreGraphicsState()
            view.cacheDisplay(in: view.bounds, to: rep)
            return Painted(rep: rep)
        }

        struct Painted {
            let rep: NSBitmapImageRep

            /// The color at a point (view coordinates, top-left origin) as sRGB.
            func color(atPoint point: NSPoint, in bounds: NSRect) -> NSColor? {
                let scale = Double(rep.pixelsWide) / bounds.width
                return rep.colorAt(x: Int(point.x * scale), y: Int(point.y * scale))?.usingColorSpace(.sRGB)
            }
        }

        private static func near(_ a: NSColor, _ b: NSColor, tolerance: CGFloat = 0.03) -> Bool {
            guard let a = a.usingColorSpace(.sRGB), let b = b.usingColorSpace(.sRGB) else { return false }
            return abs(a.redComponent - b.redComponent) < tolerance && abs(a.greenComponent - b.greenComponent) < tolerance
                && abs(a.blueComponent - b.blueComponent) < tolerance
        }
    }
}

extension NSColor {
    static func != (lhs: NSColor, rhs: NSColor) -> Bool { !(lhs.isEqual(rhs)) }
}
