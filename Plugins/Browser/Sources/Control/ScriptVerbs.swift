import Foundation
import TabsPluginSDK

/// The Script verbs (docs/BROWSER.md J-18, J-19): the page's own script surface, running caller
/// code in it and reading back what it logged.
@MainActor
enum ScriptVerbs {
    static func all(services: BrowserServices) -> [ControlVerbContribution] {
        [readConsole, executeJavaScript(files: services.agentFiles)]
    }

    // MARK: read-console

    /// Console output captured for the pane's current page. It reads the pane rather than driving
    /// the page: the buffer is filled as messages arrive (`BrowserPage.console`), because a page's
    /// console history isn't something the page can be asked for after the fact.
    ///
    /// Budget: quick (5 s), an in-process read of the pane's own buffer.
    private static let readConsole = ControlVerbContribution(
        name: "browser.readConsoleMessages",
        summary: "Captured console output for the current page. Cleared on navigation.",
        arguments: [
            ControlArgument(
                "pattern", .string,
                summary: "Regular expression; a pattern that fails to parse is refused rather than matched as literal text.",
                placeholder: "regex"),
            ControlArgument("sinceSeq", .number, summary: "Return only messages after this seq.", minimum: 0, flag: "since-seq"),
        ],
        target: .ownedPane(ofTypes: ["browser"]), timeout: .seconds(5),
        command: "read-console", wireType: "readConsoleMessages",
        resultShape: [
            "messages": [
                ["seq": "number", "level": "string", "text": "string", "timestamp": "number", "sourceURL": "string", "line": "number"]
            ]
        ]
    ) { invocation in
        let pane = try VerbSupport.pane(invocation)
        let pattern = invocation["pattern"]?.stringValue
        // Refused rather than silently matching nothing: an empty list for a bad pattern would
        // read as "no messages matched", a different claim entirely.
        if let problem = patternFilterError(pattern) { throw ControlVerbError(problem) }
        let matches = compilePattern(pattern)
        let since = invocation["sinceSeq"]?.doubleValue.map { Int($0.rounded(.down)) }
        let messages = pane.page.console.list(sinceSeq: since).filter { matches($0.text) }
        return ["messages": .array(messages.map(\.wire))]
    }

    // MARK: execute-js

    /// Runs caller-supplied code in the page and returns its value.
    ///
    /// Two failures are turned into clean errors rather than escaping: the script throwing (caught
    /// inside the page, so the message and stack are the script's own), and it returning something
    /// JSON can't represent (a cycle). The value never crosses the bridge as a live object: the page
    /// serializes it (`JSON.stringify`), so what a caller gets is exactly what JSON makes of it: a
    /// `Date` an ISO string, a DOM node an empty object, `undefined` null.
    ///
    /// This runs in the page's *own* world: a hostile page can observe or tamper with what is injected
    /// (the boundary is pane ownership, not the page). See `executeScript`.
    ///
    /// Budget: unbounded (30 s), the longest of any verb: caller-supplied code with no bound on
    /// what it does (a fetch, a wait for an animation).
    private static func executeJavaScript(files: AgentFiles) -> ControlVerbContribution {
        ControlVerbContribution(
            name: "browser.executeJavaScript",
            summary: "Evaluate one expression in the page. Wrap statements in an IIFE.",
            arguments: [
                ControlArgument("code", .string, required: true, placeholder: "expression"),
                ControlArgument(
                    "outPath", .path,
                    summary:
                        "Write the full result to a file instead of truncating at \(BrowserLimits.executeResultMax) chars; returns {path, bytes, format}. A string result is written raw, anything else as pretty-printed JSON. With a path it is resolved against your shell's cwd and never overwritten; bare --out generates a temp file swept after ~10 minutes.",
                    placeholder: "path", flag: "out"),
            ],
            target: .ownedPane(ofTypes: ["browser"]), timeout: .seconds(30),
            command: "execute-js", wireType: "executeJavaScript",
            resultShape: ["value": "object", "truncated": "boolean", "path": "string", "bytes": "number", "format": "string"]
        ) { invocation in
            let pane = try VerbSupport.pane(invocation)
            let code = invocation["code"]?.stringValue ?? ""
            let toFile = invocation["outPath"] != nil

            let answer: [String: JSONValue]
            switch await pane.page.evaluate(serializingScript(code, toFile: toFile)) {
            case .success(.object(let object)): answer = object
            case .success: throw ControlVerbError(unexpectedAnswer)
            case .failure(.exception):
                // Runtime throws are caught inside the page, so the only way to land here is
                // code that isn't a valid expression.
                throw ControlVerbError(
                    "the code is not a valid expression — wrap a sequence of statements in an IIFE, e.g. (() => { ... })()")
            case .failure(let error): throw ControlVerbError(error.message)
            }
            if answer["ok"]?.boolValue != true {
                if answer["unserializable"]?.boolValue == true {
                    throw ControlVerbError("the script returned a value that cannot be serialized (a DOM node, or a cycle)")
                }
                throw ControlVerbError("script threw: \(answer["error"]?.stringValue ?? "unknown error")")
            }
            guard let serialized = answer["serialized"]?.stringValue else { throw ControlVerbError(unexpectedAnswer) }

            // File output requested: the *full* serialization goes to the sink instead of the cap
            // applying, because the caller asked for a file precisely because the value is large. A
            // plain string goes raw (`text`): the common case is an extracted document, and a
            // JSON-quoted file would force every caller to unquote it. Anything else is pretty-printed
            // JSON, still valid for a parser.
            if toFile {
                let format = answer["format"]?.stringValue == "text" ? "text" : "json"
                let bytes = Data(serialized.utf8)
                switch files.write(
                    bytes, out: invocation["outPath"], subdirectory: AgentFiles.Subdirectory.output, ext: format == "text" ? "txt" : "json",
                    what: "result")
                {
                case .failure(let failure): throw ControlVerbError(failure.message)
                case .success(let path):
                    return ["path": .string(path), "bytes": .int(Int64(bytes.count)), "format": .string(format), "truncated": false]
                }
            }
            let units = serialized.utf16
            if units.count > BrowserLimits.executeResultMax {
                return ["value": .string(prefix(of: serialized, utf16Count: BrowserLimits.executeResultMax)), "truncated": true]
            }
            // `undefined` (a script ending in a statement, or returning a function) has no JSON form;
            // it is reported as null rather than dropping the key, so a caller can tell "ran, returned
            // nothing" from "no result field".
            guard let value = try? JSONDecoder().decode(JSONValue.self, from: Data(serialized.utf8)) else {
                throw ControlVerbError(unexpectedAnswer)
            }
            return ["value": value, "truncated": false]
        }
    }

    private static let unexpectedAnswer =
        "the page's answer was not the shape this verb expects — the page may have replaced a built-in the verb relies on"

    /// The caller's code wrapped so the page answers with a string: `executeScript`'s outcome
    /// (`{ok, value}` or `{ok: false, error}`), the value serialized in the page. `JSON.stringify` is
    /// captured before the caller's code runs, so it can't be swapped out from under the read.
    static func serializingScript(_ code: String, toFile: Bool) -> String {
        """
        (async () => {
          const stringify = JSON.stringify.bind(JSON)
          const outcome = await \(executeScript(code))
          if (!outcome.ok) return outcome
          const value = outcome.value
          try {
            if (\(toFile)) {
              return typeof value === 'string'
                ? { ok: true, format: 'text', serialized: value }
                : { ok: true, format: 'json', serialized: stringify(value ?? null, null, 2) ?? 'null' }
            }
            return { ok: true, serialized: stringify(value) ?? 'null' }
          } catch (error) {
            return { ok: false, unserializable: true }
          }
        })()
        """
    }

    /// The first `count` UTF-16 units of `text` (what `slice(0, count)` keeps), without a split
    /// surrogate pair: a lone half has no `String`, so the pair it belonged to is left out whole.
    static func prefix(of text: String, utf16Count count: Int) -> String {
        let units = text.utf16
        guard units.count > count else { return text }
        var end = units.index(units.startIndex, offsetBy: count)
        if let last = units[..<end].last, UTF16.isLeadSurrogate(last) { end = units.index(before: end) }
        return String(units[..<end]) ?? ""
    }
}

extension ConsoleEntry {
    /// The entry as the verb answers it: `sourceURL` and `line` only when the page said.
    var wire: JSONValue {
        var object: [String: JSONValue] = [
            "seq": .int(Int64(seq)), "level": .string(level), "text": .string(text), "timestamp": .int(Int64(timestamp)),
        ]
        if let sourceURL { object["sourceURL"] = .string(sourceURL) }
        if let line { object["line"] = .int(Int64(line)) }
        return .object(object)
    }
}
