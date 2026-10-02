import AppKit
import TabsPluginSDK
import Testing
import WebKit

@testable import Tabs
@testable import TabsCore

extension UIDriver {
    /// A browser input verb from `caller`'s shell against `pane`, as the socket would run it (the flags as
    /// `tabs-ctl` sends them).
    func inputVerb(_ command: String, _ flags: [String: JSONValue] = [:], pane: PaneID, from caller: PaneID) async -> JSONValue {
        var flags = flags
        flags["pane"] = .string(pane.rawValue)
        return await runtime.control.handle(.init(command: command, arguments: .object(flags), targetPane: caller))
    }
}

extension UITests {
    /// The input verbs in the real shell (docs/BROWSER.md D-3, D-7, J-12…J-17): an agent's terminal beside or
    /// over a browser pane it owns, driven the way `tabs-ctl` drives it, with the keyboard "in the terminal"
    /// (the text pane stands for it: a pane whose text a person is typing).
    @MainActor
    @Suite struct BrowserInputUITests {
        private func typedText(_ ui: UIDriver, _ pane: PaneID) -> String? { ui.config(of: pane)?["text"]?.stringValue }

        private func status(_ ui: UIDriver, _ pane: PaneID = "b") async throws -> String? {
            try await ui.pageValue(pane, "document.getElementById('status')?.textContent ?? null").stringValue
        }

        /// A shell "a" (text) with a browser "b" the agent owns, on the standard fixture page: `hidden` puts the
        /// browser in a background tab (shown first, as an agent's new pane is, then the user goes back to their
        /// terminal), else beside the shell in a split.
        private func session(hidden: Bool, path: String = "/page", title: String = "Fixture") async throws -> (
            ui: UIDriver, server: FixtureServer
        ) {
            let server = try await FixtureServer.startStandard()
            let a = Fixture.leaf("a", "text")
            let b = Fixture.leaf("b", "browser", config: ["url": .string(server.url(path))])
            let ui = UIDriver(
                layout: hidden ? Fixture.saved(Fixture.tabsWindow("w", [a, b], active: 1)) : Fixture.sideBySide(a, b, active: "a"))
            ui.runtime.panes.grantOwnership(of: "b", to: "a")
            try await ui.browserState("b") { $0["title"] == .string(title) }
            if hidden { try ui.click(tab: "t-a") }
            ui.layoutAll()
            return (ui, server)
        }

        /// D-7 and D-3: the Electron spec "driving a pane never steals keyboard focus from the terminal", for a
        /// pane in a background tab (where the agent's pane really is when the user watches their terminal) and
        /// for one beside it: every input verb lands in the page, and the keyboard and the active pane stay where they
        /// were.
        @Test(arguments: [true, false])
        func drivingAPaneNeverStealsKeyboardFocusFromTheTerminal(hidden: Bool) async throws {
            let (ui, server) = try await session(hidden: hidden)
            defer { server.stop() }
            #expect(ui.focusedPane == "a" && ui.activePane == "a")
            try ui.type("typing to my agent")
            #expect(typedText(ui, "a") == "typing to my agent")
            let web = try ui.webView("b")
            #expect(web.window != nil, "a pane in a background tab is still in its window")
            #expect(web.isHiddenOrHasHiddenAncestor == hidden)

            // Every input verb, while the user "types" in the terminal.
            #expect(await ui.inputVerb("click", ["selector": "#go"], pane: "b", from: "a")["ok"] == true)
            #expect(try await status(ui) == "clicked")
            #expect(await ui.inputVerb("type", ["selector": "#name", "text": "quiet"], pane: "b", from: "a")["ok"] == true)
            #expect(await ui.inputVerb("key", ["key": "Enter"], pane: "b", from: "a")["ok"] == true)
            let fields = "[{\"target\":{\"selector\":\"#name\"},\"value\":\"still\"}]"
            #expect(await ui.inputVerb("form-input", ["fields": .string(fields)], pane: "b", from: "a")["ok"] == true)
            // Hover, the one that can't land in a window that isn't key (this one never is), fails saying so, and
            // takes nothing either.
            let hovered = await ui.inputVerb("hover", ["selector": "#go"], pane: "b", from: "a")
            #expect(hovered["ok"] == false && hovered["error"]?.stringValue?.contains("only to the active window") == true, "\(hovered)")
            #expect(await ui.inputVerb("scroll", ["direction": "down"], pane: "b", from: "a")["ok"] == true)
            ui.layoutAll()

            // The inputs genuinely landed in the page…
            #expect(try await status(ui) == "typed:still")
            #expect(try await ui.pageValue("b", "window.scrollY").doubleValue ?? 0 > 0)
            // …and the keyboard never left the terminal, nor did the active pane follow the agent's clicks.
            #expect(ui.focusedPane == "a", "focus is in \(String(describing: ui.focusedPane))")
            #expect(ui.activePane == "a")
            let web2 = try ui.webView("b")
            #expect(web2.window?.firstResponder !== web2, "the page never held the window's keyboard")
            // The user's typing carries on where it was.
            try ui.type(" and more")
            #expect(typedText(ui, "a") == "typing to my agent and more")
            #expect(try await ui.pageValue("b", "document.getElementById('name').value") == "still", "and none of it reached the page")
        }

        /// D-7: a window in which nothing has the keyboard is left that way: the page doesn't keep it.
        @Test func aWindowWithNoKeyboardFocusIsLeftWithNone() async throws {
            let (ui, server) = try await session(hidden: false)
            defer { server.stop() }
            let window = try #require(try ui.window.window)
            window.makeFirstResponder(nil)
            #expect(window.firstResponder === window)
            #expect(await ui.inputVerb("click", ["selector": "#go"], pane: "b", from: "a")["ok"] == true)
            #expect(await ui.inputVerb("type", ["selector": "#name", "text": "x"], pane: "b", from: "a")["ok"] == true)
            #expect(try await status(ui) == "typed:x")
            #expect(window.firstResponder === window, "the page never kept the keyboard: \(String(describing: window.firstResponder))")
        }

        /// J-14: `type` appends at the focus point, whichever way the keyboard is elsewhere: the second call goes in
        /// after the first's text, and after a `form-input`'s.
        @Test(arguments: [true, false])
        func typeAppendsAcrossCallsWhileTheKeyboardStaysInTheTerminal(hidden: Bool) async throws {
            let (ui, server) = try await session(hidden: hidden)
            defer { server.stop() }
            func value() async throws -> JSONValue? { try await ui.pageValue("b", "document.getElementById('name').value") }
            #expect(await ui.inputVerb("type", ["selector": "#name", "text": "ada"], pane: "b", from: "a")["ok"] == true)
            #expect(await ui.inputVerb("type", ["selector": "#name", "text": "x"], pane: "b", from: "a")["ok"] == true)
            #expect(try await value() == "adax")
            let fields = "[{\"target\":{\"selector\":\"#name\"},\"value\":\"abc\"}]"
            #expect(await ui.inputVerb("form-input", ["fields": .string(fields)], pane: "b", from: "a")["ok"] == true)
            #expect(await ui.inputVerb("type", ["selector": "#name", "text": "X"], pane: "b", from: "a")["ok"] == true)
            #expect(try await value() == "abcX")
            #expect(ui.focusedPane == "a")
        }

        /// D-3 by contrast: a person's own click in an inactive pane's page does activate it.
        @Test func aPersonsClickInAnInactivePanesPageActivatesItWhereTheAgentsDoesNot() async throws {
            let (ui, server) = try await session(hidden: false)
            defer { server.stop() }
            #expect(await ui.inputVerb("click", ["selector": "#go"], pane: "b", from: "a")["ok"] == true)
            #expect(try await status(ui) == "clicked")
            #expect(ui.activePane == "a", "the agent's click leaves the active pane alone")
            let web = try ui.webView("b")
            try ui.click(at: NSPoint(x: 20, y: 20), in: web)
            #expect(ui.activePane == "b", "a user's press inside the page activates its pane")
        }

        /// J-16: scroll reports where it landed on a hidden pane, with a real screenful for its step.
        @Test func scrollReportsWhereItLandedOnAHiddenPane() async throws {
            let (ui, server) = try await session(hidden: true, path: "/smooth", title: "Smooth")
            defer { server.stop() }
            #expect(try ui.webView("b").isHiddenOrHasHiddenAncestor)
            let before = try await ui.pageValue("b", "window.scrollY").doubleValue ?? -1
            let hidden = await ui.inputVerb("scroll", ["direction": "down"], pane: "b", from: "a")
            #expect(hidden["ok"] == true, "\(hidden)")
            let reported = hidden["result"]?["position"]?["y"]?.doubleValue ?? 0
            #expect(reported > before)
            #expect(try await ui.pageValue("b", "window.scrollY").doubleValue == reported)
            let height = try await ui.pageValue("b", "window.innerHeight").doubleValue ?? 0
            #expect(reported == (height * 0.8).rounded(), "a step is 0.8 of the page's own height (\(height)), not of a zero-sized rect")
        }
    }
}
