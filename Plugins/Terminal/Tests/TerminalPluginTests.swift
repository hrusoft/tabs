import AppKit
import Darwin
import TabsPluginSDK
import Testing

@testable import TabsCore

/// The terminal plugin against the real core runtime, without the app
/// (docs/PLUGINS.md, Testing): what it contributes, and how its pane's view
/// follows the size core gives it. Case ids are docs/TERMINAL.md's.
@MainActor
@Suite struct TerminalPluginTests {
    let bed: TerminalTestBed

    init() throws {
        bed = try TerminalTestBed()
    }

    @Test func activatesAsItsManifestDeclares() {
        #expect(bed.harness.record?.state == .active)
        #expect(bed.harness.manifest.contentTypes == ["terminal"])
        #expect(bed.harness.manifest.displayName == "Terminal")
    }

    /// T-4: a new pane with no origin is seeded to start at home
    /// (`{cwd: "~"}`).
    @Test func aNewPaneIsSeededToStartAtHome() async throws {
        let terminal = try #require(bed.openTerminal())
        #expect(terminal.pane.startDirectory == NSHomeDirectory())
        let contribution = try #require(bed.harness.runtime.registry.contribution(to: .contentTypes, id: "terminal"))
        #expect(contribution.value.initialConfig(PaneCreation(origin: nil)) == ["cwd": "~"])
        #expect(contribution.value.displayName == "Terminal")
        guard case .image(let icon) = contribution.value.icon else { Issue.record("the icon isn't an image"); return }
        #expect(icon.isTemplate && icon.size == NSSize(width: 16, height: 16))
        #expect(contribution.value.resolvedCreationLabel == "New terminal")
        await bed.end(terminal)
    }

    /// T-75, T-79, T-80: the bell is a pane signal — the alert color, pulsing,
    /// on tabs, until seen, asking for attention — with a switch of its own
    /// in Settings ▸ Panes & Tabs.
    @Test func theBellIsAPulsingAlertSignalUntilSeen() throws {
        let kind = try #require(bed.harness.runtime.signals.kinds.first { $0.id == "terminal.bell" })
        #expect(kind.owner == "terminal")
        #expect(kind.value.color == .alert)
        #expect(kind.value.pulse == 3)
        #expect(kind.value.marksTabs)
        #expect(kind.value.lifetime == .untilSeen)
        #expect(kind.value.requestsAttention)
        #expect(kind.value.label == "Bell")
        #expect(bed.harness.runtime.signals.settingKinds.map(\.value.setting.title).contains("Bell indicator"))
    }

    /// T-125: Edit ▸ Clear Buffer, ⌘K, for terminals only.
    @Test func clearBufferIsAnEditCommandOnCommandKForTerminalsOnly() throws {
        let command = try #require(bed.harness.runtime.commands.command("terminal.clearBuffer"))
        #expect(command.value.title == "Clear Buffer")
        #expect(command.value.menu == .edit)
        #expect(command.value.defaultChord == KeyChord("k", [.command]))
        #expect(command.value.appliesTo == "terminal")
    }

    /// T-113–T-119: Settings ▸ Terminal exists.
    @Test func contributesASettingsPage() throws {
        let page = try #require(bed.harness.runtime.registry.contribution(to: .settingsPages, id: "terminal"))
        #expect(page.value.title == "Terminal")
    }

    /// T-98: the header's Clear scrollback action, drawn by core.
    @Test func offersTheClearScrollbackHeaderAction() async throws {
        let terminal = try #require(bed.openTerminal())
        let action = try #require(terminal.pane.headerActions.first)
        #expect(terminal.pane.headerActions.count == 1)
        #expect(action.id == "pane-terminal-clear-scrollback-button")
        #expect(action.label == "Clear scrollback")
        await bed.end(terminal)
    }

    /// T-35: the terminal follows the size core gives its pane — through
    /// autoresizing (a split, a window resize), as the pane body resizes it —
    /// and, while shown, so does the pty.
    @Test func theTerminalFollowsItsPanesSizeThroughAutoresizing() async throws {
        let terminal = try #require(bed.openTerminal())
        #expect(await bed.started(terminal.pane))
        terminal.pane.paneDidShow()
        // As `PaneBodyHost` holds a plugin's view.
        let body = NSView(frame: CGRect(x: 0, y: 0, width: 800, height: 400))
        let view = terminal.pane.view
        view.frame = body.bounds
        view.autoresizingMask = [.width, .height]
        body.addSubview(view)
        view.layoutSubtreeIfNeeded()
        let surface = terminal.pane.surfaceForTests
        let wide = (surface.columns, surface.rows)
        #expect(wide.0 > 40 && wide.1 > 10, "\(wide)")

        body.setFrameSize(NSSize(width: 400, height: 200))
        #expect(surface.columns < wide.0 && surface.rows < wide.1, "\((surface.columns, surface.rows)) vs \(wide)")
        let narrow = (surface.columns, surface.rows)
        #expect(await eventually { terminal.pane.testState["ptyColumns"] == .int(Int64(narrow.0)) })
        #expect(terminal.pane.testState["ptyRows"] == .int(Int64(narrow.1)))

        // The padding: 8 left, 4 top, the rest the terminal's.
        let inner = try #require(view.subviews.first)
        #expect(inner.frame.minX == 8)
        #expect(inner.frame.width == view.bounds.width - 8)
        #expect(inner.frame.height == view.bounds.height - 4)
        await bed.end(terminal)
    }

    /// T-68: quitting (the plugin deactivating) ends every shell.
    @Test func deactivatingEndsEveryShell() async throws {
        let first = try #require(bed.openTerminal())
        let second = try #require(bed.openTerminal(placement: .tab(near: first.id)))
        #expect(await bed.started(first.pane))
        #expect(await bed.started(second.pane))
        let pids = [first.pane.process?.pid, second.pane.process?.pid].compactMap { $0 }
        #expect(pids.count == 2)
        bed.harness.runtime.host.stop()
        #expect(await eventually { pids.allSatisfy { !isAlive($0) } }, "\(pids)")
    }
}

// MARK: - Shared test support

/// A terminal plugin in a harness, with its instance at hand (its live
/// settings, its own panes). Its shells start on the tests' own startup
/// files (`TestShell`), not the user's.
@MainActor
final class TerminalTestBed {
    let harness: PluginHarness
    let plugin: TerminalPlugin

    init(alongside: [PluginCandidate] = [], testFile: String = #filePath) throws {
        let made = Box<TerminalPlugin?>(nil)
        harness = try PluginHarness(alongside: alongside, testFile: testFile) {
            let plugin = TerminalPlugin()
            made.value = plugin
            return plugin
        }
        guard let plugin = made.value else { throw TestFailure("the plugin wasn't made") }
        self.plugin = plugin
        harness.runtime.panes.baseEnvironment.merge(TestShell.environment) { $1 }
    }

    var settings: PluginSettings<TerminalSettings> { plugin.settings! }

    /// Opens a terminal (as `openPane` does) and returns it with its controller.
    func openTerminal(config: JSONValue? = nil, placement: PanePlacement = .automatic, origin: PaneID? = nil) -> (
        id: PaneID, pane: TerminalPane
    )? {
        guard let id = harness.runtime.panes.openPane(PaneRequest(type: "terminal", config: config, placement: placement, origin: origin)),
            let pane = harness.controller(of: id, as: TerminalPane.self)
        else { return nil }
        return (id, pane)
    }

    /// Waits for the pane's shell to have started.
    func started(_ pane: TerminalPane, sourceLocation: SourceLocation = #_sourceLocation) async -> Bool {
        await eventually(sourceLocation: sourceLocation) { pane.process != nil || pane.hasExited }
    }

    /// Types `text` into the pane, as keys would (`\r` is Return).
    func type(_ text: String, into pane: TerminalPane) {
        pane.surfaceSend(ArraySlice(Array(text.utf8)))
    }

    /// Runs `command` in the pane's shell and waits for `marker` in its output.
    /// The command line itself must not contain the marker verbatim (compute
    /// it: `echo DONE-$((1+1))` waits for `DONE-2`).
    func run(_ command: String, in pane: TerminalPane, until marker: String, sourceLocation: SourceLocation = #_sourceLocation) async
        -> Bool
    {
        type(command + "\r", into: pane)
        return await eventually(sourceLocation: sourceLocation) { pane.surfaceForTests.bufferText.contains(marker) }
    }

    /// Closes the pane (and so its shell) and waits for the shell to be gone.
    func end(_ terminal: (id: PaneID, pane: TerminalPane), sourceLocation: SourceLocation = #_sourceLocation) async {
        let pid = terminal.pane.process?.pid
        harness.engine.close(terminal.id)
        if let pid { _ = await eventually(sourceLocation: sourceLocation) { !isAlive(pid) } }
    }
}

@MainActor
final class Box<Value> {
    var value: Value
    init(_ value: Value) { self.value = value }
}

struct TestFailure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

/// Polls `condition` until it holds or `timeout` passes (generous: it returns
/// as soon as it holds). A wait that held only after more than `slowWait` is
/// recorded as a warning, which fails nothing: a stalled shell or a starved
/// main actor shows up long before it costs a timeout.
@MainActor
func eventually(timeout: Duration = .seconds(10), sourceLocation: SourceLocation = #_sourceLocation, _ condition: () -> Bool) async -> Bool
{
    let clock = ContinuousClock()
    let start = clock.now
    var held = condition()
    while !held, clock.now < start + timeout {
        try? await Task.sleep(for: .milliseconds(20))
        held = condition()
    }
    let waited = start.duration(to: clock.now)
    if held, waited > slowWait {
        Issue.record("slow: held after \(seconds(waited)) of its \(seconds(timeout))", severity: .warning, sourceLocation: sourceLocation)
    }
    return held
}

/// How long a wait may take before it's reported as slow.
let slowWait: Duration = .seconds(3)

/// A duration as `1.2 s`.
func seconds(_ duration: Duration) -> String {
    let (whole, fraction) = duration.components
    return String(format: "%.1f s", Double(whole) + Double(fraction) / 1e18)
}

/// Whether a process exists (a zombie counts until reaped).
func isAlive(_ pid: pid_t) -> Bool {
    kill(pid, 0) == 0 || errno == EPERM
}

/// A temporary directory, symlinks resolved as the kernel reports a cwd
/// (`/private/var/…`; Foundation's `resolvingSymlinksInPath` strips `/private`).
func makeTemporaryDirectory() -> String {
    let url = TestTemporary.directory("terminal")
    guard let resolved = realpath(url.path, nil) else { return url.path }
    defer { free(resolved) }
    return String(cString: resolved)
}

/// Lines of pty output (`\r\n`, which Swift reads as one character).
func outputLines(_ text: String) -> [String] {
    text.replacingOccurrences(of: "\r", with: "").components(separatedBy: "\n")
}
