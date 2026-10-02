import AppKit
import Darwin
import TabsPluginSDK
import Testing

@testable import Tabs
@testable import TabsCore

/// The terminal plugin's real bundle, driven like a user would in the hosted
/// app (docs/TERMINAL.md). Shells are real `$SHELL -l` login shells running
/// the user's dotfiles, so tests wait for markers of their own
/// (`echo MARK-$((40+2))` prints `MARK-42`, which the echoed command line
/// doesn't), never for a particular prompt.
extension UIDriver {
    /// A control verb, as the socket would run it.
    func call(_ command: String, _ arguments: JSONValue = .emptyObject, pane: PaneID? = nil) async throws -> JSONValue {
        let response = await runtime.control.handle(.init(command: command, arguments: arguments, targetPane: pane))
        guard response["ok"] == true else {
            throw TerminalCallFailure(description: "\(command): \(response["error"]?.stringValue ?? "\(response)")")
        }
        return response["result"] ?? .null
    }

    struct TerminalCallFailure: Error, CustomStringConvertible { let description: String }

    /// The Debug verb's view of a terminal pane: pid, grid, pty size, text, cwd, focus.
    func terminal(_ pane: PaneID) async throws -> JSONValue { try await call("terminal.test.state", pane: pane) }

    /// Polls the terminal until `condition` holds (the run loop turning meanwhile); records an issue on timeout.
    @discardableResult
    func terminal(
        _ pane: PaneID, within seconds: Double = 20, sourceLocation: SourceLocation = #_sourceLocation,
        until condition: (JSONValue) -> Bool
    ) async throws -> JSONValue {
        let deadline = Date().addingTimeInterval(seconds)
        var state = try await terminal(pane)
        while !condition(state) {
            guard Date() < deadline else {
                Issue.record("timed out; the terminal: \(state["buffer"]?.stringValue?.suffix(1500) ?? "")", sourceLocation: sourceLocation)
                return state
            }
            try await Task.sleep(for: .milliseconds(50))
            layoutAll()
            state = try await terminal(pane)
        }
        return state
    }

    /// Waits until the pane's shell runs and has printed something (its prompt).
    @discardableResult
    func shellReady(_ pane: PaneID) async throws -> Int32 {
        let state = try await terminal(pane) { $0["pid"]?.intValue != nil && !($0["buffer"]?.stringValue ?? "").trimmed.isEmpty }
        return Int32(try #require(state["pid"]?.intValue))
    }

    /// Focuses `pane` and types `command` and Return into it.
    func run(_ command: String, in pane: PaneID) throws {
        engine.focus(pane)
        layoutAll()
        let window = try #require(engine.model.window(holding: pane).flatMap { renderer.windowController($0.id) })
        try type(command + "\n", in: window)
    }

    /// Runs `command; echo MARK-$((n+1))` in `pane` and waits for `MARK-<n+1>`.
    @discardableResult
    func runAndWait(_ command: String, in pane: PaneID, mark: Int = 41) async throws -> JSONValue {
        try run("\(command); echo MARK-$((\(mark)+1))", in: pane)
        return try await terminal(pane) { $0.buffer.contains("MARK-\(mark + 1)") }
    }
}

extension JSONValue {
    var buffer: String { self["buffer"]?.stringValue ?? "" }
    var screen: String { self["screen"]?.stringValue ?? "" }
}

extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}

/// Whether `pid` is a live process (a zombie counts until it's reaped).
func isAlive(_ pid: Int32) -> Bool { kill(pid, 0) == 0 }

/// Polls until `pid` is gone.
func waitGone(_ pid: Int32, within seconds: Double = 5) async throws -> Bool {
    let deadline = Date().addingTimeInterval(seconds)
    while isAlive(pid), Date() < deadline { try await Task.sleep(for: .milliseconds(50)) }
    return !isAlive(pid)
}

extension UITests {
    @MainActor
    @Suite struct TerminalUITests {
        /// One terminal pane ("a") in the window's root tab.
        static let one = Fixture.saved(Fixture.window("w", Fixture.leaf("a", "terminal")))
        /// A terminal "a" beside an empty pane "b", `active` active.
        static func besideEmpty(active: NodeID = "a") -> SavedLayout {
            Fixture.sideBySide(Fixture.leaf("a", "terminal"), Fixture.leaf("b"), active: active)
        }

        // MARK: The shell and the keyboard

        /// T-1, T-127: New terminal fills the empty pane with a live login shell that has the keyboard.
        @Test func aNewTerminalIsALoginShellWithTheKeyboard() async throws {
            let ui = UIDriver()
            let pane = try #require(ui.activePane)
            try ui.create("terminal")
            #expect(ui.contentType(of: pane) == "terminal", "filled in place")
            let pid = try await ui.shellReady(pane)
            #expect(ui.focusedPane == pane, "the new terminal has the keyboard")
            // Typing goes straight in (no click): the shell's own $HOME, and its argv carries -l.
            try ui.type("echo \"HOME:$HOME\"; ps -o args= -p $$; echo MARK-$((40+2))\n")
            let state = try await ui.terminal(pane) { $0.buffer.contains("MARK-42") }
            #expect(state.buffer.contains("HOME:\(NSHomeDirectory())"))
            #expect(state.buffer.split(separator: "\n").contains { $0.hasSuffix(" -l") }, "a login shell: \(state.buffer)")
            #expect(state["pid"]?.intValue == Int64(pid))
        }

        /// T-128: a click anywhere in a terminal gives it the keyboard.
        @Test func clickingATerminalFocusesIt() async throws {
            let ui = UIDriver(layout: Self.besideEmpty(active: "b"))
            try await ui.shellReady("a")
            #expect(ui.focusedPane == "b")
            let body = try ui.body("a")
            try ui.click(at: NSPoint(x: body.bounds.midX, y: body.bounds.midY), in: body)
            #expect(ui.activePane == "a")
            #expect(ui.focusedPane == "a")
            try ui.type("echo MARK-$((1+1))\n")
            try await ui.terminal("a") { $0.buffer.contains("MARK-2") }
        }

        // MARK: The header's Clear scrollback

        /// L-7, T-98: the terminal's header action is a header button, leftmost, and clears the scrollback.
        @Test func theHeaderClearScrollbackButtonClearsButNotTheAlternateScreen() async throws {
            let ui = UIDriver(layout: Self.one)
            try await ui.shellReady("a")
            let chrome = try ui.chrome("a")
            let window = try #require(try ui.window.window)
            let button = try #require(
                InputSynthesizer.find("pane-terminal-clear-scrollback-button", in: window, within: chrome) as? PaneActionButton)
            let split = try #require(InputSynthesizer.find("pane-split-horizontal-button", in: window, within: chrome))
            #expect(button.frame.size == CGSize(width: 23, height: 17), "a header button's box")
            #expect(button.superview === split.superview, "among the header's controls")
            #expect(button.frame.minX < split.frame.minX, "leftmost, before the split group")
            #expect(button.frame.minX == 0)
            #expect(button.action.label == "Clear scrollback")
            #expect(button.accessibilityLabel() == "Clear scrollback")

            try await ui.runAndWait("printf 'filler-%s\\n' $(seq 1 200)", in: "a")
            #expect(try await ui.terminal("a").buffer.contains("filler-1\n"), "scrollback holds the start")
            try ui.click(button)
            let cleared = try await ui.terminal("a") { !$0.buffer.contains("filler-") }
            #expect(!cleared.buffer.contains("MARK-42"), "only the prompt line is left")

            // A full-screen program's alternate screen is left alone.
            try await ui.runAndWait("printf '\\033[?1049h'; echo alt-screen-content", in: "a", mark: 10)
            #expect(try await ui.terminal("a")["alternateScreen"] == true)
            try ui.click(button)
            let kept = try await ui.runAndWait("echo after-clear-attempt", in: "a", mark: 20)
            #expect(kept.screen.contains("alt-screen-content"), "not cleared under the program")
            try ui.run("printf '\\033[?1049l'", in: "a")
        }

        // MARK: Clear Buffer (⌘K)

        /// T-95, T-97, T-125: Edit ▸ Clear Buffer is ⌘K, acts only on an active terminal.
        @Test func commandKClearsTheActiveTerminalOnly() async throws {
            let ui = UIDriver(layout: Self.besideEmpty())
            try await ui.shellReady("a")
            try await ui.runAndWait("echo clear-marker", in: "a")

            try ui.click(body: "b")
            #expect(ui.activePane == "b")
            #expect(ui.contentType(of: "b") == nil, "still empty")
            #expect(try !ui.menuItem("Edit", "Clear Buffer").isEnabled, "not for an empty pane")
            #expect(try !ui.press(KeyChord("k", [.command])), "nothing takes ⌘K there")
            try await ui.runAndWait("echo second-marker", in: "a", mark: 50)
            #expect(try await ui.terminal("a").buffer.contains("clear-marker"), "the terminal beside it wasn't cleared")

            #expect(ui.activePane == "a")
            #expect(try ui.menuItem("Edit", "Clear Buffer").isEnabled)
            #expect(try ui.press(KeyChord("k", [.command])), "⌘K is Edit ▸ Clear Buffer")
            let cleared = try await ui.terminal("a") { !$0.buffer.contains("clear-marker") }
            #expect(!cleared.buffer.contains("second-marker"))
        }

        /// T-96: ⌘K leaves a full-screen program's alternate screen alone.
        @Test func commandKLeavesTheAlternateScreenAlone() async throws {
            let ui = UIDriver(layout: Self.one)
            try await ui.shellReady("a")
            try await ui.runAndWait("printf '\\033[?1049h'; echo alt-screen-content", in: "a")
            try ui.press(KeyChord("k", [.command]))
            let state = try await ui.runAndWait("echo after-clear-attempt", in: "a", mark: 60)
            #expect(state.screen.contains("alt-screen-content"))
            try ui.run("printf '\\033[?1049l'", in: "a")
        }

        // MARK: App shortcuts over the shell

        /// T-126, T-51, T-127: ⌘T in a focused terminal is the app's: a new terminal tab beside it
        /// (the bare terminal promoted into a group), keeping its shell and scrollback; closing
        /// that tab collapses the group back and ends only the new tab's shell (T-52, T-10).
        @Test func commandTPromotesALiveTerminalAndClosingTheTabCollapsesItBack() async throws {
            let ui = UIDriver(layout: Self.besideEmpty())
            let pid = try await ui.shellReady("a")
            try await ui.runAndWait("echo before-promote-marker", in: "a")
            let view = try #require(ui.renderer.body(for: "a")?.content)

            #expect(try ui.press(KeyChord("t", [.command])), "⌘T reached the menu, not the shell")
            let promoted = try #require(ui.activePane)
            #expect(promoted != "a")
            #expect(ui.contentType(of: promoted) == "terminal", "a new pane like the one it came from")
            let group = try #require(ui.layout.shownContent?.splitNode?.children.first?.group, "a promoted into a group")
            #expect(group.tabs.map(\.content.id) == ["a", promoted])
            #expect(group.tabs.map(\.title) == ["Terminal", "Terminal"])
            let second = try await ui.shellReady(promoted)
            #expect(second != pid, "a shell of its own")
            #expect(ui.focusedPane == promoted, "typing goes to the new one")
            #expect(isAlive(pid))
            #expect(ui.renderer.body(for: "a")?.content === view, "the same view, moved")
            #expect(try await ui.terminal("a")["pid"]?.intValue == Int64(pid))
            #expect(try await ui.terminal("a").buffer.contains("before-promote-marker"))

            let tab = try #require(group.tabs.last?.id)
            try ui.close(tab: tab)
            #expect(try ui.layout.findTab(tab) == nil)
            #expect(try ui.layout.shownContent?.splitNode?.children.first?.id == "a", "collapsed back to the bare pane")
            #expect(try await waitGone(second), "the closed tab's shell ended")
            #expect(isAlive(pid))
            try await ui.runAndWait("echo survived-the-collapse", in: "a", mark: 70)
            #expect(try await ui.terminal("a").buffer.contains("before-promote-marker"))
        }

        /// T-126, T-127: ⌘→ in a focused terminal moves focus to the pane beside it, and typing follows.
        @Test func commandArrowLeavesAFocusedTerminalAndTypingFollows() async throws {
            let ui = UIDriver(
                layout: Fixture.sideBySide(Fixture.leaf("a", "terminal"), Fixture.leaf("b", "terminal"), active: "a"))
            try await ui.shellReady("a")
            try await ui.shellReady("b")
            try await ui.runAndWait("echo in-first-shell", in: "a")
            #expect(ui.focusedPane == "a")
            #expect(try ui.press(KeyChord(.arrow(.right), [.command])))
            #expect(ui.activePane == "b")
            #expect(ui.focusedPane == "b", "the keyboard went with it")
            try ui.type("echo in-second-$((1+1))\n")
            try await ui.terminal("b") { $0.buffer.contains("in-second-2") }
            #expect(try await !ui.terminal("a").buffer.contains("in-second-2"))
        }

        // MARK: The shell survives the layout

        /// T-53: splitting a sibling pane leaves an unrelated terminal alone.
        @Test func splittingASiblingKeepsTheTerminal() async throws {
            let ui = UIDriver(layout: Self.besideEmpty())
            let pid = try await ui.shellReady("a")
            try await ui.runAndWait("echo before-sibling-split", in: "a")
            let view = try #require(ui.renderer.body(for: "a")?.content)
            #expect(ui.engine.newPane(like: "b", in: "w", placement: .split(.horizontal)) != nil)
            #expect(try ui.layout.shownContent?.splitNode?.children.count == 3)
            #expect(ui.renderer.body(for: "a")?.content === view)
            let state = try await ui.terminal("a")
            #expect(state["pid"]?.intValue == Int64(pid))
            #expect(state.buffer.contains("before-sibling-split"))
        }

        /// T-56: wrapping a live terminal in a tab group keeps its shell.
        @Test func wrappingInAGroupKeepsTheShell() async throws {
            let ui = UIDriver(layout: Self.besideEmpty())
            let pid = try await ui.shellReady("a")
            try await ui.runAndWait("echo before-wrap", in: "a")
            try ui.choose(.wrapInTabGroup, of: "a")
            #expect(try ui.layout.shownContent?.splitNode?.children.first?.group?.tabs.map(\.content.id) == ["a"])
            let state = try await ui.runAndWait("echo after-wrap", in: "a", mark: 80)
            #expect(state["pid"]?.intValue == Int64(pid))
            #expect(state.buffer.contains("before-wrap"))
        }

        /// T-58: unpinning a terminal into a floating pane and pinning it back keeps its shell.
        @Test func unpinningAndPinningKeepTheShell() async throws {
            let ui = UIDriver(layout: Self.besideEmpty())
            let pid = try await ui.shellReady("a")
            try await ui.runAndWait("echo before-unpin", in: "a")
            let viewport = try #require(ui.renderer.viewport(of: "w"))
            #expect(
                ui.engine.perform(in: "w") { layout, titles in
                    layout.unpinPane("a", rect: FloatRect(x: 100, y: 100, width: 500, height: 300), viewport: viewport, titles: titles)
                })
            let floating = try #require(try ui.layout.floating.first)
            #expect(floating.content.id == "a")
            ui.layoutAll()
            var state = try await ui.runAndWait("echo while-floating", in: "a", mark: 90)
            #expect(state["pid"]?.intValue == Int64(pid))
            #expect(ui.engine.perform(in: "w") { layout, titles in layout.repinPane(floating.id, titles: titles) })
            #expect(try ui.layout.floating.isEmpty)
            state = try await ui.runAndWait("echo pinned-back", in: "a", mark: 100)
            #expect(state["pid"]?.intValue == Int64(pid))
            #expect(state.buffer.contains("before-unpin") && state.buffer.contains("while-floating"))
        }

        /// T-59, T-60: moving a terminal to another window keeps its shell and scrollback, and what it
        /// prints around the move arrives there. (A real cross-window mouse drag can't be synthesized
        /// here; this is the engine's move the drag commits.)
        @Test func movingToAnotherWindowKeepsTheShellAndItsOutput() async throws {
            let ui = UIDriver(layout: Self.besideEmpty())
            let pid = try await ui.shellReady("a")
            try await ui.runAndWait("echo before-move-marker", in: "a")
            let second = ui.engine.openWindow()
            let empty = try #require(ui.engine.model.window(second)?.leaves.first?.id)
            try ui.run("(sleep 1; echo printed-after-the-move) &", in: "a")
            try await Task.sleep(for: .milliseconds(200))
            #expect(ui.engine.move(.pane("a"), from: "w", to: second, at: .emptyPane(empty)))
            ui.layoutAll()
            let view = try #require(ui.renderer.body(for: "a")?.content)
            #expect(view.window === ui.renderer.windowController(second)?.window, "the same terminal, in the other window")
            let state = try await ui.terminal("a") { $0.buffer.contains("printed-after-the-move") }
            #expect(state["pid"]?.intValue == Int64(pid))
            #expect(state.buffer.contains("before-move-marker"))
            #expect(isAlive(pid))
        }

        /// T-65: closing a window (not the last) ends the shells it held.
        @Test func closingAWindowEndsItsShells() async throws {
            let ui = UIDriver(layout: Self.one)
            try await ui.shellReady("a")
            let second = ui.engine.openWindow()
            let pane = try #require(ui.engine.model.window(second)?.leaves.first?.id)
            try ui.create("terminal", in: pane)
            let pid = try await ui.shellReady(pane)
            let window = try #require(ui.renderer.windowController(second)?.window)
            window.performClose(nil)
            ui.settle(0.2)
            #expect(ui.engine.model.window(second) == nil, "the window closed")
            #expect(try await waitGone(pid), "its shell ended")
            #expect(try await ui.terminal("a")["exited"] == false, "the other window's is untouched")
        }

        // MARK: Job control

        /// T-7: the pty is the shell's controlling terminal — ⌃C interrupts the foreground job at
        /// once, and the shell's terminal is its tty (`ps` names it).
        @Test func theShellControlsItsTerminalAndCtrlCInterrupts() async throws {
            let ui = UIDriver(layout: Self.one)
            try await ui.shellReady("a")
            let tty = try await ui.runAndWait("ps -o tty= -p $$", in: "a")
            #expect(tty.buffer.contains("\nttys"), "the shell has a controlling terminal: \(tty.buffer.suffix(300))")

            try ui.run("sleep 30; echo NOT-$((1+1))-INTERRUPTED", in: "a")
            try await Task.sleep(for: .milliseconds(500))
            #expect(try !ui.press(KeyChord("c", [.control])), "⌃C is the shell's, not the app's")
            // The prompt is back at once: what's typed now runs now, not after the sleep.
            try ui.type("echo MARK-$((80+1))\n")
            let state = try await ui.terminal("a", within: 5) { $0.buffer.contains("MARK-81") }
            #expect(!state.buffer.contains("NOT-2-INTERRUPTED"), "the whole command line was interrupted")
        }

        /// T-70: closing a terminal running a command (not an idle prompt) warns, naming the command;
        /// an idle prompt and a background job don't.
        @Test func aRunningCommandMakesClosingWarn() async throws {
            let ui = UIDriver(layout: Self.one)
            try await ui.shellReady("a")
            let controller = try #require(ui.renderer.body(for: "a")?.live?.controller)
            #expect(controller.closeWarning == nil, "an idle prompt")
            try await ui.runAndWait("(sleep 30 &)", in: "a")
            #expect(controller.closeWarning == nil, "a background job")
            try ui.run("sleep 30", in: "a")
            let deadline = Date().addingTimeInterval(5)
            while controller.closeWarning == nil, Date() < deadline { try await Task.sleep(for: .milliseconds(50)) }
            #expect(controller.closeWarning == "sleep is still running")
            try ui.press(KeyChord("c", [.control]))
        }

        // MARK: Hidden

        /// T-21, T-55, T-36, T-37: a terminal behind another tab keeps its output, and its pty isn't
        /// resized while hidden (no SIGWINCH), only once shown again.
        @Test func aHiddenTerminalKeepsOutputAndIsResizedOnlyWhenShown() async throws {
            let ui = UIDriver(layout: Fixture.saved(Fixture.tabsWindow("w", [Fixture.leaf("x", "terminal"), Fixture.leaf("y")])))
            let pid = try await ui.shellReady("x")
            // Every SIGWINCH the shell gets, appended to a file: a prompt redraw can't erase it
            // (zsh redraws its prompt on a resize, clearing up to where it thinks the prompt began).
            let log = FileManager.default.temporaryDirectory.appending(path: "tabs-winch-\(UUID().uuidString).log").path
            defer { try? FileManager.default.removeItem(atPath: log) }
            let winches = {
                (try? String(contentsOfFile: log, encoding: .utf8))?.components(separatedBy: "\n").filter { !$0.isEmpty }.count ?? 0
            }
            try await ui.runAndWait("trap 'echo WINCHED >> \(log)' WINCH", in: "x")
            let before = try await ui.terminal("x")

            // Away and back, no resize: the pty never hears of it.
            try ui.click(tab: "t-y")
            try ui.click(tab: "t-x")
            let back = try await ui.runAndWait(":", in: "x", mark: 30)
            #expect(back["ptyColumns"] == before["ptyColumns"] && back["ptyRows"] == before["ptyRows"])
            #expect(winches() == 0, "no SIGWINCH for switching tabs")

            // Away, the window resized meanwhile: output keeps arriving, the pty keeps its size.
            try ui.run("(sleep 1; echo output-while-away) &", in: "x")
            try ui.click(tab: "t-y")
            #expect(ui.activePane == "y")
            let window = try #require(try ui.window.window)
            let size = try #require(window.contentView?.frame.size)
            window.setContentSize(NSSize(width: size.width - 160, height: size.height))
            ui.settle(0.3)
            let hidden = try await ui.terminal("x") { $0.buffer.contains("output-while-away") }
            #expect(hidden["ptyColumns"] == before["ptyColumns"], "the pty keeps its size while hidden")
            #expect(hidden["columns"] == before["columns"], "and so does the grid, as Electron's unfitted hidden terminal")
            #expect(winches() == 0, "no SIGWINCH while hidden")
            #expect(hidden["pid"]?.intValue == Int64(pid))

            // Back: the pty catches up, once.
            try ui.click(tab: "t-x")
            let shown = try await ui.terminal("x") { $0["ptyColumns"] == $0["columns"] && $0["ptyColumns"] != before["ptyColumns"] }
            #expect(shown["ptyColumns"]?.intValue ?? 0 < before["ptyColumns"]?.intValue ?? 0, "narrower, once shown")
            let stty = try await ui.runAndWait("stty size", in: "x", mark: 50)
            let columns = shown["ptyColumns"]?.intValue ?? 0
            let rows = shown["ptyRows"]?.intValue ?? 0
            #expect(stty.buffer.contains("\n\(rows) \(columns)\n"), "the tty itself has the new size")
            #expect(winches() == 1, "one SIGWINCH, once shown")
        }

        // MARK: Titles

        /// T-40, T-43: OSC 0 sets the pane's title; an empty one gives back "Terminal".
        @Test func anOSCTitleNamesThePaneAndAnEmptyOneClearsIt() async throws {
            let ui = UIDriver(layout: Self.one)
            try await ui.shellReady("a")
            // The sleep holds the title against one the shell's prompt may set when it returns.
            try ui.run("printf '\\033]0;live-title\\007'; sleep 3; echo MARK-$((1+1))", in: "a")
            try await waitTitle(ui, "live-title")
            try await ui.terminal("a") { $0.buffer.contains("MARK-2") }
            try ui.run("printf '\\033]0;\\007'; sleep 3", in: "a")
            try await waitTitle(ui, "Terminal")
        }

        /// T-41, T-42: a title the user set wins over OSC titles; clearing it shows the shell's latest.
        @Test func aManualTitleWinsAndClearingItShowsTheShellsLatest() async throws {
            let ui = UIDriver(layout: Self.one)
            try await ui.shellReady("a")
            #expect(ui.engine.perform(in: "w") { layout, titles in layout.renamePane("a", "My terminal", titles: titles) })
            try ui.run("printf '\\033]0;from-the-shell\\007'; sleep 5", in: "a")
            try await Task.sleep(for: .seconds(1))
            #expect(ui.engine.paneTitle(of: "a") == "My terminal", "the user's title isn't replaced")
            #expect(ui.engine.perform(in: "w") { layout, titles in layout.renamePane("a", nil, titles: titles) })
            #expect(ui.engine.paneTitle(of: "a") == "from-the-shell", "the latest title the shell sent (decided)")
        }

        private func waitTitle(_ ui: UIDriver, _ title: String, sourceLocation: SourceLocation = #_sourceLocation) async throws {
            let deadline = Date().addingTimeInterval(10)
            while ui.engine.paneTitle(of: "a") != title, Date() < deadline { try await Task.sleep(for: .milliseconds(50)) }
            #expect(ui.engine.paneTitle(of: "a") == title, sourceLocation: sourceLocation)
        }

        // MARK: The bell

        /// T-75, T-76, T-78: BEL in a terminal that isn't looked at raises the bell signal; in the
        /// looked-at pane it's dropped; looking at the pane clears it.
        @Test func aBellFlagsATerminalTheUserIsntLookingAt() async throws {
            let ui = UIDriver(layout: Self.besideEmpty())
            ui.renderer.focusOverride = { _ in true }
            try await ui.shellReady("a")

            try await ui.runAndWait("printf '\\a'", in: "a")
            try await Task.sleep(for: .milliseconds(300))
            #expect(ui.runtime.signals.raised(on: "a").isEmpty, "the pane being typed in: dropped")

            try ui.run("sleep 1; printf '\\a'", in: "a")
            try ui.click(body: "b")
            #expect(ui.activePane == "b")
            let deadline = Date().addingTimeInterval(5)
            while ui.runtime.signals.raised(on: "a").isEmpty, Date() < deadline { try await Task.sleep(for: .milliseconds(50)) }
            #expect(ui.runtime.signals.raised(on: "a").map(\.id) == ["terminal.bell"])
            ui.layoutAll()
            #expect(try ui.headerSignals("a") == ["terminal.bell"])
            #expect(try ui.tabView("t-w").signalIcons.compactMap(\.kindID) == ["terminal.bell"], "the tab holding it shows it")

            try ui.click(try ui.body("a"))
            #expect(ui.runtime.signals.raised(on: "a").isEmpty, "looking at it cleared it")
        }

        // MARK: Settings

        /// T-39, T-114: Settings ▸ Terminal renders, and its font size applies to an open terminal at
        /// once — a bigger font, fewer columns and rows, for the grid and the pty.
        @Test func theSettingsPageRendersAndAFontSizeChangeAppliesLive() async throws {
            let ui = UIDriver(layout: Self.one)
            try await ui.shellReady("a")
            let before = try await ui.terminal("a")

            let page = try #require(
                ui.runtime.registry.contributions(to: .settingsPages).first { $0.value.id == "terminal" }, "a Terminal settings page")
            let view = page.value.makeView()
            let host = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 520, height: 900), styleMask: [.titled], backing: .buffered, defer: true)
            host.isReleasedWhenClosed = false
            defer { host.close() }
            host.contentView = view
            view.frame = NSRect(x: 0, y: 0, width: 520, height: 900)
            view.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(200))
            view.layoutSubtreeIfNeeded()
            let steppers = view.allSubviews.compactMap { $0 as? NSStepper }
            #expect(steppers.count >= 2, "scrollback, font size, line height: \(steppers.count)")
            // SwiftUI's steppers are relative (−2…2 around 0): scrollback, font size, line height, in order.
            #expect(steppers.count == 3, "scrollback, font size, line height")
            let fontSize = try #require(steppers.count > 1 ? steppers[1] : nil, "the font size stepper")
            for _ in 0..<5 {
                fontSize.doubleValue = fontSize.increment
                fontSize.sendAction(fontSize.action, to: fontSize.target)
                try await Task.sleep(for: .milliseconds(50))
            }
            ui.layoutAll()
            let after = try await ui.terminal("a") {
                ($0["columns"]?.intValue ?? 0) < (before["columns"]?.intValue ?? 0) && $0["ptyColumns"] == $0["columns"]
            }
            #expect((after["rows"]?.intValue ?? 0) < (before["rows"]?.intValue ?? 0))
        }
    }
}

extension NSView {
    /// Every descendant, depth first.
    var allSubviews: [NSView] { subviews.flatMap { [$0] + $0.allSubviews } }
}
