import AppKit
import Foundation
import TabsPluginSDK
import Testing

@testable import TabsCore

/// What an input verb answers, as `tabs-ctl` would print it (`ok`, `result` or `error`).
struct VerbResponse {
    let raw: JSONValue
    var ok: Bool { raw["ok"] == true }
    var error: String? { raw["error"]?.stringValue }
    var result: JSONValue { raw["result"] ?? .null }
}

/// The browser plugin in a real core runtime, with an agent's terminal beside it and a browser pane the agent
/// owns, its page in a window that is never shown (so real input reaches it) and served by the standard
/// fixture pages: what the input verbs' plugin-tier tests drive, through the control plane (`tabs-ctl`'s
/// flags, or a wire request) as an agent does.
@MainActor
final class InputVerbBed {
    let harness: PluginHarness
    let server: FixtureServer
    let window: KeyableWindow
    /// The browser pane the agent owns.
    let pane: PaneID
    let browser: BrowserPane
    var page: BrowserPage { browser.page }

    /// - Parameters:
    ///   - path: the page the agent's pane opens on.
    ///   - mounted: whether the page is in a window (a pane that isn't mounted has nowhere to send input).
    init(path: String = "/page", mounted: Bool = true, testFile: String = #filePath) async throws {
        _ = NSApplication.shared
        harness = try PluginHarness.browser(withAgent: true, testFile: testFile)
        server = try await FixtureServer.startStandard()
        let agent = harness.agentPane
        pane = try #require(
            harness.runtime.panes.openPane(
                PaneRequest(
                    type: "browser", config: ["url": .string(server.url(path))], placement: .tab(near: agent), activates: false,
                    controlledBy: agent)))
        browser = try #require(harness.controller(of: pane, as: BrowserPane.self))
        window = KeyableWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        if mounted { window.contentView = page.webView }
        _ = await page.waitForLoadEnd(timeoutMs: 10_000)
    }

    isolated deinit {
        browser.paneWillClose()
        window.close()
        server.stop()
    }

    func url(_ path: String) -> String { server.url(path) }

    /// Loads `path` and waits for the load to end.
    func load(_ path: String) async {
        page.load(path.hasPrefix("/") ? server.url(path) : path)
        _ = await page.waitForLoadEnd(timeoutMs: 10_000)
    }

    // MARK: The verbs

    /// `tabs-ctl <command> --pane <pane> <flags>` from the agent's shell.
    func ctl(_ command: String, _ flags: [String: JSONValue] = [:], pane target: PaneID? = nil) async -> VerbResponse {
        var flags = flags
        flags["pane"] = .string((target ?? pane).rawValue)
        return VerbResponse(raw: await harness.tabsCtl(command, flags))
    }

    /// A raw wire request naming `targetPaneId` (a `batch` step).
    func wire(_ type: String, _ fields: [String: JSONValue] = [:], pane target: PaneID? = nil) async -> VerbResponse {
        var request = fields
        request["type"] = .string(type)
        request["targetPaneId"] = .string((target ?? pane).rawValue)
        return VerbResponse(raw: await harness.wire(request))
    }

    // MARK: The page

    /// A script's value in the page (an expression); a recorded issue if it fails.
    @discardableResult
    func value(_ script: String, sourceLocation: SourceLocation = #_sourceLocation) async -> JSONValue {
        switch await page.evaluate(script) {
        case .success(let value): return value
        case .failure(let error):
            Issue.record("the script failed: \(error) (\(script.prefix(80)))", sourceLocation: sourceLocation)
            return .null
        }
    }

    /// The fixture page's `#status` text.
    var status: String? { get async { await value("document.getElementById('status')?.textContent ?? null").stringValue } }

    /// Polls until the fixture page's `#status` reads `expected`.
    func statusBecomes(_ expected: String) async -> Bool {
        await until { await self.status == expected }
    }

    /// Polls an async condition until it holds; false if it doesn't within `timeout`.
    func until(timeout: Duration = .seconds(10), _ condition: () async -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while !(await condition()) {
            guard ContinuousClock.now < deadline else { return false }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return true
    }

    /// `read-page`'s elements, as the page reports them (refs included).
    func elements(_ filter: ReadPageFilter = ReadPageFilter()) async -> [PageElement] {
        guard case .object(let read) = await value(readPageScript(filter)), case .array(let listed)? = read["elements"] else { return [] }
        return listed.map { element in
            let rect = element["rect"]
            return PageElement(
                ref: element["ref"]?.stringValue ?? "", role: element["role"]?.stringValue ?? "", name: element["name"]?.stringValue ?? "",
                tag: element["tag"]?.stringValue ?? "",
                rect: PageRect(
                    x: rect?["x"]?.doubleValue ?? 0, y: rect?["y"]?.doubleValue ?? 0, width: rect?["width"]?.doubleValue ?? 0,
                    height: rect?["height"]?.doubleValue ?? 0))
        }
    }

    /// The element `read-page` lists under `name`, a recorded issue if there is none.
    func element(named name: String, sourceLocation: SourceLocation = #_sourceLocation) async -> PageElement {
        let listed = await elements().first { $0.name == name }
        if listed == nil { Issue.record("read-page did not surface \(name)", sourceLocation: sourceLocation) }
        return listed ?? PageElement(role: "", name: name, tag: "")
    }
}
