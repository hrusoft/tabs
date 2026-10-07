import AppKit
import Foundation
import TabsPluginSDK
import Testing

@testable import TabsCore

/// The read verbs (docs/BROWSER.md J-7…J-11, J-24, J-25), run as an agent's `tabs-ctl` runs them: through
/// the control plane, from a stand-in shell pane, against a real page engine and the standard fixture pages.
/// What needs a pane on screen (`screenshot`'s capture, `pane-info`'s viewport) is `BrowserSnapshotTests`' and
/// `BrowserPaneTests`', in a window that is never shown; a reveal is the UI tier's.
@MainActor
@Suite struct BrowserReadVerbTests {
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

    /// A pane an agent created on `url`, once the page has settled.
    func create(_ url: String) async throws -> (id: JSONValue, page: BrowserPage) {
        let created = result(await ctl("create-browser-pane", ["url": .string(url)]))
        let pane = PaneID(try #require(created["paneId"]?.stringValue, "\(created)"))
        return (.string(pane.rawValue), try #require(harness.controller(of: pane, as: BrowserPane.self)).page)
    }

    func elements(_ read: JSONValue) -> [JSONValue] {
        if case .array(let all)? = read["elements"] { all } else { [] }
    }

    // MARK: get-page-text

    /// "oversized results are truncated honestly, never silently" (the get-page-text half).
    @Test func oversizedResultsAreTruncatedHonestlyNeverSilently() async throws {
        let server = try await FixtureServer.startStandard()
        defer { server.stop() }
        let (id, _) = try await create(server.url())
        let clipped = result(await ctl("get-page-text", ["pane": id, "max-length": 10]))
        #expect(clipped["truncated"] == true)
        #expect(clipped["text"]?.stringValue?.count == 10)
        #expect(clipped["text"] == "Hello from")
        let whole = result(await ctl("get-page-text", ["pane": id]))
        #expect(whole["truncated"] == false, "always reported, not only when cut")
        #expect(whole["text"]?.stringValue?.contains("Hello from the fixture") == true)
    }

    /// J-7: the default limit is 50 000 and the hard cap 200 000, whatever a caller asks.
    @Test func thePageTextLimitsAreTheDefaultAndTheHardCap() async throws {
        let server = try await FixtureServer.startStandard()
        defer { server.stop() }
        server.page("/huge", title: "Huge", body: "<p>\(String(repeating: "x", count: 250_000))</p>")
        let (id, _) = try await create(server.url("/huge"))
        let byDefault = result(await ctl("get-page-text", ["pane": id]))
        #expect(byDefault["text"]?.stringValue?.utf16.count == 50_000 && byDefault["truncated"] == true)
        let raised = result(await ctl("get-page-text", ["pane": id, "max-length": 1_000_000]))
        #expect(raised["text"]?.stringValue?.utf16.count == 200_000 && raised["truncated"] == true, "capped at the hard maximum")
        let lowered = result(await ctl("get-page-text", ["pane": id, "max-length": 1]))
        #expect(lowered["text"] == "x")
        // Below the floor is refused by the flag, before anything is read.
        let zero = await ctl("get-page-text", ["pane": id, "max-length": 0])
        #expect(zero["ok"] == false && zero["error"]?.stringValue?.contains("at least 1") == true, "\(zero)")
    }

    /// J-7: the page's text is what is rendered: innerText, no script or style bodies, line breaks where the layout puts them.
    @Test func thePageTextIsWhatIsRenderedNotTheSource() async throws {
        let server = try await FixtureServer.startStandard()
        defer { server.stop() }
        server.page(
            "/text", title: "T", head: "<style>.x{color:red}</style>",
            body: "<h1>Head</h1><p>one</p><p>two</p><script>window.s = 'not shown'</script><div style='display:none'>hidden words</div>")
        let (id, _) = try await create(server.url("/text"))
        let text = try #require(result(await ctl("get-page-text", ["pane": id]))["text"]?.stringValue)
        #expect(text.contains("Head") && text.contains("one") && text.contains("two"))
        #expect(!text.contains("not shown") && !text.contains("color:red") && !text.contains("hidden words"))
        #expect(text.contains("\n"), "\(text.debugDescription)")
    }

    /// "tabs-ctl drains a response bigger than the pipe buffer instead of truncating it" (the verb half: the text is
    /// whole, past 64 KB, with its far end intact).
    @Test func aPageTextBiggerThanThePipeBufferComesBackWhole() async throws {
        let server = try await FixtureServer.startStandard()
        defer { server.stop() }
        let (id, _) = try await create(server.url("/bigtext"))
        let big = result(await ctl("get-page-text", ["pane": id, "max-length": 200_000]))
        let text = try #require(big["text"]?.stringValue)
        #expect(text.count > 65_536)
        #expect(text.contains("END-OF-BIGTEXT"))
    }

    // MARK: read-page

    /// "read-page narrows by role and selector, and pages by offset".
    @Test func readPageNarrowsByRoleAndSelectorAndPagesByOffset() async throws {
        let server = try await FixtureServer.startStandard()
        defer { server.stop() }
        let (id, page) = try await create(server.url("/listing"))

        // Bare read: capped, and the <select> really is out of reach.
        let bare = result(await ctl("read-page", ["pane": id]))
        #expect(elements(bare).count == 200)
        #expect(bare["truncated"] == true && bare["offset"] == 0)
        #expect((bare["total"]?.intValue ?? 0) > 240)
        #expect(!elements(bare).contains { $0["tag"] == "select" })

        // --role reaches it in one call.
        let byRole = result(await ctl("read-page", ["pane": id, "role": "combobox"]))
        #expect(elements(byRole).map { $0["tag"] } == ["select"])
        #expect(byRole["truncated"] == false && byRole["total"] == 1)

        // --selector reaches elements the default candidate set never lists at all.
        let images = result(await ctl("read-page", ["pane": id, "selector": #"img[alt]:not([alt=""])"#]))
        #expect(elements(images).map { $0["name"] } == ["Hero image", "Thumb image"])
        // So does a role only an image has: an image is `img`, a decorative one (alt="") `presentation`.
        let byImageRole = result(await ctl("read-page", ["pane": id, "role": "img"]))
        #expect(elements(byImageRole).map { $0["name"] } == ["Hero image", "Thumb image"])
        #expect(elements(byImageRole).allSatisfy { $0["role"] == "img" && $0["tag"] == "img" })
        let decorative = result(await ctl("read-page", ["pane": id, "role": "presentation"]))
        #expect(elements(decorative).map { $0["tag"] } == ["img"])
        let none = result(await ctl("read-page", ["pane": id, "role": "none"]))
        #expect(elements(none).map { $0["tag"] } == ["img"], "none is presentation's other name")

        // Paging: offset walks past the cap and reports where it is.
        let paged = result(await ctl("read-page", ["pane": id, "offset": 200]))
        #expect(paged["offset"] == 200 && paged["truncated"] == false)
        #expect(!elements(paged).contains { $0["tag"] == "img" }, "images stay out of a read that didn't ask for them")
        let sort = try #require(elements(paged).first { $0["tag"] == "select" })
        // Refs are minted for the returned page only, so a paged read hands back usable refs.
        let ref = try #require(sort["ref"]?.stringValue)
        #expect(ref.wholeMatch(of: /e\d+-[0-9a-z]+/) != nil, "\(ref)")
        #expect(await page.evaluate("\(refResolverExpression(ref))?.id") == .success("sort"), "the page resolves it")

        // A selector the page itself refuses is an error, never an empty list.
        let bad = await ctl("read-page", ["pane": id, "selector": "div:::nope"])
        #expect(bad["ok"] == false && bad["error"]?.stringValue?.contains("invalid selector") == true, "\(bad)")

        // A role that is no role is refused with the vocabulary.
        let unknownRole = await ctl("read-page", ["pane": id, "role": "nonsense"])
        #expect(unknownRole["ok"] == false)
        #expect(unknownRole["error"]?.stringValue?.contains("unknown role \"nonsense\"") == true, "\(unknownRole)")
        #expect(unknownRole["error"]?.stringValue?.contains("combobox") == true)

        // Wire-shape validation is host-side, since the socket carries untyped input.
        let negative = await ctl("read-page", ["pane": id, "offset": -3])
        #expect(negative["ok"] == false && negative["error"]?.stringValue?.contains("at least 0") == true, "\(negative)")
        let blank = await ctl("read-page", ["pane": id, "selector": "  "])
        #expect(blank["error"] == "selector must be a non-empty string")
        let fractional = await harness.wire(["type": "readPage", "targetPaneId": id, "offset": 1.5])
        #expect(
            fractional["error"] == "offset must be a non-negative integer (it is a 0-based index into the matching elements)",
            "\(fractional)")
    }

    /// "read-page names labelled controls as the browser does and reports checked state": the names are the page
    /// script's own derivation, so what WebKit's engine would compute doesn't enter.
    @Test func readPageNamesLabelledControlsAsTheBrowserDoesAndReportsCheckedState() async throws {
        let server = try await FixtureServer.startStandard()
        defer { server.stop() }
        let (id, _) = try await create(server.url("/controls"))
        func control(_ name: String) async -> JSONValue? {
            let response = await ctl("read-page", ["pane": id, "selector": .string("#\(name)")])
            #expect(response["ok"] == true, "\(response)")
            return elements(response["result"] ?? .null).first
        }
        func matches(_ element: JSONValue?, _ expected: [String: JSONValue]) -> Bool {
            expected.allSatisfy { element?[$0.key] == $0.value }
        }
        let colour = await control("colour")
        #expect(matches(colour, ["role": "combobox", "name": "Colour", "value": "r"]), "\(String(describing: colour))")
        let bare = await control("bare")
        #expect(matches(bare, ["role": "combobox", "name": "", "value": "Beta"]), "\(String(describing: bare))")
        let qty = await control("qty")
        #expect(matches(qty, ["role": "textbox", "name": "Qty of kg", "value": "3"]), "\(String(describing: qty))")
        let agree = await control("agree")
        #expect(matches(agree, ["role": "checkbox", "name": "Agree", "checked": false]), "\(String(describing: agree))")
        #expect(agree?["value"] == nil)
        #expect(matches(await control("subscribed"), ["checked": true]))
        #expect(matches(await control("some"), ["checked": "mixed"]))
        let small = await control("small")
        #expect(matches(small, ["role": "radio", "checked": true]))
        #expect(small?["value"] == nil)
        #expect(matches(await control("wifi"), ["role": "switch", "name": "Wi-Fi", "checked": true]))
    }

    // MARK: find

    /// "find mints refs only for the matches it returns": the ref counter is the page's own.
    @Test func findMintsRefsOnlyForTheMatchesItReturns() async throws {
        let server = try await FixtureServer.startStandard()
        defer { server.stop() }
        let (id, page) = try await create(server.url("/listing"))
        func refsMinted() async -> Int {
            if case .success(let value) = await page.evaluate("window.\(BrowserLimits.refCounter) ?? 0") {
                return Int(value.intValue ?? -1)
            }
            return -1
        }
        let before = await refsMinted()

        let found = result(await ctl("find", ["pane": id, "description": "Brand 7", "max-results": 2]))
        let matches = try #require(found["matches"])
        if case .array(let all) = matches { #expect(all.map { $0["name"] } == ["Brand 7", "Brand 70"]) }
        #expect(await refsMinted() == before + 2)

        // The refs it did mint are real: the best match is the checkbox by that name.
        let best = try #require(matches[0]?["ref"]?.stringValue)
        #expect(await page.evaluate("\(refResolverExpression(best))?.id") == .success("brand7"))

        // A find with nothing to return mints nothing at all.
        let none = result(await ctl("find", ["pane": id, "description": "checkout basket"]))
        #expect(none["matches"] == [])
        #expect(await refsMinted() == before + 2)
        // Each match carries the fields a caller acts on.
        let first = try #require(matches[0])
        for key in ["ref", "name", "role", "tag", "rect", "score"] { #expect(first[key] != nil, "\(key)") }
        #expect(first["role"] == "checkbox" && first["tag"] == "input")
    }

    // MARK: Readiness (J-11)

    /// "read verbs report readiness, and settled flips only with the DOM actually quiet".
    @Test func readVerbsReportReadinessAndSettledFlipsOnlyWithTheDOMActuallyQuiet() async throws {
        let server = try await FixtureServer.startStandard()
        defer { server.stop() }
        let (id, page) = try await create(server.url("/waity"))

        // The first read of a page is what starts the observation, so it can never certify quiet.
        let first = result(await ctl("read-page", ["pane": id]))
        #expect(!elements(first).isEmpty)
        #expect(first["isLoading"] == false && first["readyState"] == "complete")
        #expect(first["settled"] == false)

        // Re-reads share the tracker rather than restarting it: polling with the read itself is what pins that
        // reads don't reset the quiet clock.
        var settled = false
        let deadline = ContinuousClock.now + .seconds(15)
        while !settled, ContinuousClock.now < deadline {
            settled = result(await ctl("get-page-text", ["pane": id]))["settled"] == true
            if !settled { try await Task.sleep(for: .milliseconds(100)) }
        }
        #expect(settled)

        // find carries the same trio, from the same extraction.
        let found = result(await ctl("find", ["pane": id, "description": "waity"]))
        #expect(found["isLoading"] == false && found["readyState"] == "complete" && found["settled"] == true)

        // A change the test makes: a read right after it reports unsettled, and a later read reports the page
        // settled again once the quiet period has passed with no other.
        _ = await page.evaluate("window.appendReady('changed')")
        let changed = ContinuousClock.now
        let during = result(await ctl("read-page", ["pane": id]))
        #expect(during["settled"] == false)
        var settledAgain = false
        let end = ContinuousClock.now + .seconds(20)
        while !settledAgain, ContinuousClock.now < end {
            settledAgain = result(await ctl("read-page", ["pane": id]))["settled"] == true
            if !settledAgain { try await Task.sleep(for: .milliseconds(100)) }
        }
        #expect(settledAgain)
        #expect(ContinuousClock.now - changed >= .milliseconds(BrowserLimits.waitIdleQuietMs - 200), "not before the quiet period")
    }

    /// "read verbs report frame/shadow counts, and coordinate clicks reach inside both even though reads cannot"
    /// (the reads: the click half is the input verbs').
    @Test func readVerbsReportFrameAndShadowCounts() async throws {
        let server = try await FixtureServer.startStandard()
        defer { server.stop() }
        let (id, _) = try await create(server.url("/nested"))
        let read = result(await ctl("read-page", ["pane": id]))
        #expect(read["frames"] == 1 && read["shadowRoots"] == 1)
        let text = result(await ctl("get-page-text", ["pane": id]))
        #expect(text["frames"] == 1 && text["shadowRoots"] == 1)
        let found = result(await ctl("find", ["pane": id, "description": "button"]))
        #expect(found["frames"] == 1 && found["shadowRoots"] == 1)
        // The documented blindness: the top-document button is listed, neither the frame's nor the shadow's.
        let names = elements(read).compactMap { $0["name"]?.stringValue }
        #expect(names.contains("Top button") && !names.contains("Frame button") && !names.contains("Shadow button"), "\(names)")
        if case .array(let matches)? = found["matches"] {
            let matched = matches.compactMap { $0["name"]?.stringValue }
            #expect(!matched.contains("Frame button") && !matched.contains("Shadow button"), "\(matched)")
        }
        // A page with neither reports zero: always present.
        let plain = try await create(server.url("/other"))
        let zero = result(await ctl("get-page-text", ["pane": plain.id]))
        #expect(zero["frames"] == 0 && zero["shadowRoots"] == 0)
    }

    // MARK: Ownership and pane errors (J-24, J-25)

    /// "read-back verbs refuse a pane this caller does not own".
    @Test func readBackVerbsRefuseAPaneThisCallerDoesNotOwn() async throws {
        let foreign = try #require(harness.open("browser")).id
        let flags: [String: JSONValue] = ["pane": .string(foreign.rawValue)]
        let anything = flags.merging(["description": "x"]) { $1 }
        for (command, arguments) in [
            ("pane-info", flags), ("screenshot", flags), ("get-page-text", flags), ("read-page", flags), ("find", anything),
            ("activate-pane", flags), ("close-pane", flags),
        ] {
            let response = await ctl(command, arguments)
            #expect(response == ["ok": false, "error": "not the owner of this pane"], "\(command): \(response)")
        }
        #expect(harness.runtime.panes.panes(ofType: "browser").contains(foreign), "and the pane is still there")
    }

    /// J-24: "a pane the user closed by hand reports that, not 'not a browser pane'".
    @Test func aPaneTheUserClosedByHandReportsThatNotNotABrowserPane() async throws {
        let (id, _) = try await create("about:blank")
        let pane = PaneID(try #require(id.stringValue))
        _ = result(await ctl("activate-pane", ["pane": id]))
        // Closed the way the user closes it, not through close-pane (which would revoke ownership).
        harness.engine.close(pane)
        #expect(harness.runtime.panes.contentType(of: pane) == nil)
        for (command, flags) in [("activate-pane", ["pane": id]), ("get-page-text", ["pane": id]), ("close-pane", ["pane": id])] {
            let response = await ctl(command, flags)
            #expect(response["ok"] == false, "\(command)")
            let error = response["error"]?.stringValue ?? ""
            #expect(error.contains("no longer exists"), "\(command): \(error)")
            #expect(!error.contains("not a browser pane"), "\(command): \(error)")
        }
    }

    /// J-25: a page that can't run script reads as one sentence, never the engine's plumbing.
    @Test func aPageThatCannotRunScriptIsOneSentenceNotTheEnginesPlumbing() async throws {
        let (id, page) = try await create("about:blank")
        page.destroy()
        let sentence =
            "the page could not run script — it may be mid-navigation, showing an error page, or a viewer (such as the PDF viewer) that runs none"
        for command in ["get-page-text", "read-page"] {
            let response = await ctl(command, ["pane": id])
            #expect(response == ["ok": false, "error": .string(sentence)], "\(command): \(response)")
        }
        let find = await ctl("find", ["pane": id, "description": "x"])
        #expect(find == ["ok": false, "error": .string(sentence)])
    }

    // MARK: Screenshot request shape

    /// "screenshot clips to one element…" (refusals): both forms at once are refused before anything else is done.
    @Test func screenshotRefusesBothFormsAtOnceBeforeItRevealsAnything() async throws {
        let (id, _) = try await create("about:blank")
        let both = await ctl("screenshot", ["pane": id, "selector": "#go", "ref": "e1-x"])
        #expect(both["ok"] == false)
        #expect(both["error"] == "pass only one of selector or ref — they are different ways to name one element")
    }

    /// J-6: `--no-activate` on a pane that isn't on screen fails, naming the remedy (curly apostrophe and all), and
    /// leaves the user's visible tab alone.
    @Test func screenshotNoActivateFailsOnAPaneThatIsNotShown() async throws {
        let (id, _) = try await create("about:blank")
        let pane = PaneID(try #require(id.stringValue))
        // The user goes back to the agent's tab: the browser is backgrounded.
        let window = try #require(harness.engine.model.window(holding: pane)).id
        let agent = harness.agentPane
        harness.engine.perform(in: window) { layout, titles in layout.reveal(agent, titles: titles) }
        #expect(harness.engine.model.window(window)?.isShowing(pane) == false)
        let refused = await ctl("screenshot", ["pane": id, "no-activate": true])
        #expect(refused["ok"] == false)
        #expect(
            refused["error"]
                == "the pane is hidden — it is not its tab group’s active tab, so it has no frame to capture; rerun without noActivate, or run activatePane first"
        )
        #expect(harness.engine.model.window(window)?.isShowing(pane) == false, "the user's visible tab did not change")
    }

    // MARK: The declaration

    /// "every protocol verb is claimed by some module" (this family's share): each verb is declared with its
    /// command and wire type, listed by `capabilities`, and its flags are as specified.
    @Test func everyReadAndNavigationVerbIsDeclaredAndListedByCapabilities() async throws {
        let listed = result(await ctl("capabilities"))
        guard case .array(let capabilities)? = listed["capabilities"],
            let browser = capabilities.first(where: { $0["id"] == "browser" }), case .array(let lines)? = browser["commands"]
        else { Issue.record("no browser capability: \(listed)"); return }
        #expect(browser["enabled"] == true)
        let text = lines.compactMap(\.stringValue)
        for command in [
            "create-browser-pane", "navigate", "reload", "go-back", "go-forward", "screenshot", "get-page-text", "read-page", "find",
        ] {
            #expect(text.contains { $0.contains("tabs-ctl \(command) ") || $0.hasSuffix("tabs-ctl \(command)") }, "\(command) is listed")
        }
        for line in text { #expect(!line.contains("\n") && line.contains("tabs-ctl")) }
        let describe = result(await ctl("describe", ["capability": "browser"]))
        guard case .array(let commands)? = describe["commands"] else { Issue.record("no commands: \(describe)"); return }
        func command(_ name: String) -> JSONValue? { commands.first { $0["command"] == .string(name) } }
        #expect(command("navigate")?["usage"]?.stringValue?.contains("tabs-ctl navigate") == true)
        #expect(command("navigate")?["flags"]?["url"]?["required"] == true)
        let missingURL = await ctl("navigate", ["pane": "whatever"])
        #expect(missingURL["error"]?.stringValue?.contains("--url is required") == true, "\(missingURL)")
        #expect(command("screenshot")?["flags"]?["selector"] != nil)
        let wire = command("create-browser-pane")?["wire"]
        #expect(wire?["required"] == ["type", "url"] && wire?["additionalProperties"] == false)
        #expect(describe["limits"]?["pageTextDefaultMax"] == 50_000 && describe["limits"]?["pageTextHardMax"] == 200_000)
    }

    /// H-13, J-23: every command `capabilities` lists, one line naming it, is described and registered: sent bare,
    /// what answers is the verb's own validation (a missing flag, the pane it must name), never "unknown command".
    @Test func everyDeclaredVerbIsRegisteredAndListedByCapabilities() async throws {
        let listed = result(await ctl("capabilities"))
        guard case .array(let capabilities)? = listed["capabilities"],
            let browser = capabilities.first(where: { $0["id"] == "browser" }), case .array(let lines)? = browser["commands"],
            !lines.isEmpty
        else { Issue.record("no browser commands: \(listed)"); return }
        let commands = lines.compactMap(\.stringValue).compactMap { $0.split(separator: " ").dropFirst().first.map(String.init) }
        #expect(commands.count == lines.count, "every line names its command: \(lines)")

        let describe = result(await ctl("describe", ["capability": "browser"]))
        guard case .array(let described)? = describe["commands"] else { Issue.record("\(describe)"); return }
        #expect(Set(described.compactMap { $0["command"]?.stringValue }) == Set(commands), "described exactly what is listed")
        for command in commands {
            let bare = await ctl(command)
            #expect(bare["ok"] == false, "\(command)")
            #expect(bare["error"]?.stringValue?.contains("unknown command") == false, "\(command): \(bare)")
        }
    }
}
