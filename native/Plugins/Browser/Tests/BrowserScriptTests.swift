import AppKit
import Foundation
import TabsPluginSDK
import Testing

@testable import TabsCore

/// The page-side scripts (`PageScripts`, `WaitScripts`, verbatim from the Electron
/// app) run in a real `WKWebView` against a fixture page: each one parses, runs,
/// and answers what the verbs read off it (docs/BROWSER.md: J-7…J-11, J-16, J-17,
/// J-19, J-20 are these scripts' behaviors; the verbs are another slice).
@MainActor
@Suite struct BrowserScriptTests {
    static let controls = """
        <h1>Page Title</h1>
        <a href="/elsewhere">Link one</a>
        <button id=b1>Save</button><button id=b2>Save changes</button><button id=b3>Autosave</button>
        <label for=q>Search term</label><input id=q type=text placeholder="ph" value="abc">
        <label>Colour <select id=col><option value=r>Red</option><option value=g selected>Green</option></select></label>
        <input type=checkbox id=c1 aria-label="Agree" checked><input type=checkbox id=c2 aria-label="Partial">
        <div role=button tabindex=0 id=fake>Fake button</div>
        <div hidden><button id=hiddenbtn>Hidden</button></div>
        <span role=group id=lg aria-labelledby="lab1" style="display:inline-block;width:10px;height:10px"></span><span id=lab1>Group label</span>
        <textarea id=t aria-label="Notes">hello</textarea>
        <div id=ce contenteditable=true aria-label="Editor"></div>
        <input id=sub type=submit value="Send it">
        <div style="height:3000px"></div>
        """

    private func bed(body: String = controls, head: String = "") async throws -> PageBed {
        let bed = try await PageBed(serving: { $0.page("/controls", title: "Controls", head: head, body: body) })
        await bed.load("/controls")
        return bed
    }

    private func read(_ bed: PageBed, _ filter: ReadPageFilter = ReadPageFilter()) async -> JSONValue {
        await bed.value(readPageScript(filter))
    }

    private func names(_ result: JSONValue) -> [String] {
        guard case .array(let elements)? = result["elements"] else { return [] }
        return elements.compactMap { $0["name"]?.stringValue }
    }

    // MARK: read-page

    /// J-8: interactive elements and headings with ref, role, name, tag, rect; hidden ones never listed.
    @Test func readPageListsWhatThePageShowsWithRolesAndNamesAsTheBrowserComputesThem() async throws {
        let bed = try await bed()
        let result = await read(bed)
        guard case .array(let elements)? = result["elements"] else { Issue.record("no elements: \(result)"); return }
        func element(_ name: String) -> JSONValue? { elements.first { $0["name"]?.stringValue == name } }
        #expect(element("Page Title")?["role"] == "heading")
        #expect(element("Link one")?["role"] == "link" && element("Link one")?["tag"] == "a")
        #expect(element("Save")?["role"] == "button")
        // A label's text without the control it labels ("Colour", not "Colour RedGreen"), a select's chosen option as its value.
        #expect(element("Colour")?["role"] == "combobox")
        #expect(element("Colour")?["value"] == "g")
        #expect(element("Search term")?["role"] == "textbox" && element("Search term")?["value"] == "abc")
        #expect(element("Fake button")?["role"] == "button", "an explicit role is the role")
        #expect(element("Group label")?["role"] == "group", "aria-labelledby names it")
        #expect(element("Send it") == nil, "an unlabelled submit is named by its value attribute? no: by its text")
        #expect(elements.allSatisfy { $0["name"]?.stringValue != "Hidden" }, "a hidden element is never listed")
        for entry in elements {
            let ref = try #require(entry["ref"]?.stringValue)
            #expect(ref.wholeMatch(of: /e[0-9]+-[a-z0-9]{5}/) != nil, "\(ref)")
            #expect(entry["rect"]?["width"]?.doubleValue ?? 0 > 0)
        }
        #expect(result["total"]?.intValue == Int64(elements.count))
        #expect(result["offset"] == 0 && result["truncated"] == false)
        #expect(result["readyState"] == "complete")
    }

    /// J-8: checked state includes `mixed`, a checkbox's value is never its submit token.
    @Test func readPageReportsCheckedStateIncludingMixed() async throws {
        let bed = try await bed()
        await bed.value("(document.getElementById('c2').indeterminate = true, 1)")
        let result = await read(bed, ReadPageFilter(role: "checkbox"))
        guard case .array(let boxes)? = result["elements"] else { Issue.record("\(result)"); return }
        #expect(boxes.map { $0["name"]?.stringValue } == ["Agree", "Partial"])
        #expect(boxes[0]["checked"] == true && boxes[1]["checked"] == "mixed")
        #expect(boxes.allSatisfy { $0["value"] == nil })
    }

    /// J-8: role and selector narrow, offset pages, and the slice happens before refs are minted.
    @Test func readPageNarrowsByRoleAndSelectorAndPagesByOffset() async throws {
        let bed = try await bed()
        #expect(names(await read(bed, ReadPageFilter(role: "BUTTON"))).prefix(3) == ["Save", "Save changes", "Autosave"])
        #expect(names(await read(bed, ReadPageFilter(selector: "h1"))) == ["Page Title"])
        let page = await read(bed, ReadPageFilter(selector: "button", offset: 1))
        #expect(names(page).first == "Save changes")
        #expect(page["offset"] == 1)
        #expect(await read(bed, ReadPageFilter(selector: "["))["error"] == "invalid selector: [")
        // Skipping costs no refs: the counter only advanced for what was returned.
        let counterBefore = await bed.value("window.\(BrowserLimits.refCounter) || 0").intValue ?? 0
        _ = await read(bed, ReadPageFilter(selector: "button", offset: 2))
        let counterAfter = await bed.value("window.\(BrowserLimits.refCounter) || 0").intValue ?? 0
        #expect(counterAfter - counterBefore == 1, "one button after the offset of 2")
    }

    /// J-8: `truncated` means more after this page.
    @Test func readPageCapsAtTwoHundredAndSaysThereIsMore() async throws {
        let many = (1...230).map { "<button>b\($0)</button>" }.joined()
        let bed = try await bed(body: many)
        let first = await read(bed)
        #expect(first["total"] == 230 && first["truncated"] == true)
        #expect(names(first).count == 200)
        let rest = await read(bed, ReadPageFilter(offset: 200))
        #expect(names(rest).count == 30 && rest["truncated"] == false && rest["offset"] == 200)
    }

    /// J-11: readiness and shape on every read; the first read of a page is never settled.
    @Test func readsReportReadinessWithSettledFlippingOnlyWhenTheDOMIsQuiet() async throws {
        let bed = try await bed(
            body: "<iframe></iframe><div id=host></div><script>document.getElementById('host').attachShadow({mode:'open'})</script>")
        let first = await read(bed)
        #expect(first["settled"] == false, "the first read of any page cannot vouch for quiet")
        #expect(first["frames"] == 1 && first["shadowRoots"] == 1)
        try await Task.sleep(for: .milliseconds(650))
        #expect(await read(bed)["settled"] == true)
        await bed.value("(document.body.appendChild(document.createElement('p')), 1)")
        #expect(await read(bed)["settled"] == false, "a mutation restarts the quiet period")
    }

    /// J-7: page text is innerText with the readiness fields.
    @Test func pageTextIsWhatIsRendered() async throws {
        let bed = try await bed(body: "<p>Visible text</p><script>var hiddenScript = 1</script><style>p{color:red}</style>")
        let result = await bed.value(pageTextScript)
        #expect(result["text"]?.stringValue?.contains("Visible text") == true)
        #expect(result["text"]?.stringValue?.contains("hiddenScript") == false)
        #expect(result["readyState"] == "complete" && result["frames"] == 0)
    }

    // MARK: Refs and semantic targets

    /// J-10: a ref from another document is stale.
    @Test func aRefFromAnotherDocumentIsStale() async throws {
        let bed = try await bed()
        let ref = try #require(await read(bed, ReadPageFilter(selector: "#b1"))["elements"]?[0]?["ref"]?.stringValue)
        #expect(await bed.value(refResolverExpression(ref) + " instanceof Element") == true)
        await bed.load("/controls?again")
        #expect(await bed.value(refResolverExpression(ref)) == .null)
        #expect(staleRefError(ref).contains("call readPage again"))
        _ = await read(bed, ReadPageFilter(selector: "#b1"))
        #expect(await bed.value(refResolverExpression(ref)) == .null, "and a fresh read never rebinds it")
    }

    private func hit(_ bed: PageBed, _ target: SemanticTarget) async -> JSONValue {
        await bed.value(hitTestPointScript(semanticResolverExpression(target)))
    }

    /// J-10: the strictness ladder, hard role filter, ambiguity listing and `nth`.
    @Test func semanticTargetsMatchByTheStrictnessLadder() async throws {
        let bed = try await bed()
        // An exact name is never ambiguous merely because it prefixes a longer one.
        let exact = await hit(bed, SemanticTarget(role: "button", name: "Save"))
        #expect(exact["resolved"] == true && exact["matched"] == true)
        #expect(exact["intended"]?["name"] == "Save")
        // Case-insensitive, then substring.
        #expect(await hit(bed, SemanticTarget(name: "save CHANGES"))["intended"]?["name"] == "Save changes")
        #expect(await hit(bed, SemanticTarget(name: "autos"))["intended"]?["name"] == "Autosave")
        // Ambiguity fails, listing the candidates.
        let ambiguous = try #require(await hit(bed, SemanticTarget(role: "button", name: "ave"))["reason"]?.stringValue)
        #expect(ambiguous.contains("3 elements match role=\"button\" name=\"ave\""), "\(ambiguous)")
        #expect(ambiguous.contains("[0] button \"Save\" <button> at (") && ambiguous.contains("pass nth"))
        #expect(await hit(bed, SemanticTarget(role: "button", name: "ave", nth: 1))["intended"]?["name"] == "Save changes")
        let outOfRange = try #require(await hit(bed, SemanticTarget(role: "button", name: "ave", nth: 7))["reason"]?.stringValue)
        #expect(outOfRange.contains("nth 7 is out of range: only 3 element(s) match"))
    }

    @Test func aRoleThatIsTooStrictDiagnosesTheNearMissAndNothingClicksAcrossRoles() async throws {
        let bed = try await bed()
        let near = try #require(await hit(bed, SemanticTarget(role: "link", name: "Save"))["reason"]?.stringValue)
        #expect(
            near.contains("no link named \"Save\"") && near.contains("a button with that name exists — retry without --role"), "\(near)")
        let none = try #require(await hit(bed, SemanticTarget(name: "Nothing like this"))["reason"]?.stringValue)
        #expect(none.contains("no element matches name=\"Nothing like this\"") && none.contains("read-page shows"))
        #expect(await hit(bed, SemanticTarget(selector: "["))["reason"] == "invalid selector: [")
        #expect(await hit(bed, SemanticTarget(selector: "#hiddenbtn"))["resolved"] == false, "a hidden element never matches")
    }

    /// J-9: find mints refs only for what it returns.
    @Test func findMintsRefsOnlyForTheMatchesItReturns() async throws {
        let bed = try await bed()
        let candidates = await bed.value(findCandidatesScript(token: "t1"))
        guard case .array(let found)? = candidates["candidates"] else { Issue.record("\(candidates)"); return }
        #expect(found.allSatisfy { $0["ref"] == nil }, "described without refs")
        #expect(await bed.value("window.\(BrowserLimits.refCounter) || 0") == 0, "and none spent")
        let index = try #require(found.firstIndex { $0["name"]?.stringValue == "Save" })
        let minted = await bed.value(mintFindRefsScript(token: "t1", indices: [index, 9999]))
        let refs = try #require(minted["refs"])
        #expect(refs[0]?.stringValue?.hasPrefix("e1-") == true && refs[1] == .null, "one ref; a gone element is null")
        let again = await bed.value(mintFindRefsScript(token: "t1", indices: [0]))
        #expect(again["error"]?.stringValue?.contains("run find again") == true, "the pool is used once")
        let other = await bed.value(mintFindRefsScript(token: "another", indices: [0]))
        #expect(other["error"]?.stringValue?.contains("run find again") == true)
    }

    // MARK: Hit test, focus, fill, scroll, run

    /// J-12: a coordinate is described, never gated; a covered element fails matched.
    @Test func hitTestingScrollsIntoViewAndSaysWhatSitsAtAPoint() async throws {
        let bed = try await bed(body: Self.controls + "<button id=late style='margin-top:10px'>Late one</button>")
        let described = await bed.value(describePointScript(x: 5, y: 5))
        #expect(described.stringValue == nil && described["tag"]?.stringValue != nil)
        #expect(await bed.value(describePointScript(x: -50, y: -50)) == .null, "outside the document")
        let covered = try await self.bed(
            body: "<button id=under>Under</button><div style='position:fixed;inset:0;background:#fff'>cover</div>")
        let result = await covered.value(hitTestPointScript(semanticResolverExpression(SemanticTarget(name: "Under"))))
        #expect(result["resolved"] == true && result["matched"] == false, "an overlay covers it")
        #expect(result["element"]?["tag"] == "div")
    }

    /// J-14: focus goes to the element itself.
    @Test func focusTargetsTheElementItselfAndSaysWhyWhenItCannot() async throws {
        let bed = try await bed()
        let ref = try #require(await read(bed, ReadPageFilter(selector: "#q"))["elements"]?[0]?["ref"]?.stringValue)
        #expect(await bed.value(focusTargetScript(refResolverExpression(ref)))["focused"] == true)
        #expect(await bed.value("document.activeElement.id") == "q")
        let plain = try #require(await read(bed, ReadPageFilter(selector: "h1"))["elements"]?[0]?["ref"]?.stringValue)
        let refused = await bed.value(focusTargetScript(refResolverExpression(plain)))
        #expect(refused["focused"] == false && refused["reason"]?.stringValue?.contains("did not take focus") == true)
    }

    private func fill(_ bed: PageBed, _ selector: String, _ value: String) async -> JSONValue {
        await bed.value("(document.querySelector('\(selector)').focus(), 1)")
        return await bed.value(fillFocusedScript(value))
    }

    /// J-17: each element kind is filled its own way and read back.
    @Test func fillWritesEachElementKindWholeAndReadsItBack() async throws {
        let bed = try await bed()
        #expect(await fill(bed, "#q", "new value") == ["mode": "set", "length": 9, "tag": "input"])
        #expect(await bed.value("document.getElementById('q').value") == "new value")
        let multiline = await fill(bed, "#t", "one\ntwo\nthree")
        #expect(multiline["mode"] == "set" && multiline["length"] == 13 && multiline["tag"] == "textarea")
        // A single-line input sanitizes on write: the read-back length says so.
        #expect(await fill(bed, "#q", "a\nb")["length"] == 2)
        // A select by value or by visible label, with real events; an unmatched option lists what is valid.
        #expect(await fill(bed, "#col", "Red")["matched"] == true)
        #expect(await bed.value("document.getElementById('col').value") == "r")
        #expect(await fill(bed, "#col", "g")["matched"] == true)
        let unmatched = await fill(bed, "#col", "Purple")
        #expect(unmatched["matched"] == false && unmatched["options"]?[0]?["label"] == "Red")
        // A contenteditable through editing commands.
        let editable = await fill(bed, "#ce", "typed text")
        #expect(editable["mode"] == "editable" && editable["length"] == 10)
        #expect(await bed.value("document.getElementById('ce').innerText") == "typed text")
        // Checkboxes and buttons aren't text fields.
        #expect(await fill(bed, "#c1", "x")["mode"] == "unfillable")
        #expect(await fill(bed, "#sub", "x")["mode"] == "unfillable")
        await bed.value("(document.activeElement.blur(), 1)")
        #expect(await bed.value(fillFocusedScript("x"))["mode"] == "none")
    }

    @Test func fillGoesThroughTheNativeSetterSoFrameworksSeeTheChange() async throws {
        let bed = try await bed(
            head:
                "<script>window.seen = []; addEventListener('input', e => seen.push('input:' + e.target.value + ':' + e.isTrusted), true); addEventListener('change', e => seen.push('change:' + e.target.value), true)</script>"
        )
        _ = await fill(bed, "#q", "framework")
        #expect(await bed.value("JSON.stringify(seen)") == "[\"input:framework:false\",\"change:framework\"]")
    }

    /// J-16: instantaneous even on a smooth page; the step is from the page's own viewport.
    @Test func scrollReportsWhereItLandedOnASmoothPageToo() async throws {
        let bed = try await bed(head: "<style>html{scroll-behavior:smooth}</style>")
        let viewportHeight = await bed.value("window.innerHeight").doubleValue ?? 0
        let down = await bed.value(scrollScript(direction: .down))
        #expect(down["y"]?.doubleValue == (viewportHeight * 0.8).rounded(), "the step is 80% of the page's own height, settled at once")
        #expect(await bed.value(scrollScript(direction: .down, amount: 100))["y"]?.doubleValue == (viewportHeight * 0.8).rounded() + 100)
        #expect(await bed.value(scrollScript(direction: .up, amount: 100))["y"]?.doubleValue == (viewportHeight * 0.8).rounded())
        #expect(await bed.value(scrollScript(direction: .right, amount: 10))["x"] == 0, "nothing to scroll sideways")
    }

    /// J-19: a throw comes back as data; anything that isn't an expression is refused.
    @Test func executeWrapsCallerCodeSoAThrowIsDataNotAFailure() async throws {
        let bed = try await bed()
        #expect(await bed.value(executeScript("1 + 1")) == ["ok": true, "value": 2])
        #expect(await bed.value(executeScript("Promise.resolve('later')")) == ["ok": true, "value": "later"], "a promise is awaited")
        let thrown = await bed.value(executeScript("(() => { throw new Error('deliberate') })()"))
        #expect(thrown["ok"] == false && thrown["error"]?.stringValue?.contains("deliberate") == true)
        let nothing = await bed.value(executeScript("undefined"))
        #expect(nothing["ok"] == true && (nothing["value"] ?? .null) == .null, "undefined comes back as null")
        // A statement is not an expression: the engine's own syntax error, not a script that ran.
        switch await bed.page.evaluate(executeScript("let x = 1; x")) {
        case .failure(let error):
            #expect(
                error.message.contains("Unexpected") || error.message.lowercased().contains("syntax") || error == .unavailable, "\(error)")
        case .success(let value): Issue.record("a statement ran: \(value)")
        }
    }

    /// J-15: the editing commands run in the page.
    @Test func editingCommandsRunInThePage() async throws {
        let bed = try await bed()
        await bed.value("(document.getElementById('q').focus(), 1)")
        let selected = await bed.value(editingCommandScript("selectAll"))
        #expect(selected["applied"] == true && selected["element"]?["tag"] == "input")
        #expect(await bed.value("document.getElementById('q').selectionStart + '-' + document.getElementById('q').selectionEnd") == "0-3")
    }

    // MARK: Waiting

    /// J-20: the in-page halves resolve, never reject, and report what matched.
    @Test func theWaitScriptsResolveInThePage() async throws {
        let bed = try await bed(
            body:
                "<p id=p>waiting</p><script>setTimeout(() => { p.textContent = 'ready now'; document.body.insertAdjacentHTML('beforeend', '<i id=late>late</i>') }, 150)</script>"
        )
        let text = await bed.value(waitConditionScript(WaitConditionSpec(text: "ready now"), budgetMs: 5_000, pollMs: 50))
        #expect(text == ["settled": true])
        let selector = await bed.value(waitConditionScript(WaitConditionSpec(selector: "#late"), budgetMs: 5_000, pollMs: 50))
        #expect(selector["settled"] == true && selector["tag"] == "i" && selector["ref"]?.stringValue?.hasPrefix("e") == true)
        #expect(selector["rect"]?["width"]?.doubleValue ?? 0 > 0)
        let gone = await bed.value(waitConditionScript(WaitConditionSpec(text: "waiting", gone: true), budgetMs: 1_000, pollMs: 50))
        #expect(gone == ["settled": true])
        #expect(await bed.value(waitConditionScript(WaitConditionSpec(text: "never"), budgetMs: 200, pollMs: 50)) == ["settled": false])
        let invalid = await bed.value(waitConditionScript(WaitConditionSpec(selector: "["), budgetMs: 500, pollMs: 50))
        #expect(invalid["error"] == "invalid selector: [")
        #expect(await bed.value(domIdleScript(quietMs: 100, budgetMs: 2_000)) == ["settled": true])
    }
}
