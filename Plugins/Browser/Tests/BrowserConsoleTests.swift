import AppKit
import Foundation
import TabsPluginSDK
import Testing

@testable import TabsCore

/// The page's console (docs/BROWSER.md C-3): every `console.*` call and uncaught
/// error, into a 200-entry ring with stable sequence numbers.
@MainActor
@Suite struct BrowserConsoleTests {
    private static let script = """
        console.log('hello', 1, {a: 1}, [1, 2], null, undefined)
        console.info('info text')
        console.debug('debug text')
        console.warn('a warning happened')
        console.error('an error happened')
        console.log('%s is %d years', 'Bob', 42, 'extra')
        setTimeout(() => console.log('delayed message'), 200)
        """

    /// C-3, J-18: level names, text formatted the way the console formats it, late messages too.
    @Test func capturesEveryLevelWithItsTextIncludingALateMessage() async throws {
        let bed = try await PageBed(serving: { $0.page("/console", title: "Console", head: "<script>\(Self.script)</script>") })
        await bed.load("/console")
        #expect(await bed.consoleHas("delayed message"), "captured as messages arrive, not asked for after")
        let entries = bed.page.console.list()
        func first(_ text: String) -> ConsoleEntry? { entries.first { $0.text == text } }
        #expect(first("hello 1 {a: 1} [1, 2] null undefined")?.level == "info")
        #expect(first("info text")?.level == "info")
        #expect(first("debug text")?.level == "verbose")
        #expect(first("a warning happened")?.level == "warning")
        #expect(first("an error happened")?.level == "error")
        #expect(first("Bob is 42 years extra")?.level == "info", "the first argument's directives are applied")
        #expect(entries.map(\.seq) == Array(1...entries.count), "increasing from 1")
        #expect(entries.allSatisfy { $0.timestamp > 1_700_000_000_000 })
    }

    /// C-3 (#86, S2): a value is rendered the way the console previews it — an object's keys and values, nested
    /// three deep, a cycle marked — and `dir`, `table`, `group`, `trace` and a failing `assert` are captured too. A
    /// message is cut at `consoleMessageMax`.
    @Test func valuesAreRenderedAsTheConsolePreviewsThemAndMoreMethodsAreCaptured() async throws {
        let script = #"""
            const cycle = { name: 'c' }; cycle.self = cycle
            console.log('values', { a: 1, b: 'two', c: [true, null], d: { e: { f: { g: 1 } } } }, new Map([['k', 1]]), new Set([2]))
            console.log('more', cycle, 10n, Symbol('s'), () => 1, new Error('bad'), document.documentElement)
            console.dir({ dir: 1 })
            console.table([{ x: 1 }])
            console.group('the group')
            console.trace('traced')
            console.assert(true, 'never said')
            console.assert(false, 'it broke', 7)
            console.log('x'.repeat(20000))
            console.log('last')
            """#
        let bed = try await PageBed(serving: { $0.page("/console", title: "Console", head: "<script>\(script)</script>") })
        await bed.load("/console")
        #expect(await bed.consoleHas("last"))
        let entries = bed.page.console.list()
        let texts = entries.map(\.text)
        let values = #"values {a: 1, b: "two", c: [true, null], d: {e: {f: [Object]}}} Map(1) {"k" => 1} Set(1) {2}"#
        #expect(texts.contains(values), "\(texts)")
        #expect(texts.contains("more {name: \"c\", self: [Circular]} 10n Symbol(s) [Function] Error: bad <html>"), "\(texts)")
        #expect(texts.contains("{dir: 1}") && texts.contains("[{x: 1}]") && texts.contains("the group"), "\(texts)")
        #expect(texts.contains("Trace: traced"), "\(texts)")
        #expect(!texts.contains { $0.contains("never said") })
        #expect(entries.first { $0.text == "Assertion failed: it broke 7" }?.level == "error", "\(texts)")
        let long = try #require(texts.first { $0.hasPrefix("xxx") })
        #expect(long.utf16.count == BrowserLimits.consoleMessageMax + 1 && long.hasSuffix("…"), "\(long.utf16.count)")
    }

    /// C-3: rendering a value runs no page code it can avoid and does bounded work: a getter shows as `[Getter]` (it
    /// would otherwise run, and one that logs would recurse), a call a Proxy's trap makes mid-render isn't captured, and
    /// a huge array or typed array renders its first hundred entries only.
    @Test func renderingAValueRunsNoGetterAndStaysBounded() async throws {
        let script = #"""
            window.__gotten = 0
            console.log('getter', { get boom() { window.__gotten++; return 1 }, set only(v) {} })
            console.log('loud', { get x() { console.log('inside'); return 1 } })
            console.log('trap', new Proxy({}, { ownKeys() { console.log('in trap'); return [] } }))
            const started = performance.now()
            console.log('big', new Array(1000000).fill(7))
            console.log('typed', new Float32Array(1000000))
            window.__renderMs = performance.now() - started
            console.log('deep', [[[[1]]]], new Map([['m', new Map([['n', new Map([['o', 1]])]])]]))
            console.log('last')
            """#
        let bed = try await PageBed(serving: { $0.page("/console", title: "Console", head: "<script>\(script)</script>") })
        await bed.load("/console")
        #expect(await bed.consoleHas("last"))
        let texts = bed.page.console.list().map(\.text)
        #expect(texts.contains("getter {boom: [Getter], only: [Setter]}"), "\(texts)")
        #expect(await bed.value("window.__gotten") == 0, "the getter never ran")
        #expect(texts.contains("loud {x: [Getter]}") && !texts.contains("inside"), "\(texts)")
        #expect(texts.contains("trap {}") && !texts.contains("in trap"), "\(texts)")
        let big = try #require(texts.first { $0.hasPrefix("big ") })
        #expect(big.hasSuffix(", 7, … 999900 more]"), "\(big.suffix(40))")
        let typed = try #require(texts.first { $0.hasPrefix("typed ") })
        #expect(typed.hasPrefix("typed Float32Array(1000000) [0, 0,") && typed.hasSuffix(", … 999900 more]"), "\(typed.suffix(40))")
        #expect((await bed.value("window.__renderMs")).doubleValue ?? .infinity < 1000, "bounded work")
        #expect(texts.contains("deep [[[[Array]]]] Map(1) {\"m\" => Map(1) {\"n\" => Map(1) {\"o\" => 1}}}"), "\(texts)")
    }

    /// An uncaught error carries the file and line it happened on, and so does a `console.*` call: the line
    /// of the call.
    @Test func anUncaughtErrorAndAConsoleCallRecordTheirScriptURLAndLine() async throws {
        let bed = try await PageBed(serving: { server in
            server.page(
                "/where", title: "Where",
                head: "<script>\nconsole.log('a call')\nsetTimeout(() => { throw new Error('on line three') }, 10)\n</script>")
        })
        await bed.load("/where")
        #expect(await eventually { bed.page.console.list().contains { $0.text.contains("on line three") } })
        let error = try #require(bed.page.console.list().first { $0.text.contains("on line three") })
        #expect(error.sourceURL == bed.url("/where"))
        #expect(error.line == 3)
        let call = try #require(bed.page.console.list().first { $0.text == "a call" })
        #expect(call.sourceURL == bed.url("/where"))
        #expect(call.line == 2)
    }

    @Test func capturesUncaughtErrorsAndUnhandledRejections() async throws {
        let bed = try await PageBed(serving: { server in
            server.page(
                "/throws", title: "T",
                head: "<script>setTimeout(() => { throw new Error('boom') }, 20); Promise.reject(new Error('rej'))</script>")
        })
        await bed.load("/throws")
        #expect(await eventually { bed.page.console.list().count >= 2 })
        let texts = bed.page.console.list().map(\.text)
        #expect(texts.contains { $0.hasPrefix("Uncaught") && $0.contains("boom") }, "\(texts)")
        #expect(texts.contains { $0.hasPrefix("Uncaught (in promise)") && $0.contains("rej") }, "\(texts)")
        #expect(bed.page.console.list().allSatisfy { $0.level == "error" })
    }

    @Test func aPageCannotSilenceItsOwnCapture() async throws {
        let bed = try await PageBed(serving: {
            $0.page("/rude", title: "R", head: "<script>delete window.webkit; console.log('still heard')</script>")
        })
        await bed.load("/rude")
        #expect(await bed.consoleHas("still heard"))
    }

    /// C-3: 200 messages are retained, the oldest go, and sequence numbers stay stable.
    @Test func retainsTheLast200MessagesWithStableSequenceNumbers() async throws {
        let bed = try await PageBed(serving: {
            $0.page("/chatty", title: "C", head: "<script>for (let i = 1; i <= 250; i++) console.log('m' + i)</script>")
        })
        await bed.load("/chatty")
        #expect(await bed.consoleHas("m250"))
        let entries = bed.page.console.list()
        #expect(entries.count == 200)
        #expect(entries.first?.text == "m51" && entries.first?.seq == 51, "the oldest went, and 'm51' is still seq 51")
        #expect(bed.page.console.list(sinceSeq: 248).map(\.text) == ["m249", "m250"])
    }

    @Test func aFrameSConsoleIsCapturedToo() async throws {
        let bed = try await PageBed(serving: { server in
            server.page("/outer", title: "Outer", body: "<iframe src='/inner'></iframe>")
            server.page("/inner", title: "Inner", head: "<script>console.log('from the frame')</script>")
        })
        await bed.load("/outer")
        #expect(await bed.consoleHas("from the frame"))
    }
}
