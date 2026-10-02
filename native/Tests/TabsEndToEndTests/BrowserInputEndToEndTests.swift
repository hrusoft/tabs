import Foundation
import TabsPluginSDK
import Testing

/// The input verbs against the running app, driven by the real `tabs-ctl` from an agent's pane (docs/BROWSER.md
/// J-10, J-12…J-17, D-3, D-7): the Electron specs `e2e/external-control-input.spec.ts` (all 18), the fill-a-form
/// half of `external-control-flow.spec.ts`' first test, "driving a pane never steals keyboard focus from the
/// terminal" of `external-control.spec.ts`, and the click half of `external-control-read.spec.ts`' frame and
/// shadow test, with the same titles (camelCased) and assertions. Every assertion about the page reads the page's
/// own DOM (`AgentSession.eval`, `.text`), not `tabs-ctl`'s `{ok: true}`: the point is that real input reached the
/// page, not that the request round-tripped.
@Suite(.serialized, .sharedApp, .timeLimit(.minutes(2)), .enabled(if: LaunchedApp.nodeIsInstalled, "tabs-ctl runs under Node"))
struct BrowserInputEndToEndTests {
    // MARK: Helpers

    /// A fresh app, an agent, and a browser pane it owns on `path` of the standard fixture origin.
    private func open(_ path: String = "/page") async throws -> (agent: AgentSession, pane: String, server: FixtureServer) {
        let server = try await FixtureServer.startStandard()
        let agent = try await AgentSession.open(SharedApp.fresh())
        let pane = try await agent.createBrowserPane(url: server.url(path))
        return (agent, pane, server)
    }

    /// Polls until `condition` holds (the page settling after real input); false if it doesn't within `seconds`.
    private func poll(within seconds: Double = 10, _ condition: () async throws -> Bool) async throws -> Bool {
        let deadline = ContinuousClock.now + .seconds(seconds)
        while ContinuousClock.now < deadline {
            if try await condition() { return true }
            try await Task.sleep(for: .milliseconds(50))
        }
        return try await condition()
    }

    private func status(_ agent: AgentSession, _ pane: String) async throws -> String? { try await agent.text(pane, "#status") }

    private func statusBecomes(_ expected: String, _ agent: AgentSession, _ pane: String) async throws -> Bool {
        try await poll { try await status(agent, pane) == expected }
    }

    /// The elements `read-page` lists.
    private func elements(_ agent: AgentSession, _ pane: String, _ extra: [String] = []) async throws -> [JSONValue] {
        let read = try await agent.ctl(["read-page", "--pane", pane] + extra)
        guard case .array(let listed)? = read.result["elements"] else { return [] }
        return listed
    }

    /// The listed element named `name` (a recorded issue and an empty one if there is none).
    private func element(
        named name: String, _ agent: AgentSession, _ pane: String, sourceLocation: SourceLocation = #_sourceLocation
    ) async throws -> JSONValue {
        let found = try await elements(agent, pane).first { $0["name"] == .string(name) }
        if found == nil { Issue.record("read-page did not surface \(name)", sourceLocation: sourceLocation) }
        return found ?? .emptyObject
    }

    private func ref(_ element: JSONValue) -> String { element["ref"]?.stringValue ?? "" }

    private func fields(_ pairs: [(target: JSONValue, value: String)]) -> String {
        let array = JSONValue.array(pairs.map { ["target": $0.target, "value": .string($0.value)] })
        return String(decoding: (try? array.encodedData(pretty: false)) ?? Data(), as: UTF8.self)
    }

    // MARK: key

    @Test func aModifierChordCannotReachTheEditingCommandsAndCommandCan() async throws {
        let (agent, pane, server) = try await open()
        defer { server.stop() }
        func fill(_ value: String) async throws {
            try await agent.ctl(["form-input", "--pane", pane, "--fields", fields([(["selector": "#name"], value)])])
        }
        func selection() async throws -> JSONValue {
            try await agent.eval(
                pane, "(() => { const el = document.getElementById('name'); return el.selectionStart + '-' + el.selectionEnd })()")
        }
        func fieldValue() async throws -> JSONValue { try await agent.eval(pane, "document.getElementById('name').value") }

        try await fill("anti-fog")
        // The chord arrives for real (the page's own handlers would see it) and changes nothing about the selection.
        let chord = try await agent.ctl("key", "--pane", pane, "--key", "a", "--modifiers", "meta")
        #expect(chord.ok)
        let afterChord = try await selection()
        #expect(afterChord == "8-8", "\(afterChord)")
        // …and the response says so, rather than reporting a bare success that a follow-up Backspace would turn into
        // a silently truncated field.
        #expect(chord.result["note"]?.stringValue?.contains("synthesized chord") == true)
        #expect(chord.result["note"]?.stringValue?.contains("--command") == true)

        // The trap in full, kept visible: Backspace after the chord eats one character.
        try await agent.ctl("key", "--pane", pane, "--key", "Backspace")
        #expect(try await poll { try await fieldValue() == "anti-fo" })

        // --command goes through the real pipeline: select-all actually selects.
        try await fill("anti-fog")
        let selectAll = try await agent.ctl("key", "--pane", pane, "--command", "select-all")
        #expect(selectAll.ok, "\(selectAll.error ?? "")")
        #expect(selectAll.result["command"] == "select-all")
        let afterCommand = try await selection()
        #expect(afterCommand == "0-8", "\(afterCommand)")

        // …so the follow-up Backspace now clears the field, which is the whole point.
        try await agent.ctl("key", "--pane", pane, "--key", "Backspace")
        #expect(try await poll { try await fieldValue() == "" })

        // undo/redo ride the browser's own undo stack, which only real keystrokes fill: they work after `type`.
        // (Measured: WebKit undoes a run of typing as one step, and folds the deletion just before it into that step,
        // where Chromium undid it a character at a time and left "hell": the intent is pinned, that undo takes the
        // typing back and redo restores it.)
        try await agent.ctl("type", "--pane", pane, "--selector", "#name", "--text", "hello")
        #expect(try await fieldValue() == "hello")
        #expect(try await agent.ctl("key", "--pane", pane, "--command", "undo").ok)
        #expect(try await poll { try await fieldValue() != "hello" })
        #expect(try await agent.ctl("key", "--pane", pane, "--command", "redo").ok)
        #expect(try await poll { try await fieldValue() == "hello" })

        // A plain key still answers with no note: the note is for the chord that cannot work, not decoration.
        let plain = try await agent.ctl("key", "--pane", pane, "--key", "Enter")
        #expect(plain.ok)
        #expect(plain.result["note"] == nil)

        // Exactly one of key/command, refused by the handler, not by client-side flag coercion: the dumb CLI ships no
        // oneOf knowledge of its own, so this is the app's own message, not tabs-ctl's.
        let neither = try await agent.ctl("key", "--pane", pane)
        #expect(!neither.ok)
        #expect(neither.error?.contains("needs one of key") == true)

        // The clipboard commands are deliberately absent from the surface.
        #expect(try await !agent.ctl("key", "--pane", pane, "--command", "paste").ok)
    }

    @Test func keyDeliversArrowKeysWithAnIntactKeyCodeUnderEveryModifierAltIncluded() async throws {
        let (agent, pane, server) = try await open()
        defer { server.stop() }
        #expect(try await statusBecomes("idle", agent, pane))

        // A capture-phase listener reporting exactly what a page-level shortcut handler would see: the DOM key/code
        // strings and the modifier flags.
        _ = try await agent.eval(
            pane,
            """
            (() => {
              window.__lastKey = null
              document.addEventListener('keydown', (event) => {
                window.__lastKey = { key: event.key, code: event.code, altKey: event.altKey, shiftKey: event.shiftKey, ctrlKey: event.ctrlKey }
              }, true)
              return true
            })()
            """)

        // meta is deliberately not in this matrix: Cmd+Left is the app's own default "Focus Pane Left" shortcut and is
        // consumed before the page ever sees a keydown: a different, already-documented mechanism, not this bug.
        for modifiers in [[], ["shift"], ["control"], ["alt"]] as [[String]] {
            try await agent.ctl(
                ["key", "--pane", pane, "--key", "ArrowLeft"]
                    + (modifiers.isEmpty ? [] : ["--modifiers", modifiers.joined(separator: ",")]))
            let observed = try await agent.eval(pane, "window.__lastKey")
            #expect(
                observed == [
                    "key": "ArrowLeft", "code": "ArrowLeft", "altKey": .bool(modifiers.contains("alt")),
                    "shiftKey": .bool(modifiers.contains("shift")), "ctrlKey": .bool(modifiers.contains("control")),
                ], "\(modifiers)")
        }
    }

    // MARK: scroll, hover

    @Test func scrollReportsWhereItLandedOnASmoothPageAndOnAHiddenOne() async throws {
        let (agent, pane, server) = try await open("/smooth")
        defer { server.stop() }

        let scrolled = try await agent.ctl("scroll", "--pane", pane, "--direction", "down")
        #expect(scrolled.ok, "\(scrolled.error ?? "")")
        let reported = scrolled.result["position"]?["y"]?.doubleValue ?? 0
        #expect(reported > 0)
        // The reported number is the page's real position, not a pre-animation snapshot: read from the page itself,
        // an independent path.
        #expect(try await agent.eval(pane, "window.scrollY").doubleValue == reported)
        // …and it is still that number once any animation would have finished, which is what proves the read wasn't
        // merely lucky timing.
        try await Task.sleep(for: .milliseconds(600))
        #expect(try await agent.eval(pane, "window.scrollY").doubleValue == reported)
        // Successive scrolls advance, so comparing positions is a usable "have I reached the bottom" test.
        let again = try await agent.ctl("scroll", "--pane", pane, "--direction", "down")
        #expect((again.result["position"]?["y"]?.doubleValue ?? 0) > reported)

        // A backgrounded pane still scrolls a real screenful: the step comes from the page's own innerHeight, not from
        // the host view's (zero) rect. Backgrounded the way a user does it, clicking the terminal's tab.
        let before = try await agent.eval(pane, "window.scrollY").doubleValue ?? 0
        try await agent.show(agent.caller)
        let hidden = try await agent.ctl("scroll", "--pane", pane, "--direction", "down")
        #expect(hidden.ok, "\(hidden.error ?? "")")
        #expect((hidden.result["position"]?["y"]?.doubleValue ?? 0) > before)
        #expect(try await agent.eval(pane, "window.scrollY").doubleValue == hidden.result["position"]?["y"]?.doubleValue)
    }

    /// The pattern `click` structurally cannot reach: a menu that opens on hover and navigates on click. WebKit
    /// delivers a pointer move only to the key window, and this app runs hidden under test, so no window here is ever
    /// key: what is asserted end to end is that hover says so instead of answering for a move the page never saw,
    /// after resolving its target as click does, and presses nothing. The menu opening in a key window is
    /// `BrowserInputVerbTests/hoverOpensAHoverOnlyMenuWithoutCommittingTheClick` (docs/BROWSER.md J-13).
    @Test func hoverInAWindowThatIsNotKeyFailsSayingWhyAndPressesNothing() async throws {
        let (agent, pane, server) = try await open("/hovery")
        defer { server.stop() }

        let hovered = try await agent.ctl("hover", "--pane", pane, "--name", "Products")
        #expect(!hovered.ok)
        #expect(hovered.error?.contains("WebKit delivers hover only to the active window") == true, "\(hovered.error ?? "")")
        let missing = try await agent.ctl("hover", "--pane", pane, "--name", "No such thing")
        #expect(missing.error?.contains("No such thing") == true, "a bad target is still the error seen first")
        try await Task.sleep(for: .milliseconds(300))
        #expect(try await status(agent, pane) == "idle")

        // For contrast: clicking the same target commits the press.
        let clicked = try await agent.ctl("click", "--pane", pane, "--name", "Products")
        #expect(clicked.ok)
        #expect(try await statusBecomes("label-clicked", agent, pane))
    }

    // MARK: click, type, refs

    @Test func anAgentCanReadThePageStructureAndDriveItClickTypeSubmitScroll() async throws {
        let (agent, pane, server) = try await open()
        defer { server.stop() }
        #expect(try await statusBecomes("idle", agent, pane))
        #expect(try await poll { try await elements(agent, pane).contains { $0["name"] == "Do the thing" } })

        let button = try await element(named: "Do the thing", agent, pane)
        let field = try await element(named: "Your name", agent, pane)
        #expect(button["role"] == "button")
        #expect(field["role"] == "textbox")
        #expect((button["rect"]?["width"]?.doubleValue ?? 0) > 0)

        // find() is a heuristic over a fresh extraction, so its top match carries a *new* ref: refs accumulate per page
        // rather than rebinding.
        let found = try await agent.ctl("find", "--pane", pane, "--description", "do the thing")
        #expect(found.result["matches"]?[0]?["name"] == "Do the thing")

        // The pre-find ref still names exactly the element it did: find's re-extraction cannot silently retarget it.
        // The result reports the element the click landed on, in read-page's own vocabulary.
        let clicked = try await agent.ctl("click", "--pane", pane, "--ref", ref(button))
        #expect(clicked.result["element"] == ["role": "button", "name": "Do the thing", "tag": "button"])
        #expect(try await statusBecomes("clicked", agent, pane))

        try await agent.ctl("type", "--pane", pane, "--ref", ref(field), "--text", "ada")
        #expect(try await statusBecomes("typed:ada", agent, pane))

        // --submit sends a real Enter after the text, which the fixture reports separately from the input events.
        try await agent.ctl("type", "--pane", pane, "--ref", ref(field), "--text", "x", "--submit")
        #expect(try await statusBecomes("submitted:adax", agent, pane))

        // A raw coordinate must land in the same space read-page reported the rect in, and the result reports what sat
        // at that point, since a coordinate click is never refused (the caller named the exact spot).
        _ = try await agent.eval(pane, "document.getElementById('status').textContent = 'reset'")
        let rect = button["rect"]
        let x = ((rect?["x"]?.doubleValue ?? 0) + (rect?["width"]?.doubleValue ?? 0) / 2).rounded()
        let y = ((rect?["y"]?.doubleValue ?? 0) + (rect?["height"]?.doubleValue ?? 0) / 2).rounded()
        let atPoint = try await agent.ctl("click", "--pane", pane, "--x", "\(Int(x))", "--y", "\(Int(y))")
        #expect(atPoint.result["element"]?["name"] == "Do the thing")
        #expect(try await statusBecomes("clicked", agent, pane))

        // A bare key lands on whatever the page has focused (the field, after the clicks above) with no help from the
        // host: the page view is never focused by input verbs (see the focus test below).
        try await agent.ctl("click", "--pane", pane, "--ref", ref(field))
        try await agent.ctl("key", "--pane", pane, "--key", "Enter")
        #expect(try await statusBecomes("submitted:adax", agent, pane))

        // The fixture is 3000px tall, so a downward scroll must actually move: `position` is read back from the page.
        let scrolled = try await agent.ctl("scroll", "--pane", pane, "--direction", "down")
        #expect(scrolled.ok)
        #expect((scrolled.result["position"]?["y"]?.doubleValue ?? 0) > 0)
    }

    /// Refs live in the page's own globals, so a navigation drops them, but the counter numbering them restarts with
    /// each page too, so a ref used to be refused only until the new page was *read*: after that, an old `e3` named
    /// whatever the new page had numbered 3. The test reads the new page before using the old ref, which is the order
    /// an agent works in.
    @Test func aStaleElementRefReportsWhyRatherThanClickingSomethingElse() async throws {
        let (agent, pane, server) = try await open()
        defer { server.stop() }
        #expect(try await poll { try await !elements(agent, pane).isEmpty })
        let oldRefs = try await elements(agent, pane).map(ref)

        try await agent.ctl("navigate", "--pane", pane, "--url", server.url("/listing"))
        #expect(try await poll { try await agent.ctl("pane-info", "--pane", pane).result["title"] == "Listing" })
        let after = try await elements(agent, pane)
        #expect(after.count > oldRefs.count)
        // No ref minted on the new page repeats one from the old.
        #expect(after.filter { oldRefs.contains(ref($0)) }.isEmpty)

        for old in oldRefs.prefix(3) {
            let stale = try await agent.ctl("click", "--pane", pane, "--ref", old)
            #expect(!stale.ok, "\(old) must not rebind")
            #expect(stale.error?.contains("readPage") == true)
        }
        // Nothing on the new page was clicked by a stale ref.
        #expect(try await agent.eval(pane, "document.querySelectorAll('input:checked').length") == 0)
    }

    /// The scaffold the two layout-shift click tests share: a /shifty pane and its target button.
    private func openShiftyTarget() async throws -> (agent: AgentSession, pane: String, target: JSONValue, server: FixtureServer) {
        let (agent, pane, server) = try await open("/shifty")
        #expect(try await poll { try await elements(agent, pane).contains { $0["name"] == "Shifty target" } })
        return (agent, pane, try await element(named: "Shifty target", agent, pane), server)
    }

    @Test func aClickWhoseTargetMovedSinceReadPageLandsOnTheElementNotTheOldPoint() async throws {
        let (agent, pane, target, server) = try await openShiftyTarget()
        defer { server.stop() }
        // Shift the layout out from under the ref: 500px of new content above the button moves it well clear of the
        // rect read-page reported, which now holds only the grown spacer.
        let grown = try await agent.eval(
            pane,
            "(() => { document.getElementById('lead').style.height = '500px'; return document.getElementById('target').getBoundingClientRect().y })()"
        )
        #expect((grown.doubleValue ?? 0) > (target["rect"]?["y"]?.doubleValue ?? 0) + 400)

        // The point is re-resolved in the same page script that dispatches from, so the click follows the element
        // rather than pressing the stale spot.
        let clicked = try await agent.ctl("click", "--pane", pane, "--ref", ref(target))
        #expect(clicked.ok, "\(clicked.error ?? "")")
        #expect(clicked.result["element"] == ["role": "button", "name": "Shifty target", "tag": "button"])
        #expect(try await statusBecomes("target-clicked", agent, pane))
    }

    @Test func aClickWhoseTargetIsCoveredFailsNamingBothElementsInsteadOfPressingTheCover() async throws {
        let (agent, pane, target, server) = try await openShiftyTarget()
        defer { server.stop() }
        // A fixed full-viewport overlay now owns every point on the page: the sharpest form of "something else slid
        // into the spot".
        _ = try await agent.eval(
            pane,
            "(() => { const o = document.createElement('div'); o.setAttribute('aria-label', 'Blocking overlay'); o.style.cssText = 'position:fixed;inset:0;z-index:10'; document.body.appendChild(o); return true })()"
        )

        // The failure names both sides of the mismatch, what was asked for and what is actually there, instead of
        // silently clicking the cover.
        let clicked = try await agent.ctl("click", "--pane", pane, "--ref", ref(target))
        #expect(!clicked.ok)
        #expect(clicked.error?.contains("Shifty target") == true)
        #expect(clicked.error?.contains("Blocking overlay") == true)
        // And no events were dispatched: the page saw no click at all.
        #expect(try await status(agent, pane) == "idle")
    }

    @Test func semanticTargetsDriveThePageByRoleNameAndSelectorInOneCall() async throws {
        let (agent, pane, server) = try await open()
        defer { server.stop() }
        #expect(try await statusBecomes("idle", agent, pane))

        // The headline path: no read-page first, no ref: the match happens inside the page as the verb runs, and the
        // result reports what was hit in the same {role, name, tag} vocabulary read-page speaks.
        let clicked = try await agent.ctl("click", "--pane", pane, "--role", "button", "--name", "Do the thing")
        #expect(clicked.ok, "\(clicked.error ?? "")")
        #expect(clicked.result["element"] == ["role": "button", "name": "Do the thing", "tag": "button"])
        #expect(try await statusBecomes("clicked", agent, pane))

        // The exact tier is what kept that unambiguous: "Do the thing" also prefixes this button's name, which
        // substring matching alone would have reported as a second candidate. Case-insensitive exact reaches it.
        try await agent.ctl("click", "--pane", pane, "--name", "do the thing twice")
        #expect(try await statusBecomes("twice-clicked", agent, pane))

        // A selector target reaches an element by CSS alone.
        try await agent.ctl("click", "--pane", pane, "--selector", "#dup-a")
        #expect(try await statusBecomes("dup-a-clicked", agent, pane))

        // Substring is the last tier: a fragment no name equals still targets the one control containing it.
        _ = try await agent.eval(pane, "document.getElementById('status').textContent = 'reset'")
        try await agent.ctl("click", "--pane", pane, "--name", "thing twice")
        #expect(try await statusBecomes("twice-clicked", agent, pane))

        // type: matched and focused in one page pass, then real keystrokes.
        try await agent.ctl("type", "--pane", pane, "--role", "textbox", "--name", "Your name", "--text", "ada")
        #expect(try await statusBecomes("typed:ada", agent, pane))

        // form-input rides the same target union: a semantic select fill.
        let form = try await agent.ctl([
            "form-input", "--pane", pane, "--fields", fields([(["role": "combobox", "name": "Pick one"], "two")]),
        ])
        #expect(form.ok)
        #expect(form.result["filled"] == 1)
        #expect(try await statusBecomes("picked:two", agent, pane))

        // No match is a loud failure naming the criteria, not a no-op.
        let missing = try await agent.ctl("click", "--pane", pane, "--name", "Nonexistent")
        #expect(!missing.ok)
        #expect(missing.error?.contains("no element matches") == true)
        #expect(missing.error?.contains("Nonexistent") == true)
    }

    @Test func anAmbiguousSemanticTargetFailsListingItsCandidatesAndNthPicksAmongThem() async throws {
        let (agent, pane, server) = try await open()
        defer { server.stop() }
        #expect(try await statusBecomes("idle", agent, pane))

        // The fixture holds three "Duplicate" buttons, one display:none. Exactly 2 candidates means the hidden twin was
        // excluded: counting it would make name targeting useless on any page with a hidden mobile-menu duplicate.
        let ambiguous = try await agent.ctl("click", "--pane", pane, "--name", "Duplicate")
        #expect(!ambiguous.ok)
        #expect(ambiguous.error?.contains("2 elements match") == true)
        #expect(ambiguous.error?.contains("[0]") == true)
        #expect(ambiguous.error?.contains("[1]") == true)
        #expect(ambiguous.error?.contains("nth") == true)
        // Refused means refused: no click reached the page.
        #expect(try await status(agent, pane) == "idle")

        // nth indexes that listing: 0-based, document order.
        let second = try await agent.ctl("click", "--pane", pane, "--name", "Duplicate", "--nth", "1")
        #expect(second.ok)
        #expect(try await statusBecomes("dup-b-clicked", agent, pane))

        // Out of range names the real count instead of clamping to the last match.
        let outOfRange = try await agent.ctl("click", "--pane", pane, "--name", "Duplicate", "--nth", "5")
        #expect(!outOfRange.ok)
        #expect(outOfRange.error?.contains("out of range") == true)
    }

    @Test func aRoleThatIsTooStrictDiagnosesTheNearMissInsteadOfAGenericNoMatch() async throws {
        let (agent, pane, server) = try await open()
        defer { server.stop() }
        #expect(try await statusBecomes("idle", agent, pane))

        // The fixture's "Add to Cart" is a <div role="group">, not a <button>: real production markup. role stays a hard
        // filter (silently clicking across roles is exactly the wrong-target class semantic targeting exists to remove),
        // so role=button/name="Add to Cart" must still miss: but the error says *why*.
        let tooStrict = try await agent.ctl("click", "--pane", pane, "--role", "button", "--name", "Add to Cart")
        #expect(!tooStrict.ok)
        #expect(tooStrict.error == "no button named \"Add to Cart\"; a group with that name exists — retry without --role")
        // Refused means refused: no click reached the page, same as any other miss.
        #expect(try await status(agent, pane) == "idle")

        // The suggested retry actually works: dropping --role reaches the group and clicks it for real, reported in
        // read-page's own vocabulary.
        let retried = try await agent.ctl("click", "--pane", pane, "--name", "Add to Cart")
        #expect(retried.ok)
        #expect(retried.result["element"] == ["role": "group", "name": "Add to Cart", "tag": "div"])
        #expect(try await statusBecomes("cart-added", agent, pane))
    }

    @Test func theNearMissDiagnosisAlsoReachesTypeFormInputViaTheSharedMatcher() async throws {
        let (agent, pane, server) = try await open()
        defer { server.stop() }
        #expect(try await statusBecomes("idle", agent, pane))

        // Same criteria, routed through type's focus path (focusTargetScript) instead of click's hit-test path: both are
        // built on the one semanticResolverExpression, so the diagnosis needed no separate implementation for this side.
        let typed = try await agent.ctl("type", "--pane", pane, "--role", "button", "--name", "Add to Cart", "--text", "x")
        #expect(!typed.ok)
        #expect(typed.error == "no button named \"Add to Cart\"; a group with that name exists — retry without --role")
    }

    @Test func inputVerbsRefuseAPaneThisCallerDoesNotOwn() async throws {
        try await AgentSession.expectRefusedForForeignPane(SharedApp.fresh()) { foreign in
            [
                ["read-page", "--pane", foreign], ["find", "--pane", foreign, "--description", "anything"],
                ["click", "--pane", foreign, "--x", "10", "--y", "10"], ["hover", "--pane", foreign, "--x", "10", "--y", "10"],
                ["type", "--pane", foreign, "--x", "10", "--y", "10", "--text", "hi"], ["key", "--pane", foreign, "--key", "Enter"],
                ["scroll", "--pane", foreign, "--direction", "down"],
            ]
        }
    }

    // MARK: form-input

    @Test func formInputPicksSelectOptionsByValueWithRealChangeEvents() async throws {
        let (agent, pane, server) = try await open()
        defer { server.stop() }
        #expect(try await statusBecomes("idle", agent, pane))

        let select = try await element(named: "Pick one", agent, pane)
        #expect(select["role"] == "combobox")

        let filled = try await agent.ctl(["form-input", "--pane", pane, "--fields", fields([(["ref": .string(ref(select))], "two")])])
        #expect(filled.ok)
        #expect(filled.result["filled"] == 1)
        #expect(filled.exitCode == 0)
        // The fixture's own change listener fired: the page saw a real change, not just a silently mutated value.
        #expect(try await statusBecomes("picked:two", agent, pane))

        // A value matching no option reports the options rather than guessing.
        let unmatched = try await agent.ctl(["form-input", "--pane", pane, "--fields", fields([(["ref": .string(ref(select))], "three")])])
        #expect(unmatched.result["filled"] == 0)
        #expect(unmatched.result["errors"]?[0]?["error"]?.stringValue?.contains("no option matching") == true)
        // Labels and values both: both are accepted, and the labels are what the page shows.
        #expect(unmatched.result["errors"]?[0]?["error"]?.stringValue?.contains("(options: \"One\" (one), \"Two\" (two))") == true)
        // The response stays ok (the report is the useful part), but the exit code reflects the failed field: batch's
        // any-step-failed rule, so a shell `&&` can't read "nothing was filled" as success.
        #expect(unmatched.ok)
        #expect(unmatched.exitCode == 1)
    }

    @Test func formInputSetsMultilineValuesVerbatimReadsThemBackAndRefusesFieldsThatWillNotHoldThem() async throws {
        let (agent, pane, server) = try await open()
        defer { server.stop() }
        #expect(try await statusBecomes("idle", agent, pane))

        let notes = try await element(named: "Notes", agent, pane)
        let nameField = try await element(named: "Your name", agent, pane)
        let button = try await element(named: "Do the thing", agent, pane)

        // A value the keystrokes could never deliver: embedded newlines, a blank line, quotes and indentation, checked
        // byte-for-byte end to end.
        let multiline = "line one\nline two\n\n  \"quoted\" & indented\nlast line"
        let filled = try await agent.ctl(["form-input", "--pane", pane, "--fields", fields([(["ref": .string(ref(notes))], multiline)])])
        #expect(filled.ok)
        #expect(filled.result["filled"] == 1)
        // The read-back report: exactly as many characters as were sent.
        #expect(filled.result["fields"] == [["index": 0, "length": .int(Int64(multiline.utf16.count))]])
        // The fixture's own input listener saw the whole value in one event: a framework bound to this field would have
        // seen the same.
        #expect(try await statusBecomes("noted:\(multiline.utf16.count)", agent, pane))
        // And the element holds it verbatim, replacing the preset content, read through an independent path.
        #expect(try await agent.eval(pane, "document.getElementById('notes').value") == .string(multiline))

        // A multiline value into a single-line <input> does not survive the engine's own sanitization, and a button is
        // not a fillable field at all: both are loud errors, neither counts as filled.
        let refused = try await agent.ctl([
            "form-input", "--pane", pane, "--fields",
            fields([(["ref": .string(ref(nameField))], "first\nsecond"), (["ref": .string(ref(button))], "x")]),
        ])
        #expect(refused.result["filled"] == 0)
        #expect(refused.result["fields"] == nil)
        #expect(refused.result["errors"]?[0]?["index"] == 0)
        #expect(refused.result["errors"]?[0]?["error"]?.stringValue?.contains("11 of the 12 characters") == true)
        #expect(refused.result["errors"]?[0]?["error"]?.stringValue?.contains("cannot hold newlines") == true)
        #expect(refused.result["errors"]?[1]?["index"] == 1)
        #expect(refused.result["errors"]?[1]?["error"]?.stringValue?.contains("not a fillable field") == true)
        if case .array(let errors)? = refused.result["errors"] { #expect(errors.count == 2) }
        // Failed fields fail the exit code even on an ok response.
        #expect(refused.exitCode == 1)
        // What the input actually holds is what the error described.
        #expect(try await agent.eval(pane, "document.getElementById('name').value") == "firstsecond")

        // A contenteditable is filled through real editing commands: the preset text is replaced and both lines land.
        // (Its length is measured on innerText, which normalizes blank lines: reported, not strict-checked.)
        let editor = try await agent.ctl(["form-input", "--pane", pane, "--fields", fields([(["selector": "#editor"], "alpha\nbeta")])])
        #expect(editor.result["filled"] == 1)
        #expect(editor.result["fields"]?[0]?["index"] == 0)
        let text = try await agent.eval(pane, "document.getElementById('editor').innerText").stringValue ?? ""
        #expect(text.contains("alpha") && text.contains("beta") && !text.contains("preset"), "\(text)")
    }

    /// The fill-a-form half of "an agent can run script in a pane and fill a form, and gets clean errors when it
    /// cannot" (`external-control-flow.spec.ts`): the execute-js half is the script verbs' test.
    @Test func anAgentCanFillAFormAndGetsCleanErrorsWhenItCannot() async throws {
        let (agent, pane, server) = try await open()
        defer { server.stop() }
        #expect(try await statusBecomes("idle", agent, pane))

        // form-input replaces a field's contents rather than appending to them.
        let field = try await element(named: "Your name", agent, pane)
        try await agent.ctl("type", "--pane", pane, "--ref", ref(field), "--text", "stale")
        #expect(try await statusBecomes("typed:stale", agent, pane))

        let filled = try await agent.ctl(["form-input", "--pane", pane, "--fields", fields([(["ref": .string(ref(field))], "grace")])])
        #expect(filled.ok)
        #expect(filled.result["filled"] == 1)
        // 'grace', not 'stalegrace': the previous value was selected and replaced.
        #expect(try await statusBecomes("typed:grace", agent, pane))

        // A field that can't be focused is reported and skipped, not fatal.
        let partial = try await agent.ctl([
            "form-input", "--pane", pane, "--fields",
            fields([(["ref": "not-a-real-ref"], "x"), (["ref": .string(ref(field))], "ada")]),
        ])
        #expect(partial.result["filled"] == 1)
        if case .array(let errors)? = partial.result["errors"] {
            #expect(errors.count == 1)
        } else {
            Issue.record("no errors: \(partial.response)")
        }
        #expect(try await statusBecomes("typed:ada", agent, pane))
    }

    // MARK: type

    @Test func typeRefusesTextItsKeystrokesCannotCarryBeforeTouchingThePage() async throws {
        let (agent, pane, server) = try await open()
        defer { server.stop() }
        #expect(try await statusBecomes("idle", agent, pane))

        // A keystroke can't carry a newline, so type refuses the text outright instead of sending fewer keystrokes than
        // asked.
        let rejected = try await agent.ctl("type", "--pane", pane, "--name", "Your name", "--text", "one\ntwo")
        #expect(!rejected.ok)
        #expect(rejected.error?.contains("a newline at index 3") == true)
        #expect(rejected.error?.contains("form-input") == true)

        // Refused before anything was focused or typed: the page is untouched.
        #expect(try await status(agent, pane) == "idle")
        #expect(try await agent.eval(pane, "document.getElementById('name').value") == "")

        // Plain printable text still types: the refusal is not a general gate.
        let typed = try await agent.ctl("type", "--pane", pane, "--name", "Your name", "--text", "ok")
        #expect(typed.ok)
        #expect(try await statusBecomes("typed:ok", agent, pane))
    }

    /// Enter is a full press (keydown, keypress and keyup), which is what submits a plain form implicitly: neither `type
    /// --submit` nor `key --key Enter` submitted one when a press was only a keydown and a keyup. A textarea takes the
    /// same press as exactly one line break.
    @Test func enterFromTypeSubmitAndFromKeySubmitsAPlainFormOnce() async throws {
        let (agent, pane, server) = try await open("/form")
        defer { server.stop() }
        func state() async throws -> JSONValue {
            try await agent.eval(pane, "[window.__submits, document.getElementById('query').value, document.getElementById('notes').value]")
        }

        let typed = try await agent.ctl("type", "--pane", pane, "--selector", "#query", "--text", "hello", "--submit")
        #expect(typed.ok, "\(typed.error ?? "")")
        #expect(try await poll { try await state() == [1, "hello", ""] })

        // A bare Enter at the field, as the guide suggests for a stubborn widget.
        #expect(try await agent.ctl("key", "--pane", pane, "--key", "Enter").ok)
        #expect(try await poll { try await state() == [2, "hello", ""] })

        // The same press in a textarea is a line break, not a submit.
        try await agent.ctl("type", "--pane", pane, "--selector", "#notes", "--text", "a")
        try await agent.ctl("key", "--pane", pane, "--key", "Enter")
        #expect(try await poll { try await state() == [2, "hello", "a\n"] })
    }

    /// Every printable ASCII character is typed here, because each one is a separate keystroke and any of them could come
    /// out as a null keydown or insert twice.
    @Test func typeDeliversEachCharacterAsKeydownKeypressAndKeyupInsertingItOnce() async throws {
        let (agent, pane, server) = try await open("/form")
        defer { server.stop() }
        let printable = (0x20..<0x7f).map { String(UnicodeScalar(UInt8($0))) }
        let text = printable.joined()

        let typed = try await agent.ctl("type", "--pane", pane, "--selector", "#query", "--text", text)
        #expect(typed.ok, "\(typed.error ?? "")")
        let seen = try await agent.eval(
            pane, "({ value: document.getElementById('query').value, keys: window.__keys, submits: window.__submits })")
        #expect(seen["value"]?.stringValue == text)
        #expect(seen["submits"] == 0)
        // Three events per character, each naming the character typed, with shift exactly where a keyboard needs it for
        // a capital letter.
        guard case .array(let keys)? = seen["keys"] else {
            Issue.record("no keys: \(seen)")
            return
        }
        #expect(
            keys.map { "\($0[0]?.stringValue ?? "")|\($0[1]?.stringValue ?? "")" }
                == printable.flatMap { character in ["keydown", "keypress", "keyup"].map { "\($0)|\(character)" } })
        for key in keys {
            let character = key[1]?.stringValue ?? ""
            let label = "\(key[0]?.stringValue ?? "") \(character)"
            if character.count == 1, character.first?.isASCII == true {
                if character.first?.isUppercase == true { #expect(key[3] == true, "\(label)") }
                if character.first?.isLowercase == true || character.first?.isNumber == true { #expect(key[3] == false, "\(label)") }
            }
            #expect(key[2]?.stringValue != "", "\(label)")
        }

        // Text with no key behind it still arrives, as a character without a keydown.
        try await agent.ctl("type", "--pane", pane, "--selector", "#notes", "--text", "é")
        #expect(try await agent.eval(pane, "document.getElementById('notes').value") == "é")
        // Mixed with keyed characters, it lands in the order given.
        try await agent.ctl("type", "--pane", pane, "--selector", "#notes", "--text", "café 日本 ok")
        #expect(try await agent.eval(pane, "document.getElementById('notes').value") == "écafé 日本 ok")
    }

    // MARK: focus, frames

    /// D-7, D-3. The user is typing in their terminal while an agent drives the browser pane in the background tab
    /// beside it; nothing the agent does may take the keyboard or move the active pane.
    @Test func drivingAPaneNeverStealsKeyboardFocusFromTheTerminal() async throws {
        let (agent, pane, server) = try await open()
        defer { server.stop() }
        #expect(try await statusBecomes("idle", agent, pane))
        // create-browser-pane opens as a new tab by default, which wraps the terminal and the browser into a tab group with
        // the browser active. Switch back to the terminal's tab like a user would: the scenario where stolen focus would
        // actually bite is one where they can see and are typing into the terminal while an agent drives the (now
        // backgrounded) browser pane alongside it. The pane stays mounted while hidden, so driving it works as in the
        // foreground.
        try await agent.show(agent.caller)

        let button = try await element(named: "Do the thing", agent, pane)
        let field = try await element(named: "Your name", agent, pane)

        func window() async throws -> JSONValue {
            guard case .array(let windows) = try await agent.app.call("tabs.test.windows"),
                let front = windows.first(where: { $0["frontmost"] == true }) ?? windows.first
            else { throw LaunchedApp.Failure(description: "no window") }
            return front
        }
        let before = try await window()
        #expect(before["activePane"] == .string(agent.caller))
        #expect(before["focusedPane"] != .string(pane), "the user's keyboard is not in the browser")

        // Every input verb, while the user "types" in the terminal.
        try await agent.ctl("click", "--pane", pane, "--ref", ref(button))
        try await agent.ctl("type", "--pane", pane, "--ref", ref(field), "--text", "quiet")
        try await agent.ctl("key", "--pane", pane, "--key", "Enter")
        try await agent.ctl(["form-input", "--pane", pane, "--fields", fields([(["ref": .string(ref(field))], "still")])])

        // The inputs genuinely landed in the page…
        #expect(try await statusBecomes("typed:still", agent, pane))
        // …and the keyboard never moved to the page…
        let after = try await window()
        #expect(after["focusedPane"] == before["focusedPane"])
        // …nor did the active pane follow the agent's clicks.
        #expect(after["activePane"] == before["activePane"])
    }

    /// The click half of "read verbs report frame/shadow counts, and coordinate clicks reach inside both even though
    /// reads cannot" (`external-control-read.spec.ts`; the counts are the read verbs' test).
    @Test func coordinateClicksReachInsideAFrameAndAShadowRootEvenThoughReadsCannot() async throws {
        let (agent, pane, server) = try await open("/nested")
        defer { server.stop() }

        // The documented blindness: read-page lists the top-document button but neither the frame's nor the shadow button.
        let names = try await elements(agent, pane).compactMap { $0["name"]?.stringValue }
        #expect(names.contains("Top button"))
        #expect(!names.contains("Frame button"))
        #expect(!names.contains("Shadow button"))

        // The workaround SKILL.md documents: compute the target's viewport coordinate in the page (the frame's rect plus
        // the button's rect inside it: only possible because this fixture's frame is same-origin), then click by
        // coordinate. A poll guards the frame's own document load, which the outer pane's `loaded` wait doesn't guarantee.
        #expect(
            try await poll {
                try await agent.eval(pane, "!!document.getElementById('the-frame').contentDocument?.getElementById('frame-button')") == true
            })
        let framePoint = try await agent.eval(
            pane,
            """
            (() => {
              const frame = document.getElementById('the-frame')
              const frameRect = frame.getBoundingClientRect()
              const btn = frame.contentDocument.getElementById('frame-button')
              const btnRect = btn.getBoundingClientRect()
              return { x: frameRect.x + btnRect.x + btnRect.width / 2, y: frameRect.y + btnRect.y + btnRect.height / 2 }
            })()
            """)
        let frameClick = try await agent.ctl(
            "click", "--pane", pane, "--x", "\(framePoint["x"]?.doubleValue ?? 0)", "--y", "\(framePoint["y"]?.doubleValue ?? 0)")
        #expect(frameClick.ok, "\(frameClick.error ?? "")")
        // Real input reaches inside the frame (the click fires the button's own handler), but the reporting half only ever
        // queries the top document's elementFromPoint, which does not cross a frame boundary: it names the <iframe> itself.
        #expect(frameClick.result["element"]?["tag"] == "iframe")
        #expect(try await poll { try await agent.eval(pane, "window.frameButtonClicked") == true })

        // Shadow DOM: shadowRoot.querySelector then the element's own rect (no host offset: an open shadow tree renders inline).
        let shadowPoint = try await agent.eval(
            pane,
            """
            (() => {
              const btn = document.getElementById('shadow-host').shadowRoot.querySelector('#shadow-button')
              const rect = btn.getBoundingClientRect()
              return { x: rect.x + rect.width / 2, y: rect.y + rect.height / 2 }
            })()
            """)
        let shadowClick = try await agent.ctl(
            "click", "--pane", pane, "--x", "\(shadowPoint["x"]?.doubleValue ?? 0)", "--y", "\(shadowPoint["y"]?.doubleValue ?? 0)")
        #expect(shadowClick.ok, "\(shadowClick.error ?? "")")
        // elementFromPoint retargets across a shadow boundary the same way it stops at a frame boundary: the result names
        // the shadow host (a bare div here), not the button inside it.
        #expect(shadowClick.result["element"]?["tag"] == "div")
        #expect(shadowClick.result["element"]?["name"] == "")
        #expect(try await agent.eval(pane, "window.shadowButtonClicked") == true)
    }
}
