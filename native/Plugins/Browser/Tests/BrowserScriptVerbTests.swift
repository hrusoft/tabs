import AppKit
import Foundation
import TabsPluginSDK
import Testing

@testable import TabsCore

/// `execute-js` and `read-console` (docs/BROWSER.md J-18, J-19, J-24, J-26, J-27) as an agent
/// drives them: `tabs-ctl` flags in, the answer out, against the real plugin in a real core runtime
/// and a page from the fixture server. The Electron tests these port are
/// `e2e/external-control-flow.spec.ts` (the script half of "an agent can run script in a pane…",
/// "scripting verbs refuse a pane this caller does not own", "execute-js --out writes…"),
/// `e2e/external-control.spec.ts` ("oversized results are truncated honestly…") and
/// `e2e/external-control-read.spec.ts` ("an agent can read the console…").
@MainActor
@Suite struct BrowserScriptVerbTests {
    // MARK: execute-js

    /// J-19: a throw's stack keeps the frames that say where they are: the page's own code, with its URL, line and
    /// column. The `--code` expression itself has none on WebKit (its frames are a bare `@`), so a throw straight
    /// from it is its message alone.
    @Test func aThrowsStackKeepsThePagesFramesAndDropsTheEmptyOnes() async throws {
        let bed = try await ScriptVerbBed.open(
            "/thrower",
            serving: { server in
                server.page(
                    "/thrower", title: "Thrower",
                    body: "<script>\nfunction pageThrow() {\n  throw new TypeError('from the page')\n}\n</script>")
            })
        let own = await bed.ctl("execute-js", ["code": "(() => { throw new Error('boom') })()"])
        #expect(own.error == "script threw: Error: boom", "\(own.json)")
        // A built-in's frame has no location either.
        let builtIn = await bed.ctl("execute-js", ["code": "[1].forEach(() => { throw new Error('inside') })"])
        #expect(builtIn.error == "script threw: Error: inside", "\(builtIn.json)")
        let page = await bed.ctl("execute-js", ["code": "pageThrow()"])
        let lines = page.error?.components(separatedBy: "\n") ?? []
        #expect(lines.first == "script threw: TypeError: from the page", "\(page.json)")
        #expect(lines.dropFirst().first?.hasPrefix("pageThrow@\(bed.server.url("/thrower")):") == true, "\(page.json)")
        #expect(lines.dropFirst().allSatisfy { $0.range(of: #":\d+:\d+$"#, options: .regularExpression) != nil }, "\(page.json)")
    }

    /// J-19: a value, a structured value from the real page, an awaited promise; a script that throws
    /// fails with its own message; code that isn't an expression is told so, actionably; a value JSON
    /// can't represent is refused; a DOM node is an empty object.
    @Test func anAgentCanRunScriptInAPaneAndGetsCleanErrorsWhenItCannot() async throws {
        let bed = try await ScriptVerbBed.open("/page")
        func run(_ code: String) async -> ScriptAnswer { await bed.ctl("execute-js", ["code": .string(code)]) }

        #expect(await run("1 + 1").result["value"] == 2)
        // A structured value, and one that proves the script ran in the real page.
        #expect(await run("({ title: document.title })").result["value"] == ["title": "Fixture"])
        // A promise is awaited rather than returned as a pending object.
        #expect(await run("Promise.resolve('resolved')").result["value"] == "resolved")

        // A script that throws fails with its *own* message.
        let threw = await run("(() => { throw new Error('deliberate') })()")
        #expect(!threw.ok)
        #expect(threw.error?.hasPrefix("script threw: ") == true && threw.error?.contains("deliberate") == true, "\(threw.json)")

        // Code that isn't an expression is told so, actionably.
        let statement = await run("const x = 1; x")
        #expect(!statement.ok)
        #expect(
            statement.error == "the code is not a valid expression — wrap a sequence of statements in an IIFE, e.g. (() => { ... })()",
            "\(statement.json)")

        // So does one returning something JSON cannot represent.
        let circular = await run("(() => { const a = {}; a.self = a; return a })()")
        #expect(!circular.ok)
        #expect(circular.error == "the script returned a value that cannot be serialized (a DOM node, or a cycle)")

        // A DOM node does not error: it is an ordinary (useless) object, so the docs' advice to return a
        // property instead of an element stays accurate.
        let node = await run("document.body")
        #expect(node.ok && node.result["value"] == .emptyObject)
    }

    /// J-19: what a value becomes is what `JSON.stringify` makes of it, which is what the Electron app's
    /// result is after crossing to the host: an undefined result (a script ending in a statement, a function)
    /// is null, not a missing key; a Date is its ISO string.
    @Test func aResultIsWhatJSONMakesOfIt() async throws {
        let bed = try await ScriptVerbBed.open("/page")
        func value(_ code: String) async -> JSONValue? { await bed.ctl("execute-js", ["code": .string(code)]).result["value"] }
        #expect(await value("undefined") == .null)
        #expect(await value("(() => {})()") == .null)
        #expect(await value("() => 1") == .null)
        #expect(await value("new Date(0)") == "1970-01-01T00:00:00.000Z")
        #expect(await value("[1, 'a', null, { b: true }]") == [1, "a", nil, ["b": true]])
        #expect(await value("'é日😀'") == "é日😀")
        #expect(await value("NaN") == .null)
        let result = await bed.ctl("execute-js", ["code": "({ a: 1 })"]).result
        #expect(result["truncated"] == false)
    }

    /// J-19: page script the app ran can't have its serialization swapped out by the page: the wrapper
    /// holds `JSON.stringify` from before the caller's code ran.
    @Test func aPageThatReplacesJSONStringifyDoesNotChangeWhatIsRead() async throws {
        let bed = try await ScriptVerbBed.open("/page")
        let answer = await bed.ctl("execute-js", ["code": "(JSON.stringify = () => '\"forged\"', 5)"])
        #expect(answer.result["value"] == 5, "\(answer.json)")
    }

    /// J-19, J-27: an oversized result is cut at 50 000 characters and says so; nothing is cut silently.
    @Test func oversizedResultsAreTruncatedHonestlyNeverSilently() async throws {
        let bed = try await ScriptVerbBed.open("/page")
        let big = await bed.ctl("execute-js", ["code": "'x'.repeat(60000)"])
        #expect(big.ok)
        #expect(big.result["truncated"] == true)
        #expect(big.result["value"]?.stringValue?.count ?? 0 <= BrowserLimits.executeResultMax)
        let small = await bed.ctl("execute-js", ["code": "'x'.repeat(100)"])
        #expect(small.result["truncated"] == false)
    }

    /// J-19: the cut is in UTF-16 units, as the Electron app's `slice` is, and never leaves half of a pair.
    @Test func theTruncationNeverSplitsASurrogatePair() {
        let text = String(repeating: "a", count: 9) + "😀" + "tail"
        #expect(ScriptVerbs.prefix(of: text, utf16Count: 9) == String(repeating: "a", count: 9))
        #expect(ScriptVerbs.prefix(of: text, utf16Count: 10) == String(repeating: "a", count: 9), "a lone half has no string")
        #expect(ScriptVerbs.prefix(of: text, utf16Count: 11) == String(repeating: "a", count: 9) + "😀")
        #expect(ScriptVerbs.prefix(of: "short", utf16Count: 50) == "short")
    }

    /// J-19, J-26, J-27: `--out` writes the full result: a bare `--out` to a generated path in the swept
    /// directory (a string raw as `.txt`), a named path exactly there (pretty JSON), never overwritten.
    @Test func executeJsOutWritesTheFullResultToAFileInsteadOfTruncating() async throws {
        let bed = try await ScriptVerbBed.open("/page")

        // Bare --out: a generated path in the app's swept directory. A string result lands raw, and in
        // full, past the cap the inline path would have applied.
        let text = await bed.ctl("execute-js", ["code": "'x'.repeat(60000)", "out": true])
        #expect(text.ok, "\(text.json)")
        #expect(text.result["truncated"] == false)
        #expect(text.result["format"] == "text")
        #expect(text.result["bytes"] == 60000)
        // The value never rides the socket on this path: only the path does.
        #expect(text.result["value"] == nil)
        let generated = try #require(text.result["path"]?.stringValue)
        #expect(generated.contains("agent-output") && generated.hasPrefix(bed.cacheDirectory.path))
        #expect(generated.hasSuffix(".txt"))
        #expect(try String(contentsOfFile: generated, encoding: .utf8) == String(repeating: "x", count: 60000))

        // --out <path>: written exactly there, pretty-printed JSON for a non-string value, parseable as is.
        let outPath = try bed.scratchDirectory().appending(path: "result.json").path
        let json = await bed.ctl("execute-js", ["code": "({ n: 1, list: [1, 2] })", "out": .string(outPath)])
        #expect(json.ok, "\(json.json)")
        #expect(json.result["path"] == .string(outPath))
        #expect(json.result["format"] == "json")
        let written = try String(contentsOfFile: outPath, encoding: .utf8)
        let parsed = try JSONDecoder().decode(JSONValue.self, from: Data(written.utf8))
        #expect(parsed == ["n": 1, "list": [1, 2]])
        #expect(written.contains("\n"))
        #expect(json.result["bytes"] == .int(Int64(written.utf8.count)))

        // A caller-named path is never clobbered: same rule as save-resource.
        let clobber = await bed.ctl("execute-js", ["code": "1", "out": .string(outPath)])
        #expect(!clobber.ok)
        #expect(clobber.error == "refusing to overwrite an existing file: \(outPath)")
        #expect(try String(contentsOfFile: outPath, encoding: .utf8) == written, "the file is untouched")
    }

    /// J-26: a relative `--out` is the caller's, resolved against the caller's working directory.
    @Test func aRelativeOutIsResolvedAgainstTheCallersWorkingDirectory() async throws {
        let bed = try await ScriptVerbBed.open("/page")
        let directory = try bed.scratchDirectory()
        let answer = await bed.ctl("execute-js", ["code": "'hello'", "out": "note.txt"], cwd: directory)
        #expect(answer.ok, "\(answer.json)")
        let resolved = directory.appending(path: "note.txt").path
        #expect(
            answer.result["path"]?.stringValue.map { URL(filePath: $0).resolvingSymlinksInPath().path }
                == URL(filePath: resolved).resolvingSymlinksInPath().path)
        #expect(try String(contentsOfFile: resolved, encoding: .utf8) == "hello")
    }

    /// J-19: `--out` asks for the serialization too: an unserializable value is refused, not written.
    @Test func executeJsOutRefusesAValueThatCannotBeSerialized() async throws {
        let bed = try await ScriptVerbBed.open("/page")
        let answer = await bed.ctl("execute-js", ["code": "(() => { const a = {}; a.self = a; return a })()", "out": true])
        #expect(answer.error == "the script returned a value that cannot be serialized (a DOM node, or a cycle)")
        let directory = bed.cacheDirectory.appending(path: "agent-output").path
        #expect((try? FileManager.default.contentsOfDirectory(atPath: directory))?.isEmpty ?? true, "nothing was written")
    }

    /// J-24: a pane this caller does not own is refused, and one that isn't a browser pane says so; the
    /// same for every scripting verb.
    @Test func scriptingVerbsRefuseAPaneThisCallerDoesNotOwn() async throws {
        let bed = try await ScriptVerbBed.open("/page")
        let foreign = try #require(bed.harness.open("browser"))
        for (command, flags) in [("execute-js", ["code": JSONValue.string("document.title")]), ("read-console", [:])] {
            let answer = await bed.ctl(command, flags, pane: foreign.id)
            #expect(!answer.ok)
            #expect(answer.error == "not the owner of this pane", "\(command): \(answer.json)")
        }
        // The caller's own pane is not a browser pane.
        let notBrowser = await bed.ctl("execute-js", ["code": "1"], pane: bed.harness.agentPane)
        #expect(notBrowser.error == "not the owner of this pane")
    }

    /// J-24: a pane the caller closed is gone, and the caller is told so.
    @Test func aClosedPaneIsReportedGone() async throws {
        let bed = try await ScriptVerbBed.open("/page")
        _ = bed.harness.runtime.panes.closePane(bed.pane)
        let answer = await bed.ctl("execute-js", ["code": "1"])
        #expect(answer.error == "target pane no longer exists — it was closed; listOwnedPanes shows the panes still open")
    }

    /// J-25: a page that can't run script at all answers with one sentence, never the engine's plumbing.
    @Test func aPageThatCannotRunScriptSaysSoInOneSentence() async throws {
        let bed = try await ScriptVerbBed.open("/page")
        bed.page.destroy()
        let answer = await bed.ctl("execute-js", ["code": "1"])
        #expect(
            answer.error
                == "the page could not run script — it may be mid-navigation, showing an error page, or a viewer (such as the PDF viewer) that runs none",
            "\(answer.json)")
    }

    /// H-9, I-2: `execute-js` is a control-plane verb (the CLI command, the wire type, the flags as
    /// `controlSpec.ts` declares them, with their docs).
    @Test func executeJsIsDeclaredAsControlSpecDeclaresIt() async throws {
        let bed = try await ScriptVerbBed.open()
        let verb = try #require(bed.verb("browser.executeJavaScript"))
        #expect(verb.command == "execute-js" && verb.wireType == "executeJavaScript" && verb.batchable)
        #expect(verb.summary == "Evaluate one expression in the page. Wrap statements in an IIFE.")
        #expect(verb.timeout == .seconds(30), "unbounded: the longest budget of any verb")
        let code = try #require(verb.arguments.first { $0.name == "code" })
        #expect(code.kind == .string && code.required && code.placeholder == "expression")
        let out = try #require(verb.arguments.first { $0.name == "outPath" })
        #expect(out.kind == .path && out.flagName == "out" && out.placeholder == "path")
        #expect(
            out.summary
                == "Write the full result to a file instead of truncating at 50000 chars; returns {path, bytes, format}. A string result is written raw, anything else as pretty-printed JSON. With a path it is resolved against your shell's cwd and never overwritten; bare --out generates a temp file swept after ~10 minutes."
        )
    }

    // MARK: read-console

    /// J-18: messages captured as they arrive (a timer's included), levels, an anchored pattern narrows the
    /// read, `sinceSeq` polls incrementally, a bad pattern is refused, and a navigation starts a fresh console.
    @Test func anAgentCanReadTheConsoleIncludingAMessageThatArrivesLate() async throws {
        let bed = try await ScriptVerbBed.open("/page")
        func messages(_ flags: [String: JSONValue] = [:]) async -> [JSONValue] {
            if case .array(let list)? = await bed.ctl("read-console", flags).result["messages"] { return list }
            return []
        }
        func texts(_ list: [JSONValue]) -> [String] { list.compactMap { $0["text"]?.stringValue } }
        let wanted = ["fixture ready", "a warning happened", "an error happened", "delayed message"]
        var all = await messages()
        for _ in 0..<100 where !wanted.allSatisfy({ texts(all).contains($0) }) {
            try await Task.sleep(for: .milliseconds(50))
            all = await messages()
        }
        #expect(wanted.allSatisfy { texts(all).contains($0) }, "\(texts(all))")
        let levels = Set(all.compactMap { $0["level"]?.stringValue })
        #expect(levels.isSuperset(of: ["error", "warning", "info"]))
        // Each call says where it was made: the fixture's inline script.
        let ready = all.first { $0["text"] == "fixture ready" }
        #expect(ready?["sourceURL"] == .string(bed.server.url("/page")) && ready?["line"]?.intValue != nil, "\(String(describing: ready))")

        // A pattern narrows the read.
        #expect(texts(await messages(["pattern": "^a warning happened$"])) == ["a warning happened"])

        // An unparseable pattern is refused, not silently matched as literal text.
        let bad = await bed.ctl("read-console", ["pattern": "["])
        #expect(!bad.ok)
        #expect(bad.error?.contains("--pattern") == true, "\(bad.json)")

        // sinceSeq makes repeat polling incremental.
        let lastSeq = all.compactMap { $0["seq"]?.intValue }.max() ?? 0
        #expect(await messages(["since-seq": .int(lastSeq)]).isEmpty)
        #expect(await messages(["since-seq": .int(lastSeq - 1)]).count == 1)

        // Navigating starts a fresh page, and so a fresh console.
        await bed.load("/other")
        #expect(await messages().isEmpty)
    }

    /// J-18: an entry carries what the page told the console (`seq`, `level`, `text`, `timestamp`); an
    /// uncaught error carries its file and line.
    @Test func aConsoleEntryCarriesItsSeqLevelTextAndTimestamp() async throws {
        let bed = try await ScriptVerbBed.open("/page")
        _ = await bed.value("(console.log('one'), console.debug('two'), console.error('three'), 1)")
        let messages = await bed.ctl("read-console", ["pattern": "^(one|two|three)$"]).result["messages"]
        guard case .array(let list)? = messages else { Issue.record("no messages"); return }
        #expect(list.compactMap { $0["text"]?.stringValue } == ["one", "two", "three"])
        #expect(list.compactMap { $0["level"]?.stringValue } == ["info", "verbose", "error"])
        let seqs = list.compactMap { $0["seq"]?.intValue }
        #expect(seqs == seqs.sorted() && Set(seqs).count == 3)
        #expect(list.allSatisfy { ($0["timestamp"]?.intValue ?? 0) > 1_600_000_000_000 })
    }

    /// J-18: reading needs no page script: a page that can't run any still has its console, and an
    /// empty console is an empty list, not an error.
    @Test func readConsoleNeedsNoPageScript() async throws {
        let bed = try await ScriptVerbBed.open()
        #expect(await bed.ctl("read-console").result["messages"] == [])
        bed.page.destroy()
        let after = await bed.ctl("read-console")
        #expect(after.ok && after.result["messages"] == [])
    }

    /// J-18: the wire request is validated by the verb's schema: an unknown field, a negative `sinceSeq`.
    @Test func readConsoleIsValidatedAgainstItsWireSchema() async throws {
        let bed = try await ScriptVerbBed.open("/page")
        let negative = await bed.wire("readConsoleMessages", ["sinceSeq": -1])
        #expect(negative.error?.contains("sinceSeq") == true, "\(negative.json)")
        let unknown = await bed.wire("readConsoleMessages", ["nope": 1])
        #expect(unknown.error?.contains("nope") == true, "\(unknown.json)")
        let fine = await bed.wire("readConsoleMessages", ["pattern": "fixture", "sinceSeq": 0])
        #expect(fine.ok)
        if case .array(let matched)? = fine.result["messages"] { #expect(matched.count <= 1) }
    }

    /// J-23: `read-network` and `capture-bodies` are not ported: the command is unknown, and neither is in `capabilities`.
    @Test func captureVerbsAreAbsent() async throws {
        let bed = try await ScriptVerbBed.open("/page")
        for command in ["read-network", "capture-bodies"] {
            let answer = await bed.ctl(command)
            #expect(!answer.ok)
            #expect(answer.error?.contains("unknown command") == true, "\(command): \(answer.json)")
        }
        let capabilities = await bed.harness.tabsCtl("capabilities")
        let listing = String(decoding: try JSONEncoder().encode(capabilities), as: UTF8.self)
        #expect(!listing.contains("read-network") && !listing.contains("capture-bodies"))
        #expect(listing.contains("read-console") && listing.contains("execute-js"))
    }
}
