import AppKit
import Foundation
import TabsPluginSDK
import Testing

@testable import TabsCore

/// The navigation verbs (docs/BROWSER.md J-1…J-5, J-24, F-3…F-5, G-1, G-2), run as an agent's
/// `tabs-ctl` runs them: through the control plane, from a stand-in shell pane, against a real
/// page engine and the standard fixture pages (`e2e/external-control-flow.spec.ts`,
/// `e2e/external-control.spec.ts`).
@MainActor
@Suite struct BrowserNavigationVerbTests {
    let harness: PluginHarness
    let plugin = BrowserPlugin()

    init() throws {
        let plugin = plugin
        harness = try PluginHarness(withAgent: true) { plugin }
    }

    func ctl(_ command: String, _ flags: [String: JSONValue] = [:]) async -> JSONValue {
        await harness.tabsCtl(command, flags)
    }

    func result(_ response: JSONValue, sourceLocation: SourceLocation = #_sourceLocation) -> JSONValue {
        #expect(response["ok"] == true, "\(response)", sourceLocation: sourceLocation)
        return response["result"] ?? .null
    }

    /// `create-browser-pane`, answering the new pane's id.
    func create(_ url: String) async throws -> PaneID {
        let created = result(await ctl("create-browser-pane", ["url": .string(url)]))
        return PaneID(try #require(created["paneId"]?.stringValue, "\(created)"))
    }

    func page(_ pane: PaneID) throws -> BrowserPage {
        try #require(harness.controller(of: pane, as: BrowserPane.self)).page
    }

    // MARK: create-browser-pane

    /// "navigation verbs wait for the page and report load failures by name" (create half): the create itself
    /// waited for the page, and a dead origin still yields the pane with the failure beside its id.
    @Test func navigationVerbsWaitForThePageAndReportLoadFailuresByName() async throws {
        let server = try await FixtureServer.startStandard()
        defer { server.stop() }
        let created = result(await ctl("create-browser-pane", ["url": .string(server.url())]))
        let pane = try #require(created["paneId"]?.stringValue)
        #expect(created["loaded"] == true, "the create itself waited for the fixture page")
        let text = result(await ctl("get-page-text", ["pane": .string(pane)]))
        #expect(text["text"]?.stringValue?.contains("Hello from the fixture") == true)

        // A connection-refused load is a hard failure with the code in the error: "is my dev server actually up".
        let dead = try await FixtureServer.deadOrigin()
        let refused = await ctl("navigate", ["pane": .string(pane), "url": .string(dead)])
        #expect(refused["ok"] == false)
        #expect(refused["error"]?.stringValue?.contains("ERR_CONNECTION_REFUSED") == true, "\(refused)")
        #expect(refused["error"]?.stringValue?.hasPrefix("failed to load \(dead): ") == true)

        // A 404 is a *successful* load of an error page, not a load failure.
        let missing = result(await ctl("navigate", ["pane": .string(pane), "url": .string(server.url("/missing"))]))
        #expect(missing["loaded"] == true)

        // Creating a pane against a dead origin still yields the pane, with the failure beside it.
        let deadPane = result(await ctl("create-browser-pane", ["url": .string(dead)]))
        #expect(deadPane["paneId"]?.stringValue != nil)
        #expect(deadPane["loaded"] == false)
        #expect(deadPane["loadError"]?.stringValue?.contains("ERR_CONNECTION_REFUSED") == true)
    }

    /// J-1: the answer is the pane's id, the load's outcome and where the page is.
    @Test func createBrowserPaneAnswersWithThePageItLoaded() async throws {
        let server = try await FixtureServer.startStandard()
        defer { server.stop() }
        let created = result(await ctl("create-browser-pane", ["url": .string(server.url("/other"))]))
        #expect(created["loaded"] == true && created["url"] == .string(server.url("/other")) && created["title"] == "Elsewhere")
        #expect(created["status"] == 200 && created["statusText"] == "OK")
        #expect(created["redirected"] == false)
        #expect(created["loadError"] == nil && created["titleFromUrl"] == nil)
        let blank = result(await ctl("create-browser-pane", ["url": "about:blank"]))
        #expect(blank["loaded"] == true && blank["url"] == "about:blank" && blank["redirected"] == false)
        #expect(blank["status"] == nil, "no HTTP answer behind about:blank")
    }

    /// F-5: "a disallowed URL scheme is rejected without touching the pane tree".
    @Test func aDisallowedURLSchemeIsRejectedWithoutTouchingThePaneTree() async throws {
        let before = harness.engine.model.windows.flatMap(\.leaves).count
        let created = await ctl("create-browser-pane", ["url": "file:///etc/passwd"])
        #expect(created["ok"] == false)
        #expect(created["error"]?.stringValue?.contains("url not allowed") == true, "\(created)")
        #expect(created["error"] == "url not allowed: file:///etc/passwd")
        #expect(harness.engine.model.windows.flatMap(\.leaves).count == before, "no pane was made")
        #expect(harness.runtime.panes.panes(ofType: "browser").isEmpty)

        let pane = try await create("about:blank")
        for url in ["file:///etc/hosts", "javascript:alert(1)", "data:text/html,x", "ftp://example.com/", "not a url"] {
            let refused = await ctl("navigate", ["pane": .string(pane.rawValue), "url": .string(url)])
            #expect(refused["error"] == .string("url not allowed: \(url)"), "\(url): \(refused)")
        }
    }

    /// J-1, A-7: "create-browser-pane is refused while the browser content type is turned off": the message names
    /// where to undo it, the pane made earlier stays drivable and listed, and turning it back on restores creation.
    @Test func createBrowserPaneIsRefusedWhileTheBrowserContentTypeIsTurnedOff() async throws {
        let owned = try await create("about:blank")
        harness.runtime.host.setUserEnabled(false, for: "browser")
        let refused = await ctl("create-browser-pane", ["url": "about:blank"])
        #expect(refused["ok"] == false)
        #expect(refused["error"]?.stringValue?.contains("Content types") == true, "\(refused)")
        #expect(refused["error"]?.stringValue?.contains("Settings → General → Content types") == true)

        #expect(result(await ctl("navigate", ["pane": .string(owned.rawValue), "url": "about:blank"])) != .null)
        #expect(result(await ctl("list-panes"))["panes"]?[0]?["paneId"] == .string(owned.rawValue))
        #expect(result(await ctl("list-panes"))["panes"]?[1] == nil)

        harness.runtime.host.setUserEnabled(true, for: "browser")
        let allowed = await ctl("create-browser-pane", ["url": "about:blank"])
        #expect(allowed["ok"] == true, "\(allowed)")
    }

    /// H-12: create-browser-pane registers a new pane's ownership partway through, so a batch refuses it by name.
    @Test func createBrowserPaneCannotBeUsedInsideABatch() async throws {
        let before = harness.runtime.panes.panes(ofType: "browser").count
        let batched = await ctl(
            "batch", ["requests": .string(#"[{"type":"createBrowserPane","url":"about:blank"}]"#)])
        #expect(batched["ok"] == false)
        #expect(batched["error"]?.stringValue?.contains("createBrowserPane cannot be used inside a batch") == true, "\(batched)")
        #expect(harness.runtime.panes.panes(ofType: "browser").count == before)
    }

    /// "an agent can create and control a browser pane it owns, but no other" (verbs half): ownership is the
    /// caller's, the pane is not the active one's keyboard, and another caller is refused.
    @Test func anAgentCanCreateAndControlABrowserPaneItOwnsButNoOther() async throws {
        let pane = try await create("about:blank")
        #expect(harness.runtime.panes.ownership.owner(of: pane) == harness.agentPane)
        let navigated = await ctl("navigate", ["pane": .string(pane.rawValue), "url": "about:blank"])
        #expect(navigated["ok"] == true)
        let rejected = await ctl("navigate", ["pane": "not-a-pane-this-agent-created", "url": "about:blank"])
        #expect(rejected == ["ok": false, "error": "not the owner of this pane"])
        // The caller's own pane, and one the user opened by hand, are not the agent's to drive.
        let own = await ctl("navigate", ["pane": .string(harness.agentPane.rawValue), "url": "about:blank"])
        #expect(own["error"] == "not the owner of this pane")
        let byHand = try #require(harness.open("browser"))
        let foreign = await ctl("get-page-text", ["pane": .string(byHand.id.rawValue)])
        #expect(foreign["error"] == "not the owner of this pane")
    }

    /// "one agent cannot drive a pane another agent created": the check is who created it, not whether the id resolves.
    @Test func oneAgentCannotDriveAPaneAnotherAgentCreated() async throws {
        let pane = try await create("about:blank")
        let other = try #require(harness.open("harness-agent"))
        let stolen = await harness.tabsCtl("navigate", ["pane": .string(pane.rawValue), "url": "about:blank"], from: other.id)
        #expect(stolen == ["ok": false, "error": "not the owner of this pane"])
        #expect(await harness.tabsCtl("list-panes", from: other.id) == ["ok": true, "result": ["panes": []]])
    }

    /// J-24: a pane that exists but isn't a browser.
    @Test func aPaneThatIsNotABrowserIsRefusedByName() async throws {
        let pane = try await create("about:blank")
        // The agent owns a terminal-ish pane too (a stub of another type made on its behalf).
        let stub = try #require(
            harness.runtime.panes.openPane(PaneRequest(type: "harness-agent", placement: .tab(near: nil), controlledBy: harness.agentPane)))
        let refused = await ctl("navigate", ["pane": .string(stub.rawValue), "url": "about:blank"])
        #expect(refused["error"] == "target is not a browser pane", "\(refused)")
        _ = pane
    }

    // MARK: Placement (G-1, G-2)

    /// Every split of the window's docked tree.
    private func splits(in window: WindowLayout) -> [Split] {
        func walk(_ node: LayoutNode) -> [Split] {
            switch node {
            case .leaf: []
            case .tabs(let group): group.tabs.flatMap { walk($0.content) }
            case .split(let split): [split] + split.children.flatMap(walk)
            }
        }
        return walk(window.rootNode)
    }

    private func placed(_ setting: NewPanePlacement) async throws -> (pane: PaneID, window: WindowLayout) {
        plugin.services?.settings.update { $0.controlledPanePlacement = setting }
        let pane = try await create("about:blank")
        let window = try #require(harness.engine.model.window(holding: pane))
        return (pane, window)
    }

    /// "create-browser-pane splits <direction>ly when placement is set to <placement>" (2).
    @Test func createBrowserPaneSplitsHorizontallyWhenPlacementIsSetToSplitHorizontal() async throws {
        let (pane, window) = try await placed(.splitHorizontal)
        let split = try #require(splits(in: window).first)
        #expect(split.direction == .horizontal)
        #expect(split.children.map(\.id).contains(pane) && split.children.map(\.id).contains(harness.agentPane))
        #expect(split.children.map(\.id) == [harness.agentPane, pane], "the new pane after the caller's")
    }

    @Test func createBrowserPaneSplitsVerticallyWhenPlacementIsSetToSplitVertical() async throws {
        let (pane, window) = try await placed(.splitVertical)
        let split = try #require(splits(in: window).first)
        #expect(split.direction == .vertical)
        #expect(split.children.map(\.id) == [harness.agentPane, pane])
    }

    /// "create-browser-pane opens its own unpinned window when placement is set to unpinned": the docked root is untouched.
    @Test func createBrowserPaneOpensItsOwnUnpinnedWindowWhenPlacementIsSetToUnpinned() async throws {
        let (pane, window) = try await placed(.unpinned)
        #expect(window.floatingPane(holding: pane) != nil)
        #expect(window.rootNode.leaves.map(\.id).contains(pane) == false, "not docked anywhere")
        #expect(window.rootNode.leaves.map(\.id).contains(harness.agentPane), "the caller's own pane never moved")
    }

    /// G-1: the default is a new tab beside the caller.
    @Test func createBrowserPaneOpensANewTabByDefault() async throws {
        let (pane, window) = try await placed(.tab)
        let tab = try #require(window.root.tabs.first { $0.content.leaves.map(\.id).contains(pane) })
        #expect(tab.content.leaves.map(\.id) == [pane])
        #expect(window.root.tabs.count == 2, "beside the caller's own tab")
    }

    /// J-1: a floating caller's own window takes the new tab; `unpinned` opens a window of its own near it.
    @Test func aFloatingCallersNewPaneOpensInsideItsWindowOrInAnotherFloatingOne() async throws {
        let floater = try #require(
            harness.runtime.panes.openPane(PaneRequest(type: "harness-agent", placement: .floating(near: harness.agentPane))))
        let created = result(await harness.tabsCtl("create-browser-pane", ["url": "about:blank"], from: floater))
        let pane = PaneID(try #require(created["paneId"]?.stringValue))
        let window = try #require(harness.engine.model.window(holding: pane))
        let float = try #require(window.floatingPane(holding: floater))
        #expect(float.content.leaves.map(\.id).contains(pane), "inside the caller's own floating window")
        #expect(harness.runtime.panes.ownership.owner(of: pane) == floater)

        plugin.services?.settings.update { $0.controlledPanePlacement = .unpinned }
        let other = result(await harness.tabsCtl("create-browser-pane", ["url": "about:blank"], from: floater))
        let unpinned = PaneID(try #require(other["paneId"]?.stringValue))
        let own = try #require(harness.engine.model.window(holding: unpinned)?.floatingPane(holding: unpinned))
        #expect(own.id != float.id, "a floating window of its own")
    }

    /// G-2: the setting only affects create-browser-pane; a browser opened by hand never reads it.
    @Test func aBrowserOpenedByHandNeverReadsThePlacementSetting() async throws {
        plugin.services?.settings.update { $0.controlledPanePlacement = .unpinned }
        let byHand = try #require(harness.open("browser"))
        let window = try #require(harness.engine.model.window(holding: byHand.id))
        #expect(window.floatingPane(holding: byHand.id) == nil)
    }

    /// The agent's pane doesn't take the keyboard from the caller (`agentCreated`), once.
    @Test func anAgentsPaneDoesNotTakeTheKeyboardFromItsCaller() async throws {
        let pane = try await create("about:blank")
        let live = try #require(harness.engine.live(pane))
        #expect(live.consumeKeyboardExemption(), "activates: false")
        #expect(!live.consumeKeyboardExemption(), "spent once")
    }

    /// "createBrowserPane grants ownership as soon as the pane exists, not only once its own relay resolves" and F-3:
    /// the pane is owned, and its controller known, before the verb answers: while the first load is still pending.
    @Test func createBrowserPaneGrantsOwnershipAsSoonAsThePaneExistsNotOnlyOnceItsOwnRelayResolves() async throws {
        let server = try await FixtureServer.startStandard()
        defer { server.stop() }
        let agent = harness.agentPane
        let harness = harness
        let created = Task { @MainActor in
            await harness.tabsCtl("create-browser-pane", ["url": .string(server.url("/slow"))])
        }
        // /slow answers after a second: this probes through an independent request while the create is still waiting.
        try await Task.sleep(for: .milliseconds(300))
        let listed = result(await ctl("list-panes"))
        #expect(listed["panes"]?[0] != nil, "listed while the create is pending: \(listed)")
        let owned = try #require(listed["panes"]?[0]?["paneId"]?.stringValue)
        #expect(harness.runtime.panes.ownership.owner(of: PaneID(owned)) == agent)
        let browser = try #require(harness.controller(of: PaneID(owned), as: BrowserPane.self))
        #expect(browser.controller() == agent, "the guards read it live, from the first load")
        #expect(browser.page.isControlled())
        let answer = await created.value
        #expect(answer["ok"] == true && answer["result"]?["paneId"] == .string(owned))
    }

    /// F-3, F-4: the very first load already runs under the scheme allowlist, and the created pane's popups are denied.
    @Test func aPageScriptCannotSteerAnAgentPaneOutsideTheSchemeAllowlist() async throws {
        let server = try await FixtureServer.startStandard()
        defer { server.stop() }
        let pane = try await create(server.url())
        let page = try page(pane)
        // The verb-level check is the front door; this is the back door: a navigation the *page* starts.
        _ = await page.evaluate("(location.href = 'file:///etc/hosts')")
        try await Task.sleep(for: .milliseconds(500))
        let info = result(await ctl("pane-info", ["pane": .string(pane.rawValue)]))
        #expect(info["url"] == .string(server.url()))
        let text = result(await ctl("get-page-text", ["pane": .string(pane.rawValue)]))
        #expect(text["text"]?.stringValue?.contains("Hello from the fixture") == true)
    }

    // MARK: navigate

    /// "navigation verbs report where the pane actually ended up".
    @Test func navigationVerbsReportWhereThePaneActuallyEndedUp() async throws {
        let server = try await FixtureServer.startStandard()
        defer { server.stop() }
        // The first load server-redirects: loaded says a load settled, url says where it went, redirected says
        // it wasn't the URL asked for.
        let created = result(await ctl("create-browser-pane", ["url": .string(server.url("/redirect"))]))
        let pane = try #require(created["paneId"]?.stringValue)
        #expect(created["loaded"] == true)
        #expect(created["url"] == .string(server.url("/other")))
        #expect(created["title"] == "Elsewhere")
        #expect(created["redirected"] == true)
        #expect(created["status"] == 200, "the status describes the landing document, not the 302 hop")

        // navigate through the same redirect reports the same trio; the URL comes back absolute.
        let bounced = result(await ctl("navigate", ["pane": .string(pane), "url": .string(server.url("/redirect"))]))
        #expect(bounced["loaded"] == true && bounced["url"] == .string(server.url("/other")))
        #expect(bounced["title"] == "Elsewhere" && bounced["redirected"] == true && bounced["status"] == 200)

        // A straight load answers redirected: false.
        let straight = result(await ctl("navigate", ["pane": .string(pane), "url": .string(server.url())]))
        #expect(straight["loaded"] == true && straight["url"] == .string(server.url()))
        #expect(straight["redirected"] == false && straight["status"] == 200)
        #expect(straight["titleFromUrl"] == nil, "the fixture titles itself with a real <title>")

        // reload and history report the landing page too, with no `redirected`.
        let reloaded = result(await ctl("reload", ["pane": .string(pane)]))
        #expect(reloaded["url"] == .string(server.url()) && reloaded["title"] == "Fixture")
        #expect(reloaded["redirected"] == nil && reloaded["status"] == 200)
        let back = result(await ctl("go-back", ["pane": .string(pane)]))
        #expect(back["url"] == .string(server.url("/other")) && back["title"] == "Elsewhere")

        // A 404 loads "successfully": status, not loaded, answers "is this page real".
        let missing = result(await ctl("navigate", ["pane": .string(pane), "url": .string(server.url("/missing"))]))
        #expect(missing["loaded"] == true && missing["status"] == 404 && missing["statusText"] == "Not Found")
        #expect(missing["titleFromUrl"] == true, "a plain-text 404 page never titles itself either")
    }

    /// A page that sends itself elsewhere from script while it loads (during parse, from its load event) is a
    /// redirect too: the verbs answer for where the pane ended up, as Electron's do (its load is superseded), and
    /// `--retry-on-redirect` sees the bounce.
    @Test(arguments: ["/js-redirect", "/onload-redirect"])
    func aScriptRedirectWhileThePageLoadsIsReportedAsARedirect(path: String) async throws {
        let server = try await FixtureServer.startStandard()
        defer { server.stop() }
        let created = result(await ctl("create-browser-pane", ["url": .string(server.url(path))]))
        let pane = try #require(created["paneId"]?.stringValue)
        #expect(created["url"] == .string(server.url("/other")) && created["title"] == "Elsewhere")
        #expect(created["loaded"] == true && created["redirected"] == true)

        let straight = result(await ctl("navigate", ["pane": .string(pane), "url": .string(server.url())]))
        #expect(straight["redirected"] == false)
        let bounced = result(await ctl("navigate", ["pane": .string(pane), "url": .string(server.url(path))]))
        #expect(bounced["url"] == .string(server.url("/other")) && bounced["title"] == "Elsewhere")
        #expect(bounced["loaded"] == true && bounced["redirected"] == true)

        let retried = result(await ctl("navigate", ["pane": .string(pane), "url": .string(server.url(path)), "retry-on-redirect": true]))
        #expect(retried["retried"] == true && retried["firstUrl"] == .string(server.url("/other")))
        #expect(retried["url"] == .string(server.url("/other")) && retried["redirected"] == true, "the redirect stood")
        #expect(server.requests.filter { $0.path == path }.count == 4, "created, navigated, and asked twice by the retry")
    }

    /// When the page a script redirect leads to is what fails, the failure names that page, not the one asked for,
    /// which loaded fine.
    @Test func aScriptRedirectToAPageThatFailsNamesThatPage() async throws {
        let server = try await FixtureServer.startStandard()
        defer { server.stop() }
        let dead = try await FixtureServer.deadOrigin()
        server.page("/to-dead", title: "R", body: "<script>location.replace(\(jsonQuoted(dead)))</script>")
        let pane = try await create(server.url())
        let failed = await ctl("navigate", ["pane": .string(pane.rawValue), "url": .string(server.url("/to-dead"))])
        #expect(failed["ok"] == false)
        let error = failed["error"]?.stringValue ?? ""
        #expect(error.hasPrefix("failed to load \(dead) (where \(server.url("/to-dead")) sent itself): ERR_"), "\(failed)")
    }

    /// "--retry-on-redirect re-asserts the requested URL once after a bounce".
    @Test func retryOnRedirectReassertsTheRequestedURLOnceAfterABounce() async throws {
        let server = try await FixtureServer.startStandard()
        defer { server.stop() }
        let pane = try await create(server.url())
        let id = JSONValue.string(pane.rawValue)

        // Without the flag the bounce is reported, never fought.
        let deep = server.url("/bounce-once/no-retry-\(UUID().uuidString)")
        let reported = result(await ctl("navigate", ["pane": id, "url": .string(deep)]))
        #expect(reported["url"] == .string(server.url("/other")) && reported["redirected"] == true)
        #expect(reported["retried"] == nil)

        // With it: one automatic re-issue lands the deep link, and both attempts' landings are visible.
        let deepRetry = server.url("/bounce-once/retry-\(UUID().uuidString)")
        let retried = result(await ctl("navigate", ["pane": id, "url": .string(deepRetry), "retry-on-redirect": true]))
        #expect(retried["loaded"] == true && retried["url"] == .string(deepRetry) && retried["title"] == "Deep link")
        #expect(retried["redirected"] == false && retried["retried"] == true && retried["firstUrl"] == .string(server.url("/other")))

        // A page that redirects every time still earns exactly one retry, and the answer says the redirect stood.
        let always = result(await ctl("navigate", ["pane": id, "url": .string(server.url("/redirect")), "retry-on-redirect": true]))
        #expect(always["url"] == .string(server.url("/other")) && always["redirected"] == true)
        #expect(always["retried"] == true && always["firstUrl"] == .string(server.url("/other")))
        #expect(server.requests.filter { $0.path == "/redirect" }.count == 2, "asked twice, no more")

        // A pane that is already where it was asked to be is not "elsewhere": no retry.
        let same = result(await ctl("navigate", ["pane": id, "url": .string(server.url()), "retry-on-redirect": true]))
        #expect(same["retried"] == nil && same["redirected"] == false)
    }

    /// The retry that fails says it was the retry, and where the first attempt landed.
    @Test func aFailingRetryIsSaidToBeTheRetry() async throws {
        let server = try await FixtureServer.startStandard()
        defer { server.stop() }
        let dead = try await FixtureServer.deadOrigin()
        let token = UUID().uuidString
        // The first request redirects to a dead origin's page, so the second attempt's failure is the retry's.
        let hits = Hits()
        server.route("/flaky") { _ in
            hits.count += 1
            return hits.count == 1 ? .redirect(to: server.url("/other")) : .redirect(to: dead)
        }
        _ = token
        let pane = try await create(server.url())
        let failed = await ctl(
            "navigate", ["pane": .string(pane.rawValue), "url": .string(server.url("/flaky")), "retry-on-redirect": true])
        #expect(failed["ok"] == false)
        let error = try #require(failed["error"]?.stringValue)
        #expect(error.hasPrefix("failed to load \(server.url("/flaky")): "), "\(error)")
        #expect(error.hasSuffix("(on the retry — the first attempt landed on \(server.url("/other")))"), "\(error)")
    }

    final class Hits: @unchecked Sendable { var count = 0 }

    /// "a title the page sets after load-settle is flagged as a URL fallback".
    @Test func aTitleThePageSetsAfterLoadSettleIsFlaggedAsAURLFallback() async throws {
        let server = try await FixtureServer.startStandard()
        defer { server.stop() }
        let pane = try await create(server.url())
        // The SPA shape: no <title> in the HTML, the real one set by script after the load settles.
        let late = result(await ctl("navigate", ["pane": .string(pane.rawValue), "url": .string(server.url("/late-title"))]))
        #expect(late["loaded"] == true && late["titleFromUrl"] == true)
        #expect(late["title"] != "Set later")
        // The live title lands moments later exactly where the flag points.
        #expect(
            await eventually {
                (try? self.page(pane).title) == "Set later"
            })
        let info = result(await ctl("pane-info", ["pane": .string(pane.rawValue)]))
        #expect(info["title"] == "Set later")
    }

    /// "titleFromUrl is correct on reload and history steps, not only navigate": read from the document, not tracked from events.
    @Test func titleFromUrlIsCorrectOnReloadAndHistoryStepsNotOnlyNavigate() async throws {
        let server = try await FixtureServer.startStandard()
        defer { server.stop() }
        let pane = try await create(server.url("/missing"))
        let id = JSONValue.string(pane.rawValue)
        let missing = result(await ctl("navigate", ["pane": id, "url": .string(server.url("/missing"))]))
        #expect(missing["titleFromUrl"] == true)
        let other = result(await ctl("navigate", ["pane": id, "url": .string(server.url("/other"))]))
        #expect(other["title"] == "Elsewhere" && other["titleFromUrl"] == nil)
        // A reload of an explicit-title page whose title does not change.
        let reloadedOther = result(await ctl("reload", ["pane": id]))
        #expect(reloadedOther["title"] == "Elsewhere" && reloadedOther["titleFromUrl"] == nil)
        let backToMissing = result(await ctl("navigate", ["pane": id, "url": .string(server.url("/missing"))]))
        #expect(backToMissing["titleFromUrl"] == true)
        // A reload of a URL-derived page: also unchanged, also must stay flagged.
        #expect(result(await ctl("reload", ["pane": id]))["titleFromUrl"] == true)
        // go-back lands on the explicit-title page: the flag clears. go-forward lands on the URL-derived one: it sets.
        let back = result(await ctl("go-back", ["pane": id]))
        #expect(back["title"] == "Elsewhere" && back["titleFromUrl"] == nil)
        #expect(result(await ctl("go-forward", ["pane": id]))["titleFromUrl"] == true)
    }

    // MARK: reload, go-back, go-forward

    /// "reload and history verbs settle on the page they land on".
    @Test func reloadAndHistoryVerbsSettleOnThePageTheyLandOn() async throws {
        let server = try await FixtureServer.startStandard()
        defer { server.stop() }
        let pane = try await create(server.url())
        let id = JSONValue.string(pane.rawValue)
        let page = try page(pane)
        // Mutate page state, then reload: the state must be gone, proving a real fresh document.
        _ = await page.evaluate("(document.getElementById('status').textContent = 'clicked', 1)")
        #expect(await page.evaluate("document.getElementById('status').textContent") == .success("clicked"))
        let reloaded = result(await ctl("reload", ["pane": id]))
        #expect(reloaded["loaded"] == true)
        #expect(await page.evaluate("document.getElementById('status').textContent") == .success("idle"))

        _ = result(await ctl("navigate", ["pane": id, "url": .string(server.url("/other"))]))
        let back = result(await ctl("go-back", ["pane": id]))
        #expect(back["loaded"] == true && back["title"] == "Fixture")
        #expect(result(await ctl("pane-info", ["pane": id]))["title"] == "Fixture")
        let forward = result(await ctl("go-forward", ["pane": id]))
        #expect(forward["title"] == "Elsewhere")

        // The history edge is an error that says which way was empty, not a no-op.
        let tooFar = await ctl("go-forward", ["pane": id])
        #expect(tooFar == ["ok": false, "error": "cannot go forward — no later page in this pane's history"])
        _ = result(await ctl("go-back", ["pane": id]))
        let noEarlier = await ctl("go-back", ["pane": id])
        #expect(noEarlier == ["ok": false, "error": "cannot go back — no earlier page in this pane's history"])
    }

    /// J-3: a pane on its starting blank reloads and answers as a settled blank.
    @Test func reloadingAFreshPaneAnswersAsASettledBlank() async throws {
        let pane = try await create("about:blank")
        let reloaded = result(await ctl("reload", ["pane": .string(pane.rawValue)]))
        #expect(reloaded["loaded"] == true && reloaded["url"] == "about:blank" && reloaded["status"] == nil)
    }

    /// "landing on a failed page reports the failure, whichever verb got there".
    @Test func landingOnAFailedPageReportsTheFailureWhicheverVerbGotThere() async throws {
        let server = try await FixtureServer.startStandard()
        defer { server.stop() }
        let pane = try await create(server.url())
        let id = JSONValue.string(pane.rawValue)
        let dead = try await FixtureServer.deadOrigin()
        func info() async -> JSONValue { result(await ctl("pane-info", ["pane": id])) }
        func fixtureConsole() -> Int {
            ((try? self.page(pane))?.console.list() ?? []).filter { $0.text == "fixture ready" }.count
        }
        func listedURL() async -> JSONValue? {
            result(await ctl("list-panes"))["panes"].flatMap { panes in
                if case .array(let all) = panes { all.first { $0["paneId"] == id }?["url"] } else { nil }
            }
        }
        #expect(fixtureConsole() == 1)

        #expect(await ctl("navigate", ["pane": id, "url": .string(dead)])["ok"] == false)
        let failedInfo = await info()
        #expect(failedInfo["url"] == .string(dead) && failedInfo["showingErrorPage"] == true)
        #expect(fixtureConsole() == 0, "the fixture page's console belonged to the fixture page")
        // What a re-created pane would come back on (list-panes reads config.url).
        #expect(await listedURL() == .string(dead))

        // Back onto the failed entry from a 200 page.
        let other = result(await ctl("navigate", ["pane": id, "url": .string(server.url("/other"))]))
        #expect(other["status"] == 200)
        let back = result(await ctl("go-back", ["pane": id]))
        #expect(back["loaded"] == false && back["url"] == .string(dead))
        #expect(back["loadError"]?.stringValue?.contains("ERR_CONNECTION_REFUSED") == true, "\(back)")
        #expect(back["status"] == nil && back["statusText"] == nil)
        let reloaded = result(await ctl("reload", ["pane": id]))
        #expect(reloaded["loaded"] == false && reloaded["status"] == nil)

        // The other variant: the stale status was a 404's.
        let missing = result(await ctl("navigate", ["pane": id, "url": .string(server.url("/missing"))]))
        #expect(missing["status"] == 404)
        #expect(await ctl("navigate", ["pane": id, "url": .string(dead)])["ok"] == false)
        let reloadedAgain = result(await ctl("reload", ["pane": id]))
        #expect(reloadedAgain["loadError"]?.stringValue?.contains("ERR_CONNECTION_REFUSED") == true)
        #expect(reloadedAgain["status"] == nil)
    }

    // MARK: Budgets (H-10)

    /// The budgets `main/browserExternalControl.ts` prices: load 15 s + headroom, `create` 5 s + 15 s + headroom,
    /// `navigate` two loads + headroom, the read tier 15 s.
    @Test func theVerbsBudgetsAreTheElectronAppsTiers() throws {
        func budget(_ name: String) throws -> Duration {
            let verb = try #require(harness.runtime.registry.contribution(to: .controlVerbs, id: name)).value
            return ControlDispatcher.budget(of: verb, [:])
        }
        #expect(try budget("browser.createBrowserPane") == .milliseconds(5_000 + 15_000 + 5_000))
        #expect(try budget("browser.navigate") == .milliseconds(2 * 15_000 + 5_000))
        for name in ["browser.reload", "browser.goBack", "browser.goForward"] {
            #expect(try budget(name) == .milliseconds(15_000 + 5_000), "\(name)")
        }
        for name in ["browser.screenshot", "browser.getPageText", "browser.readPage", "browser.find"] {
            #expect(try budget(name) == .seconds(15), "\(name)")
        }
    }
}
