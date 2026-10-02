import AppKit
import Foundation
import TabsPluginSDK
import Testing

@testable import TabsCore

/// One plugin — the real class, compiled into its own test bundle — running
/// in a real core runtime with a layout engine and a fake renderer: no app,
/// no windows, no other plugin unless the test adds one. What a plugin's unit
/// tests (Plugins/<Name>/Tests) drive.
///
/// ```swift
/// let harness = try PluginHarness { TerminalPlugin() }
/// let pane = try #require(harness.open("terminal"))
/// ```
@MainActor
final class PluginHarness {
    let runtime: CoreRuntime
    let engine: LayoutEngine
    let renderer = FakeRenderer()
    /// Read from the plugin's own Info.plist, as core reads it.
    let manifest: PluginManifest

    /// - Parameters:
    ///   - alongside: other in-process plugins to run with it (a stub content
    ///     type to produce pane events, say).
    ///   - withAgent: also run a stand-in for the terminal an agent types
    ///     `tabs-ctl` in (a stub content type, `agent`), so control-plane verbs have
    ///     a caller: `agentPane`, `tabsCtl`, `wire`.
    ///   - testFile: finds the plugin's folder (Plugins/<Name>/Tests/<file>).
    init(
        alongside: [PluginCandidate] = [], withAgent: Bool = false, testFile: String = #filePath,
        _ make: @escaping @MainActor () -> any TabsPlugin
    ) throws {
        let folder = URL(filePath: testFile).deletingLastPathComponent().deletingLastPathComponent()
        let info = NSDictionary(contentsOf: folder.appending(path: "Info.plist")) as? [String: Any] ?? [:]
        manifest = try PluginManifest(infoDictionary: info)
        runtime = TestSupport.runtime()
        let agent =
            withAgent
            ? [
                TestSupport.candidate(TestSupport.manifest("harness-agent", contentTypes: ["harness-agent"])) { context in
                    context.register(TestSupport.contentType("harness-agent"))
                }
            ] : []
        runtime.startPlugins(from: nil, inProcess: [TestSupport.candidate(manifest, make)] + alongside + agent)
        engine = LayoutEngine(runtime: runtime)
        engine.renderer = renderer
        engine.restore(nil)
    }

    /// Quit, as far as the plugin can tell: it deactivates (its tasks and
    /// subscriptions end with it) and its scratch data goes.
    isolated deinit {
        runtime.host.stop()
        try? FileManager.default.removeItem(at: runtime.paths.dataDirectory)
    }

    /// The plugin's record: its state, notes and ignored calls.
    var record: PluginRecord? { runtime.host.record(for: manifest.id) }

    /// Opens a pane of `type` (as `openPane` does) and returns it.
    @discardableResult
    func open(_ type: ContentTypeID, config: JSONValue? = nil, placement: PanePlacement = .automatic) -> LivePane? {
        runtime.panes.openPane(PaneRequest(type: type, config: config, placement: placement)).flatMap(engine.live)
    }

    /// A live pane's controller as the plugin's own type.
    func controller<T: PaneController>(of pane: PaneID, as type: T.Type = T.self) -> T? {
        engine.live(pane)?.controller as? T
    }

    /// A pane's state as core would save it now.
    func config(of pane: PaneID) -> JSONValue? { engine.live(pane).map(runtime.panes.snapshot)?.config }

    /// Runs a command in the context of the active pane, as the menu does.
    /// Returns whether it was enabled (and so ran).
    @discardableResult
    func perform(_ command: CommandID) -> Bool {
        runtime.commands.perform(
            command, window: engine.frontmostWindowID, pane: engine.activePaneID, contentType: engine.activeContentType)
    }

    /// Whether a command is enabled for the active pane (as the menu shows it).
    func isEnabled(_ command: CommandID) -> Bool {
        guard let contribution = runtime.commands.command(command) else { return false }
        let invocation = runtime.commands.invocation(
            for: contribution.owner, window: engine.frontmostWindowID, pane: engine.activePaneID, contentType: engine.activeContentType)
        return runtime.commands.isEnabled(contribution, invocation)
    }

    /// The pane of the stand-in agent shell (`withAgent:`), opened on first use:
    /// the caller a control-plane verb needs, and the owner of what it creates.
    var agentPane: PaneID {
        if let existing = agent { return existing }
        let pane = runtime.panes.openPane(PaneRequest(type: "harness-agent", placement: .tab(near: nil)))
        precondition(pane != nil, "the harness has no agent: pass withAgent: true")
        agent = pane
        return pane ?? ""
    }
    private var agent: PaneID?

    /// What `tabs-ctl <command> …flags` sends from the shell in `caller` (the
    /// agent pane by default): a control-plane verb by its CLI command, its
    /// flags as the CLI passes them (`"pane": id`, `"url": "…"`, a bare flag `true`).
    func tabsCtl(
        _ command: String, _ flags: [String: JSONValue] = [:], from caller: PaneID? = nil,
        cwd: URL? = URL(filePath: "/tmp", directoryHint: .isDirectory)
    ) async -> JSONValue {
        await runtime.control.handle(
            ControlDispatcher.Envelope(command: command, arguments: .object(flags), targetPane: caller ?? agentPane, cwd: cwd))
    }

    /// A raw wire request from `caller` (the agent pane by default): a `batch`
    /// step, or a client speaking the protocol.
    func wire(_ request: [String: JSONValue], from caller: PaneID? = nil, cwd: URL? = URL(filePath: "/tmp", directoryHint: .isDirectory))
        async
        -> JSONValue
    {
        var request = request
        request["paneId"] = .string((caller ?? agentPane).rawValue)
        return await runtime.control.dispatch(wire: .object(request), cwd: cwd)
    }

    /// Calls a control verb; returns the whole response (`ok`, `result` or `error`).
    func call(_ verb: String, _ arguments: JSONValue = .emptyObject, pane: PaneID? = nil) async -> JSONValue {
        await runtime.control.handle(ControlDispatcher.Envelope(command: verb, arguments: arguments, targetPane: pane))
    }

    /// The plugin's settings as stored.
    var storedSettings: JSONValue? { runtime.settings.storedSettings(for: manifest.id) }
}
