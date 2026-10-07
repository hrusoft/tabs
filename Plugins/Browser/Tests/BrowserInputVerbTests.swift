import AppKit
import Foundation
import TabsPluginSDK
import Testing

@testable import TabsCore

/// The input verbs through the control plane, as an agent reaches them (docs/BROWSER.md J-10, J-12…J-17,
/// D-3, D-7): `tabs-ctl`'s flags and wire requests against a browser pane the agent owns, its page in a window
/// that is never shown, served by the standard fixture pages.
@MainActor
@Suite struct BrowserInputVerbTests {
    /// A JSON value as the text a `--fields` flag carries.
    private func json(_ value: JSONValue) -> JSONValue {
        .string(String(decoding: (try? value.encodedData(pretty: false)) ?? Data(), as: UTF8.self))
    }

    private func field(_ target: JSONValue, _ value: String) -> JSONValue { ["target": target, "value": .string(value)] }

    // MARK: key

    /// J-15: both halves of the editing-command gap, pinned together because they only make sense as a pair:
    /// the chord genuinely cannot work, so the note has to say so, and `--command` has to be the thing that does.
    @Test func aModifierChordCannotReachTheEditingCommandsAndCommandCan() async throws {
        let bed = try await InputVerbBed()
        func fill(_ value: String) async {
            let filled = await bed.ctl("form-input", ["fields": json([field(["selector": "#name"], value)])])
            #expect(filled.result["filled"] == 1, "\(filled.raw)")
        }
        func selection() async -> JSONValue {
            await bed.value("(() => { const el = document.getElementById('name'); return el.selectionStart + '-' + el.selectionEnd })()")
        }
        func fieldValue() async -> JSONValue { await bed.value("document.getElementById('name').value") }

        await fill("anti-fog")
        // A field just filled has its caret at the end of what it holds, whichever way the host's focus went while it
        // was (WebKit resets it when the page gives up the keyboard).
        let afterFill = await selection()
        #expect(afterFill == "8-8", "\(afterFill)")
        // The chord arrives for real (the page's own handlers would see it) and changes nothing about the selection.
        let chord = await bed.ctl("key", ["key": "a", "modifiers": "meta"])
        #expect(chord.ok)
        let afterChord = await selection()
        #expect(afterChord == "8-8", "\(afterChord)")
        // …and the response says so, rather than reporting a bare success that a follow-up Backspace would turn
        // into a silently truncated field.
        #expect(chord.result["note"]?.stringValue?.contains("synthesized chord") == true)
        #expect(chord.result["note"]?.stringValue?.contains("--command") == true)

        // The trap in full, kept visible: Backspace after the chord eats one character.
        _ = await bed.ctl("key", ["key": "Backspace"])
        #expect(await bed.until { await fieldValue() == "anti-fo" })

        // --command goes through the real pipeline: select-all actually selects.
        await fill("anti-fog")
        let selectAll = await bed.ctl("key", ["command": "select-all"])
        #expect(selectAll.ok, "\(selectAll.error ?? "")")
        #expect(selectAll.result["command"] == "select-all")
        let afterCommand = await selection()
        #expect(afterCommand == "0-8", "\(afterCommand)")

        // …so the follow-up Backspace now clears the field, which is the whole point.
        _ = await bed.ctl("key", ["key": "Backspace"])
        #expect(await bed.until { await fieldValue() == "" })

        // undo/redo ride the browser's own undo stack, which only real keystrokes fill: they work after `type`.
        // (Measured: WebKit undoes a run of typing as one step, and folds the deletion just before it into that step
        // ("anti-fog" comes back): the intent is pinned, that undo takes the typing back and redo restores it.)
        _ = await bed.ctl("type", ["selector": "#name", "text": "hello"])
        #expect(await fieldValue() == "hello")
        #expect(await bed.ctl("key", ["command": "undo"]).ok)
        #expect(await bed.until { await fieldValue() != "hello" })
        #expect(await bed.ctl("key", ["command": "redo"]).ok)
        #expect(await bed.until { await fieldValue() == "hello" })

        // A plain key still answers with no note: the note is for the chord that cannot work, not decoration.
        let plain = await bed.ctl("key", ["key": "Enter"])
        #expect(plain.ok)
        #expect(plain.result["note"] == nil)

        // Exactly one of key/command: refused by the handler, not by client-side flag coercion.
        let neither = await bed.ctl("key")
        #expect(!neither.ok)
        #expect(neither.error?.contains("needs one of key") == true)
        let both = await bed.ctl("key", ["key": "a", "command": "undo"])
        #expect(both.error?.contains("pass only one of key or command") == true)

        // The clipboard commands are deliberately absent from the surface.
        #expect(!(await bed.ctl("key", ["command": "paste"])).ok)
    }

    /// J-15: arrows keep `key` and `code` intact under every modifier, alt included.
    @Test func keyDeliversArrowKeysWithAnIntactKeyCodeUnderEveryModifierAltIncluded() async throws {
        let bed = try await InputVerbBed()
        // A capture-phase listener reporting exactly what a page-level shortcut handler would see.
        await bed.value(
            """
            (() => {
              window.__lastKey = null
              document.addEventListener('keydown', (event) => {
                window.__lastKey = { key: event.key, code: event.code, altKey: event.altKey, shiftKey: event.shiftKey, ctrlKey: event.ctrlKey }
              }, true)
              return true
            })()
            """)
        // meta is deliberately not in this matrix: Cmd+Left is the app's own default "Focus Pane Left" shortcut.
        for modifiers in [[], ["shift"], ["control"], ["alt"]] {
            var flags: [String: JSONValue] = ["key": "ArrowLeft"]
            if !modifiers.isEmpty { flags["modifiers"] = .string(modifiers.joined(separator: ",")) }
            _ = await bed.ctl("key", flags)
            let observed = await bed.value("window.__lastKey")
            #expect(
                observed == [
                    "key": "ArrowLeft", "code": "ArrowLeft", "altKey": .bool(modifiers.contains("alt")),
                    "shiftKey": .bool(modifiers.contains("shift")), "ctrlKey": .bool(modifiers.contains("control")),
                ], "\(modifiers)")
        }
    }

    // MARK: scroll

    /// J-16: `scroll` reports where it landed, on a smooth page, and on one that is hidden as a background tab's is,
    /// with a real screenful for its step.
    @Test func scrollReportsWhereItLandedOnASmoothPage() async throws {
        let bed = try await InputVerbBed(path: "/smooth")
        let scrolled = await bed.ctl("scroll", ["direction": "down"])
        #expect(scrolled.ok, "\(scrolled.error ?? "")")
        let reported = try #require(scrolled.result["position"]?["y"]?.doubleValue)
        #expect(reported > 0)
        // The reported number is the page's real position, not a pre-animation snapshot.
        #expect(await bed.value("window.scrollY").doubleValue == reported)
        // …and it is still that number once any animation would have finished.
        try await Task.sleep(for: .milliseconds(300))
        #expect(await bed.value("window.scrollY").doubleValue == reported)
        // Successive scrolls advance, so comparing positions is a usable "have I reached the bottom" test.
        let again = await bed.ctl("scroll", ["direction": "down"])
        #expect((again.result["position"]?["y"]?.doubleValue ?? 0) > reported)
        // The step is about one screen, from the page's own height; `amount` overrides it, and up undoes it.
        let up = await bed.ctl("scroll", ["direction": "up", "amount": 100])
        let expected = (again.result["position"]?["y"]?.doubleValue ?? 0) - 100
        #expect(up.result["position"]?["y"]?.doubleValue == expected)
        #expect(up.result["position"]?["x"] == 0)
        // Hidden: the step is still 0.8 of the page's own height, not of a zero-sized rect.
        bed.page.webView.isHidden = true
        #expect(!bed.page.isVisible)
        let height = try #require(await bed.value("window.innerHeight").doubleValue)
        let hidden = await bed.ctl("scroll", ["direction": "down"])
        #expect(hidden.ok, "\(hidden.error ?? "")")
        let landed = try #require(hidden.result["position"]?["y"]?.doubleValue)
        #expect(height > 0 && landed == expected + (height * 0.8).rounded(), "\(landed) from \(expected), a page \(height) high")
        #expect(await bed.value("window.scrollY").doubleValue == landed)
    }

    /// J-16: a wire request with no direction is refused as the schema does (the flag's default is the CLI's).
    @Test func scrollWithNoDirectionIsRefusedOnTheWireAndDefaultsToDownAsAFlag() async throws {
        let bed = try await InputVerbBed(path: "/smooth")
        let missing = await bed.wire("scroll")
        #expect(!missing.ok)
        #expect(missing.error?.contains("direction") == true, "\(missing.error ?? "")")
        let flag = await bed.ctl("scroll")
        #expect(flag.ok && (flag.result["position"]?["y"]?.doubleValue ?? 0) > 0)
        #expect(!(await bed.ctl("scroll", ["direction": "sideways"])).ok)
        #expect(!(await bed.ctl("scroll", ["direction": "down", "amount": 0])).ok, "the floor is 1")
    }

    // MARK: hover

    /// J-13: the same targets and hit test as `click`, a move and nothing else: it opens a hover-only menu, which
    /// stays open for the read that follows, without pressing the label.
    @Test func hoverOpensAHoverOnlyMenuWithoutCommittingTheClick() async throws {
        let bed = try await InputVerbBed(path: "/hovery")
        await bed.window.setKey(true)
        // Before: the submenu is display:none, so it is invisible to read-page and its link cannot be targeted.
        #expect(await bed.elements(ReadPageFilter(selector: "#submenu a")).isEmpty)
        let hovered = await bed.ctl("hover", ["name": "Products"])
        #expect(hovered.ok, "\(hovered.error ?? "")")
        #expect(hovered.result["element"]?["name"] == "Products")
        #expect(hovered.result["x"]?.doubleValue != nil && hovered.result["y"]?.doubleValue != nil)
        // Open by the time the verb answers, and still open for the read.
        #expect(await bed.status == "menu-open")
        #expect(await bed.elements(ReadPageFilter(selector: "#submenu a")).first?.name == "Widgets")
        // For contrast: clicking the same target commits the press.
        let clicked = await bed.ctl("click", ["name": "Products"])
        #expect(clicked.ok)
        #expect(await bed.statusBecomes("label-clicked"))
    }

    /// J-13: WebKit delivers a pointer move only to the key window, so anywhere else hover fails saying so, and
    /// what to do instead, rather than answer for a move the page never saw. A target that doesn't resolve is still
    /// the error a caller sees first.
    @Test func hoverInAWindowThatIsNotKeyFailsSayingWhy() async throws {
        let bed = try await InputVerbBed(path: "/hovery")
        let hovered = await bed.ctl("hover", ["name": "Products"])
        #expect(!hovered.ok)
        #expect(hovered.error == InputVerbs.hoverWindowNotActiveError)
        #expect(await bed.status == "idle", "nothing reached the page")
        let missing = await bed.ctl("hover", ["name": "No such thing"])
        #expect(missing.error != InputVerbs.hoverWindowNotActiveError && missing.error?.contains("No such thing") == true)
    }

    /// J-13: hover resolves as click does (a ref is hit-tested, a covered target fails naming both, in the same words),
    /// and presses nothing.
    @Test func hoverResolvesTargetsAsClickDoesAndNeverPresses() async throws {
        let bed = try await InputVerbBed(path: "/shifty")
        await bed.window.setKey(true)
        let target = await bed.element(named: "Shifty target")
        let hovered = await bed.ctl("hover", ["ref": .string(target.ref)])
        #expect(hovered.ok, "\(hovered.error ?? "")")
        #expect(hovered.result["element"] == ["role": "button", "name": "Shifty target", "tag": "button"])
        await bed.value(
            "(() => { const o = document.createElement('div'); o.setAttribute('aria-label', 'Blocking overlay'); o.style.cssText = 'position:fixed;inset:0;z-index:10'; document.body.appendChild(o); return true })()"
        )
        let covered = await bed.ctl("hover", ["ref": .string(target.ref)])
        #expect(!covered.ok)
        #expect(covered.error?.contains("Shifty target") == true && covered.error?.contains("Blocking overlay") == true)
        let atPoint = await bed.ctl("hover", ["x": 30, "y": 30])
        #expect(atPoint.ok && atPoint.result["element"]?["name"] == "Blocking overlay", "a coordinate is described, not refused")
        #expect(await bed.status == "idle", "no press reached the page")
    }

    // MARK: click

    /// J-12, J-14, J-16: read the page, then click, type, submit and scroll by ref and by coordinate.
    @Test func anAgentCanReadThePageStructureAndDriveItClickTypeSubmitScroll() async throws {
        let bed = try await InputVerbBed()
        #expect(await bed.status == "idle")
        let button = await bed.element(named: "Do the thing")
        let field = await bed.element(named: "Your name")
        #expect(button.role == "button" && field.role == "textbox")
        #expect(button.rect.width > 0)

        // The ref names exactly the element it did; the result reports the element the click landed on, in
        // read-page's own vocabulary.
        let clicked = await bed.ctl("click", ["ref": .string(button.ref)])
        #expect(clicked.result["element"] == ["role": "button", "name": "Do the thing", "tag": "button"], "\(clicked.raw)")
        #expect(await bed.statusBecomes("clicked"))

        _ = await bed.ctl("type", ["ref": .string(field.ref), "text": "ada"])
        #expect(await bed.statusBecomes("typed:ada"))

        // --submit sends a real Enter after the text, which the fixture reports separately from the input events.
        _ = await bed.ctl("type", ["ref": .string(field.ref), "text": "x", "submit": true])
        #expect(await bed.statusBecomes("submitted:adax"))

        // A raw coordinate must land in the same space read-page reported the rect in, and the result reports what
        // sat at that point: a coordinate click is never refused (the caller named the exact spot).
        await bed.value("document.getElementById('status').textContent = 'reset'")
        let atPoint = await bed.ctl(
            "click",
            [
                "x": .double((button.rect.x + button.rect.width / 2).rounded()),
                "y": .double((button.rect.y + button.rect.height / 2).rounded()),
            ])
        #expect(atPoint.result["element"]?["name"] == "Do the thing")
        #expect(await bed.statusBecomes("clicked"))

        // A bare key lands on whatever the page has focused (the field, after the click) with no help from the host.
        _ = await bed.ctl("click", ["ref": .string(field.ref)])
        _ = await bed.ctl("key", ["key": "Enter"])
        #expect(await bed.statusBecomes("submitted:adax"))

        // The fixture is 3000px tall, so a downward scroll must actually move: `position` is read back from the page.
        let scrolled = await bed.ctl("scroll", ["direction": "down"])
        #expect(scrolled.ok)
        #expect((scrolled.result["position"]?["y"]?.doubleValue ?? 0) > 0)
    }

    /// J-10: refs live in the page's own globals, so a navigation drops them, and the counter numbering them
    /// restarts with each page too; a ref from an earlier page never names anything on a later one.
    @Test func aStaleElementRefReportsWhyRatherThanClickingSomethingElse() async throws {
        let bed = try await InputVerbBed()
        let oldRefs = await bed.elements().map(\.ref)
        #expect(!oldRefs.isEmpty)
        await bed.load("/listing")
        let after = await bed.elements()
        #expect(after.count > oldRefs.count)
        // No ref minted on the new page repeats one from the old.
        #expect(after.filter { oldRefs.contains($0.ref) }.isEmpty)
        for ref in oldRefs.prefix(3) {
            let stale = await bed.ctl("click", ["ref": .string(ref)])
            #expect(!stale.ok, "\(ref) must not rebind")
            #expect(stale.error?.contains("readPage") == true, "\(stale.error ?? "")")
        }
        // Nothing on the new page was clicked by a stale ref.
        #expect(await bed.value("document.querySelectorAll('input:checked').length") == 0)
    }

    /// J-12: a ref's point is re-resolved in the same page script that hit-tests it, so the click follows the
    /// element rather than pressing the stale spot.
    @Test func aClickWhoseTargetMovedSinceReadPageLandsOnTheElementNotTheOldPoint() async throws {
        let bed = try await InputVerbBed(path: "/shifty")
        let target = await bed.element(named: "Shifty target")
        // Shift the layout out from under the ref: 500px of new content above the button moves it well clear of
        // the rect read-page reported, which now holds only the grown spacer.
        let grown = await bed.value(
            "(() => { document.getElementById('lead').style.height = '500px'; return document.getElementById('target').getBoundingClientRect().y })()"
        )
        #expect((grown.doubleValue ?? 0) > target.rect.y + 400)
        let clicked = await bed.ctl("click", ["ref": .string(target.ref)])
        #expect(clicked.ok, "\(clicked.error ?? "")")
        #expect(clicked.result["element"] == ["role": "button", "name": "Shifty target", "tag": "button"])
        #expect(await bed.statusBecomes("target-clicked"))
    }

    /// J-12: a covered target fails naming both elements instead of pressing the cover, and no event reaches the page.
    @Test func aClickWhoseTargetIsCoveredFailsNamingBothElementsInsteadOfPressingTheCover() async throws {
        let bed = try await InputVerbBed(path: "/shifty")
        let target = await bed.element(named: "Shifty target")
        // A fixed full-viewport overlay now owns every point on the page: the sharpest form of "something else
        // slid into the spot".
        await bed.value(
            "(() => { const o = document.createElement('div'); o.setAttribute('aria-label', 'Blocking overlay'); o.style.cssText = 'position:fixed;inset:0;z-index:10'; document.body.appendChild(o); return true })()"
        )
        let clicked = await bed.ctl("click", ["ref": .string(target.ref)])
        #expect(!clicked.ok)
        #expect(clicked.error?.contains("Shifty target") == true)
        #expect(clicked.error?.contains("Blocking overlay") == true)
        #expect(clicked.error?.contains("call readPage again, or click by coordinate to press what is actually there") == true)
        // And no events were dispatched: the page saw no click at all.
        #expect(await bed.status == "idle")
        // A semantic target's remedy is its own.
        let semantic = await bed.ctl("click", ["name": "Shifty target"])
        #expect(semantic.error?.contains("dismiss what covers it, or click by coordinate") == true, "\(semantic.error ?? "")")
        // The coordinate names the exact point and presses whatever is there: the cover.
        let atPoint = await bed.ctl("click", ["x": 40, "y": 40])
        #expect(atPoint.ok)
        #expect(atPoint.result["element"]?["name"] == "Blocking overlay")
        #expect(await bed.status == "idle")
    }

    /// J-10: no read-page first, no ref: the match happens inside the page as the verb runs.
    @Test func semanticTargetsDriveThePageByRoleNameAndSelectorInOneCall() async throws {
        let bed = try await InputVerbBed()
        #expect(await bed.status == "idle")
        let clicked = await bed.ctl("click", ["role": "button", "name": "Do the thing"])
        #expect(clicked.ok, "\(clicked.error ?? "")")
        #expect(clicked.result["element"] == ["role": "button", "name": "Do the thing", "tag": "button"])
        #expect(await bed.statusBecomes("clicked"))

        // The exact tier is what kept that unambiguous: "Do the thing" also prefixes another button's name,
        // which substring matching alone would have reported as a second candidate.
        _ = await bed.ctl("click", ["name": "do the thing twice"])
        #expect(await bed.statusBecomes("twice-clicked"))

        // A selector target reaches an element by CSS alone.
        _ = await bed.ctl("click", ["selector": "#dup-a"])
        #expect(await bed.statusBecomes("dup-a-clicked"))

        // Substring is the last tier: a fragment no name equals still targets the one control containing it.
        await bed.value("document.getElementById('status').textContent = 'reset'")
        _ = await bed.ctl("click", ["name": "thing twice"])
        #expect(await bed.statusBecomes("twice-clicked"))

        // type: matched and focused in one page pass, then real keystrokes.
        _ = await bed.ctl("type", ["role": "textbox", "name": "Your name", "text": "ada"])
        #expect(await bed.statusBecomes("typed:ada"))

        // form-input rides the same target union: a semantic select fill.
        let form = await bed.ctl("form-input", ["fields": json([field(["role": "combobox", "name": "Pick one"], "two")])])
        #expect(form.ok)
        #expect(form.result["filled"] == 1)
        #expect(await bed.statusBecomes("picked:two"))

        // No match is a loud failure naming the criteria, not a no-op.
        let missing = await bed.ctl("click", ["name": "Nonexistent"])
        #expect(!missing.ok)
        #expect(missing.error?.contains("no element matches") == true)
        #expect(missing.error?.contains("Nonexistent") == true)
    }

    /// J-10: an image is found by its role (`img`) and name (its alt text), which the default candidate set alone
    /// would never list.
    @Test func aSemanticTargetFindsAnImageByItsRoleAndName() async throws {
        let bed = try await InputVerbBed(path: "/listing")
        let clicked = await bed.ctl("click", ["role": "img", "name": "Thumb image"])
        #expect(clicked.ok, "\(clicked.error ?? "")")
        #expect(clicked.result["element"] == ["role": "img", "name": "Thumb image", "tag": "img"])
        #expect(await bed.ctl("click", ["role": "img", "name": "Sort by"]).ok == false, "the role is still a hard filter")
    }

    /// J-10: ambiguity fails listing candidates with the indices `nth` indexes into.
    @Test func anAmbiguousSemanticTargetFailsListingItsCandidatesAndNthPicksAmongThem() async throws {
        let bed = try await InputVerbBed()
        // Three "Duplicate" buttons, one display:none. Exactly 2 candidates means the hidden twin was excluded.
        let ambiguous = await bed.ctl("click", ["name": "Duplicate"])
        #expect(!ambiguous.ok)
        #expect(ambiguous.error?.contains("2 elements match") == true, "\(ambiguous.error ?? "")")
        #expect(ambiguous.error?.contains("[0]") == true && ambiguous.error?.contains("[1]") == true)
        #expect(ambiguous.error?.contains("nth") == true)
        // Refused means refused: no click reached the page.
        #expect(await bed.status == "idle")
        // nth indexes that listing: 0-based, document order.
        let second = await bed.ctl("click", ["name": "Duplicate", "nth": 1])
        #expect(second.ok)
        #expect(await bed.statusBecomes("dup-b-clicked"))
        // Out of range names the real count instead of clamping to the last match.
        let outOfRange = await bed.ctl("click", ["name": "Duplicate", "nth": 5])
        #expect(!outOfRange.ok)
        #expect(outOfRange.error?.contains("out of range") == true)
    }

    /// J-10: role stays a hard filter, and says why it missed.
    @Test func aRoleThatIsTooStrictDiagnosesTheNearMissInsteadOfAGenericNoMatch() async throws {
        let bed = try await InputVerbBed()
        // The fixture's "Add to Cart" is a <div role="group">, not a <button>.
        let tooStrict = await bed.ctl("click", ["role": "button", "name": "Add to Cart"])
        #expect(!tooStrict.ok)
        #expect(tooStrict.error == "no button named \"Add to Cart\"; a group with that name exists — retry without --role")
        // Refused means refused: no click reached the page.
        #expect(await bed.status == "idle")
        // The suggested retry actually works: dropping --role reaches the group and clicks it for real.
        let retried = await bed.ctl("click", ["name": "Add to Cart"])
        #expect(retried.ok)
        #expect(retried.result["element"] == ["role": "group", "name": "Add to Cart", "tag": "div"])
        #expect(await bed.statusBecomes("cart-added"))
    }

    /// J-10: the same criteria routed through `type`'s focus path, built on the one matcher.
    @Test func theNearMissDiagnosisAlsoReachesTypeFormInputViaTheSharedMatcher() async throws {
        let bed = try await InputVerbBed()
        let typed = await bed.ctl("type", ["role": "button", "name": "Add to Cart", "text": "x"])
        #expect(!typed.ok)
        #expect(typed.error == "no button named \"Add to Cart\"; a group with that name exists — retry without --role")
        let form = await bed.ctl("form-input", ["fields": json([field(["role": "button", "name": "Add to Cart"], "x")])])
        #expect(form.ok, "form-input reports a field's failure as data")
        #expect(
            form.result["errors"]?[0]?["error"]?.stringValue
                == "no button named \"Add to Cart\"; a group with that name exists — retry without --role"
        )
    }

    /// J-10: a target that can't be a target is refused before anything touches the page.
    @Test func aMalformedTargetIsRefusedBeforeAnythingTouchesThePage() async throws {
        let bed = try await InputVerbBed()
        // From the flags: core composes exactly one form.
        let mixed = await bed.ctl("click", ["ref": "e1", "x": 1, "y": 1])
        #expect(mixed.error?.contains("different target forms") == true, "\(mixed.error ?? "")")
        #expect(await bed.ctl("click", ["x": 5]).error?.contains("needs both --x and --y") == true)
        #expect(await bed.ctl("click").error?.contains("is required") == true)
        #expect(await bed.ctl("click", ["role": "button", "nth": -1]).error?.contains("--nth must be a non-negative integer") == true)
        // From the wire, past the flags: the schema, then the handler's own rules for what a schema can't say.
        #expect(!(await bed.wire("click", ["target": ["x": 5]])).ok, "a coordinate needs both axes")
        #expect(!(await bed.wire("click", ["target": ["ref": "e1", "x": 1, "y": 1]])).ok, "exactly one form")
        #expect(!(await bed.wire("click", ["target": [:]])).ok)
        let blank = await bed.wire("click", ["target": ["name": "  "]])
        #expect(blank.error == "a semantic target needs at least one of role, name, selector", "\(blank.error ?? "")")
        let fractional = await bed.wire("click", ["target": ["name": "Duplicate", "nth": 1.5]])
        #expect(
            fractional.error == "nth must be a non-negative integer (it is a 0-based index into the matches)", "\(fractional.error ?? "")")
        let negative = await bed.wire("click", ["target": ["name": "Duplicate", "nth": -1]])
        #expect(negative.error?.contains("non-negative integer") == true)
        let badRole = await bed.wire("click", ["target": ["role": "buton"]])
        #expect(badRole.error?.contains("buton") == true, "\(badRole.error ?? "")")
        #expect(await bed.status == "idle")
    }

    /// H-8: `--ref`, `--x/--y` and `--role/--name/--selector/--nth` each reach the handler as the one `target`.
    @Test func everyElementTargetFormFromTheFlagsReachesTheHandler() async throws {
        let bed = try await InputVerbBed()
        let button = await bed.element(named: "Do the thing")
        let byRef = await bed.ctl("click", ["ref": .string(button.ref)])
        #expect(byRef.result["element"]?["name"] == "Do the thing")
        let byPoint = await bed.ctl("click", ["x": .double(button.rect.x + 2), "y": .double(button.rect.y + 2)])
        #expect(byPoint.result["element"]?["name"] == "Do the thing")
        let bySelector = await bed.ctl("click", ["selector": "#dup-b"])
        #expect(bySelector.result["element"]?["name"] == "Duplicate")
        #expect(await bed.statusBecomes("dup-b-clicked"))
        let byNth = await bed.ctl("click", ["name": "Duplicate", "nth": 0])
        #expect(byNth.ok)
        #expect(await bed.statusBecomes("dup-a-clicked"))
        // The same forms in a raw wire request.
        let wired = await bed.wire("click", ["target": ["role": "button", "name": "Do the thing"]])
        #expect(wired.ok && wired.result["element"]?["name"] == "Do the thing")
    }

    /// J-12: a coordinate press is described, not refused, on a page that can't answer for it.
    @Test func aCoordinateClickOnAPageThatRunsNoScriptStillPresses() async throws {
        let bed = try await InputVerbBed(path: "about:blank")
        let clicked = await bed.ctl("click", ["x": 10, "y": 10])
        #expect(clicked.ok, "\(clicked.error ?? "")")
        #expect(clicked.result["x"] == 10 && clicked.result["y"] == 10)
    }

    // MARK: A pane the caller does not own, or that is not mounted

    /// J-24: an input verb refuses a pane this caller does not own, and says the same whether or not it exists.
    @Test func inputVerbsRefuseAPaneThisCallerDoesNotOwn() async throws {
        let bed = try await InputVerbBed()
        let foreign = try #require(bed.harness.open("browser")).id
        for (command, flags) in Self.everyVerb {
            let response = await bed.ctl(command, flags, pane: foreign)
            #expect(!response.ok, "\(command)")
            #expect(response.error == "not the owner of this pane", "\(command): \(response.error ?? "")")
            let missing = await bed.ctl(command, flags, pane: "no-such-pane")
            #expect(missing.error == "not the owner of this pane", "\(command): \(missing.error ?? "")")
        }
        #expect(await bed.status == "idle", "nothing reached the owned pane either")
    }

    private static let everyVerb: [(String, [String: JSONValue])] = [
        ("click", ["x": 10, "y": 10]), ("hover", ["x": 10, "y": 10]), ("type", ["x": 10, "y": 10, "text": "hi"]),
        ("key", ["key": "Enter"]), ("scroll", ["direction": "down"]),
        ("form-input", ["fields": "[{\"target\":{\"selector\":\"#name\"},\"value\":\"x\"}]"]),
    ]

    /// J-24: a pane the caller owns that has no page on screen has nowhere to send input.
    @Test func inputVerbsRefuseAPaneThatIsNotMounted() async throws {
        let bed = try await InputVerbBed(mounted: false)
        for (command, flags) in Self.everyVerb where command != "scroll" && command != "form-input" {
            let response = await bed.ctl(command, flags)
            #expect(!response.ok, "\(command)")
            #expect(response.error == "browser pane is not currently mounted", "\(command): \(response.error ?? "")")
        }
        // The two that work on the page by script don't need a window.
        #expect(await bed.ctl("scroll", ["direction": "down"]).ok)
        #expect(await bed.ctl("form-input", ["fields": json([field(["selector": "#name"], "x")])]).result["filled"] == 1)
    }

    /// J-25: a page that can't run script answers with the one sentence, never the engine's plumbing.
    @Test func aPageThatCannotRunScriptAnswersInOneSentence() async throws {
        let bed = try await InputVerbBed()
        let button = await bed.element(named: "Do the thing")
        bed.page.destroy()
        let sentence =
            "the page could not run script — it may be mid-navigation, showing an error page, or a viewer (such as the PDF viewer) that runs none"
        #expect(await bed.ctl("click", ["ref": .string(button.ref)]).error == sentence)
        #expect(await bed.ctl("hover", ["selector": "#go"]).error == sentence)
        #expect(await bed.ctl("type", ["selector": "#name", "text": "x"]).error == sentence)
        #expect(await bed.ctl("scroll", ["direction": "down"]).error == sentence)
        #expect(await bed.ctl("key", ["command": "select-all"]).error == sentence)
        let form = await bed.ctl("form-input", ["fields": json([field(["selector": "#name"], "x")])])
        #expect(form.result["errors"]?[0]?["error"]?.stringValue == sentence, "a field's failure is data: \(form.raw)")
    }

    // MARK: form-input

    /// J-17: a select picks by value with real `input` and `change` events, and lists what it has when nothing matches.
    @Test func formInputPicksSelectOptionsByValueWithRealChangeEvents() async throws {
        let bed = try await InputVerbBed()
        #expect(await bed.status == "idle")
        let select = await bed.element(named: "Pick one")
        #expect(select.role == "combobox")
        let filled = await bed.ctl("form-input", ["fields": json([field(["ref": .string(select.ref)], "two")])])
        #expect(filled.ok)
        #expect(filled.result["filled"] == 1)
        // The fixture's own change listener fired: the page saw a real change, not just a silently mutated value.
        #expect(await bed.statusBecomes("picked:two"))

        // A value matching no option reports the options rather than guessing.
        let unmatched = await bed.ctl("form-input", ["fields": json([field(["ref": .string(select.ref)], "three")])])
        #expect(unmatched.result["filled"] == 0)
        let error = unmatched.result["errors"]?[0]?["error"]?.stringValue
        #expect(error?.contains("no option matching") == true)
        // Labels and values both: both are accepted, and the labels are what the page shows.
        #expect(error?.contains("(options: \"One\" (one), \"Two\" (two))") == true, "\(error ?? "")")
        // The response stays ok (the report is the useful part).
        #expect(unmatched.ok)
    }

    /// J-17: multiline values verbatim, read back, and fields that will not hold them refused.
    @Test func formInputSetsMultilineValuesVerbatimReadsThemBackAndRefusesFieldsThatWillNotHoldThem() async throws {
        let bed = try await InputVerbBed()
        let notes = await bed.element(named: "Notes")
        let nameField = await bed.element(named: "Your name")
        let button = await bed.element(named: "Do the thing")

        // A value the keystrokes could never deliver: embedded newlines, a blank line, quotes and indentation,
        // checked byte-for-byte end to end.
        let multiline = "line one\nline two\n\n  \"quoted\" & indented\nlast line"
        let filled = await bed.ctl("form-input", ["fields": json([field(["ref": .string(notes.ref)], multiline)])])
        #expect(filled.ok)
        #expect(filled.result["filled"] == 1)
        // The read-back report: exactly as many characters as were sent.
        #expect(filled.result["fields"] == [["index": 0, "length": .int(Int64(multiline.utf16.count))]])
        // The fixture's own input listener saw the whole value in one event.
        #expect(await bed.statusBecomes("noted:\(multiline.utf16.count)"))
        // And the element holds it verbatim, replacing the preset content.
        #expect(await bed.value("document.getElementById('notes').value") == .string(multiline))

        // A multiline value into a single-line <input> does not survive the engine's own sanitization, and a
        // button is not a fillable field at all: both are loud errors, neither counts as filled.
        let refused = await bed.ctl(
            "form-input",
            ["fields": json([field(["ref": .string(nameField.ref)], "first\nsecond"), field(["ref": .string(button.ref)], "x")])])
        #expect(refused.result["filled"] == 0)
        #expect(refused.result["fields"] == nil)
        #expect(refused.result["errors"]?[0]?["index"] == 0)
        let first = refused.result["errors"]?[0]?["error"]?.stringValue
        #expect(first?.contains("11 of the 12 characters") == true, "\(first ?? "")")
        #expect(first?.contains("cannot hold newlines") == true)
        #expect(refused.result["errors"]?[1]?["index"] == 1)
        #expect(refused.result["errors"]?[1]?["error"]?.stringValue?.contains("not a fillable field") == true)
        // What the input actually holds is what the error described.
        #expect(await bed.value("document.getElementById('name').value") == "firstsecond")

        // A contenteditable is filled through real editing commands: the preset text is replaced and both lines land.
        let editor = await bed.ctl("form-input", ["fields": json([field(["selector": "#editor"], "alpha\nbeta")])])
        #expect(editor.result["filled"] == 1)
        #expect(editor.result["fields"]?[0]?["index"] == 0)
        let text = await bed.value("document.getElementById('editor').innerText").stringValue ?? ""
        #expect(text.contains("alpha") && text.contains("beta") && !text.contains("preset"), "\(text)")
    }

    /// J-14, J-17: `type` appends at the focus point, and after a `form-input` that is the end of what was filled
    /// (WebKit leaves the caret there only for a page that holds the keyboard).
    @Test func typeAfterFormInputAppendsToTheFilledValue() async throws {
        let bed = try await InputVerbBed()
        _ = await bed.ctl("form-input", ["fields": json([field(["selector": "#name"], "abc"), field(["selector": "#notes"], "one\ntwo")])])
        #expect(
            await bed.value("(() => { const el = document.getElementById('name'); return el.selectionStart + '-' + el.selectionEnd })()")
                == "3-3")
        _ = await bed.ctl("type", ["selector": "#name", "text": "X"])
        #expect(await bed.value("document.getElementById('name').value") == "abcX")
        _ = await bed.ctl("type", ["selector": "#notes", "text": "!"])
        #expect(await bed.value("document.getElementById('notes').value") == "one\ntwo!")
    }

    /// J-17: a coordinate target is clicked to focus the field, then filled like any other.
    @Test func formInputByCoordinateClicksTheFieldThenFillsIt() async throws {
        let bed = try await InputVerbBed()
        let name = await bed.element(named: "Your name")
        let point: JSONValue = ["x": .double(name.rect.x + name.rect.width / 2), "y": .double(name.rect.y + name.rect.height / 2)]
        let filled = await bed.ctl("form-input", ["fields": json([field(point, "by point")])])
        #expect(filled.result["filled"] == 1, "\(filled.raw)")
        #expect(await bed.statusBecomes("typed:by point"))
        // The shape of a field is the schema's, not the handler's.
        let missing = await bed.wire("formInput", ["fields": [["target": ["x": 1, "y": 2]]]])
        #expect(!missing.ok)
        #expect(missing.error?.contains("request.fields[0] is missing required field \"value\"") == true, "\(missing.error ?? "")")
    }

    /// J-17: a length is JavaScript's (UTF-16 code units, as the page reads it), so a value the field holds whole
    /// is counted filled whatever the characters.
    @Test func formInputCountsLengthsTheWayThePageReadsThem() async throws {
        let bed = try await InputVerbBed()
        let value = "café 日本 😀"
        let filled = await bed.ctl("form-input", ["fields": json([field(["selector": "#name"], value)])])
        #expect(filled.result["filled"] == 1, "\(filled.raw)")
        #expect(filled.result["fields"] == [["index": 0, "length": .int(Int64(value.utf16.count))]])
        // …including a CRLF, which a single-line input strips as two characters, and says so.
        let crlf = await bed.ctl("form-input", ["fields": json([field(["selector": "#name"], "a\r\nb")])])
        #expect(crlf.result["errors"]?[0]?["error"]?.stringValue?.contains("cannot hold newlines") == true, "\(crlf.raw)")
    }

    /// J-17: form-input replaces a field's contents rather than appending, and skips a field it can't focus.
    @Test func formInputReplacesAFieldsContentsAndReportsAFieldThatCannotBeFocused() async throws {
        let bed = try await InputVerbBed()
        let name = await bed.element(named: "Your name")
        _ = await bed.ctl("type", ["ref": .string(name.ref), "text": "stale"])
        #expect(await bed.statusBecomes("typed:stale"))
        let filled = await bed.ctl("form-input", ["fields": json([field(["ref": .string(name.ref)], "grace")])])
        #expect(filled.ok)
        #expect(filled.result["filled"] == 1)
        // 'grace', not 'stalegrace': the previous value was selected and replaced.
        #expect(await bed.statusBecomes("typed:grace"))

        // A field that can't be focused is reported and skipped, not fatal.
        let partial = await bed.ctl(
            "form-input",
            ["fields": json([field(["ref": "not-a-real-ref"], "x"), field(["ref": .string(name.ref)], "ada")])])
        #expect(partial.result["filled"] == 1)
        #expect(partial.result["errors"]?[0]?["index"] == 0)
        if case .array(let errors)? = partial.result["errors"] { #expect(errors.count == 1) }
        #expect(await bed.statusBecomes("typed:ada"))
        // An empty form fills nothing and says so.
        let none = await bed.ctl("form-input", ["fields": "[]"])
        #expect(none.ok && none.result == ["filled": 0])
    }

    // MARK: type

    /// J-14: text a keystroke can't carry is refused before anything is focused or typed.
    @Test func typeRefusesTextItsKeystrokesCannotCarryBeforeTouchingThePage() async throws {
        let bed = try await InputVerbBed()
        #expect(await bed.status == "idle")
        let rejected = await bed.ctl("type", ["name": "Your name", "text": "one\ntwo"])
        #expect(!rejected.ok)
        #expect(rejected.error?.contains("a newline at index 3") == true, "\(rejected.error ?? "")")
        #expect(rejected.error?.contains("form-input") == true)
        // Refused before anything was focused or typed: the page is untouched.
        #expect(await bed.status == "idle")
        #expect(await bed.value("document.getElementById('name').value") == "")
        #expect(await bed.value("document.activeElement === document.body") == true)
        for (text, described) in [
            ("a\rb", "a carriage return at index 1"), ("a\tb", "a tab at index 1"), ("ab\u{7f}", "control character 0x7f at index 2"),
            ("\u{1}", "control character 0x01 at index 0"), ("😀\n", "a newline at index 2"),
        ] {
            let refused = await bed.ctl("type", ["name": "Your name", "text": .string(text)])
            #expect(refused.error?.contains(described) == true, "\(described): \(refused.error ?? "")")
        }
        // Plain printable text still types: the refusal is not a general gate.
        let typed = await bed.ctl("type", ["name": "Your name", "text": "ok"])
        #expect(typed.ok)
        #expect(await bed.statusBecomes("typed:ok"))
    }

    /// J-14: Enter submits a plain form, once, from `type --submit` and from `key`; a textarea gains one line break.
    @Test func enterFromTypeSubmitAndFromKeySubmitsAPlainFormOnce() async throws {
        let bed = try await InputVerbBed(path: "/form")
        func state() async -> JSONValue {
            await bed.value("[window.__submits, document.getElementById('query').value, document.getElementById('notes').value]")
        }
        let typed = await bed.ctl("type", ["selector": "#query", "text": "hello", "submit": true])
        #expect(typed.ok, "\(typed.error ?? "")")
        #expect(await bed.until { await state() == [1, "hello", ""] })
        // A bare Enter at the field, as the guide suggests for a stubborn widget.
        #expect(await bed.ctl("key", ["key": "Enter"]).ok)
        #expect(await bed.until { await state() == [2, "hello", ""] })
        // The same press in a textarea is a line break, not a submit.
        _ = await bed.ctl("type", ["selector": "#notes", "text": "a"])
        _ = await bed.ctl("key", ["key": "Enter"])
        #expect(await bed.until { await state() == [2, "hello", "a\n"] })
    }

    /// J-14: every printable ASCII character is a full keydown, keypress and keyup, inserting once.
    @Test func typeDeliversEachCharacterAsKeydownKeypressAndKeyupInsertingItOnce() async throws {
        let bed = try await InputVerbBed(path: "/form")
        let printable = (0x20..<0x7f).map { String(UnicodeScalar(UInt8($0))) }
        let text = printable.joined()
        let typed = await bed.ctl("type", ["selector": "#query", "text": .string(text)])
        #expect(typed.ok, "\(typed.error ?? "")")
        let seen = await bed.value("({ value: document.getElementById('query').value, keys: window.__keys, submits: window.__submits })")
        #expect(seen["value"]?.stringValue == text)
        #expect(seen["submits"] == 0)
        // Three events per character, each naming the character typed, with shift exactly where a keyboard needs it.
        guard case .array(let keys)? = seen["keys"] else { Issue.record("no keys"); return }
        let observed = keys.map { "\($0[0]?.stringValue ?? "")|\($0[1]?.stringValue ?? "")" }
        let expected = printable.flatMap { character in ["keydown", "keypress", "keyup"].map { "\($0)|\(character)" } }
        #expect(observed == expected)
        for key in keys {
            let label = "\(key[0]?.stringValue ?? "") \(key[1]?.stringValue ?? "")"
            let character = key[1]?.stringValue ?? ""
            if character.count == 1, character.first?.isASCII == true, character.first?.isUppercase == true {
                #expect(key[3] == true, "\(label)")
            }
            if character.count == 1, character.first?.isASCII == true,
                character.first?.isLowercase == true || character.first?.isNumber == true
            {
                #expect(key[3] == false, "\(label)")
            }
            #expect(key[2]?.stringValue != "", "\(label)")
        }
        // Text with no key behind it still arrives, as a character without a keydown.
        _ = await bed.ctl("type", ["selector": "#notes", "text": "é"])
        #expect(await bed.value("document.getElementById('notes').value") == "é")
        // Mixed with keyed characters, it lands in the order given.
        _ = await bed.ctl("type", ["selector": "#notes", "text": "café 日本 ok"])
        #expect(await bed.value("document.getElementById('notes').value") == "écafé 日本 ok")
    }

    /// J-14: typing into a field inside a frame, by coordinate, where the page's input counters can't see the keys:
    /// mixed text still lands in order, and the pacing that waits on those counters gives up once rather than
    /// running out before every character with no key.
    @Test func mixedTextTypedIntoAFrameLandsInOrderWithoutAWaitPerCharacter() async throws {
        let bed = try await InputVerbBed(path: "/framed-field")
        #expect(await bed.until { await bed.value("!!document.getElementById('fr').contentDocument?.getElementById('f')") == true })
        let started = Date()
        let typed = await bed.ctl("type", ["x": 20, "y": 15, "text": "a東京大阪京都名古屋"])
        #expect(typed.ok, "\(typed.error ?? "")")
        #expect(Date().timeIntervalSince(started) < 2.5, "one wait ran out, not one per character")
        #expect(await bed.value("document.getElementById('fr').contentDocument.getElementById('f').value") == "a東京大阪京都名古屋")
    }

    // MARK: click reaches inside frames and shadow roots

    /// J-11: coordinate clicks reach inside a frame and a shadow root, though the reads cannot; the result names what
    /// the top document's hit test finds: the `<iframe>`, the shadow host.
    @Test func coordinateClicksReachInsideAFrameAndAShadowRootEvenThoughReadsCannot() async throws {
        let bed = try await InputVerbBed(path: "/nested")
        let names = await bed.elements().map(\.name)
        #expect(names.contains("Top button"))
        #expect(!names.contains("Frame button") && !names.contains("Shadow button"))
        // The workaround SKILL.md documents: compute the target's viewport coordinate in the page (the frame's
        // rect plus the button's rect inside it: only possible because this fixture's frame is same-origin), then
        // click by coordinate. A poll guards the frame's own load.
        #expect(
            await bed.until {
                await bed.value("!!document.getElementById('the-frame').contentDocument?.getElementById('frame-button')") == true
            })
        let framePoint = await bed.value(
            """
            (() => {
              const frame = document.getElementById('the-frame')
              const frameRect = frame.getBoundingClientRect()
              const btn = frame.contentDocument.getElementById('frame-button')
              const btnRect = btn.getBoundingClientRect()
              return { x: frameRect.x + btnRect.x + btnRect.width / 2, y: frameRect.y + btnRect.y + btnRect.height / 2 }
            })()
            """)
        let frameClick = await bed.ctl(
            "click", ["x": .double(framePoint["x"]?.doubleValue ?? 0), "y": .double(framePoint["y"]?.doubleValue ?? 0)])
        #expect(frameClick.ok)
        // Real input reaches inside the frame (the click fires the button's own handler), but the reporting half
        // only ever queries the top document's elementFromPoint, which names the <iframe> itself.
        #expect(frameClick.result["element"]?["tag"] == "iframe")
        #expect(await bed.until { await bed.value("window.frameButtonClicked") == true })

        let shadowPoint = await bed.value(
            """
            (() => {
              const btn = document.getElementById('shadow-host').shadowRoot.querySelector('#shadow-button')
              const rect = btn.getBoundingClientRect()
              return { x: rect.x + rect.width / 2, y: rect.y + rect.height / 2 }
            })()
            """)
        let shadowClick = await bed.ctl(
            "click", ["x": .double(shadowPoint["x"]?.doubleValue ?? 0), "y": .double(shadowPoint["y"]?.doubleValue ?? 0)])
        #expect(shadowClick.ok)
        // elementFromPoint retargets across a shadow boundary the same way it stops at a frame boundary: the result
        // names the shadow host (a bare div here), not the button inside it.
        #expect(shadowClick.result["element"]?["tag"] == "div")
        #expect(shadowClick.result["element"]?["name"] == "")
        #expect(await bed.value("window.shadowButtonClicked") == true)
    }

    // MARK: Spec

    /// H-10: each verb's budget is its tier.
    @Test func theInputVerbsDeclareTheirBudgets() throws {
        let bed = try PluginHarness.browser(withAgent: true)
        let budgets: [(String, Duration)] = [
            ("click", .seconds(5)), ("hover", .seconds(5)), ("type", .seconds(15)), ("key", .seconds(5)), ("scroll", .seconds(5)),
            ("formInput", .seconds(15)),
        ]
        for (name, budget) in budgets {
            let verb = try #require(bed.runtime.registry.contribution(to: .controlVerbs, id: "browser.\(name)"), "\(name)")
            #expect(verb.value.timeout == budget, "\(name)")
            #expect(verb.value.batchable, "\(name)")
            #expect(verb.value.target == .ownedPane(ofTypes: ["browser"]), "\(name)")
        }
        for name in ["click", "hover", "type"] {
            #expect(bed.runtime.registry.contribution(to: .controlVerbs, id: "browser.\(name)")?.value.composition == .elementTarget)
        }
    }

    /// H-13: `describe` states each verb's flags as specified.
    @Test func describeStatesTheInputVerbsFlags() async throws {
        let harness = try PluginHarness.browser(withAgent: true)
        let described = await harness.tabsCtl("describe", ["capability": "browser"])
        let commands = described["result"]?["commands"]
        func command(_ name: String) -> JSONValue? {
            if case .array(let all)? = commands { return all.first { $0["command"]?.stringValue == name } }
            return commands?[name]
        }
        for name in ["click", "hover", "type", "key", "scroll", "form-input"] { #expect(command(name) != nil, "\(name): \(described)") }
        let key = command("key")
        #expect(key?["flags"]?["modifiers"]?["type"] == "csv")
        #expect(key?["flags"]?["command"]?["enum"] == ["select-all", "undo", "redo", "delete"])
        #expect(key?["usage"]?.stringValue?.contains("[--modifiers <shift,control,alt,meta>]") == true)
        let scroll = command("scroll")
        #expect(scroll?["flags"]?["direction"]?["default"] == "down")
        #expect(scroll?["flags"]?["amount"]?["min"] == 1)
        let form = command("form-input")
        #expect(form?["flags"]?["fields"]?["required"] == true)
        #expect(form?["flags"]?["fields"]?["type"] == "json")
        #expect(form?["flags"]?["fields"]?["doc"] == "A JSON array of {target, value} pairs.")
        #expect(command("type")?["flags"]?["submit"]?["type"] == "boolean")
        #expect(command("click")?["flags"]?["ref"]?["doc"] == "An opaque ref from a previous read-page/find.")
    }
}
