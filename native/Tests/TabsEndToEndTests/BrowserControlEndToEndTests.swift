import Foundation
import TabsPluginSDK
import Testing

/// The agent's side of the browser: the built app as its own process, the real bundled `tabs-ctl` under Node
/// run from a pane the app made, panes reading a loopback fixture server (docs/BROWSER.md J-1…J-11, J-24,
/// H-2…H-5, H-11, E-2, E-5). The Electron specs these are ported from are `e2e/external-control.spec.ts`,
/// `external-control-flow.spec.ts` and `external-control-read.spec.ts` (titles camelCased). What the input,
/// script, wait and resource families add is their own file.
extension AgentSession {
    /// The response of `tabs-ctl <arguments>` from the caller's pane, its `ok` asserted (the whole response in the message).
    @discardableResult
    func ok(_ arguments: String..., sourceLocation: SourceLocation = #_sourceLocation) async throws -> JSONValue {
        let response = try await ctl(arguments)
        #expect(response.ok, "\(arguments.joined(separator: " ")): \(response.response)", sourceLocation: sourceLocation)
        return response.result
    }

    /// The layout a window reports for itself (`tabs.test.windows`), the first window's.
    func windowLayout() async throws -> JSONValue {
        try await app.call("tabs.test.windows")[0]?["layout"] ?? .null
    }

    /// Whether `pane` is on screen (the tab above it is the shown one).
    func isShowing(_ pane: String) async throws -> Bool {
        guard case .array(let windows) = try await app.call("tabs.test.windows") else { return false }
        for window in windows {
            if case .array(let panes)? = window["panes"], panes.contains(where: { $0["id"] == .string(pane) && $0["visible"] == true }) {
                return true
            }
        }
        return false
    }

    /// Every split of a layout (docked or floating), depth first.
    static func splits(in node: JSONValue?) -> [JSONValue] {
        guard let node else { return [] }
        switch node["type"]?.stringValue {
        case "split":
            var found = [node]
            if case .array(let children)? = node["children"] { for child in children { found += splits(in: child) } }
            return found
        case "tabs":
            var found: [JSONValue] = []
            if case .array(let tabs)? = node["tabs"] { for tab in tabs { found += splits(in: tab["content"]) } }
            return found
        default: return []
        }
    }

    /// The leaf ids under a layout node.
    static func leaves(in node: JSONValue?) -> [String] {
        guard let node else { return [] }
        switch node["type"]?.stringValue {
        case "split":
            if case .array(let children)? = node["children"] { return children.flatMap { leaves(in: $0) } }
            return []
        case "tabs":
            if case .array(let tabs)? = node["tabs"] { return tabs.flatMap { leaves(in: $0["content"]) } }
            return []
        default: return node["id"]?.stringValue.map { [$0] } ?? []
        }
    }

    /// A second shell in a tab of its own, standing for another agent: the pane its `tabs-ctl` runs from.
    static func anotherCaller(in app: LaunchedApp) async throws -> String {
        guard try await app.call("tabs.test.press", ["key": "t", "modifiers": ["command"]]) == true else {
            throw LaunchedApp.Failure(description: "Command-T was not handled: no new tab")
        }
        // A new tab is a copy of the active pane's type: another terminal, a live pane for a socket to be "in".
        return try await app.activePane()
    }

    /// The page-side lookup of a `read-page` ref (the registry is the page's own global, `shared/pageRefs.ts`).
    func refElement(_ ref: String) -> String {
        "(window.__tabsPageRefs instanceof Map ? window.__tabsPageRefs.get(\(String(decoding: (try? JSONEncoder().encode(ref)) ?? Data(), as: UTF8.self))) : null)"
    }

    /// The bytes of the PNG a verb wrote, its signature checked.
    func png(_ path: String?) throws -> Data {
        let data = try Data(contentsOf: URL(filePath: try #require(path)))
        #expect(data.prefix(8) == Data([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]), "a PNG on disk")
        return data
    }
}

extension Data {
    /// A PNG's width and height, from its IHDR.
    fileprivate var pngSize: (width: Int64, height: Int64) {
        func word(_ offset: Int) -> Int64 { self[offset..<offset + 4].reduce(0) { $0 << 8 | Int64($1) } }
        return (word(16), word(20))
    }
}

@Suite(.serialized, .sharedApp, .timeLimit(.minutes(2)), .enabled(if: LaunchedApp.nodeIsInstalled, "tabs-ctl runs under Node"))
struct BrowserControlEndToEndTests {
    // MARK: The plane

    @Test func aSkillRunningOutsideTabsIsRejectedBeforeItCanDoAnything() async throws {
        let agent = try await AgentSession.open(SharedApp.fresh())
        let response = try await agent.ctlOutsideTabs(["create-browser-pane", "--url", "about:blank"])
        #expect(!response.ok)
        #expect(response.error?.contains("not running inside a Tabs terminal pane") == true)
        #expect(try await agent.browserPanes().isEmpty)
    }

    @Test func capabilitiesListsEveryCapabilityWithItsEnabledStateDescribeReturnsOneCapabilitysFullReference() async throws {
        let agent = try await AgentSession.open(SharedApp.fresh())
        let capabilities = try await agent.ok("capabilities")
        guard case .array(let entries)? = capabilities["capabilities"] else { Issue.record("\(capabilities)"); return }
        let ids = entries.compactMap { $0["id"]?.stringValue }
        #expect(ids.contains("core") && ids.contains("browser"))
        let browser = try #require(entries.first { $0["id"] == "browser" })
        #expect(browser["enabled"] == true)
        guard case .array(let lines)? = browser["commands"], !lines.isEmpty else { Issue.record("no commands: \(browser)"); return }
        // Every command line is compact: one line, naming the command.
        for line in lines.compactMap(\.stringValue) { #expect(!line.contains("\n") && line.contains("tabs-ctl"), "\(line)") }

        let describe = try await agent.ok("describe", "--capability", "browser")
        #expect(describe["capability"] == "browser")
        guard case .array(let commands)? = describe["commands"] else { Issue.record("\(describe)"); return }
        let navigate = try #require(commands.first { $0["command"] == "navigate" })
        #expect(navigate["wire"]?["type"] == "object")
        #expect(navigate["usage"]?.stringValue?.contains("tabs-ctl navigate") == true)
        // (`describe`'s guide — "Browser panes" — is the guide's own test.)

        let unknown = try await agent.ctl(["describe", "--capability", "nonexistent"])
        #expect(!unknown.ok && unknown.error?.contains("unknown capability") == true)
    }

    @Test func aMalformedEnvelopeIsRefusedWithAValidationMessageBeforeAnythingIsDispatched() async throws {
        let agent = try await AgentSession.open(SharedApp.fresh())
        let unknownCommand = try await agent.ctl(["not-a-real-command"])
        #expect(!unknownCommand.ok && unknownCommand.error?.contains("unknown command") == true)
        // A known command, missing its one required flag.
        let missingFlag = try await agent.ctl(["navigate", "--pane", "whatever"])
        #expect(!missingFlag.ok && missingFlag.error?.contains("--url is required") == true)
    }

    /// "every protocol verb is claimed by some module in the main process" (native: every verb the browser declares is
    /// listed by `capabilities`, described, and dispatched to a handler: none answers "unknown command").
    @Test func everyDeclaredVerbIsRegisteredAndListedByCapabilities() async throws {
        let agent = try await AgentSession.open(SharedApp.fresh())
        let capabilities = try await agent.ok("capabilities")
        guard case .array(let entries)? = capabilities["capabilities"],
            case .array(let lines)? = entries.first(where: { $0["id"] == "browser" })?["commands"]
        else { Issue.record("\(capabilities)"); return }
        let listed = lines.compactMap(\.stringValue).compactMap { line in line.split(separator: " ").dropFirst().first.map(String.init) }
        #expect(listed.count == lines.count, "every line names its command: \(lines)")
        let describe = try await agent.ok("describe", "--capability", "browser")
        guard case .array(let commands)? = describe["commands"] else { Issue.record("\(describe)"); return }
        #expect(Set(commands.compactMap { $0["command"]?.stringValue }) == Set(listed), "described exactly what is listed")
        for command in listed {
            // Bare, so what answers is the verb's own validation (a missing flag, or the pane it must name),
            // never "unknown command".
            let response = try await agent.ctl([command])
            #expect(!response.ok, "\(command)")
            #expect(response.error?.contains("unknown command") == false, "\(command): \(response.response)")
        }
        for command in ["read-network", "capture-bodies"] {
            #expect(!listed.contains(command), "\(command) is not ported (docs/BROWSER.md J-23)")
        }
    }

    // MARK: Creating and owning

    @Test func anAgentCanCreateAndControlABrowserPaneItOwnsButNoOther() async throws {
        let agent = try await AgentSession.open(SharedApp.fresh())
        let created = try await agent.create(url: "about:blank")
        #expect(created.ok)
        let pane = try #require(created.result["paneId"]?.stringValue)
        #expect(try await agent.isShowing(pane), "opened beside its caller as a tab, shown")
        // The control indicator: autonomous but marked, not a silent creation.
        let signals = try await agent.app.signals()
        #expect(signals["windows"]?[0]?["panes"]?[pane]?["header"] == ["controlled"])

        #expect(try await agent.ctl(["navigate", "--pane", pane, "--url", "about:blank"]).ok)
        let rejected = try await agent.ctl(["navigate", "--pane", "not-a-pane-this-agent-created", "--url", "about:blank"])
        #expect(!rejected.ok && rejected.error?.contains("not the owner") == true)
    }

    /// "an agent-owned pane pulses the control indicator, and it never propagates to its tab": the `controlled` signal
    /// is raised on the pane, and on no tab.
    @Test func anAgentOwnedPanePulsesTheControlIndicatorAndItNeverPropagatesToItsTab() async throws {
        let agent = try await AgentSession.open(SharedApp.fresh())
        let pane = try await agent.createBrowserPane(url: "about:blank")
        let report = try await agent.app.signals { $0["windows"]?[0]?["panes"]?[pane]?["header"] == ["controlled"] }
        #expect(report["raised"]?[pane] == ["controlled"], "\(report)")
        #expect(report["windows"]?[0]?["panes"]?[pane]?["header"] == ["controlled"])
        #expect(report["windows"]?[0]?["panes"]?[pane]?["outline"] == "controlled", "the pane's own outline, in the signal's color")
        guard case .object(let tabs)? = report["windows"]?[0]?["tabs"] else { Issue.record("\(report)"); return }
        #expect(tabs.count == 2, "the caller's tab and the browser's")
        for (id, tab) in tabs { #expect(tab["signals"] == [], "no icon on tab \(id): \(tab)") }
        try await agent.closePane(pane)
        let after = try await agent.app.signals { $0["raised"]?[pane] == nil }
        #expect(after["raised"]?[pane] == nil, "ownership ends with the pane, and so does its cue")
    }

    /// "list-panes shows only the panes this caller created, and close-pane revokes ownership".
    @Test func listPanesShowsOnlyThePanesThisCallerCreatedAndClosePaneRevokesOwnership() async throws {
        let agent = try await AgentSession.open(SharedApp.fresh(), foreignPane: true)
        let pane = try await agent.createBrowserPane(url: "about:blank")
        let listed = try await agent.ok("list-panes")
        guard case .array(let panes)? = listed["panes"] else { Issue.record("\(listed)"); return }
        #expect(panes.map { $0["paneId"] } == [.string(pane)])
        #expect(panes.first?["type"] == "browser" && panes.first?["url"] == "about:blank")

        #expect(try await agent.closePane(pane).ok)
        #expect(try await agent.browserPanes().map(\.pane) == [try #require(agent.foreignPane)], "only the hand-opened one is left")
        // Ownership is dropped with the pane, so the same id is no longer targetable: but the caller who closed it is
        // told the pane is gone, not that it was never theirs.
        let afterClose = try await agent.ctl(["navigate", "--pane", pane, "--url", "about:blank"])
        #expect(!afterClose.ok)
        #expect(afterClose.error?.contains("no longer exists") == true && afterClose.error?.contains("not the owner") == false)
        #expect(try await agent.ok("list-panes")["panes"] == [])
    }

    @Test func closePaneRefusesAPaneThisCallerDoesNotOwn() async throws {
        let agent = try await AgentSession.open(SharedApp.fresh())
        let response = try await agent.ctl(["close-pane", "--pane", agent.caller])
        #expect(!response.ok && response.error?.contains("not the owner") == true)
        #expect(try await agent.app.activePane() == agent.caller, "the caller's own pane is still standing")
    }

    /// "createBrowserPane grants ownership as soon as the pane exists, not only once its own relay resolves".
    @Test func createBrowserPaneGrantsOwnershipAsSoonAsThePaneExistsNotOnlyOnceItsOwnRelayResolves() async throws {
        let server = try await FixtureServer.startStandard()
        defer { server.stop() }
        let agent = try await AgentSession.open(SharedApp.fresh())
        // The fixture delays its response, so create-browser-pane is still waiting when list-panes probes for
        // ownership through a second, independent connection.
        async let created = agent.createBrowserPane(url: server.url("/slow"))
        try await Task.sleep(for: .milliseconds(300))
        let owned = try await agent.ok("list-panes")
        guard case .array(let panes)? = owned["panes"] else { Issue.record("\(owned)"); return }
        #expect(panes.count == 1)
        let pane = try await created
        #expect(panes.first?["paneId"] == .string(pane))
    }

    /// "activate-pane brings a backgrounded pane to the front so it can be captured".
    @Test func activatePaneBringsABackgroundedPaneToTheFrontSoItCanBeCaptured() async throws {
        let server = try await FixtureServer.startStandard()
        defer { server.stop() }
        let agent = try await AgentSession.open(SharedApp.fresh())
        let pane = try await agent.createBrowserPane(url: server.url())
        #expect(try await agent.isShowing(pane))
        try await agent.show(agent.caller)
        #expect(try await !agent.isShowing(pane))

        #expect(try await agent.ctl(["activate-pane", "--pane", pane]).ok)
        #expect(try await agent.isShowing(pane))
        #expect(try await agent.app.activePane() == agent.caller, "revealed, never activated: the keyboard is not stolen")
        let shot = try await agent.ok("screenshot", "--pane", pane)
        #expect(shot["path"] != nil)
    }

    /// "oversized results are truncated honestly, never silently" (the get-page-text half).
    @Test func oversizedResultsAreTruncatedHonestlyNeverSilently() async throws {
        let server = try await FixtureServer.startStandard()
        defer { server.stop() }
        let agent = try await AgentSession.open(SharedApp.fresh())
        let pane = try await agent.createBrowserPane(url: server.url())
        let clipped = try await agent.ok("get-page-text", "--pane", pane, "--max-length", "10")
        #expect(clipped["truncated"] == true)
        #expect(clipped["text"]?.stringValue?.count == 10)
    }

    /// "tabs-ctl drains a response bigger than the pipe buffer…" (the get-page-text side of it).
    @Test func aPageTextBiggerThanThePipeBufferComesBackWhole() async throws {
        let server = try await FixtureServer.startStandard()
        defer { server.stop() }
        let agent = try await AgentSession.open(SharedApp.fresh())
        let pane = try await agent.createBrowserPane(url: server.url("/bigtext"))
        let big = try await agent.ctl(["get-page-text", "--pane", pane, "--max-length", "200000"])
        #expect(big.ok && big.exitCode == 0, "\(big.error ?? "")")
        let text = big.result["text"]?.stringValue ?? ""
        #expect(text.count > 65_536 && text.contains("END-OF-BIGTEXT"))
    }

    /// "one agent cannot drive a pane another agent created".
    @Test func oneAgentCannotDriveAPaneAnotherAgentCreated() async throws {
        let app = try await SharedApp.fresh()
        let a = try await AgentSession.open(app)
        let b = try await AgentSession.anotherCaller(in: app)
        #expect(b != a.caller)
        let pane = try await a.createBrowserPane(url: "about:blank")

        // Agent B holds a perfectly real pane id: the check is who created it, not whether the id resolves.
        let stolen = try await a.ctl(["navigate", "--pane", pane, "--url", "about:blank"], from: b)
        #expect(!stolen.ok && stolen.error?.contains("not the owner") == true)
        #expect(try await a.ctl(["list-panes"], from: b).result["panes"] == [])

        _ = try await a.closePane(pane)
        // The tombstone is scoped to the caller who closed it: A is told the pane is gone; B, who never owned it, still
        // gets the uniform ownership refusal for the very same id (else it would be a liveness oracle).
        let closerSees = try await a.ctl(["navigate", "--pane", pane, "--url", "about:blank"])
        #expect(closerSees.error?.contains("no longer exists") == true)
        let strangerSees = try await a.ctl(["navigate", "--pane", pane, "--url", "about:blank"], from: b)
        #expect(strangerSees.error?.contains("not the owner") == true && strangerSees.error?.contains("no longer exists") == false)
    }

    /// "a disallowed URL scheme is rejected without touching the pane tree".
    @Test func aDisallowedURLSchemeIsRejectedWithoutTouchingThePaneTree() async throws {
        let agent = try await AgentSession.open(SharedApp.fresh())
        let response = try await agent.create(url: "file:///etc/passwd")
        #expect(!response.ok)
        #expect(response.error?.contains("url not allowed") == true)
        #expect(try await agent.browserPanes().isEmpty)
    }

    /// "a pane the user closed by hand reports that, not 'not a browser pane'".
    @Test func aPaneTheUserClosedByHandReportsThatNotNotABrowserPane() async throws {
        let agent = try await AgentSession.open(SharedApp.fresh())
        let pane = try await agent.createBrowserPane(url: "about:blank")
        #expect(try await agent.ctl(["activate-pane", "--pane", pane]).ok, "the happy path works through the same shared check")
        // Closed through the pane's own chrome, exactly as a user would: not through close-pane, which would revoke
        // ownership and answer "not the owner".
        try await agent.app.call("tabs.test.click", ["identifier": "pane-close-button", "paneId": .string(pane)])
        #expect(try await agent.browserPanes().isEmpty, "the pane is gone")
        for arguments in [["activate-pane", "--pane", pane], ["get-page-text", "--pane", pane], ["close-pane", "--pane", pane]] {
            let response = try await agent.ctl(arguments)
            #expect(!response.ok, "\(arguments[0])")
            #expect(response.error?.contains("no longer exists") == true, "\(arguments[0]): \(response.response)")
            #expect(response.error?.contains("not a browser pane") == false)
        }
    }

    // MARK: Navigation

    /// "navigation verbs wait for the page and report load failures by name".
    @Test func navigationVerbsWaitForThePageAndReportLoadFailuresByName() async throws {
        let server = try await FixtureServer.startStandard()
        defer { server.stop() }
        let agent = try await AgentSession.open(SharedApp.fresh())
        let created = try await agent.create(url: server.url())
        let pane = try #require(created.result["paneId"]?.stringValue)
        #expect(created.result["loaded"] == true, "the create itself waited for the fixture page")
        let text = try await agent.ok("get-page-text", "--pane", pane)
        #expect(text["text"]?.stringValue?.contains("Hello from the fixture") == true)

        let dead = try await FixtureServer.deadOrigin()
        let refused = try await agent.ctl(["navigate", "--pane", pane, "--url", dead])
        #expect(!refused.ok && refused.error?.contains("ERR_CONNECTION_REFUSED") == true, "\(refused.response)")
        // A 404 is a *successful* load of an error page, not a load failure.
        let missing = try await agent.ctl(["navigate", "--pane", pane, "--url", server.url("/missing")])
        #expect(missing.ok && missing.result["loaded"] == true)
        // Creating a pane against a dead origin still yields the pane, with the failure reported alongside.
        let deadPane = try await agent.create(url: dead)
        #expect(deadPane.ok && deadPane.result["loaded"] == false)
        #expect(deadPane.result["loadError"]?.stringValue?.contains("ERR_CONNECTION_REFUSED") == true)
        #expect(deadPane.result["paneId"] != nil)
    }

    /// "reload and history verbs settle on the page they land on".
    @Test func reloadAndHistoryVerbsSettleOnThePageTheyLandOn() async throws {
        let server = try await FixtureServer.startStandard()
        defer { server.stop() }
        let agent = try await AgentSession.open(SharedApp.fresh())
        let pane = try await agent.createBrowserPane(url: server.url())
        // Mutate page state, then reload: the state must be gone, proving a real fresh document.
        _ = try await agent.eval(pane, "(document.getElementById('status').textContent = 'clicked', 1)")
        #expect(try await agent.text(pane, "#status") == "clicked")
        let reloaded = try await agent.ok("reload", "--pane", pane)
        #expect(reloaded["loaded"] == true)
        #expect(try await agent.text(pane, "#status") == "idle")

        try await agent.ok("navigate", "--pane", pane, "--url", server.url("/other"))
        #expect(try await agent.ok("go-back", "--pane", pane)["title"] == "Fixture")
        #expect(try await agent.ok("pane-info", "--pane", pane)["title"] == "Fixture")
        #expect(try await agent.ok("go-forward", "--pane", pane)["title"] == "Elsewhere")
        // The history edge is an error that says which way was empty, not a no-op.
        let tooFar = try await agent.ctl(["go-forward", "--pane", pane])
        #expect(!tooFar.ok && tooFar.error?.contains("no later page") == true)
    }

    /// "landing on a failed page reports the failure, whichever verb got there".
    @Test func landingOnAFailedPageReportsTheFailureWhicheverVerbGotThere() async throws {
        let server = try await FixtureServer.startStandard()
        defer { server.stop() }
        let agent = try await AgentSession.open(SharedApp.fresh())
        let pane = try await agent.createBrowserPane(url: server.url())
        let dead = try await FixtureServer.deadOrigin()
        func info() async throws -> JSONValue { try await agent.ok("pane-info", "--pane", pane) }
        func listedURL() async throws -> JSONValue? {
            guard case .array(let panes)? = try await agent.ok("list-panes")["panes"] else { return nil }
            return panes.first { $0["paneId"] == .string(pane) }?["url"]
        }
        let consoleBefore = try await agent.state(pane)["console"]
        #expect(consoleBefore != nil && consoleBefore != 0, "the fixture page logged")

        #expect(try await !agent.ctl(["navigate", "--pane", pane, "--url", dead]).ok)
        let failed = try await info()
        #expect(failed["url"] == .string(dead) && failed["showingErrorPage"] == true)
        #expect(try await agent.state(pane)["console"] == 0, "the fixture page's console belonged to the fixture page")
        // What a re-created pane would come back on (list-panes reads config.url).
        #expect(try await listedURL() == .string(dead))

        // Back onto the failed entry from a 200 page.
        let other = try await agent.ok("navigate", "--pane", pane, "--url", server.url("/other"))
        #expect(other["status"] == 200)
        let back = try await agent.ok("go-back", "--pane", pane)
        #expect(back["loaded"] == false && back["url"] == .string(dead))
        #expect(back["loadError"]?.stringValue?.contains("ERR_CONNECTION_REFUSED") == true)
        #expect(back["status"] == nil && back["statusText"] == nil)
        let reloaded = try await agent.ok("reload", "--pane", pane)
        #expect(reloaded["loaded"] == false && reloaded["status"] == nil)

        // The other variant seen: the stale status was a 404's.
        let missing = try await agent.ok("navigate", "--pane", pane, "--url", server.url("/missing"))
        #expect(missing["status"] == 404)
        #expect(try await !agent.ctl(["navigate", "--pane", pane, "--url", dead]).ok)
        let reloadedAgain = try await agent.ok("reload", "--pane", pane)
        #expect(reloadedAgain["loadError"]?.stringValue?.contains("ERR_CONNECTION_REFUSED") == true && reloadedAgain["status"] == nil)

        // A pane re-created while on the error page comes back on the page it was showing: config.url followed the failure.
        let config = try await agent.app.call("tabs.test.paneConfig", ["paneId": .string(pane)])
        #expect(config["url"] == .string(dead), "\(config)")
    }

    /// A page that sends itself elsewhere from script while it loads (an auth bounce's shape) is a redirect: the
    /// answer is where the pane ended up, as Electron's is.
    @Test func aScriptRedirectWhileThePageLoadsIsReportedAsARedirect() async throws {
        let server = try await FixtureServer.startStandard()
        defer { server.stop() }
        let agent = try await AgentSession.open(SharedApp.fresh())
        let created = try await agent.create(url: server.url("/js-redirect"))
        let pane = try #require(created.result["paneId"]?.stringValue)
        #expect(created.result["url"] == .string(server.url("/other")) && created.result["redirected"] == true)
        let bounced = try await agent.ok("navigate", "--pane", pane, "--url", server.url("/onload-redirect"))
        #expect(bounced["loaded"] == true && bounced["url"] == .string(server.url("/other")))
        #expect(bounced["title"] == "Elsewhere" && bounced["redirected"] == true)
    }

    /// "navigation verbs report where the pane actually ended up".
    @Test func navigationVerbsReportWhereThePaneActuallyEndedUp() async throws {
        let server = try await FixtureServer.startStandard()
        defer { server.stop() }
        let agent = try await AgentSession.open(SharedApp.fresh())
        // The first load server-redirects: loaded says a load settled, url says where it went, redirected says it wasn't
        // the URL asked for.
        let created = try await agent.create(url: server.url("/redirect"))
        let pane = try #require(created.result["paneId"]?.stringValue)
        #expect(created.result["loaded"] == true && created.result["url"] == .string(server.url("/other")))
        #expect(created.result["title"] == "Elsewhere" && created.result["redirected"] == true)
        #expect(created.result["status"] == 200, "the status describes the landing document, not the 302 hop")

        let bounced = try await agent.ok("navigate", "--pane", pane, "--url", server.url("/redirect"))
        #expect(bounced["loaded"] == true && bounced["url"] == .string(server.url("/other")))
        #expect(bounced["title"] == "Elsewhere" && bounced["redirected"] == true && bounced["status"] == 200)

        let straight = try await agent.ok("navigate", "--pane", pane, "--url", server.url())
        #expect(straight["loaded"] == true && straight["url"] == .string(server.url()))
        #expect(straight["redirected"] == false && straight["status"] == 200 && straight["titleFromUrl"] == nil)

        let reloaded = try await agent.ok("reload", "--pane", pane)
        #expect(reloaded["url"] == .string(server.url()) && reloaded["title"] == "Fixture")
        #expect(reloaded["redirected"] == nil && reloaded["status"] == 200)
        let back = try await agent.ok("go-back", "--pane", pane)
        #expect(back["url"] == .string(server.url("/other")) && back["title"] == "Elsewhere")

        let missing = try await agent.ok("navigate", "--pane", pane, "--url", server.url("/missing"))
        #expect(missing["loaded"] == true && missing["status"] == 404 && missing["statusText"] == "Not Found")
        #expect(missing["titleFromUrl"] == true, "a plain-text 404 page never titles itself either")
    }

    /// "--retry-on-redirect re-asserts the requested URL once after a bounce".
    @Test func retryOnRedirectReassertsTheRequestedURLOnceAfterABounce() async throws {
        let server = try await FixtureServer.startStandard()
        defer { server.stop() }
        let agent = try await AgentSession.open(SharedApp.fresh())
        let pane = try await agent.createBrowserPane(url: server.url())

        let deep = server.url("/bounce-once/no-retry-\(UUID().uuidString)")
        let reported = try await agent.ok("navigate", "--pane", pane, "--url", deep)
        #expect(reported["url"] == .string(server.url("/other")) && reported["redirected"] == true && reported["retried"] == nil)

        let deepRetry = server.url("/bounce-once/retry-\(UUID().uuidString)")
        let retried = try await agent.ok("navigate", "--pane", pane, "--url", deepRetry, "--retry-on-redirect")
        #expect(retried["loaded"] == true && retried["url"] == .string(deepRetry) && retried["title"] == "Deep link")
        #expect(retried["redirected"] == false && retried["retried"] == true && retried["firstUrl"] == .string(server.url("/other")))

        let always = try await agent.ok("navigate", "--pane", pane, "--url", server.url("/redirect"), "--retry-on-redirect")
        #expect(always["url"] == .string(server.url("/other")) && always["redirected"] == true)
        #expect(always["retried"] == true && always["firstUrl"] == .string(server.url("/other")))
    }

    /// "a title the page sets after load-settle is flagged as a URL fallback".
    @Test func aTitleThePageSetsAfterLoadSettleIsFlaggedAsAURLFallback() async throws {
        let server = try await FixtureServer.startStandard()
        defer { server.stop() }
        let agent = try await AgentSession.open(SharedApp.fresh())
        let pane = try await agent.createBrowserPane(url: server.url())
        let late = try await agent.ok("navigate", "--pane", pane, "--url", server.url("/late-title"))
        #expect(late["loaded"] == true && late["titleFromUrl"] == true && late["title"] != "Set later")
        // The live title lands moments later, exactly where the flag points.
        let deadline = ContinuousClock.now + .seconds(10)
        var title = try await agent.ok("pane-info", "--pane", pane)["title"]
        while title != "Set later", ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(100))
            title = try await agent.ok("pane-info", "--pane", pane)["title"]
        }
        #expect(title == "Set later")
    }

    /// "titleFromUrl is correct on reload and history steps, not only navigate".
    @Test func titleFromUrlIsCorrectOnReloadAndHistoryStepsNotOnlyNavigate() async throws {
        let server = try await FixtureServer.startStandard()
        defer { server.stop() }
        let agent = try await AgentSession.open(SharedApp.fresh())
        let pane = try await agent.createBrowserPane(url: server.url("/missing"))
        let missing = try await agent.ok("navigate", "--pane", pane, "--url", server.url("/missing"))
        #expect(missing["titleFromUrl"] == true)
        let other = try await agent.ok("navigate", "--pane", pane, "--url", server.url("/other"))
        #expect(other["title"] == "Elsewhere" && other["titleFromUrl"] == nil)
        let reloadedOther = try await agent.ok("reload", "--pane", pane)
        #expect(reloadedOther["title"] == "Elsewhere" && reloadedOther["titleFromUrl"] == nil)
        let backToMissing = try await agent.ok("navigate", "--pane", pane, "--url", server.url("/missing"))
        #expect(backToMissing["titleFromUrl"] == true)
        #expect(try await agent.ok("reload", "--pane", pane)["titleFromUrl"] == true)
        let back = try await agent.ok("go-back", "--pane", pane)
        #expect(back["title"] == "Elsewhere" && back["titleFromUrl"] == nil)
        #expect(try await agent.ok("go-forward", "--pane", pane)["titleFromUrl"] == true)
    }

    /// "a page script cannot steer an agent pane outside the scheme allowlist".
    @Test func aPageScriptCannotSteerAnAgentPaneOutsideTheSchemeAllowlist() async throws {
        let server = try await FixtureServer.startStandard()
        defer { server.stop() }
        let agent = try await AgentSession.open(SharedApp.fresh())
        let pane = try await agent.createBrowserPane(url: server.url())
        // The verb-level check is the front door; this is the back door: a navigation the *page* starts. Without the
        // guard this loads the local file and get-page-text becomes a local file reader.
        _ = try? await agent.eval(pane, "(location.href = 'file:///etc/hosts')")
        try await Task.sleep(for: .milliseconds(500))
        #expect(try await agent.ok("pane-info", "--pane", pane)["url"] == .string(server.url()))
        #expect(try await agent.ok("get-page-text", "--pane", pane)["text"]?.stringValue?.contains("Hello from the fixture") == true)
    }

    // MARK: Reading

    /// "an agent can read back a pane it owns: info, text, and a real PNG on disk".
    @Test func anAgentCanReadBackAPaneItOwnsInfoTextAndARealPNGOnDisk() async throws {
        let server = try await FixtureServer.startStandard()
        defer { server.stop() }
        let agent = try await AgentSession.open(SharedApp.fresh())
        let pane = try await agent.createBrowserPane(url: server.url())
        let text = try await agent.ok("get-page-text", "--pane", pane)
        #expect(text["text"]?.stringValue?.contains("Hello from the fixture") == true)
        let info = try await agent.ok("pane-info", "--pane", pane)
        #expect(info["title"] == "Fixture")
        #expect((info["viewport"]?["width"]?.doubleValue ?? 0) > 0)

        let shot = try await agent.ok("screenshot", "--pane", pane)
        let png = try agent.png(shot["path"]?.stringValue)
        #expect(shot["pngBytes"] == nil, "the bytes never come back over the socket, only a path")
        #expect(shot["activated"] == nil, "a pane that was visible all along reports no `activated` key")
        // `width`/`height` describe the actual PNG (device pixels); `viewport` the space a coordinate lives in
        // (CSS pixels); `scaleFactor` converts between them.
        #expect(shot["width"]?.intValue == png.pngSize.width && shot["height"]?.intValue == png.pngSize.height)
        #expect(shot["viewport"] == info["viewport"])
        let says = try await agent.eval(pane, "[innerWidth, innerHeight, devicePixelRatio]")
        #expect(
            shot["viewport"]?["width"]?.doubleValue == says[0]?.doubleValue
                && shot["viewport"]?["height"]?.doubleValue == says[1]?.doubleValue)
        #expect(shot["scaleFactor"]?.doubleValue == says[2]?.doubleValue)
        let ratio = try #require(says[2]?.doubleValue), width = try #require(says[0]?.doubleValue)
        #expect(abs(Double(png.pngSize.width) - width * ratio) <= ratio)
    }

    /// "screenshot clips to one element, in CSS pixels, at the same scale factor".
    @Test func screenshotClipsToOneElementInCSSPixelsAtTheSameScaleFactor() async throws {
        let server = try await FixtureServer.startStandard()
        defer { server.stop() }
        let agent = try await AgentSession.open(SharedApp.fresh())
        let pane = try await agent.createBrowserPane(url: server.url())
        let full = try await agent.ok("screenshot", "--pane", pane)
        let clipped = try await agent.ok("screenshot", "--pane", pane, "--selector", "#go")
        #expect(clipped["element"]?["name"] == "Do the thing")
        let rect = try #require(clipped["clipped"])
        let png = try agent.png(clipped["path"]?.stringValue)
        #expect(png.pngSize.width == clipped["width"]?.intValue && png.pngSize.height == clipped["height"]?.intValue)
        #expect((clipped["width"]?.intValue ?? .max) < (full["width"]?.intValue ?? 0))
        #expect((clipped["height"]?.intValue ?? .max) < (full["height"]?.intValue ?? 0))
        #expect(clipped["scaleFactor"] == full["scaleFactor"])
        let scale = try #require(clipped["scaleFactor"]?.doubleValue)
        #expect(clipped["width"]?.doubleValue == (rect["width"]?.doubleValue ?? 0) * scale)
        #expect(clipped["viewport"] == full["viewport"])

        // A ref clips identically; the two forms name one element two ways.
        let read = try await agent.ok("read-page", "--pane", pane, "--role", "button")
        guard case .array(let elements)? = read["elements"],
            let ref = elements.first(where: { $0["name"] == "Do the thing" })?["ref"]?.stringValue
        else { Issue.record("\(read)"); return }
        #expect(try await agent.ok("screenshot", "--pane", pane, "--ref", ref)["clipped"] == rect)

        let both = try await agent.ctl(["screenshot", "--pane", pane, "--selector", "#go", "--ref", ref])
        #expect(!both.ok && both.error?.contains("only one of selector or ref") == true)
        let missing = try await agent.ctl(["screenshot", "--pane", pane, "--selector", "#nope"])
        #expect(!missing.ok && missing.error?.contains("no element matches") == true)
    }

    /// "read-back verbs refuse a pane this caller does not own" (this family's verbs).
    @Test func readBackVerbsRefuseAPaneThisCallerDoesNotOwn() async throws {
        try await AgentSession.expectRefusedForForeignPane(SharedApp.fresh()) { foreign in
            [
                ["pane-info", "--pane", foreign], ["screenshot", "--pane", foreign], ["get-page-text", "--pane", foreign],
                ["read-page", "--pane", foreign], ["find", "--pane", foreign, "--description", "x"],
                ["navigate", "--pane", foreign, "--url", "about:blank"], ["reload", "--pane", foreign], ["go-back", "--pane", foreign],
                ["go-forward", "--pane", foreign],
            ]
        }
    }

    /// "pane-info flags an error page and refuses to invent a viewport for a hidden pane".
    @Test func paneInfoFlagsAnErrorPageAndRefusesToInventAViewportForAHiddenPane() async throws {
        let server = try await FixtureServer.startStandard()
        defer { server.stop() }
        let agent = try await AgentSession.open(SharedApp.fresh())
        let pane = try await agent.createBrowserPane(url: server.url())
        let healthy = try await agent.ok("pane-info", "--pane", pane)
        #expect((healthy["viewport"]?["width"]?.doubleValue ?? 0) > 0)
        #expect(healthy["showingErrorPage"] == nil && healthy["hidden"] == nil)

        let dead = try await FixtureServer.deadOrigin()
        #expect(try await !agent.ctl(["navigate", "--pane", pane, "--url", dead]).ok)
        let errored = try await agent.ok("pane-info", "--pane", pane)
        #expect(errored["showingErrorPage"] == true && errored["loadError"]?.stringValue?.contains("ERR_") == true)
        #expect(errored["url"]?.stringValue?.contains("127.0.0.1") == true)

        // Recovering clears the flag.
        #expect(try await agent.ctl(["navigate", "--pane", pane, "--url", server.url()]).ok)
        let healed = try await agent.ok("pane-info", "--pane", pane)
        #expect(healed["showingErrorPage"] == nil && healed["loadError"] == nil)

        // Backgrounded: no viewport at all rather than a zero one, plus the flag that names the remedy.
        try await agent.show(agent.caller)
        let backgrounded = try await agent.ok("pane-info", "--pane", pane)
        #expect(backgrounded["hidden"] == true && backgrounded["viewport"] == nil)
        // ...and activate-pane is what makes it answerable again.
        #expect(try await agent.ctl(["activate-pane", "--pane", pane]).ok)
        var revealed = try await agent.ok("pane-info", "--pane", pane)
        for _ in 0..<40 where revealed["hidden"] != nil {
            try await Task.sleep(for: .milliseconds(50))
            revealed = try await agent.ok("pane-info", "--pane", pane)
        }
        #expect((revealed["viewport"]?["width"]?.doubleValue ?? 0) > 0)
    }

    /// "read-page narrows by role and selector, and pages by offset".
    @Test func readPageNarrowsByRoleAndSelectorAndPagesByOffset() async throws {
        let server = try await FixtureServer.startStandard()
        defer { server.stop() }
        let agent = try await AgentSession.open(SharedApp.fresh())
        let pane = try await agent.createBrowserPane(url: server.url("/listing"))
        func elements(_ read: JSONValue) -> [JSONValue] { if case .array(let all)? = read["elements"] { all } else { [] } }

        let bare = try await agent.ok("read-page", "--pane", pane)
        #expect(elements(bare).count == 200 && bare["truncated"] == true && bare["offset"] == 0)
        #expect((bare["total"]?.intValue ?? 0) > 240)
        #expect(!elements(bare).contains { $0["tag"] == "select" }, "the <select> really is out of reach")
        let byRole = try await agent.ok("read-page", "--pane", pane, "--role", "combobox")
        #expect(elements(byRole).map { $0["tag"] } == ["select"] && byRole["truncated"] == false && byRole["total"] == 1)
        let images = try await agent.ok("read-page", "--pane", pane, "--selector", #"img[alt]:not([alt=""])"#)
        #expect(elements(images).map { $0["name"] } == ["Hero image", "Thumb image"])
        // So does a role only an image has.
        let byImageRole = try await agent.ok("read-page", "--pane", pane, "--role", "img")
        #expect(elements(byImageRole).map { $0["name"] } == ["Hero image", "Thumb image"])
        let clicked = try await agent.ok("click", "--pane", pane, "--role", "img", "--name", "Thumb image")
        #expect(clicked["element"] == ["role": "img", "name": "Thumb image", "tag": "img"])

        let paged = try await agent.ok("read-page", "--pane", pane, "--offset", "200")
        #expect(paged["offset"] == 200 && paged["truncated"] == false)
        let sort = try #require(elements(paged).first { $0["tag"] == "select" })
        // Refs are minted for the returned page only: a paged read hands back usable refs.
        let ref = try #require(sort["ref"]?.stringValue)
        _ = try await agent.eval(pane, "\(agent.refElement(ref)).value = 'price'")

        let bad = try await agent.ctl(["read-page", "--pane", pane, "--selector", "div:::nope"])
        #expect(!bad.ok && bad.error?.contains("invalid selector") == true)
        let unknownRole = try await agent.ctl(["read-page", "--pane", pane, "--role", "nonsense"])
        #expect(!unknownRole.ok && unknownRole.error?.contains("unknown role \"nonsense\"") == true)
        #expect(unknownRole.error?.contains("combobox") == true)
        let negative = try await agent.ctl(["read-page", "--pane", pane, "--offset=-3"])
        #expect(!negative.ok && negative.error?.contains("at least 0") == true, "\(negative.response)")
    }

    /// "read-page names labelled controls as the browser does and reports checked state".
    @Test func readPageNamesLabelledControlsAsTheBrowserDoesAndReportsCheckedState() async throws {
        let server = try await FixtureServer.startStandard()
        defer { server.stop() }
        let agent = try await AgentSession.open(SharedApp.fresh())
        let pane = try await agent.createBrowserPane(url: server.url("/controls"))
        func control(_ id: String) async throws -> JSONValue? {
            let response = try await agent.ok("read-page", "--pane", pane, "--selector", "#\(id)")
            if case .array(let all)? = response["elements"] { return all.first }
            return nil
        }
        func has(_ element: JSONValue?, _ expected: [String: JSONValue]) -> Bool { expected.allSatisfy { element?[$0.key] == $0.value } }
        #expect(has(try await control("colour"), ["role": "combobox", "name": "Colour", "value": "r"]))
        #expect(has(try await control("bare"), ["role": "combobox", "name": "", "value": "Beta"]))
        #expect(has(try await control("qty"), ["role": "textbox", "name": "Qty of kg", "value": "3"]))
        let agree = try await control("agree")
        #expect(has(agree, ["role": "checkbox", "name": "Agree", "checked": false]) && agree?["value"] == nil)
        #expect(has(try await control("subscribed"), ["checked": true]))
        #expect(has(try await control("some"), ["checked": "mixed"]))
        let small = try await control("small")
        #expect(has(small, ["role": "radio", "checked": true]) && small?["value"] == nil)
        #expect(has(try await control("wifi"), ["role": "switch", "name": "Wi-Fi", "checked": true]))
    }

    /// "find mints refs only for the matches it returns".
    @Test func findMintsRefsOnlyForTheMatchesItReturns() async throws {
        let server = try await FixtureServer.startStandard()
        defer { server.stop() }
        let agent = try await AgentSession.open(SharedApp.fresh())
        let pane = try await agent.createBrowserPane(url: server.url("/listing"))
        func refsMinted() async throws -> Int64 { try await agent.eval(pane, "window.__tabsPageRefSeq ?? 0").intValue ?? -1 }
        let before = try await refsMinted()
        let found = try await agent.ok("find", "--pane", pane, "--description", "Brand 7", "--max-results", "2")
        guard case .array(let matches)? = found["matches"] else { Issue.record("\(found)"); return }
        #expect(matches.map { $0["name"] } == ["Brand 7", "Brand 70"])
        #expect(try await refsMinted() == before + 2)
        // The refs it did mint are real: the best match is the checkbox by that name.
        let best = try #require(matches.first?["ref"]?.stringValue)
        #expect(try await agent.eval(pane, "\(agent.refElement(best)).id") == "brand7")
        let none = try await agent.ok("find", "--pane", pane, "--description", "checkout basket")
        #expect(none["matches"] == [])
        #expect(try await refsMinted() == before + 2)
    }

    /// "read verbs report readiness, and settled flips only with the DOM actually quiet".
    @Test func readVerbsReportReadinessAndSettledFlipsOnlyWithTheDOMActuallyQuiet() async throws {
        let server = try await FixtureServer.startStandard()
        defer { server.stop() }
        let agent = try await AgentSession.open(SharedApp.fresh())
        let pane = try await agent.createBrowserPane(url: server.url("/waity"))
        let first = try await agent.ok("read-page", "--pane", pane)
        #expect(first["isLoading"] == false && first["readyState"] == "complete" && first["settled"] == false)

        func settledSoon(_ command: String, seconds: Double) async throws -> Bool {
            let deadline = ContinuousClock.now + .seconds(seconds)
            while ContinuousClock.now < deadline {
                if try await agent.ok(command, "--pane", pane)["settled"] == true { return true }
                try await Task.sleep(for: .milliseconds(200))
            }
            return false
        }
        #expect(try await settledSoon("get-page-text", seconds: 15))
        let found = try await agent.ok("find", "--pane", pane, "--description", "waity")
        #expect(found["isLoading"] == false && found["readyState"] == "complete" && found["settled"] == true)

        _ = try await agent.eval(pane, "window.churn(3000)")
        #expect(try await agent.ok("read-page", "--pane", pane)["settled"] == false)
        #expect(try await settledSoon("read-page", seconds: 20))
    }

    /// "read verbs report frame/shadow counts, and coordinate clicks reach inside both even though reads cannot": the
    /// real trusted click is the Debug input verb (`click`'s own result — the element it names — is the input family's).
    @Test func readVerbsReportFrameShadowCountsAndCoordinateClicksReachInsideBothEvenThoughReadsCannot() async throws {
        let server = try await FixtureServer.startStandard()
        defer { server.stop() }
        let agent = try await AgentSession.open(SharedApp.fresh())
        let pane = try await agent.createBrowserPane(url: server.url("/nested"))
        let read = try await agent.ok("read-page", "--pane", pane)
        #expect(read["frames"] == 1 && read["shadowRoots"] == 1)
        #expect(try await agent.ok("get-page-text", "--pane", pane)["frames"] == 1)
        let found = try await agent.ok("find", "--pane", pane, "--description", "button")
        #expect(found["frames"] == 1 && found["shadowRoots"] == 1)
        guard case .array(let elements)? = read["elements"] else { Issue.record("\(read)"); return }
        let names = elements.compactMap { $0["name"]?.stringValue }
        #expect(names.contains("Top button") && !names.contains("Frame button") && !names.contains("Shadow button"))

        // The workaround the skill documents: compute the target's viewport coordinate in the page, then click it.
        for _ in 0..<100 {
            if try await agent.eval(pane, "!!document.getElementById('the-frame').contentDocument?.getElementById('frame-button')") == true
            {
                break
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        func point(_ script: String) async throws -> (Double, Double) {
            let value = try await agent.eval(pane, script)
            return (try #require(value["x"]?.doubleValue), try #require(value["y"]?.doubleValue))
        }
        try await agent.show(pane)
        let frame = try await point(
            """
            (() => { const f = document.getElementById('the-frame').getBoundingClientRect()
              const b = document.getElementById('the-frame').contentDocument.getElementById('frame-button').getBoundingClientRect()
              return { x: f.x + b.x + b.width / 2, y: f.y + b.y + b.height / 2 } })()
            """)
        try await agent.input(pane, x: frame.0, y: frame.1)
        #expect(try await agent.eval(pane, "window.frameButtonClicked") == true)
        let shadow = try await point(
            """
            (() => { const b = document.getElementById('shadow-host').shadowRoot.querySelector('#shadow-button').getBoundingClientRect()
              return { x: b.x + b.width / 2, y: b.y + b.height / 2 } })()
            """)
        try await agent.input(pane, x: shadow.0, y: shadow.1)
        #expect(try await agent.eval(pane, "window.shadowButtonClicked") == true)
    }

    /// "screenshot reveals a backgrounded pane itself and says so with activated: true".
    @Test func screenshotRevealsABackgroundedPaneItselfAndSaysSoWithActivatedTrue() async throws {
        let server = try await FixtureServer.startStandard()
        defer { server.stop() }
        let agent = try await AgentSession.open(SharedApp.fresh())
        let pane = try await agent.createBrowserPane(url: server.url())
        #expect(try await agent.isShowing(pane))
        try await agent.show(agent.caller)
        #expect(try await !agent.isShowing(pane))

        // No activate-pane first: the reveal is the verb's own.
        let shot = try await agent.ok("screenshot", "--pane", pane)
        #expect(shot["activated"] == true)
        _ = try agent.png(shot["path"]?.stringValue)
        #expect(try await agent.isShowing(pane))
        // The reveal rides the same revealPane as activate-pane: what's visible changed, the keyboard didn't move.
        #expect(try await agent.app.activePane() == agent.caller)
    }

    /// "screenshot --no-activate fails on a backgrounded pane and leaves the visible tab alone".
    @Test func screenshotNoActivateFailsOnABackgroundedPaneAndLeavesTheVisibleTabAlone() async throws {
        let server = try await FixtureServer.startStandard()
        defer { server.stop() }
        let agent = try await AgentSession.open(SharedApp.fresh())
        let pane = try await agent.createBrowserPane(url: server.url())
        try await agent.show(agent.caller)
        let shot = try await agent.ctl(["screenshot", "--pane", pane, "--no-activate"])
        #expect(!shot.ok && shot.error?.contains("the pane is hidden") == true)
        #expect(try await !agent.isShowing(pane), "the refusal is the whole point of the flag: the visible tab did not change")
    }
}

// MARK: - Placement

/// Where `create-browser-pane` puts the pane is Settings ▸ Browser's "New pane placement" (docs/BROWSER.md G-1). Each
/// test launches an app of its own with the setting stored, since there is nothing in a running app to change it
/// with but the Settings window. Read back as the layout the window reports for itself.
@Suite(.serialized, .timeLimit(.minutes(2)), .enabled(if: LaunchedApp.nodeIsInstalled, "tabs-ctl runs under Node"))
struct BrowserPlacementEndToEndTests {
    private func launch(placement: String) async throws -> LaunchedApp {
        let directory = FileManager.default.temporaryDirectory.appending(path: "tabs-e2e-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let settings: JSONValue = ["version": 1, "core": [:], "plugins": ["browser": ["controlledPanePlacement": .string(placement)]]]
        try settings.encodedData().write(to: directory.appending(path: "settings.json"))
        return try await LaunchedApp.launch(dataDirectory: directory)
    }

    /// "create-browser-pane splits horizontally when placement is set to split-horizontal" (2).
    @Test(arguments: [("split-horizontal", "horizontal"), ("split-vertical", "vertical")])
    func createBrowserPaneSplitsInTheDirectionWhenPlacementIsSetToASplit(placement: String, direction: String) async throws {
        let app = try await launch(placement: placement)
        defer { app.terminate() }
        let agent = try await AgentSession.open(app)
        let pane = try await agent.createBrowserPane(url: "about:blank")
        let layout = try await agent.windowLayout()
        let splits = AgentSession.splits(in: layout["root"])
        let split = try #require(splits.first, "\(layout)")
        #expect(split["direction"] == .string(direction))
        #expect(AgentSession.leaves(in: split) == [agent.caller, pane], "the new pane after the caller's")
        #expect(try await agent.isShowing(pane))
        #expect(try await agent.isShowing(agent.caller), "the caller stays visible beside it, not backgrounded")
    }

    /// "create-browser-pane opens its own unpinned window when placement is set to unpinned".
    @Test func createBrowserPaneOpensItsOwnUnpinnedWindowWhenPlacementIsSetToUnpinned() async throws {
        let app = try await launch(placement: "unpinned")
        defer { app.terminate() }
        let agent = try await AgentSession.open(app)
        let pane = try await agent.createBrowserPane(url: "about:blank")
        let layout = try await agent.windowLayout()
        guard case .array(let floating)? = layout["floating"], floating.count == 1 else { Issue.record("\(layout)"); return }
        #expect(AgentSession.leaves(in: floating[0]["content"]) == [pane])
        #expect(AgentSession.leaves(in: layout["root"]) == [agent.caller], "the caller's own pane never moved")
        #expect(try await agent.isShowing(pane))
    }

    /// "creating and closing split-placed panes leaves an existing browser pane untouched": what lives only in the page
    /// (history, a filled field, the console, refs) survives its siblings coming and going.
    @Test func creatingAndClosingSplitPlacedPanesLeavesAnExistingBrowserPaneUntouched() async throws {
        let server = try await FixtureServer.startStandard()
        defer { server.stop() }
        let app = try await launch(placement: "split-horizontal")
        defer { app.terminate() }
        let agent = try await AgentSession.open(app)
        let first = try await agent.createBrowserPane(url: server.url("/other"))
        try await agent.ok("navigate", "--pane", first, "--url", server.url())
        _ = try await agent.eval(first, "(document.getElementById('name').value = 'kept', 1)")
        let read = try await agent.ok("read-page", "--pane", first, "--selector", "#go")
        guard case .array(let elements)? = read["elements"], let ref = elements.first?["ref"]?.stringValue else {
            Issue.record("\(read)"); return
        }

        /// Everything that lives only in the page, read the way an agent would.
        func pageState() async throws -> JSONValue {
            let info = try await agent.ok("pane-info", "--pane", first)
            return [
                "pageInstance": info["pageInstance"] ?? .null,
                "page": try await agent.eval(first, "[history.length, document.getElementById('name').value]"),
                "canGoBack": info["canGoBack"] ?? .null,
                "consoles": try await agent.state(first)["console"] ?? .null,
                "refResolves": try await agent.eval(first, "!!\(agent.refElement(ref))"),
            ]
        }
        // The fixture's console has its last message 300ms after load: read the state once that has come.
        try await Task.sleep(for: .milliseconds(600))
        let before = try await pageState()
        #expect(before["consoles"] == 4 || before["consoles"]?.intValue ?? 0 >= 3, "the console the page wrote is kept: \(before)")
        #expect(before["page"] == [2, "kept"] && before["canGoBack"] == true && before["refResolves"] == true)

        let second = try await agent.createBrowserPane(url: server.url("/other"))
        let third = try await agent.createBrowserPane(url: server.url("/other"))
        #expect(try await pageState() == before)
        #expect(try await agent.closePane(third).ok)
        #expect(try await pageState() == before)
        #expect(try await agent.closePane(second).ok)
        #expect(try await pageState() == before)
    }
}
