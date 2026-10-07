import AppKit
import Foundation
import TabsPluginSDK
import Testing

@testable import TabsCore

/// What core's pane verbs say about a browser pane (docs/BROWSER.md C-7, C-8, E-4, E-5, H-3, H-11): `list-panes`,
/// `pane-info`, `activate-pane` and `close-pane` on panes an agent made.
@MainActor
@Suite struct BrowserControlPaneTests {
    let harness: PluginHarness

    init() throws {
        harness = try PluginHarness.browser(withAgent: true)
    }

    func ctl(_ command: String, _ flags: [String: JSONValue] = [:]) async -> JSONValue {
        await harness.tabsCtl(command, flags)
    }

    func result(_ response: JSONValue, sourceLocation: SourceLocation = #_sourceLocation) -> JSONValue {
        #expect(response["ok"] == true, "\(response)", sourceLocation: sourceLocation)
        return response["result"] ?? .null
    }

    func create(_ url: String) async throws -> PaneID {
        let created = result(await ctl("create-browser-pane", ["url": .string(url)]))
        return PaneID(try #require(created["paneId"]?.stringValue, "\(created)"))
    }

    func panes(_ response: JSONValue) -> [JSONValue] {
        if case .array(let all)? = response["panes"] { all } else { [] }
    }

    // MARK: list-panes

    /// "list-panes shows only the panes this caller created, and close-pane revokes ownership".
    @Test func listPanesShowsOnlyThePanesThisCallerCreatedAndClosePaneRevokesOwnership() async throws {
        let server = try await FixtureServer.startStandard()
        defer { server.stop() }
        // A browser the user opened by hand, which must never show up in an agent's listing.
        _ = try #require(harness.open("browser"))
        let pane = try await create(server.url("/other"))

        // C-8: {paneId, type, title, url}.
        let listed = result(await ctl("list-panes"))
        #expect(panes(listed).count == 1)
        let entry = try #require(panes(listed).first)
        #expect(entry["paneId"] == .string(pane.rawValue) && entry["type"] == "browser" && entry["url"] == .string(server.url("/other")))
        #expect(entry["title"] != nil)
        #expect(Set(entry.objectKeys) == ["paneId", "type", "title", "url"], "\(entry)")

        let closed = await ctl("close-pane", ["pane": .string(pane.rawValue)])
        #expect(closed["ok"] == true)
        #expect(harness.runtime.panes.contentType(of: pane) == nil)

        // Ownership is dropped with the pane, so the same id is no longer targetable: but the caller who closed it is
        // told the pane is *gone*, not that it was never theirs.
        let afterClose = await ctl("navigate", ["pane": .string(pane.rawValue), "url": "about:blank"])
        #expect(afterClose["ok"] == false)
        #expect(afterClose["error"]?.stringValue?.contains("no longer exists") == true)
        #expect(afterClose["error"]?.stringValue?.contains("not the owner") == false)
        #expect(panes(result(await ctl("list-panes"))).isEmpty)
    }

    /// C-8: `list-panes` reads the URL from config, so it works while unmounted, and follows every committed
    /// document (an error page's failed URL too).
    @Test func listPanesReportsTheUrlThePaneWouldBeSavedWith() async throws {
        let server = try await FixtureServer.startStandard()
        defer { server.stop() }
        let pane = try await create(server.url())
        let dead = try await FixtureServer.deadOrigin()
        func listedURL() async -> JSONValue? { panes(result(await ctl("list-panes"))).first?["url"] }
        #expect(await listedURL() == .string(server.url()))
        _ = await ctl("navigate", ["pane": .string(pane.rawValue), "url": .string(dead)])
        #expect(await listedURL() == .string(dead), "the failed URL: where a re-created pane returns")
        #expect(harness.config(of: pane) == ["url": .string(dead)])
        _ = await ctl("navigate", ["pane": .string(pane.rawValue), "url": .string(server.url("/other"))])
        #expect(await listedURL() == .string(server.url("/other")))
    }

    // MARK: pane-info

    /// C-7: the live fields, and the two flags that appear only when they are true.
    @Test func paneInfoReportsTheLivePageAndFlagsAnErrorPage() async throws {
        let server = try await FixtureServer.startStandard()
        defer { server.stop() }
        let pane = try await create(server.url())
        let id = JSONValue.string(pane.rawValue)
        let healthy = result(await ctl("pane-info", ["pane": id]))
        #expect(healthy["paneId"] == id && healthy["type"] == "browser")
        #expect(healthy["url"] == .string(server.url()) && healthy["title"] == "Fixture")
        #expect(healthy["isLoading"] == false && healthy["canGoBack"] == false && healthy["canGoForward"] == false)
        #expect(healthy["showingErrorPage"] == nil && healthy["loadError"] == nil)
        let instance = try #require(healthy["pageInstance"]?.stringValue)
        #expect(!instance.isEmpty)

        // A failed navigation leaves the error page showing, its URL still the address that was asked for.
        let dead = try await FixtureServer.deadOrigin()
        #expect(await ctl("navigate", ["pane": id, "url": .string(dead)])["ok"] == false)
        let errored = result(await ctl("pane-info", ["pane": id]))
        #expect(errored["showingErrorPage"] == true)
        #expect(errored["loadError"]?.stringValue?.contains("ERR_") == true)
        #expect(errored["url"] == .string(dead) && errored["canGoBack"] == true)

        // Recovering clears the flag: it describes the load in flight, not a sticky "this pane once failed" bit.
        _ = result(await ctl("navigate", ["pane": id, "url": .string(server.url())]))
        let healed = result(await ctl("pane-info", ["pane": id]))
        #expect(healed["showingErrorPage"] == nil && healed["loadError"] == nil)
        #expect(healed["pageInstance"] == .string(instance), "changes only when the page is re-created, never for a navigation")
    }

    /// C-7: a pane that isn't on screen has no viewport at all, never an invented one, and says so.
    @Test func paneInfoRefusesToInventAViewportForAPaneThatIsNotShown() async throws {
        let pane = try await create("about:blank")
        let info = result(await ctl("pane-info", ["pane": .string(pane.rawValue)]))
        #expect(info["hidden"] == true, "the harness has no window for the page")
        #expect(info["viewport"] == nil)
    }

    /// C-7: "pane-info" on a pane that isn't the caller's, or is gone.
    @Test func paneInfoRefusesAPaneThisCallerDoesNotOwnAndReportsAClosedOne() async throws {
        let foreign = try #require(harness.open("browser")).id
        #expect(await ctl("pane-info", ["pane": .string(foreign.rawValue)]) == ["ok": false, "error": "not the owner of this pane"])
        let pane = try await create("about:blank")
        harness.engine.close(pane)
        let gone = await ctl("pane-info", ["pane": .string(pane.rawValue)])
        #expect(gone["error"]?.stringValue?.contains("no longer exists") == true, "\(gone)")
    }

    // MARK: close-pane

    /// "close-pane refuses a pane this caller does not own": the caller's own pane included.
    @Test func closePaneRefusesAPaneThisCallerDoesNotOwn() async throws {
        let response = await ctl("close-pane", ["pane": .string(harness.agentPane.rawValue)])
        #expect(response == ["ok": false, "error": "not the owner of this pane"])
        #expect(harness.runtime.panes.contentType(of: harness.agentPane) != nil, "the caller's own pane is still standing")
    }

    /// A-8: closing a browser pane has nothing to warn about, and ends its page.
    @Test func closingABrowserPaneEndsItsPageWithoutAsking() async throws {
        let pane = try await create("about:blank")
        let browser = try #require(harness.controller(of: pane, as: BrowserPane.self))
        var ended = false
        let subscription = browser.page.events.subscribe { if $0 == .destroyed { ended = true } }
        defer { subscription.cancel() }
        #expect(browser.closeWarning == nil)
        #expect(result(await ctl("close-pane", ["pane": .string(pane.rawValue)])) == .null)
        #expect(harness.renderer.asked.isEmpty, "nothing to lose: the user was not asked")
        #expect(ended)
    }

    // MARK: activate-pane, E-5

    /// "activate-pane brings a backgrounded pane to the front so it can be captured": revealed, never activated.
    @Test func activatePaneBringsABackgroundedPaneToTheFrontWithoutStealingTheKeyboard() async throws {
        let pane = try await create("about:blank")
        let agent = harness.agentPane
        let window = try #require(harness.engine.model.window(holding: pane))
        #expect(window.isShowing(pane), "a new tab: shown, with the browser active")
        // The user goes back to the agent's tab: the browser is backgrounded.
        harness.engine.perform(in: window.id) { layout, titles in layout.reveal(agent, titles: titles) }
        #expect(harness.engine.model.window(window.id)?.isShowing(pane) == false)

        let activated = await ctl("activate-pane", ["pane": .string(pane.rawValue)])
        #expect(activated["ok"] == true)
        let after = try #require(harness.engine.model.window(window.id))
        #expect(after.isShowing(pane), "brought to the front")
        #expect(after.activeLeafID == agent, "but the user's active pane is still theirs: the keyboard is not stolen")
    }

    /// E-5: a hidden pane keeps its page running: the verbs answer for it (reads, waits, scripts) without revealing it.
    @Test func aBackgroundedPaneKeepsItsPageRunningAndAnswersTheReadVerbs() async throws {
        let server = try await FixtureServer.startStandard()
        defer { server.stop() }
        let pane = try await create(server.url())
        let id = JSONValue.string(pane.rawValue)
        let agent = harness.agentPane
        let window = try #require(harness.engine.model.window(holding: pane))
        harness.engine.perform(in: window.id) { layout, titles in layout.reveal(agent, titles: titles) }
        #expect(harness.engine.model.window(window.id)?.isShowing(pane) == false)
        let text = result(await ctl("get-page-text", ["pane": id]))
        #expect(text["text"]?.stringValue?.contains("Hello from the fixture") == true)
        let read = result(await ctl("read-page", ["pane": id]))
        #expect(read["elements"] != nil)
        #expect(result(await ctl("wait-for", ["pane": id, "text": "Hello from the fixture"]))["elapsedMs"] != nil)
        #expect(await ctl("assert", ["pane": id, "text": "Hello from the fixture"])["ok"] == true)
        #expect(result(await ctl("execute-js", ["pane": id, "code": "document.title"]))["value"] == "Fixture")
        #expect(harness.engine.model.window(window.id)?.isShowing(pane) == false, "none of it reveals the pane")
        #expect(harness.engine.model.window(window.id)?.activeLeafID == agent)
    }

    // MARK: E-4

    /// "an agent keeps driving and listing its pane after the user drags that pane into another window".
    @Test func anAgentKeepsDrivingAndListingItsPaneAfterTheUserDragsThatPaneIntoAnotherWindow() async throws {
        let server = try await FixtureServer.startStandard()
        defer { server.stop() }
        let pane = try await create(server.url())
        let id = JSONValue.string(pane.rawValue)
        let source = try #require(harness.engine.model.window(holding: pane)).id
        let other = try #require(harness.runtime.panes.openPane(PaneRequest(type: "harness-agent", placement: .window)))
        let destination = try #require(harness.engine.model.window(holding: other))
        #expect(destination.id != source)
        #expect(harness.engine.move(.pane(pane), from: source, to: destination.id, at: .tabBar(groupID: destination.root.id, index: 1)))
        #expect(harness.engine.model.window(holding: pane)?.id == destination.id, "the pane is in the other window now")

        let instance = result(await ctl("pane-info", ["pane": id]))["pageInstance"]
        let listed = result(await ctl("list-panes"))
        #expect(panes(listed).map { $0["paneId"] } == [id], "still listed")
        let text = result(await ctl("get-page-text", ["pane": id]))
        #expect(text["text"]?.stringValue?.contains("Hello from the fixture") == true, "still driven")
        let navigated = result(await ctl("navigate", ["pane": id, "url": .string(server.url("/other"))]))
        #expect(navigated["title"] == "Elsewhere")
        // E-1, E-6: a moved pane keeps its page: history, and the same instance.
        let info = result(await ctl("pane-info", ["pane": id]))
        #expect(info["canGoBack"] == true && info["pageInstance"] == instance)
    }
}

extension JSONValue {
    fileprivate var objectKeys: [String] {
        if case .object(let object) = self { Array(object.keys) } else { [] }
    }
}
