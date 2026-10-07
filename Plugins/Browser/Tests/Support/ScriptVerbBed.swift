import AppKit
import Foundation
import TabsPluginSDK
import Testing

@testable import TabsCore

/// What a verb test stands on: the real Browser plugin in a real core runtime, an agent pane (the
/// caller of `tabs-ctl`) that owns a browser pane, and the standard fixture pages on a loopback
/// server. The pane is built by the plugin as core builds it, with no window (a page evaluates and
/// waits without one), so a test drives the verbs exactly as the control socket does:
///
/// ```swift
/// let bed = try await ScriptVerbBed.open("/page")
/// let answer = await bed.ctl("execute-js", ["code": "1 + 1"])
/// #expect(answer.result["value"] == 2)
/// ```
@MainActor
final class ScriptVerbBed {
    let harness: PluginHarness
    /// The plugin under test: its services are where a test lowers a cap.
    let plugin: BrowserPlugin
    let server: FixtureServer
    let pane: PaneID
    let browser: BrowserPane
    private var scratch: [URL] = []

    /// A browser pane owned by the agent, on `path` of the standard server (loaded, when there is one).
    static func open(_ path: String? = nil, serving: (FixtureServer) -> Void = { _ in }, testFile: String = #filePath) async throws
        -> ScriptVerbBed
    {
        _ = NSApplication.shared
        let server = try await FixtureServer.startStandard()
        serving(server)
        let plugin = BrowserPlugin()
        let harness = try PluginHarness.browser(plugin, withAgent: true, testFile: testFile)
        let request = PaneRequest(type: "browser", placement: .tab(near: nil), controlledBy: harness.agentPane)
        let id = try #require(harness.runtime.panes.openPane(request))
        let browser = try #require(harness.controller(of: id, as: BrowserPane.self))
        let bed = ScriptVerbBed(harness: harness, plugin: plugin, server: server, pane: id, browser: browser)
        if let path { await bed.load(path) }
        return bed
    }

    private init(harness: PluginHarness, plugin: BrowserPlugin, server: FixtureServer, pane: PaneID, browser: BrowserPane) {
        self.harness = harness
        self.plugin = plugin
        self.server = server
        self.pane = pane
        self.browser = browser
    }

    isolated deinit {
        browser.paneWillClose()
        server.stop()
        for directory in scratch { try? FileManager.default.removeItem(at: directory) }
    }

    var page: BrowserPage { browser.page }

    /// The plugin's cache directory, where generated agent files land.
    var cacheDirectory: URL { harness.runtime.paths.pluginCache("browser") }

    /// Loads `path` (or a full URL) and waits for the load to end.
    @discardableResult
    func load(_ path: String, timeoutMs: Int = 10_000) async -> LoadOutcome {
        page.load(path.hasPrefix("/") ? server.url(path) : path)
        return await page.waitForLoadEnd(timeoutMs: timeoutMs)
    }

    /// Evaluates an expression in the page; the value, or a recorded issue.
    @discardableResult
    func value(_ script: String, sourceLocation: SourceLocation = #_sourceLocation) async -> JSONValue {
        switch await page.evaluate(script) {
        case .success(let value): return value
        case .failure(let error):
            Issue.record("the script failed: \(error) (\(script.prefix(80)))", sourceLocation: sourceLocation)
            return .null
        }
    }

    /// `tabs-ctl <command> --pane <this pane> …flags`, from the agent's pane.
    func ctl(_ command: String, _ flags: [String: JSONValue] = [:], pane: PaneID? = nil, cwd: URL? = nil) async -> ScriptAnswer {
        var flags = flags
        flags["pane"] = .string((pane ?? self.pane).rawValue)
        if let cwd { return ScriptAnswer(await harness.tabsCtl(command, flags, cwd: cwd)) }
        return ScriptAnswer(await harness.tabsCtl(command, flags))
    }

    /// A raw wire request (a `batch` step) aimed at this pane.
    func wire(_ type: String, _ fields: [String: JSONValue] = [:]) async -> ScriptAnswer {
        var request = fields
        request["type"] = .string(type)
        request["targetPaneId"] = .string(pane.rawValue)
        return ScriptAnswer(await harness.wire(request))
    }

    /// A verb the plugin registered, by its qualified name.
    func verb(_ name: String) -> ControlVerbContribution? {
        harness.runtime.registry.contribution(to: .controlVerbs, id: name)?.value
    }

    /// A fresh directory for files a test asks a verb to write.
    func scratchDirectory() throws -> URL {
        let directory = TestTemporary.directory("verb-bed")
        scratch.append(directory)
        return directory
    }

}

/// A control response, read as the agent reads it.
struct ScriptAnswer {
    let json: JSONValue
    init(_ json: JSONValue) { self.json = json }
    /// The response's `ok`.
    var ok: Bool { json["ok"] == true }
    /// The response's `error`.
    var error: String? { json["error"]?.stringValue }
    /// The response's `result` (`.null` when there is none).
    var result: JSONValue { json["result"] ?? .null }
}
