import Foundation
import TabsPluginSDK
import Testing

/// An agent's seat in the running app, for the browser verb tests (the native `e2e/helpers/agentSession.ts`
/// and `guest.ts`): a pane the app made, standing for the caller's terminal, and the real `tabs-ctl`
/// (`LaunchedApp.tabsCtl`, ControlPlaneEndToEndTests.swift: Node, the skill's one script, the app's socket)
/// run from it. Panes an agent creates are read back the way `guestEval` and `guestText` read a guest, through
/// the app's `browser.test.*` Debug verbs, so a check is an independent observation of the page, not an echo
/// of what the verb answered.
///
/// ```swift
/// @Suite(.serialized, .sharedApp, .timeLimit(.minutes(2)), .enabled(if: LaunchedApp.nodeIsInstalled)) struct XTests {
///     @Test func aClickReachesThePage() async throws {
///         let server = try await FixtureServer.startStandard()
///         defer { server.stop() }
///         let agent = try await AgentSession.open(SharedApp.fresh())
///         let pane = try await agent.createBrowserPane(url: server.url("/page"))
///         let clicked = try await agent.ctl(["click", "--pane", pane, "--name", "Do the thing"])
///         #expect(clicked.ok)
///         #expect(try await agent.text(pane, "#status") == "clicked")
///     }
/// }
/// ```
///
/// A test needs no teardown: `SharedApp.fresh()` empties the app before the next one, which is what the
/// Electron `closeAgentSession` did by hand. Other panes than the caller's are reached by their id.
struct AgentSession {
    let app: LaunchedApp
    /// The pane `tabs-ctl` runs "in": `TABS_PANE_ID` is this and the agent's panes are owned by it.
    let caller: String

    /// The browser pane the user opened by hand beside the caller, when the session was opened with one:
    /// never targetable by an agent (`expectRefusedForForeignPane`).
    let foreignPane: String?

    /// A session in `app`'s active pane, which becomes a terminal (a pane that is still empty is not one to
    /// a socket), as `openAgentSession`'s does.
    ///
    /// `foreignPane: true` also opens a browser pane by hand first, as a tab beside the caller's (the
    /// pane id is `foreignPane`). It is made first because a new tab is a copy of the active pane's content
    /// type: from the still-empty pane it is another empty one, from the terminal it would be a terminal. The
    /// caller's tab is then brought back, so the caller stays the active pane and the foreign pane is in
    /// the background.
    ///
    /// Where a created pane is placed is the browser's own setting (Electron: `controlledPanePlacement`,
    /// which `openAgentSession` pins to `tab`); the native default is what a test gets until that setting
    /// is ported, and a test about placement states its own.
    static func open(_ app: LaunchedApp, foreignPane makeForeign: Bool = false) async throws -> AgentSession {
        let pane = try await app.activePane()
        var foreign: String?
        if makeForeign {
            guard try await app.call("tabs.test.press", ["key": "t", "modifiers": ["command"]]) == true else {
                throw LaunchedApp.Failure(description: "Command-T was not handled: no new tab")
            }
            let other = try await app.activePane()
            guard other != pane else { throw LaunchedApp.Failure(description: "Command-T made no new active pane") }
            try await app.call("tabs.test.click", ["create": "browser", "paneId": .string(other)])
            foreign = other
            // A hidden pane has no empty-pane button to click: bring the caller's tab back first.
            try await Self.show(pane, in: app)
        }
        try await app.call("tabs.test.click", ["create": "terminal", "paneId": .string(pane)])
        return AgentSession(app: app, caller: pane, foreignPane: foreign)
    }

    /// The shared scaffold of the per-verb-family ownership tests (`expectRefusedForForeignPane`): a session with a
    /// hand-opened pane, and the assertion that every listed command, built from that pane's id, is refused with
    /// the ownership error.
    static func expectRefusedForForeignPane(
        _ app: LaunchedApp, sourceLocation: SourceLocation = #_sourceLocation, commands: (_ foreign: String) -> [[String]]
    ) async throws {
        let agent = try await open(app, foreignPane: true)
        let foreign = try #require(agent.foreignPane, sourceLocation: sourceLocation)
        for arguments in commands(foreign) {
            let response = try await agent.ctl(arguments)
            #expect(!response.ok, "\(arguments[0]) should be refused", sourceLocation: sourceLocation)
            #expect(response.error?.contains("not the owner") == true, "\(response.response)", sourceLocation: sourceLocation)
        }
    }

    /// Clicks the tab that holds exactly `pane`, as a user does: the pane becomes the visible, active one.
    static func show(_ pane: String, in app: LaunchedApp) async throws {
        try await app.call("tabs.test.click", ["identifier": .string("tab-\(try await tab(holding: pane, in: app))")])
    }

    func show(_ pane: String) async throws {
        try await Self.show(pane, in: app)
    }

    /// The id of the tab that holds exactly `pane` (its `tab-<id>` control is what a user clicks).
    private static func tab(holding pane: String, in app: LaunchedApp) async throws -> String {
        let report = try await app.call("tabs.test.signals")
        guard case .object(let tabs)? = report["windows"]?[0]?["tabs"],
            let id = tabs.sorted(by: { $0.key < $1.key }).first(where: { _, entry in
                if case .array(let leaves)? = entry["leaves"] { leaves == [.string(pane)] } else { false }
            })?.key
        else { throw LaunchedApp.Failure(description: "no tab holds \(pane): \(report)") }
        return id
    }

    // MARK: tabs-ctl

    /// Runs `tabs-ctl <arguments>` from the caller's pane (`runTabsCtl(args, env)`).
    @discardableResult
    func ctl(_ arguments: [String]) async throws -> LaunchedApp.CtlResult {
        try await app.tabsCtl(arguments, from: caller)
    }

    @discardableResult
    func ctl(_ arguments: String...) async throws -> LaunchedApp.CtlResult {
        try await ctl(arguments)
    }

    /// Runs it from another pane's environment (a pane that isn't the owner of the one it names).
    func ctl(_ arguments: [String], from pane: String) async throws -> LaunchedApp.CtlResult {
        try await app.tabsCtl(arguments, from: pane)
    }

    /// Runs it with neither `TABS_PANE_ID` nor `TABS_CONTROL_SOCKET`, as a script outside Tabs would (the
    /// test process may itself run inside a Tabs pane: `tabsCtl` clears the variables either way).
    func ctlOutsideTabs(_ arguments: [String]) async throws -> LaunchedApp.CtlResult {
        try await app.tabsCtl(arguments, from: nil)
    }

    // MARK: Panes

    /// `create-browser-pane [--url <url>] <extra…>`, answering the raw response for a test whose subject is
    /// creation itself (its `ok`, `loaded`, `loadError`, `redirected`).
    func create(url: String? = nil, _ extra: String...) async throws -> LaunchedApp.CtlResult {
        try await ctl(["create-browser-pane"] + (url.map { ["--url", $0] } ?? []) + extra)
    }

    /// `create-browser-pane` plus the pane id every other test wants: throws, with the response, when the
    /// verb answered none.
    func createBrowserPane(url: String? = nil, _ extra: String...) async throws -> String {
        let created = try await ctl(["create-browser-pane"] + (url.map { ["--url", $0] } ?? []) + extra)
        guard let pane = created.result["paneId"]?.stringValue else {
            throw LaunchedApp.Failure(description: "create-browser-pane did not return a paneId: \(created.response)")
        }
        return pane
    }

    /// `close-pane --pane <pane>` (the agent closing one of its own).
    @discardableResult
    func closePane(_ pane: String) async throws -> LaunchedApp.CtlResult {
        try await ctl(["close-pane", "--pane", pane])
    }

    /// Every browser pane the app holds, oldest first as the layout lists them: `guestSnapshots`.
    func browserPanes() async throws -> [(pane: String, url: String, loading: Bool)] {
        guard case .array(let windows) = try await app.call("tabs.test.windows") else { return [] }
        var found: [(pane: String, url: String, loading: Bool)] = []
        for window in windows {
            guard case .array(let panes) = window["panes"] else { continue }
            for entry in panes where entry["type"] == "browser" {
                guard let id = entry["id"]?.stringValue else { continue }
                let state = try await app.browser(id)
                found.append((id, state["url"]?.stringValue ?? "", state["isLoading"] == true))
            }
        }
        return found
    }

    // MARK: The page a pane holds

    /// The pane's `browser.test.state`: url, title, history, load state, status, console count, address text.
    func state(_ pane: String) async throws -> JSONValue {
        try await app.browser(pane)
    }

    /// The state once `condition` holds (polled every 50ms for `seconds`; a timeout is a recorded issue).
    @discardableResult
    func state(
        _ pane: String, within seconds: Double = 15, sourceLocation: SourceLocation = #_sourceLocation,
        until condition: (JSONValue) -> Bool
    ) async throws -> JSONValue {
        try await app.browser(pane, within: seconds, sourceLocation: sourceLocation, until: condition)
    }

    /// Loads `url` into the pane the way a user does and waits for the load to end (`browser.test.load`).
    @discardableResult
    func load(_ pane: String, _ url: String) async throws -> JSONValue {
        try await app.call("browser.test.load", ["url": .string(url)], paneId: pane)
    }

    /// Evaluates an expression in the pane's page and answers its value: `guestEval`. A page-side throw
    /// is a thrown `Failure`, never a value that could pass an assertion vacuously.
    func eval(_ pane: String, _ expression: String) async throws -> JSONValue {
        try await app.call("browser.test.script", ["code": .string(expression)], paneId: pane)["value"] ?? .null
    }

    /// The text content of the first element matching `selector`, or nil: `guestText`.
    func text(_ pane: String, _ selector: String) async throws -> String? {
        let quoted = String(decoding: try JSONEncoder().encode(selector), as: UTF8.self)
        return try await eval(pane, "document.querySelector(\(quoted))?.textContent ?? null").stringValue
    }

    /// Trusted input into the page, as a control verb sends it (`browser.test.input`): a click at a point
    /// in CSS pixels, typed text, or a key (`modifiers`: `shift`, `control`, `option`, `command`).
    func input(
        _ pane: String, x: Double? = nil, y: Double? = nil, text: String? = nil, key: String? = nil, modifiers: [String] = []
    ) async throws {
        var arguments: [String: JSONValue] = [:]
        if let x, let y { arguments["x"] = .double(x); arguments["y"] = .double(y) }
        if let text { arguments["text"] = .string(text) }
        if let key { arguments["key"] = .string(key) }
        if !modifiers.isEmpty { arguments["modifiers"] = .array(modifiers.map { .string($0) }) }
        try await app.call("browser.test.input", .object(arguments), paneId: pane)
    }
}

extension LaunchedApp.CtlResult {
    /// The response's `ok`.
    var ok: Bool { response["ok"] == true }
    /// The response's `error`, when it has one.
    var error: String? { response["error"]?.stringValue }
    /// The response's `result` (`.null` when there is none).
    var result: JSONValue { response["result"] ?? .null }
}
