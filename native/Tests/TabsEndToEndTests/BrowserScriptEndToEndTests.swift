import Foundation
import TabsPluginSDK
import Testing

/// The script, wait and resource verbs against the running app (docs/BROWSER.md J-18…J-22, J-26, J-27, H-12's
/// browser half): the real `tabs-ctl` under Node, the socket, the built bundle's plugin, a real page from a
/// loopback server in this process. Ports of the Electron specs `e2e/external-control-flow.spec.ts`,
/// `external-control.spec.ts` and `external-control-read.spec.ts`, same titles (camelCased), same assertions
/// where the engine allows; each difference is said where it happens.
///
/// The Electron tests drive every page change *from the test* (through the fixtures' own helpers) rather than from
/// page-side timers, so "the wait was already pending when the condition arrived" is a matter of test-side
/// sequencing: start the wait, give its subprocess a generous head start, then trigger the change.
@Suite(.serialized, .sharedApp, .timeLimit(.minutes(3)), .enabled(if: LaunchedApp.nodeIsInstalled, "tabs-ctl runs under Node"))
struct BrowserScriptEndToEndTests {
    /// A session with a pane it owns, on `path` of a fresh standard server (or on `about:blank`).
    private func session(_ path: String? = "/page") async throws -> (agent: AgentSession, pane: String, server: FixtureServer) {
        let server = try await FixtureServer.startStandard()
        let agent = try await AgentSession.open(SharedApp.fresh())
        let pane = try await agent.createBrowserPane(url: path.map(server.url) ?? "about:blank")
        return (agent, pane, server)
    }

    private func run(_ agent: AgentSession, _ command: String, _ pane: String, _ flags: [String] = []) async throws -> LaunchedApp.CtlResult
    {
        try await agent.ctl([command, "--pane", pane] + flags)
    }

    private func execute(_ agent: AgentSession, _ pane: String, _ code: String, _ flags: [String] = []) async throws
        -> LaunchedApp.CtlResult
    {
        try await run(agent, "execute-js", pane, ["--code", code] + flags)
    }

    private func steps(_ result: LaunchedApp.CtlResult) -> [JSONValue] {
        if case .array(let list)? = result.result["steps"] { list } else { [] }
    }

    // MARK: execute-js

    @Test func anAgentCanRunScriptInAPaneAndGetsCleanErrorsWhenItCannot() async throws {
        let (agent, pane, server) = try await session()
        defer { server.stop() }
        #expect(try await agent.text(pane, "#status") == "idle")

        #expect(try await execute(agent, pane, "1 + 1").result["value"] == 2)
        // A structured value, and one that proves the script ran in the real page.
        #expect(try await execute(agent, pane, "({ title: document.title })").result["value"] == ["title": "Fixture"])
        // A promise is awaited rather than returned as a pending object.
        #expect(try await execute(agent, pane, "Promise.resolve('resolved')").result["value"] == "resolved")

        // A script that throws fails with its *own* message.
        let threw = try await execute(agent, pane, "(() => { throw new Error('deliberate') })()")
        #expect(!threw.ok && threw.error?.contains("deliberate") == true, "\(threw.response)")

        // Code that isn't an expression is told so, actionably.
        let statement = try await execute(agent, pane, "const x = 1; x")
        #expect(!statement.ok && statement.error?.contains("IIFE") == true, "\(statement.response)")

        // So does one returning something JSON cannot represent.
        let circular = try await execute(agent, pane, "(() => { const a = {}; a.self = a; return a })()")
        #expect(!circular.ok && circular.error?.contains("cannot be serialized") == true, "\(circular.response)")

        // A DOM node does not error: what arrives is an ordinary (useless) object, so the docs' advice to
        // return a property instead of an element stays accurate.
        let node = try await execute(agent, pane, "document.body")
        #expect(node.ok && node.result["value"] == .emptyObject)
        // (The form-input half of the Electron test is the input family's.)
    }

    @Test func scriptingVerbsRefuseAPaneThisCallerDoesNotOwn() async throws {
        try await AgentSession.expectRefusedForForeignPane(SharedApp.fresh()) { foreign in
            [["execute-js", "--pane", foreign, "--code", "document.title"], ["read-console", "--pane", foreign]]
        }
    }

    @Test func oversizedResultsAreTruncatedHonestlyNeverSilently() async throws {
        let (agent, pane, server) = try await session()
        defer { server.stop() }
        let big = try await execute(agent, pane, "'x'.repeat(60000)")
        #expect(big.ok)
        #expect(big.result["truncated"] == true)
        #expect(big.result["value"]?.stringValue?.count ?? 0 <= 50_000)
    }

    @Test func executeJsOutWritesTheFullResultToAFileInsteadOfTruncating() async throws {
        let (agent, pane, server) = try await session()
        defer { server.stop() }

        // Bare --out: a generated path in the app's swept directory. A string result lands raw, and in full,
        // past the cap the inline path would have applied.
        let text = try await execute(agent, pane, "'x'.repeat(60000)", ["--out"])
        #expect(text.ok, "\(text.response)")
        #expect(text.result["truncated"] == false && text.result["format"] == "text" && text.result["bytes"] == 60000)
        // The value never rides the socket on this path: only the path does.
        #expect(text.result["value"] == nil && text.result["serializedResult"] == nil)
        let generated = try #require(text.result["path"]?.stringValue)
        #expect(generated.contains("agent-output") && generated.hasSuffix(".txt"))
        #expect(try String(contentsOfFile: generated, encoding: .utf8) == String(repeating: "x", count: 60000))

        // --out <path>: written exactly there (tabs-ctl resolves against the caller's cwd; this one is already
        // absolute), pretty-printed JSON for a non-string value, parseable as is.
        let directory = FileManager.default.temporaryDirectory.appending(
            path: "tabs-exec-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let outPath = directory.appending(path: "result.json").path
        let json = try await execute(agent, pane, "({ n: 1, list: [1, 2] })", ["--out", outPath])
        #expect(json.ok, "\(json.response)")
        #expect(json.result["path"] == .string(outPath) && json.result["format"] == "json")
        let written = try String(contentsOfFile: outPath, encoding: .utf8)
        #expect(try JSONDecoder().decode(JSONValue.self, from: Data(written.utf8)) == ["n": 1, "list": [1, 2]])
        #expect(written.contains("\n"))

        // A caller-named path is never clobbered: same rule as save-resource.
        let clobber = try await execute(agent, pane, "1", ["--out", outPath])
        #expect(!clobber.ok && clobber.error?.contains("refusing to overwrite") == true, "\(clobber.response)")
    }

    // MARK: batch

    @Test func aBatchRunsItsRequestsInOrderStopsAtTheFirstFailureAndRefusesNesting() async throws {
        let (agent, pane, server) = try await session()
        defer { server.stop() }
        #expect(try await agent.text(pane, "#status") == "idle")
        // The Electron test drives `click` and `get-page-text`; the ordering is the point, so the page's own script stands
        // in for both (those verbs are another family's).
        let click: JSONValue = [
            "type": "executeJavaScript", "targetPaneId": .string(pane), "code": "(document.getElementById('go').click(), true)",
        ]
        let read: JSONValue = [
            "type": "executeJavaScript", "targetPaneId": .string(pane), "code": "document.getElementById('status').textContent",
        ]
        let missing: JSONValue = [
            "type": "executeJavaScript", "targetPaneId": .string(pane), "code": "document.getElementById('nope').click()",
        ]
        let info: JSONValue = ["type": "getPaneInfo", "targetPaneId": .string(pane)]
        func batch(_ requests: [JSONValue], _ flags: [String] = []) async throws -> LaunchedApp.CtlResult {
            let json = String(decoding: try JSONEncoder().encode(JSONValue.array(requests)), as: UTF8.self)
            return try await agent.ctl(["batch", "--requests", json] + flags)
        }

        // Ordering is the point: the click must land before the text is read back.
        let batched = try await batch([click, read])
        #expect(batched.ok && batched.exitCode == 0)
        let transcript = steps(batched)
        #expect(transcript.count == 2)
        // The transcript names what ran and how long it took, per step.
        #expect(transcript.compactMap { $0["type"]?.stringValue } == ["executeJavaScript", "executeJavaScript"])
        #expect(transcript.allSatisfy { $0["ok"] == true && ($0["durationMs"]?.intValue ?? -1) >= 0 })
        #expect(transcript[1]["result"]?["value"] == "clicked")

        // A failing step stops the batch, and the caller can see exactly where: the transcript stays aligned to
        // what was sent, with the unrun tail marked skipped rather than absent.
        let stopped = try await batch([info, missing, read])
        #expect(stopped.result["stoppedAt"] == 1 && stopped.exitCode == 1)
        let stoppedSteps = steps(stopped)
        #expect(stoppedSteps.count == 3 && stoppedSteps[0]["ok"] == true && stoppedSteps[1]["ok"] == false)
        #expect(stoppedSteps[2] == ["type": "executeJavaScript", "skipped": true])

        // --continue-on-error runs the same sequence to the end: the failure stays visible in its step, nothing is
        // skipped, and the exit code still reports.
        let continued = try await batch([info, missing, read], ["--continue-on-error"])
        #expect(continued.ok && continued.exitCode == 1 && continued.result["stoppedAt"] == nil)
        let continuedSteps = steps(continued)
        #expect(continuedSteps.count == 3 && continuedSteps[1]["ok"] == false && continuedSteps[2]["ok"] == true)
        #expect(continuedSteps[2]["result"]?["value"] == "clicked")

        // A sub-request naming somebody else's pane is refused like any other.
        let foreign = try await batch([["type": "executeJavaScript", "targetPaneId": .string(agent.caller), "code": "1"]])
        #expect(steps(foreign)[0]["error"]?.stringValue?.contains("not the owner") == true)

        let refused: [(String, JSONValue)] = [
            ("nested batch", ["type": "batch", "requests": []]),
            ("createBrowserPane", ["type": "createBrowserPane", "url": "about:blank"]),
        ]
        for (label, step) in refused {
            let rejected = try await batch([step])
            #expect(!rejected.ok || rejected.exitCode != 0, "\(label) should be refused")
        }
    }

    // MARK: wait-for

    @Test func waitForResolvesWhenTextAppearsAndHandsBackAUsableRefForASelectorMatch() async throws {
        let (agent, pane, server) = try await session("/waity")
        defer { server.stop() }

        // Text: the wait is pending (started, plus a head start) before the text exists; one call blocks until it
        // appears and reports how long that took.
        async let textWait = run(agent, "wait-for", pane, ["--text", "MAGIC_DONE", "--timeout", "30000"])
        try await Task.sleep(for: .seconds(1))
        _ = try await execute(agent, pane, "window.appendReady('MAGIC_DONE')")
        let text = try await textWait
        #expect(text.ok, "\(text.response)")
        let elapsed = text.result["elapsedMs"]?.intValue ?? 0
        #expect(elapsed >= 500 && elapsed < 30000)

        // A selector only matches what the page shows: #panel is in the DOM but display:none, so a bounded wait for
        // it times out naming the condition.
        let hidden = try await run(agent, "wait-for", pane, ["--selector", "#panel", "--timeout", "1200"])
        #expect(!hidden.ok)
        #expect(hidden.error?.contains("timed out after 1200ms") == true && hidden.error?.contains("#panel") == true)

        // Revealed mid-wait, the match reports a read-page-compatible ref: which the natural next step (use it) needs
        // no read-page round trip for.
        async let selectorWait = run(agent, "wait-for", pane, ["--selector", "#panel", "--timeout", "30000"])
        try await Task.sleep(for: .seconds(1))
        _ = try await execute(agent, pane, "window.revealPanel()")
        let selector = try await selectorWait
        #expect(selector.ok, "\(selector.response)")
        #expect(selector.result["tag"] == "div" && (selector.result["rect"]?["width"]?.doubleValue ?? 0) > 0)
        let ref = try #require(selector.result["ref"]?.stringValue)
        let scoped = try await run(agent, "assert", pane, ["--selector", "#panel"])
        #expect(scoped.ok && scoped.result["ref"] != nil)
        // (The Electron test clicks the ref, a verb of the input family; the ref itself is read back here.)
        #expect(ref.wholeMatch(of: /e[0-9]+-[0-9a-z]+/) != nil, "\(ref)")
    }

    @Test func waitForGoneWaitsOutASpinnerAndValidatesItsConditionShapeLoudly() async throws {
        let (agent, pane, server) = try await session("/waity")
        defer { server.stop() }

        async let goneWait = run(agent, "wait-for", pane, ["--selector", "#spinner", "--gone", "--timeout", "30000"])
        try await Task.sleep(for: .seconds(1))
        _ = try await execute(agent, pane, "window.hideSpinner()")
        let gone = try await goneWait
        #expect(gone.ok && (gone.result["elapsedMs"]?.intValue ?? 0) >= 500, "\(gone.response)")

        // A wait that never holds fails at its bound, naming the condition: and the caller really did wait that long.
        let started = ContinuousClock.now
        let timedOut = try await run(agent, "wait-for", pane, ["--text", "NEVER_THERE", "--timeout", "1500"])
        #expect(ContinuousClock.now - started >= .milliseconds(1500))
        #expect(!timedOut.ok)
        #expect(timedOut.error?.contains("timed out after 1500ms") == true)
        #expect(timedOut.error?.contains("\"NEVER_THERE\"") == true && timedOut.error?.contains("appear") == true)

        // The wire shape is validated before anything waits: no condition, two conditions, and gone without something
        // to invert are each named.
        let none = try await run(agent, "wait-for", pane)
        #expect(!none.ok && none.error?.contains("needs a condition") == true)
        let two = try await run(agent, "wait-for", pane, ["--text", "x", "--idle"])
        #expect(!two.ok && two.error?.contains("exactly one condition") == true)
        let badGone = try await run(agent, "wait-for", pane, ["--idle", "--gone"])
        #expect(!badGone.ok && badGone.error?.contains("gone inverts") == true)
    }

    @Test func waitForSurvivesThePageNavigatingMidWaitAndUrlContainsRidesNavigation() async throws {
        let (agent, pane, server) = try await session("/waity")
        defer { server.stop() }

        // The URL wait: pending well before the test steers the page elsewhere.
        async let urlWait = run(agent, "wait-for", pane, ["--url-contains", "/other", "--timeout", "30000"])
        try await Task.sleep(for: .seconds(1))
        _ = try await execute(agent, pane, "location.href = '/other'")
        let url = try await urlWait
        #expect(url.ok, "\(url.response)")
        #expect(url.result["url"]?.stringValue?.contains("/other") == true)
        #expect((url.result["elapsedMs"]?.intValue ?? 0) >= 500)

        // The load-bearing case for the in-page waits: a cross-document navigation destroys the context holding the
        // watcher (and strands the pending evaluation: measured, it never settles either way), so only the supervisor's
        // re-injection can let this resolve. The condition's text exists solely on the page the mid-wait navigation lands on.
        _ = try await run(agent, "navigate", pane, ["--url", server.url("/waity")])
        async let acrossNavigation = run(agent, "wait-for", pane, ["--text", "Elsewhere", "--timeout", "30000"])
        try await Task.sleep(for: .seconds(1))
        _ = try await execute(agent, pane, "location.href = '/other'")
        let across = try await acrossNavigation
        #expect(across.ok && (across.result["elapsedMs"]?.intValue ?? 0) >= 500, "\(across.response)")
    }

    @Test func waitForIdleSettlesOnlyOnceTheDOMStopsChurning() async throws {
        let (agent, pane, server) = try await session("/waity")
        defer { server.stop() }
        // The churn is already running when the wait starts, and keeps mutating for ~2.5s more; idle may only resolve
        // after the churn ends plus the quiet period, so a resolution under the churn's remaining span means the quiet
        // clock fired mid-churn: the failure this test exists to catch.
        _ = try await execute(agent, pane, "window.churn(2500)")
        let idle = try await run(agent, "wait-for", pane, ["--idle", "--timeout", "30000"])
        #expect(idle.ok, "\(idle.response)")
        let elapsed = idle.result["elapsedMs"]?.intValue ?? 0
        #expect(elapsed >= 1000 && elapsed < 15000, "\(elapsed)")
    }

    @Test func waitForComposesInsideABatchOnItsOwnPerRequestBudget() async throws {
        let (agent, pane, server) = try await session("/waity")
        defer { server.stop() }
        // Click-wait-read as one call, with the wait sized past the 5s default budget on purpose: a sub-request priced by
        // the batch's own budget (or the default) instead of the wait's per-request budget would time out at 5s, so the
        // ~6.5s elapsed here is the arithmetic composing.
        let requests: [JSONValue] = [
            [
                "type": "executeJavaScript", "targetPaneId": .string(pane),
                "code": "(setTimeout(() => window.appendReady('BATCH_DONE'), 6500), true)",
            ],
            ["type": "waitFor", "targetPaneId": .string(pane), "text": "BATCH_DONE", "timeoutMs": 30000],
            ["type": "executeJavaScript", "targetPaneId": .string(pane), "code": "document.body.innerText"],
        ]
        let json = String(decoding: try JSONEncoder().encode(JSONValue.array(requests)), as: UTF8.self)
        let batched = try await agent.ctl(["batch", "--requests", json])
        #expect(batched.ok && batched.result["stoppedAt"] == nil, "\(batched.response)")
        let transcript = steps(batched)
        #expect(transcript.count == 3 && transcript[1]["ok"] == true)
        #expect((transcript[1]["result"]?["elapsedMs"]?.intValue ?? 0) > 5000)
        // The transcript's own timing agrees with the wait it wraps.
        #expect((transcript[1]["durationMs"]?.intValue ?? 0) > 5000)
        #expect(transcript[2]["result"]?["value"]?.stringValue?.contains("BATCH_DONE") == true)
    }

    // MARK: assert

    @Test func assertChecksAConditionRightNowPassWithAUsableRefFailNamingThePremise() async throws {
        let (agent, pane, server) = try await session("/waity")
        defer { server.stop() }

        // Text that is on the page: holds, exit 0.
        let pass = try await run(agent, "assert", pane, ["--text", "spinner is spinning"])
        #expect(pass.ok && pass.exitCode == 0)

        // A selector match hands back a ref, like wait-for's: so "assert it's there, then act on it" needs no read-page.
        let matched = try await run(agent, "assert", pane, ["--selector", "#spinner"])
        #expect(matched.ok && matched.result["tag"] == "div")
        #expect(matched.result["ref"]?.stringValue?.wholeMatch(of: /e[0-9]+-[0-9a-z]+/) != nil)

        // #panel exists but is hidden, so asserting it fails: quickly (the fixed check budget, nowhere near wait-for's
        // 10s default) and naming the premise, which is what a batch transcript surfaces.
        let started = ContinuousClock.now
        let failed = try await run(agent, "assert", pane, ["--selector", "#panel"])
        #expect(!failed.ok && failed.exitCode == 1)
        #expect(failed.error?.contains("assertion failed") == true && failed.error?.contains("#panel") == true)
        #expect(ContinuousClock.now - started < .seconds(8))

        // --gone inverts: the spinner is showing, so asserting it gone fails...
        let goneFailed = try await run(agent, "assert", pane, ["--selector", "#spinner", "--gone"])
        #expect(!goneFailed.ok && goneFailed.error?.contains("still matches") == true)
        // ...and holds once the page hides it.
        _ = try await execute(agent, pane, "window.hideSpinner()")
        #expect(try await run(agent, "assert", pane, ["--selector", "#spinner", "--gone"]).ok)

        // The URL condition works both ways too.
        let url = try await run(agent, "assert", pane, ["--url-contains", "/waity"])
        #expect(url.ok && url.result["url"]?.stringValue?.contains("/waity") == true)
        let urlFailed = try await run(agent, "assert", pane, ["--url-contains", "/nowhere"])
        #expect(!urlFailed.ok && urlFailed.error?.contains("assertion failed") == true)

        // Condition-shape validation mirrors wait-for's, naming its own verb.
        let none = try await run(agent, "assert", pane)
        #expect(none.error?.contains("assert needs a condition") == true)
        let two = try await run(agent, "assert", pane, ["--text", "x", "--selector", "#y"])
        #expect(two.error?.contains("exactly one condition") == true)
    }

    @Test func anAssertStepMakesABatchSelfVerifyingTheTranscriptNamesThePremiseThatBroke() async throws {
        let (agent, pane, server) = try await session("/waity")
        defer { server.stop() }
        let requests: [JSONValue] = [
            ["type": "assert", "targetPaneId": .string(pane), "text": "spinner is spinning"],
            ["type": "assert", "targetPaneId": .string(pane), "text": "NOT_ON_THIS_PAGE"],
            ["type": "executeJavaScript", "targetPaneId": .string(pane), "code": "document.body.innerText"],
        ]
        let json = String(decoding: try JSONEncoder().encode(JSONValue.array(requests)), as: UTF8.self)
        let batched = try await agent.ctl(["batch", "--requests", json])
        #expect(batched.ok && batched.exitCode == 1)
        #expect(batched.result["stoppedAt"] == 1)
        let transcript = steps(batched)
        #expect(transcript[0]["ok"] == true)
        #expect(transcript[1]["error"]?.stringValue?.contains("assertion failed") == true)
        #expect(transcript[1]["error"]?.stringValue?.contains("NOT_ON_THIS_PAGE") == true)
        #expect(transcript[2] == ["type": "executeJavaScript", "skipped": true])
    }

    // MARK: read-console

    @Test func anAgentCanReadTheConsoleIncludingAMessageThatArrivesLate() async throws {
        let (agent, pane, server) = try await session()
        defer { server.stop() }
        func messages(_ flags: [String] = []) async throws -> [JSONValue] {
            if case .array(let list)? = try await run(agent, "read-console", pane, flags).result["messages"] { return list }
            return []
        }
        func texts(_ list: [JSONValue]) -> [String] { list.compactMap { $0["text"]?.stringValue } }
        let wanted = ["fixture ready", "a warning happened", "an error happened", "delayed message"]
        var all = try await messages()
        for _ in 0..<100 where !wanted.allSatisfy({ texts(all).contains($0) }) {
            try await Task.sleep(for: .milliseconds(100))
            all = try await messages()
        }
        // Emitted from a setTimeout, so it can only be here because the buffer captures as messages arrive.
        #expect(wanted.allSatisfy { texts(all).contains($0) }, "\(texts(all))")
        let levels = Set(all.compactMap { $0["level"]?.stringValue })
        #expect(levels.contains("error") && levels.contains("warning"))

        // A pattern narrows the read, and sinceSeq makes repeat polling incremental.
        #expect(texts(try await messages(["--pattern", "^a warning happened$"])) == ["a warning happened"])

        // An unparseable pattern is refused, not silently matched as literal text.
        let bad = try await run(agent, "read-console", pane, ["--pattern", "["])
        #expect(!bad.ok && bad.error?.contains("--pattern") == true)

        let lastSeq = all.compactMap { $0["seq"]?.intValue }.max() ?? 0
        #expect(try await messages(["--since-seq", String(lastSeq)]).isEmpty)

        // Navigating starts a fresh page, and so a fresh console.
        _ = try await run(agent, "navigate", pane, ["--url", server.url("/other")])
        _ = try await agent.state(pane) { $0["title"] == "Elsewhere" }
        let carriedOver = texts(try await messages()).filter { wanted.contains($0) }
        #expect(carriedOver.isEmpty)
    }

    // MARK: save-resource

    private func blobReady(_ agent: AgentSession, _ pane: String) async throws {
        for _ in 0..<100 {
            if try await agent.eval(pane, "window.__blobReady") == true { return }
            try await Task.sleep(for: .milliseconds(100))
        }
        Issue.record("the blob page never minted its blob")
    }

    @Test func saveResourceGetsBytesOutOfAPageABlobBehindAStrictCSPAndElementSrcs() async throws {
        let (agent, pane, server) = try await session("/blobpage")
        defer { server.stop() }
        try await blobReady(agent, pane)
        let asset = FixtureServer.Standard.assetBytes

        // The premise this verb exists for: connect-src 'self' blocks an in-page fetch of the blob, so its bytes are
        // genuinely unreachable from execute-js.
        let inPage = try await execute(agent, pane, "fetch(window.__blobUrl).then(() => 'reached', (e) => 'blocked:' + e.name)")
        #expect(inPage.result["value"]?.stringValue?.contains("blocked") == true)
        let blobURL = try #require(try await execute(agent, pane, "window.__blobUrl").result["value"]?.stringValue)

        let directory = FileManager.default.temporaryDirectory.appending(
            path: "tabs-save-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        // 1) blob: via --url --out: the reported incident. (Read inside the page in a world the page's CSP doesn't bind.)
        let blobOut = directory.appending(path: "doc.pdf").path
        let savedBlob = try await run(agent, "save-resource", pane, ["--url", blobURL, "--out", blobOut])
        #expect(savedBlob.ok, "\(savedBlob.response)")
        #expect(savedBlob.result["path"] == .string(blobOut) && savedBlob.result["bytes"] == .int(Int64(asset.count)))
        #expect(try Data(contentsOf: URL(filePath: blobOut)) == asset)

        // 2) an http element src by --selector: a generated path whose extension is typed to png.
        let savedImage = try await run(agent, "save-resource", pane, ["--selector", "img#pic"])
        #expect(savedImage.ok, "\(savedImage.response)")
        #expect(savedImage.result["contentType"] == "image/png")
        let generated = try #require(savedImage.result["path"]?.stringValue)
        #expect(generated.hasSuffix(".png"))
        #expect(try Data(contentsOf: URL(filePath: generated)) == asset)

        // 3) the same asset by --ref: a ref that wait-for minted for the download link (the Electron test uses read-page's,
        // a verb of another family; the two share one ref registry), whose href resolves to it.
        let link = try await run(agent, "wait-for", pane, ["--selector", "a#dl"])
        let ref = try #require(link.result["ref"]?.stringValue)
        let refOut = directory.appending(path: "via-ref.bin").path
        let savedRef = try await run(agent, "save-resource", pane, ["--ref", ref, "--out", refOut])
        #expect(savedRef.ok, "\(savedRef.response)")
        #expect(try Data(contentsOf: URL(filePath: refOut)) == asset)

        // --out never clobbers: a second save to the same path is refused, not silently overwritten.
        let clobber = try await run(agent, "save-resource", pane, ["--url", blobURL, "--out", blobOut])
        #expect(!clobber.ok && clobber.error?.contains("refusing to overwrite") == true)

        // file: is refused on the front door.
        let refusedFile = try await run(agent, "save-resource", pane, ["--url", "file:///etc/hosts"])
        #expect(!refusedFile.ok && refusedFile.error?.contains("not allowed") == true)

        // The one blob Electron cannot reach (minted, never loaded, on a page whose CSP blocks blob fetches) is read here:
        // a difference of the engine, measured (docs/BROWSER.md, Known differences).
        let unloaded = try #require(
            try await execute(agent, pane, "(window.__unloaded = URL.createObjectURL(new Blob(['x'])), window.__unloaded)").result["value"]?
                .stringValue)
        let reached = try await run(agent, "save-resource", pane, ["--url", unloaded])
        #expect(reached.ok, "\(reached.response)")
        #expect(try Data(contentsOf: URL(filePath: try #require(reached.result["path"]?.stringValue))) == Data("x".utf8))
    }

    @Test func saveResourceReadsABlobThePageOnlyMintedTheAboutBlankCasesTheResourceTreeCannotSee() async throws {
        let (agent, pane, server) = try await session(nil)
        defer { server.stop() }
        // Deterministic bytes minted inside the page; the test mirrors the formula, so both saves below are compared byte
        // for byte against this buffer.
        let expected = Data((0..<600).map { UInt8(($0 * 7 + 3) % 256) })
        let minted = try await execute(
            agent, pane,
            "(() => { window.__u = URL.createObjectURL(new Blob([Uint8Array.from({ length: 600 }, (_, i) => (i * 7 + 3) % 256)], { type: 'application/pdf' })); return window.__u })()"
        )
        let blobURL = try #require(minted.result["value"]?.stringValue)
        #expect(blobURL.hasPrefix("blob:"))

        // Case 1: the blob was created but never loaded anywhere.
        let directory = FileManager.default.temporaryDirectory.appending(
            path: "tabs-save-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let out = directory.appending(path: "minted.pdf").path
        let saved = try await run(agent, "save-resource", pane, ["--url", blobURL, "--out", out])
        #expect(saved.ok, "\(saved.response)")
        #expect(saved.result["bytes"] == .int(Int64(expected.count)) && saved.result["contentType"] == "application/pdf")
        #expect(try Data(contentsOf: URL(filePath: out)) == expected)

        // Case 2: the same blob as an iframe's src, targeted by --selector. No --out: the generated name takes its
        // extension from the blob's own type.
        _ = try await execute(
            agent, pane,
            "(() => { const f = document.createElement('iframe'); f.id = 'fr'; f.src = window.__u; document.body.appendChild(f); return true })()"
        )
        let savedFrame = try await run(agent, "save-resource", pane, ["--selector", "#fr"])
        #expect(savedFrame.ok, "\(savedFrame.response)")
        let path = try #require(savedFrame.result["path"]?.stringValue)
        #expect(path.hasSuffix(".pdf"))
        #expect(try Data(contentsOf: URL(filePath: path)) == expected)
    }

    // MARK: Ownership and the reference

    @Test func captureVerbsRefuseAPaneThisCallerDoesNotOwn() async throws {
        let agent = try await AgentSession.open(SharedApp.fresh(), foreignPane: true)
        let foreign = try #require(agent.foreignPane)
        let refused = try await agent.ctl(["read-console", "--pane", foreign])
        #expect(!refused.ok && refused.error?.contains("not the owner") == true)
        // read-network and capture-bodies are not ported (docs/BROWSER.md J-23): as unknown as any other command, and
        // absent from capabilities and describe.
        for command in ["read-network", "capture-bodies"] {
            let answer = try await agent.ctl([command, "--pane", foreign])
            #expect(!answer.ok && answer.error?.contains("unknown command") == true, "\(command): \(answer.response)")
        }
        let capabilities = try await agent.ctl(["capabilities"])
        let described = try await agent.ctl(["describe", "--capability", "browser"])
        for result in [capabilities, described] {
            let text = String(decoding: try JSONEncoder().encode(result.response), as: UTF8.self)
            #expect(!text.contains("read-network") && !text.contains("capture-bodies"))
        }
    }

    /// I-4: the guide `describe` prints is the plugin bundle's own: the Electron guide without the network section,
    /// listing no command the app lacks.
    @Test func describeServesTheBrowserGuideFromTheBuiltBundle() async throws {
        let agent = try await AgentSession.open(SharedApp.fresh())
        let described = try await agent.ctl(["describe", "--capability", "browser"])
        #expect(described.ok, "\(described.response)")
        let guide = try #require(described.result["guide"]?.stringValue)
        #expect(guide.hasPrefix("# Browser panes") && guide.contains("## Waiting and asserting"))
        #expect(!guide.contains("read-network") && !guide.contains("capture-bodies"))
        let flags = try #require(described.result["commands"])
        let listing = String(decoding: try JSONEncoder().encode(flags), as: UTF8.self)
        for command in ["wait-for", "assert", "read-console", "execute-js", "save-resource"] {
            #expect(listing.contains("\"\(command)\""), "\(command)")
        }
    }
}
