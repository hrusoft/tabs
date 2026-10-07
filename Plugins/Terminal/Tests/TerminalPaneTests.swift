import AppKit
import Darwin
import TabsPluginSDK
import Testing

@testable import TabsCore

/// Terminal panes in a real core runtime with the layout engine: real login
/// shells (`$SHELL -l`, on the tests' own startup files: `TestShell`), so a
/// test waits for output it computed itself (`echo X-$((1+1))` → `X-2`),
/// never for a prompt. Case ids are docs/TERMINAL.md's.
@MainActor
@Suite struct TerminalPaneTests {
    let bed: TerminalTestBed

    init() throws {
        bed = try TerminalTestBed()
    }

    private func buffer(_ pane: TerminalPane) -> String { pane.surfaceForTests.bufferText }

    /// Opens a terminal and waits for its shell to answer.
    private func openReady(
        config: JSONValue? = nil, placement: PanePlacement = .automatic, origin: PaneID? = nil,
        sourceLocation: SourceLocation = #_sourceLocation
    ) async throws -> (id: PaneID, pane: TerminalPane) {
        let terminal = try #require(bed.openTerminal(config: config, placement: placement, origin: origin), sourceLocation: sourceLocation)
        #expect(await bed.started(terminal.pane, sourceLocation: sourceLocation), sourceLocation: sourceLocation)
        #expect(
            await bed.run("echo UP-$((40+2))", in: terminal.pane, until: "UP-42", sourceLocation: sourceLocation),
            "\(buffer(terminal.pane))",
            sourceLocation: sourceLocation)
        return terminal
    }

    /// T-1, T-5, T-6, T-11: a real login shell — its startup files run, the
    /// login one and the interactive one — with the user's HOME, the
    /// terminal's identity, and the pane's id for programs inside.
    @Test func runsALoginShellThatKnowsItsTerminalAndPane() async throws {
        let terminal = try await openReady()
        let pid = try #require(terminal.pane.process?.pid)
        #expect(pid > 0)
        #expect(
            await bed.run("echo \"files:$TABS_TEST_ZPROFILE:$TABS_TEST_ZSHRC:$((1))\"", in: terminal.pane, until: "files:1:1:1"),
            "\(buffer(terminal.pane).suffix(400))")
        #expect(await bed.run("echo \"home:$HOME:$((1))\"", in: terminal.pane, until: "home:\(NSHomeDirectory()):1"))
        #expect(
            await bed.run(
                "echo \"colour:$TERM:$COLORTERM:$TERM_PROGRAM:$TABS_PANE_ID\"", in: terminal.pane,
                until: "colour:xterm-256color:truecolor:Tabs:\(terminal.id)"), "\(buffer(terminal.pane).suffix(400))")
        #expect(terminal.pane.testState["pid"] == .int(Int64(pid)))
        await bed.end(terminal)
    }

    /// T-9: the shell exiting prints `[process exited]` and keeps the pane
    /// (and its output); typing afterwards goes nowhere.
    @Test func anExitedShellKeepsItsPane() async throws {
        let terminal = try await openReady()
        bed.type("echo BYE-$((6*7)); exit\r", into: terminal.pane)
        #expect(await eventually { terminal.pane.hasExited })
        #expect(await eventually { buffer(terminal.pane).contains("[process exited]") })
        #expect(buffer(terminal.pane).contains("BYE-42"))
        #expect(bed.harness.engine.model.leaf(terminal.id) != nil, "the pane stays")
        bed.type("echo nobody\r", into: terminal.pane)
        #expect(terminal.pane.closeWarning == nil)
        #expect(bed.harness.runtime.panes.capability(.workingDirectory, of: terminal.id) == nil, "nothing to inherit from it")
        await bed.end(terminal)
    }

    /// T-21, T-55: output that arrives while the pane is hidden is kept.
    @Test func outputWhileHiddenIsKept() async throws {
        let terminal = try await openReady()
        bed.type("(sleep 0.05; echo AWAY-$((2+3))) &\r", into: terminal.pane)
        // Hidden as core hides a background tab: told so, its view hidden.
        terminal.pane.paneDidHide()
        terminal.pane.view.isHidden = true
        #expect(await eventually { buffer(terminal.pane).contains("AWAY-5") })
        terminal.pane.view.isHidden = false
        terminal.pane.paneDidShow()
        await bed.end(terminal)
    }

    /// T-35, T-36, T-37: the pty follows the view's size while the pane is
    /// shown; hidden, it keeps its size (no SIGWINCH), and catches up when
    /// shown again — checked by the shell itself (`stty size`).
    @Test func aHiddenPaneNeverResizesThePtyButCatchesUpWhenShown() async throws {
        let terminal = try await openReady()
        let surface = terminal.pane.surfaceForTests
        terminal.pane.paneDidShow()
        let body = NSView(frame: CGRect(x: 0, y: 0, width: 900, height: 500))
        terminal.pane.view.frame = body.bounds
        terminal.pane.view.autoresizingMask = [.width, .height]
        body.addSubview(terminal.pane.view)
        terminal.pane.view.layoutSubtreeIfNeeded()
        let shown = (rows: surface.rows, columns: surface.columns)
        #expect(await bed.run("echo \"S$((1)):$(stty size)\"", in: terminal.pane, until: "S1:\(shown.rows) \(shown.columns)"))

        terminal.pane.paneDidHide()
        body.setFrameSize(NSSize(width: 450, height: 250))
        #expect(surface.columns == shown.columns && surface.rows == shown.rows, "hidden, the grid keeps its size too")
        // No wait needed: a resize would reach the pty before the next command
        // (both go through the shell's one serial I/O queue, in order).
        #expect(
            await bed.run("echo \"S$((2)):$(stty size)\"", in: terminal.pane, until: "S2:\(shown.rows) \(shown.columns)"),
            "\(buffer(terminal.pane).suffix(300))")

        terminal.pane.paneDidShow()
        let caughtUp = (rows: surface.rows, columns: surface.columns)
        #expect(caughtUp.columns < shown.columns, "shown, the grid takes the view's size")
        #expect(
            await bed.run("echo \"S$((3)):$(stty size)\"", in: terminal.pane, until: "S3:\(caughtUp.rows) \(caughtUp.columns)"),
            "\(buffer(terminal.pane).suffix(300))")
        await bed.end(terminal)
    }

    /// T-40, T-43: OSC 0/2 titles the pane; an empty one gives it back its
    /// type's name.
    @Test func oscTitlesTitleThePane() async throws {
        let terminal = try #require(bed.openTerminal())
        let live = try #require(bed.harness.runtime.panes.pane(terminal.id))
        terminal.pane.surfaceForTests.feed(Array("\u{1b}]0;live-title\u{07}".utf8))
        #expect(live.title == "live-title")
        #expect(bed.harness.engine.paneTitle(of: terminal.id) == "live-title")
        terminal.pane.surfaceForTests.feed(Array("\u{1b}]2;window-title\u{1b}\\".utf8))
        #expect(live.title == "window-title")
        terminal.pane.surfaceForTests.feed(Array("\u{1b}]0;\u{07}".utf8))
        #expect(live.title == "Terminal")
        await bed.end(terminal)
    }

    /// T-40 through a real shell (a trailing sleep holds the title against a
    /// prompt theme that sets its own).
    @Test func aShellsOscTitleReachesThePane() async throws {
        let terminal = try await openReady()
        let live = try #require(bed.harness.runtime.panes.pane(terminal.id))
        bed.type("printf '\\033]0;from-the-shell\\007'; sleep 3\r", into: terminal.pane)
        #expect(await eventually { live.title == "from-the-shell" }, "\(live.title)")
        terminal.pane.surfaceSend([0x03])
        await bed.end(terminal)
    }

    /// T-41, T-42: a manual title wins over OSC titles; cleared, the pane
    /// shows the shell's latest title.
    @Test func aManualTitleWinsAndClearingItShowsTheLatestOscTitle() async throws {
        let terminal = try #require(bed.openTerminal())
        let window = try #require(bed.harness.engine.model.window(holding: terminal.id)?.id)
        bed.harness.engine.perform(in: window) { layout, titles in layout.renamePane(terminal.id, "My terminal", titles: titles) }
        terminal.pane.surfaceForTests.feed(Array("\u{1b}]0;from-the-shell\u{07}".utf8))
        #expect(bed.harness.engine.paneTitle(of: terminal.id) == "My terminal")
        bed.harness.engine.perform(in: window) { layout, titles in layout.renamePane(terminal.id, nil, titles: titles) }
        #expect(bed.harness.engine.paneTitle(of: terminal.id) == "from-the-shell")
        await bed.end(terminal)
    }

    private func signals(on pane: PaneID) -> [String] { bed.harness.runtime.signals.raised(on: pane).map(\.id) }

    /// T-75, T-79: a BEL in a pane the user isn't looking at raises the bell
    /// (and bounces the Dock), without a sound.
    @Test func aBellRaisesTheBellSignalWhenUnseen() async throws {
        let terminal = try #require(bed.openTerminal())
        terminal.pane.surfaceForTests.feed([0x07])
        #expect(signals(on: terminal.id) == ["terminal.bell"])
        #expect(bed.harness.renderer.attentionRequests == 1)
        await bed.end(terminal)
    }

    /// T-76: a bell in the pane being looked at (active, window focused) is dropped.
    @Test func aBellInThePaneBeingLookedAtIsDropped() async throws {
        let terminal = try #require(bed.openTerminal())
        let window = try #require(bed.harness.engine.model.window(holding: terminal.id))
        #expect(window.activePaneID == terminal.id)
        bed.harness.renderer.focusedWindows = [window.id]
        terminal.pane.surfaceForTests.feed([0x07])
        #expect(signals(on: terminal.id).isEmpty)
        await bed.end(terminal)
    }

    /// T-75 through a real shell: `printf '\a'`.
    @Test func aShellsBellReachesThePane() async throws {
        let terminal = try await openReady()
        bed.type("printf '\\a'\r", into: terminal.pane)
        #expect(await eventually { signals(on: terminal.id) == ["terminal.bell"] })
        await bed.end(terminal)
    }

    /// Fills the terminal with more than a screenful: real scrollback.
    private func fill(_ pane: TerminalPane, lines: Int = 200) {
        pane.surfaceForTests.feed(Array((1...lines).map { "filler-\($0)\r\n" }.joined().utf8))
    }

    /// T-95, T-125: Clear Buffer (⌘K) clears the screen and the scrollback,
    /// leaving the cursor's line as the first.
    @Test func clearBufferClearsScreenAndScrollback() async throws {
        let terminal = try #require(bed.openTerminal())
        fill(terminal.pane)
        terminal.pane.surfaceForTests.feed(Array("prompt-line".utf8))
        #expect(buffer(terminal.pane).contains("filler-1\n"))
        #expect(bed.harness.perform("terminal.clearBuffer"))
        #expect(!buffer(terminal.pane).contains("filler-"), "\(buffer(terminal.pane).prefix(200))")
        #expect(terminal.pane.surfaceForTests.screenText.hasPrefix("prompt-line"))
        await bed.end(terminal)
    }

    /// T-96: …but not while a full-screen program owns the alternate screen.
    @Test func clearBufferLeavesTheAlternateScreenAlone() async throws {
        let terminal = try #require(bed.openTerminal())
        let surface = terminal.pane.surfaceForTests
        surface.feed(Array("\u{1b}[?1049halt-screen-content".utf8))
        #expect(surface.isAlternateScreen)
        #expect(!terminal.pane.clear())
        #expect(bed.harness.perform("terminal.clearBuffer"), "enabled on a terminal; it declines itself")
        #expect(surface.screenText.contains("alt-screen-content"))
        surface.feed(Array("\u{1b}[?1049l".utf8))
        #expect(!surface.isAlternateScreen)
        await bed.end(terminal)
    }

    /// T-98: the header's Clear scrollback does what ⌘K does, alternate
    /// screen rule included.
    @Test func theHeaderActionClearsLikeTheCommand() async throws {
        let terminal = try #require(bed.openTerminal())
        let action = try #require(terminal.pane.headerActions.first)
        fill(terminal.pane)
        action.perform()
        #expect(!buffer(terminal.pane).contains("filler-"))
        terminal.pane.surfaceForTests.feed(Array("\u{1b}[?1049halt-content".utf8))
        action.perform()
        #expect(terminal.pane.surfaceForTests.screenText.contains("alt-content"))
        await bed.end(terminal)
    }

    /// T-95 through a real shell: after ⌘K the old output is gone and the
    /// shell keeps working.
    @Test func clearingALiveShellKeepsItWorking() async throws {
        let terminal = try await openReady()
        #expect(await bed.run("for i in $(seq 1 120); do echo filler-$i; done; echo FILLED-$((1+1))", in: terminal.pane, until: "FILLED-2"))
        #expect(terminal.pane.clear())
        #expect(!buffer(terminal.pane).contains("filler-"))
        #expect(await bed.run("echo AFTER-$((1+1))", in: terminal.pane, until: "AFTER-2"))
        await bed.end(terminal)
    }

    /// T-112: scrollback applies live, 0 keeping none.
    @Test func scrollbackAppliesLiveDownToNone() async throws {
        let terminal = try #require(bed.openTerminal())
        fill(terminal.pane, lines: 300)
        #expect(buffer(terminal.pane).contains("filler-1\n"))
        bed.settings.update { $0.scrollback = 0 }
        let rows = terminal.pane.surfaceForTests.rows
        let lines = buffer(terminal.pane).split(separator: "\n", omittingEmptySubsequences: false).count
        #expect(lines <= rows + 1, "\(lines) lines for \(rows) rows")
        #expect(!buffer(terminal.pane).contains("filler-1\n"))
        bed.settings.update { $0.scrollback = 1000 }
        fill(terminal.pane, lines: 300)
        #expect(buffer(terminal.pane).contains("filler-1\n"), "history is kept again")
        await bed.end(terminal)
    }

    /// T-112: a scrollback past the most a pane keeps (a typo, a hand-edited
    /// file) is taken as the most: SwiftTerm reserves the whole ring at once,
    /// so a billion lines would take gigabytes in every pane, at every launch.
    @Test func aHugeScrollbackIsCapped() async throws {
        #expect(TerminalSettings.scrollbackLines(1_000_000_000) == TerminalSettings.maxScrollback)
        #expect(TerminalSettings.scrollbackLines(-5) == 0)
        #expect(TerminalSettings.scrollbackLines(2500) == 2500)
        // What SwiftTerm sizes its ring from: the pane's own, not the process's
        // memory (other tests may be allocating at the same time).
        func reserved(_ pane: TerminalPane) throws -> Int {
            try #require(pane.view as? TerminalContainerView).terminal.getTerminal().options.scrollback
        }
        let open = try #require(bed.openTerminal())
        #expect(try reserved(open.pane) == 1000)
        bed.settings.update { $0.scrollback = 1_000_000_000 }
        #expect(try reserved(open.pane) == TerminalSettings.maxScrollback, "live, an open pane takes the cap, not a billion lines")
        let made = try #require(bed.openTerminal(placement: .tab(near: open.id)))
        #expect(try reserved(made.pane) == TerminalSettings.maxScrollback, "and so does a new one")
        fill(made.pane, lines: 300)
        #expect(buffer(made.pane).contains("filler-1\n"), "history is kept, up to the cap")
        await bed.end(made)
        await bed.end(open)
    }

    /// T-114–T-118: appearance changes reach open panes.
    @Test func appearanceAppliesLive() async throws {
        let terminal = try #require(bed.openTerminal())
        let view = try #require(terminal.pane.view as? TerminalContainerView)
        bed.settings.update {
            $0.appearance.background = "#102030"
            $0.appearance.fontSize = 20
        }
        #expect(view.background.hexString == "#102030")
        #expect(view.terminal.nativeBackgroundColor.hexString == "#102030")
        #expect(view.terminal.font.pointSize == 20)
        bed.settings.update { $0.appearance.cursorStyle = .block }
        await bed.end(terminal)
    }

    /// T-100, T-106: a new terminal made from a terminal starts in its live
    /// directory, and the saved config is the live directory.
    @Test func aNewTerminalFromATerminalStartsInItsLiveDirectory() async throws {
        let directory = makeTemporaryDirectory()
        let origin = try await openReady()
        #expect(await bed.run("cd \(directory) && echo CD-$((1+1))", in: origin.pane, until: "CD-2"))
        #expect(await eventually { origin.pane.liveDirectory == directory })
        #expect(await eventually { bed.harness.config(of: origin.id) == ["cwd": .string(directory)] })

        let made = try await openReady(placement: .tab(near: origin.id), origin: origin.id)
        #expect(made.pane.startDirectory == directory)
        #expect(await eventually { made.pane.liveDirectory == directory })
        await bed.end(made)
        await bed.end(origin)
    }

    /// T-101: with inheritance off, it starts at home.
    @Test func withInheritanceOffANewTerminalStartsAtHome() async throws {
        let directory = makeTemporaryDirectory()
        bed.settings.update { $0.inheritCwdOnNewPane = false }
        let origin = try await openReady()
        #expect(await bed.run("cd \(directory) && echo CD-$((1+1))", in: origin.pane, until: "CD-2"))
        #expect(await eventually { origin.pane.liveDirectory == directory })
        let made = try #require(bed.openTerminal(placement: .tab(near: origin.id), origin: origin.id))
        #expect(made.pane.startDirectory == NSHomeDirectory())
        await bed.end(made)
        await bed.end(origin)
    }

    /// T-103: a terminal offers its live directory to other panes, whatever
    /// its own inheritance setting says.
    @Test func aTerminalOffersItsLiveDirectoryEvenWithInheritanceOff() async throws {
        let directory = makeTemporaryDirectory()
        bed.settings.update { $0.inheritCwdOnNewPane = false }
        let terminal = try await openReady()
        #expect(await bed.run("cd \(directory) && echo CD-$((1+1))", in: terminal.pane, until: "CD-2"))
        #expect(
            await eventually {
                bed.harness.runtime.panes.capability(.workingDirectory, of: terminal.id)?.path == directory
            })
        await bed.end(terminal)
    }

    /// T-104: an origin whose shell has exited offers nothing: home.
    @Test func anExitedOriginGivesHome() async throws {
        let directory = makeTemporaryDirectory()
        let origin = try await openReady(config: ["cwd": .string(directory)])
        bed.type("exit\r", into: origin.pane)
        #expect(await eventually { origin.pane.hasExited })
        let made = try #require(bed.openTerminal(placement: .tab(near: origin.id), origin: origin.id))
        #expect(made.pane.startDirectory == NSHomeDirectory())
        await bed.end(made)
        await bed.end(origin)
    }

    /// T-108, T-109: an unreadable saved config is refused (the pane isn't
    /// made, a restored one stays unavailable with its leaf kept), never
    /// replaced by a fresh terminal's.
    @Test func anUnreadableConfigIsRefused() throws {
        #expect(bed.openTerminal(config: ["cwd": 3]) == nil)
        let window = try #require(bed.harness.engine.model.windows.first?.id)
        let restored = bed.harness.runtime.panes.restore(LayoutLeaf(type: "terminal", config: ["cwd": 3]), in: window)
        guard case .unavailable(let reason) = restored else {
            Issue.record("expected unavailable, got \(restored)")
            return
        }
        #expect(reason.contains("Terminal"))
    }

    /// T-3: a saved directory that's gone starts the shell at home.
    @Test func aDeletedSavedDirectoryStartsAtHome() async throws {
        let terminal = try #require(bed.openTerminal(config: ["cwd": "/no/such/directory/anymore"]))
        #expect(terminal.pane.startDirectory == NSHomeDirectory())
        #expect(await bed.started(terminal.pane))
        #expect(!terminal.pane.hasExited)
        await bed.end(terminal)
    }

    /// T-10, T-62: closing the pane ends its shell.
    @Test func closingThePaneEndsItsShell() async throws {
        let terminal = try await openReady()
        let pid = try #require(terminal.pane.process?.pid)
        bed.harness.engine.close(terminal.id)
        #expect(bed.harness.renderer.asked.isEmpty, "an idle prompt doesn't ask")
        #expect(await eventually { !isAlive(pid) })
    }

    /// T-70: closing a pane whose shell runs a command asks first, naming it;
    /// an idle prompt never asks.
    @Test func aRunningCommandWarnsBeforeClosing() async throws {
        let terminal = try await openReady()
        #expect(terminal.pane.closeWarning == nil)
        bed.type("sleep 30\r", into: terminal.pane)
        // Named once it has exec'd: from the fork until then, the group holding the terminal is a zsh.
        #expect(await eventually { terminal.pane.closeWarning == "sleep is still running" }, "\(terminal.pane.closeWarning ?? "nil")")
        bed.harness.renderer.answers = [false]
        bed.harness.engine.close(terminal.id)
        #expect(bed.harness.renderer.asked == [["sleep is still running"]])
        #expect(bed.harness.engine.model.leaf(terminal.id) != nil, "Cancel keeps it")
        terminal.pane.surfaceSend([0x03])
        #expect(await eventually { terminal.pane.closeWarning == nil })
        await bed.end(terminal)
    }
}

/// T-102, T-104: a terminal made from another type's pane starts in the
/// directory that pane offers, and from one that offers none, at home.
@MainActor
@Suite struct TerminalInheritanceFromOtherTypesTests {
    let directory: String
    let bed: TerminalTestBed

    init() throws {
        let directory = makeTemporaryDirectory()
        self.directory = directory
        let standIn = TestSupport.candidate(TestSupport.manifest("stand-in", contentTypes: ["stand-in", "stand-in.plain"])) { context in
            context.register(
                ContentTypeContribution(id: "stand-in", displayName: "Stand-in", icon: .symbol("square")) { pane in
                    pane.offer(.workingDirectory, URL(filePath: directory, directoryHint: .isDirectory))
                    return StubPane(config: pane.initialConfig)
                })
            context.register(TestSupport.contentType("stand-in.plain"))
        }
        bed = try TerminalTestBed(alongside: [standIn])
    }

    @Test func startsWhereAnotherTypesPaneOffers() async throws {
        let origin = try #require(bed.harness.runtime.panes.openPane(PaneRequest(type: "stand-in")))
        let made = try #require(bed.openTerminal(placement: .tab(near: origin), origin: origin))
        #expect(made.pane.startDirectory == directory)
        #expect(await eventually { made.pane.liveDirectory == directory })
        await bed.end(made)
    }

    @Test func anOriginThatOffersNothingGivesHome() async throws {
        let origin = try #require(bed.harness.runtime.panes.openPane(PaneRequest(type: "stand-in.plain")))
        let made = try #require(bed.openTerminal(placement: .tab(near: origin), origin: origin))
        #expect(made.pane.startDirectory == NSHomeDirectory())
        await bed.end(made)
    }

    /// T-97: ⌘K with another type's pane active does nothing to a terminal.
    @Test func clearBufferIsForTheActiveTerminalOnly() async throws {
        let terminal = try #require(bed.openTerminal())
        terminal.pane.surfaceForTests.feed(Array("keep-me\r\n".utf8))
        let other = try #require(
            bed.harness.runtime.panes.openPane(PaneRequest(type: "stand-in.plain", placement: .tab(near: terminal.id))))
        #expect(bed.harness.engine.activePaneID == other)
        #expect(!bed.harness.isEnabled("terminal.clearBuffer"))
        #expect(!bed.harness.perform("terminal.clearBuffer"))
        #expect(terminal.pane.surfaceForTests.bufferText.contains("keep-me"))
        await bed.end(terminal)
    }
}
