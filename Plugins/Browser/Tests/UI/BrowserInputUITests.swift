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
            ui.runtime.panes.ownership.enableControl(of: "b", from: "a")
            try await ui.browserState("b") { $0["title"] == .string(title) }
            if hidden { try ui.click(tab: "t-a") }
            ui.layoutAll()
            return (ui, server)
        }

        /// D-7 and D-3: driving a pane never steals keyboard focus from the terminal, for a pane in a background
        /// tab (where the agent's pane really is when the user watches their terminal) and for one beside it: every
        /// input verb lands in the page, and the keyboard and the active pane stay where they were. J-14: a second
        /// `type` appends, the keyboard in the terminal all along.
        @Test(arguments: [true, false])
        func drivingAPaneNeverStealsKeyboardFocusFromTheTerminal(hidden: Bool) async throws {
            let (ui, server) = try await session(hidden: hidden)
            defer { ui.discardWebData() }
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
            #expect(await ui.inputVerb("type", ["selector": "#name", "text": "er"], pane: "b", from: "a")["ok"] == true)
            #expect(try await ui.pageValue("b", "document.getElementById('name').value") == "quieter", "appended")
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

        /// D-3 (#86, B2): a key an agent sends reaches its page and nothing else, whether or not the page used it —
        /// not the app's event monitors, not its menu, not another pane. WebKit hands a keystroke its page didn't
        /// handle back to the app (`NSApp.sendEvent`) to try as a shortcut, and that routes by key window, which is
        /// wherever the user's keyboard is. The page here handles none of these keys: nothing on it is focused.
        @Test(arguments: [true, false])
        func aKeyThePageDidNotUseNeverReachesTheApp(hidden: Bool) async throws {
            let (ui, server) = try await session(hidden: hidden, path: "/form", title: "Form")
            defer { ui.discardWebData() }
            defer { server.stop() }
            let seen = SeenKeys()
            let monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { event in
                MainActor.assumeIsolated { seen.record(event) }
                return event
            }
            defer { if let monitor { NSEvent.removeMonitor(monitor) } }
            // A chord no app command binds, on an item with a real target: the menu runs it whatever window is key.
            let probe = MenuProbe()
            let item = NSMenuItem(title: "Probe", action: #selector(MenuProbe.probe(_:)), keyEquivalent: "j")
            item.keyEquivalentModifierMask = [.command, .option, .shift]
            item.target = probe
            let menu = NSMenu(title: "Probe")
            menu.addItem(item)
            let holder = NSMenuItem(title: "Probe", action: nil, keyEquivalent: "")
            holder.submenu = menu
            NSApp.mainMenu?.insertItem(holder, at: 0)
            defer { NSApp.mainMenu?.removeItem(holder) }

            let keys: [(key: String, modifiers: String?)] = [
                ("a", "meta"), ("j", "meta,alt,shift"), ("Escape", nil), ("ArrowUp", nil), ("q", nil), ("w", "meta"),
            ]
            for (key, modifiers) in keys {
                var flags: [String: JSONValue] = ["key": .string(key)]
                if let modifiers { flags["modifiers"] = .string(modifiers) }
                let answer = await ui.inputVerb("key", flags, pane: "b", from: "a")
                #expect(answer["ok"] == true, "\(key): \(answer)")
            }
            let pageSaw = try await ui.pageValue("b", "window.__keys.filter(k => k[0] === 'keydown').map(k => k[1]).join(' ')")
            #expect(pageSaw == "a j Escape ArrowUp q w", "the page saw every key: \(pageSaw)")
            #expect(seen.lines.isEmpty, "the app saw: \(seen.lines.joined(separator: "; "))")
            #expect(probe.fired == 0, "the menu ran the probe's chord \(probe.fired) times")
            #expect(typedText(ui, "a") == nil || typedText(ui, "a") == "", "the terminal got: \(typedText(ui, "a") ?? "")")
            #expect(ui.engine.model.leaves.count == 2, "no pane was closed")
        }
    }
}

extension UITests.BrowserInputUITests {
    /// D-9, J-15 (#86, N1): in the real shell, where AppKit closes an undo group only after an input event and an
    /// agent's verbs bring none, each edit is still its own undo step. An undo after refilling one field takes back that
    /// field alone (one used to take back every field filled since the user last typed), an undo after a fill gives
    /// back what the field held before it (not the typing before that too), and with nothing left it is refused. A
    /// real event between verbs leaves that so.
    @Test func eachEditIsItsOwnUndoStepWithNoInputEventBetween() async throws {
        let server = try await FixtureServer.startStandard()
        defer { server.stop() }
        let a = Fixture.leaf("a", "text")
        let b = Fixture.leaf("b", "browser", config: ["url": .string(server.url("/form"))])
        let ui = UIDriver(layout: Fixture.sideBySide(a, b, active: "a"))
        defer { ui.discardWebData() }
        ui.runtime.panes.ownership.enableControl(of: "b", from: "a")
        try await ui.browserState("b") { $0["title"] == "Form" }
        func values() async throws -> String {
            try await ui.pageValue("b", "['query', 'notes'].map(id => document.getElementById(id).value).join(' | ')").stringValue ?? "?"
        }
        func fill(_ fields: [(String, String)]) async {
            let items = fields.map { #"{"target":{"selector":"\#($0.0)"},"value":"\#($0.1)"}"# }
            let answer = await ui.inputVerb(
                "form-input", ["fields": .string("[" + items.joined(separator: ",") + "]")], pane: "b", from: "a")
            #expect(answer["result"]?["filled"] == .int(Int64(fields.count)), "\(answer)")
        }
        func command(_ name: String) async -> JSONValue { await ui.inputVerb("key", ["command": .string(name)], pane: "b", from: "a") }

        await fill([("#query", "Ada"), ("#notes", "note")])
        await fill([("#query", "x@y.z")])
        #expect(try await values() == "x@y.z | note")
        #expect(await command("undo")["ok"] == true)
        #expect(try await values() == "Ada | note", "only the refill is taken back")
        #expect(await command("undo")["ok"] == true)
        #expect(try await values() == "Ada | ", "then the other field's fill")
        #expect(await command("undo")["ok"] == true)
        #expect(try await values() == " | ")
        let nothing = await command("undo")
        #expect(nothing["error"] == "there is nothing to undo on this page", "\(nothing)")

        // A real event through the app, after which AppKit ends its own groupings: the pane's history is unaffected.
        let key = try #require(
            NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: 0,
                context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: 80))
        NSApp.postEvent(key, atStart: false)
        _ = try await values()
        #expect(await ui.inputVerb("type", ["selector": "#query", "text": "x"], pane: "b", from: "a")["ok"] == true)
        await fill([("#query", "hello")])
        NSApp.postEvent(key, atStart: false)
        #expect(await command("undo")["ok"] == true)
        #expect(try await values() == "x | ", "the fill alone, not the typing before it")
        #expect(await command("redo")["ok"] == true)
        #expect(try await values() == "hello | ")
        #expect(await command("redo")["error"] == "there is nothing to redo on this page")
    }
}

/// The keyboard events an app-wide monitor saw, as `<type> <characters> <modifiers> window=<number>`.
@MainActor
private final class SeenKeys {
    private(set) var lines: [String] = []

    func record(_ event: NSEvent) {
        let type = event.type == .keyDown ? "down" : "up"
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        lines.append("\(type) \(event.charactersIgnoringModifiers ?? "") flags=\(flags.rawValue) window=\(event.windowNumber)")
    }
}

/// A menu item's target that counts how often the menu ran it.
@MainActor
private final class MenuProbe: NSObject {
    private(set) var fired = 0
    @objc func probe(_ sender: Any?) { fired += 1 }
}
