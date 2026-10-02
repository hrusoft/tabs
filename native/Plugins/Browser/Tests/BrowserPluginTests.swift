import AppKit
import TabsPluginSDK
import Testing

@testable import TabsCore

/// The browser plugin against the real core runtime, without the app
/// (docs/PLUGINS.md, Testing): what it contributes and how its pane reads and
/// writes its config. Case ids are docs/BROWSER.md's.
@MainActor
@Suite struct BrowserPluginTests {
    let harness: PluginHarness

    init() throws {
        harness = try PluginHarness { BrowserPlugin() }
    }

    @Test func activatesAsItsManifestDeclares() {
        #expect(harness.record?.state == .active)
        #expect(harness.manifest.contentTypes == ["browser"])
        #expect(harness.manifest.displayName == "Browser")
        #expect(harness.manifest.canDisable)
    }

    /// A-1, A-2, L-8: the creation action is "New browser" with the globe, seeded
    /// to open on `about:blank`; no directory is inherited from the pane it is made from.
    @Test func theCreationActionIsNewBrowserSeededToAboutBlank() throws {
        let contribution = try #require(harness.runtime.registry.contribution(to: .contentTypes, id: "browser"))
        #expect(contribution.value.displayName == "Browser")
        #expect(contribution.value.resolvedCreationLabel == "New browser")
        guard case .image(let icon) = contribution.value.icon else { Issue.record("the icon isn't the Electron app's globe"); return }
        #expect(icon.isTemplate && icon.size == NSSize(width: 16, height: 16))
        #expect(contribution.value.initialConfig(PaneCreation(origin: nil)) == ["url": "about:blank"])
        #expect(
            contribution.value.initialConfig(PaneCreation(origin: "other")) == ["url": "about:blank"],
            "a browser has no directory to inherit")
    }

    /// A-2: a browser pane opens with the seed config, on its blank page.
    @Test func aNewPaneStartsBlank() throws {
        let pane = try #require(harness.open("browser"))
        #expect(harness.config(of: pane.id) == ["url": "about:blank"])
        let browser = try #require(harness.controller(of: pane.id, as: BrowserPane.self))
        #expect(browser.page.url == "about:blank")
        #expect(!browser.page.hasCommitted)
        #expect(browser.toolbar == nil, "the header builds its chrome when it asks for it")
    }

    /// A-3: the address bar of a new pane reads about:blank.
    @Test func aNewPanesAddressBarReadsAboutBlank() throws {
        let pane = try #require(harness.open("browser"))
        let browser = try #require(harness.controller(of: pane.id, as: BrowserPane.self))
        _ = browser.headerTitle
        #expect(browser.toolbar?.bar.address == "about:blank")
        #expect(browser.toolbar?.bar.field.stringValue == "about:blank")
        #expect(browser.toolbar?.bar.title == "")
    }

    /// A-4: a pane restored from a saved layout resumes at its saved URL, never at the seed.
    @Test func aRestoredPaneLoadsItsSavedURL() async throws {
        let server = try await FixtureServer.start()
        defer { server.stop() }
        server.page("/saved", title: "Saved page")
        guard
            case .live(let restored) = harness.runtime.panes.restore(
                LayoutLeaf(id: "r", type: "browser", config: ["url": .string(server.url("/saved"))]), in: "w1")
        else { Issue.record("expected a live pane"); return }
        let browser = try #require(restored.controller as? BrowserPane)
        #expect(await eventually { browser.page.title == "Saved page" })
        #expect(browser.page.url == server.url("/saved"))
        #expect(restored.controller.currentConfig() == ["url": .string(server.url("/saved"))])
        #expect(!browser.page.canGoBack, "the starting page is never a Back target")
    }

    /// A-5: `config.url` follows every committed document, an in-page navigation and an error page.
    @Test func theConfigFollowsEveryNavigation() async throws {
        let server = try await FixtureServer.start()
        defer { server.stop() }
        server.page("/one", title: "One", body: "<a id=hash href='#part'>x</a>")
        server.page("/two", title: "Two")
        let dead = try await FixtureServer.closedPort()
        let pane = try #require(harness.open("browser"))
        let browser = try #require(harness.controller(of: pane.id, as: BrowserPane.self))
        browser.page.load(server.url("/one"))
        #expect(await eventually { harness.config(of: pane.id) == ["url": .string(server.url("/one"))] })
        browser.page.load(server.url("/two"))
        #expect(await eventually { harness.config(of: pane.id) == ["url": .string(server.url("/two"))] })
        // An in-page navigation, not a document.
        _ = await browser.page.evaluate("(history.pushState({}, '', '/two#pushed'), 1)")
        #expect(await eventually { harness.config(of: pane.id) == ["url": .string(server.url("/two#pushed"))] })
        // The error page a failed load commits: a re-created pane returns to the failed URL.
        let failed = "http://127.0.0.1:\(dead)/gone"
        browser.page.load(failed)
        #expect(await eventually { harness.config(of: pane.id) == ["url": .string(failed)] })
    }

    /// A-4: unknown keys in the saved config survive (only `url` is the pane's).
    @Test func keepsUnknownConfigKeys() async throws {
        let pane = try #require(harness.open("browser", config: ["url": "about:blank", "extra": 1]))
        #expect(harness.config(of: pane.id) == ["url": "about:blank", "extra": 1])
    }

    /// A-2, A-4: a pane made from a browser (a new tab or split "like" it) is a copy of it, as-is: where it is now,
    /// with the original's other keys; one made from anything else, or from nothing, is blank.
    @Test func aCopyOfABrowserStartsWhereTheOriginalIs() async throws {
        let server = try await FixtureServer.start()
        defer { server.stop() }
        server.page("/here", title: "Here")
        server.page("/there", title: "There")
        let original = try #require(harness.open("browser", config: ["url": .string(server.url("/here")), "extra": 1]))
        let browser = try #require(harness.controller(of: original.id, as: BrowserPane.self))
        #expect(await eventually { browser.page.title == "Here" })
        browser.page.load(server.url("/there"))
        #expect(await eventually { browser.page.title == "There" })
        let request = PaneRequest(type: "browser", placement: .tab(near: original.id), origin: original.id)
        let copy = try #require(harness.runtime.panes.openPane(request).flatMap(harness.engine.live))
        #expect(
            harness.config(of: copy.id) == ["url": .string(server.url("/there")), "extra": 1], "the page it is on now, not where it started"
        )
        let fresh = try #require(harness.open("browser"))
        #expect(harness.config(of: fresh.id) == ["url": "about:blank"])
    }

    /// A-6: a config the plugin can't read refuses the pane (core keeps it verbatim).
    @Test func aSavedConfigItCannotReadRefusesThePane() {
        #expect(harness.open("browser", config: ["url": 5]) == nil)
        #expect(harness.open("browser", config: "https://example.com") == nil)
        guard
            case .unavailable(let reason) = harness.runtime.panes.restore(
                LayoutLeaf(id: "bad", type: "browser", config: ["url": ["nested": true]]), in: "w1")
        else { Issue.record("expected an unavailable pane"); return }
        #expect(reason.contains("a browser's url must be a string"), "\(reason)")
    }

    /// A-6: what is missing takes its default: no URL is a blank page, and so is null.
    @Test func aMissingURLTakesTheDefault() throws {
        for config: JSONValue in [[:], ["url": .null], .null] {
            let pane = try #require(harness.open("browser", config: config))
            let browser = try #require(harness.controller(of: pane.id, as: BrowserPane.self))
            #expect(browser.page.url == "about:blank")
        }
    }

    /// A-8: nothing to lose; closing ends the page.
    @Test func hasNoCloseWarningAndClosingEndsThePage() throws {
        let pane = try #require(harness.open("browser"))
        let browser = try #require(harness.controller(of: pane.id, as: BrowserPane.self))
        #expect(browser.closeWarning == nil)
        var events: [PageEvent] = []
        browser.page.events.subscribe { events.append($0) }
        browser.paneWillClose()
        #expect(events.contains(.destroyed))
        #expect(harness.controller(of: pane.id, as: BrowserPane.self) != nil)
    }

    /// G-1, G-4: Settings ▸ Browser, with the globe; the value core stores is the four placements.
    @Test func contributesASettingsPage() throws {
        let page = try #require(harness.runtime.registry.contribution(to: .settingsPages, id: "browser"))
        #expect(page.value.title == "Browser")
        #expect(page.value.symbolName == "globe")
    }
}

/// Polls until `condition` holds; false if it doesn't within `timeout`.
@MainActor
func eventually(timeout: Duration = .seconds(10), _ condition: () -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while !condition() {
        guard ContinuousClock.now < deadline else { return false }
        try? await Task.sleep(for: .milliseconds(20))
    }
    return true
}
