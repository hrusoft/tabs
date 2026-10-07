import AppKit
import Foundation
import TabsPluginSDK
import Testing

@testable import TabsCore

/// A `BrowserPage` in a window that is never shown, served by a `FixtureServer`:
/// what the page-level tests drive (docs/BROWSER.md, Cases). The web view is the
/// window's content, as core puts a pane's view in a window, so input and
/// snapshots work; nothing is ever put on screen.
@MainActor
final class PageBed {
    let server: FixtureServer
    let window: KeyableWindow
    let page: BrowserPage
    /// The page's web data: the bed's own, so no test sees another's cookies, removed when the bed goes.
    let dataStore = UUID()
    /// Where the page's `LoopbackExemption` compiles its list: the bed's own.
    let ruleListDirectory = TestTemporary.directory("page-bed")
    /// Every event the page emitted, in order.
    private(set) var events: [PageEvent] = []
    private var subscription: PageSubscription?

    /// Starts a server and a page on `url` (the seed; `about:blank` loads nothing).
    /// `serving` gets the server before the page exists, so a seed can name its routes.
    init(serving: (FixtureServer) -> Void = { _ in }, url: (FixtureServer) -> String = { _ in BrowserPage.blank }, mounted: Bool = true)
        async throws
    {
        _ = NSApplication.shared
        server = try await FixtureServer.start()
        serving(server)
        page = BrowserPage(dataStore: dataStore, url: url(server), loopbackExemption: LoopbackExemption(directory: ruleListDirectory))
        window = KeyableWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        if mounted { window.contentView = page.webView }
        subscription = page.events.subscribe { [weak self] in self?.events.append($0) }
    }

    isolated deinit {
        page.destroy()
        window.close()
        server.stop()
        try? FileManager.default.removeItem(at: ruleListDirectory)
        WebDataStores.discard(dataStore)
    }

    func url(_ path: String) -> String { server.url(path) }

    /// Loads `path` and waits for the load to end.
    @discardableResult
    func load(_ path: String, timeoutMs: Int = 10_000) async -> LoadOutcome {
        page.load(path.hasPrefix("/") ? server.url(path) : path)
        return await page.waitForLoadEnd(timeoutMs: timeoutMs)
    }

    /// Evaluates an expression in the page; the value, or a recorded issue.
    @discardableResult
    func value(_ script: String, sourceLocation: SourceLocation = #_sourceLocation) async -> JSONValue {
        switch await page.evaluate(script) {
        case .success(let value): return value
        case .failure(let error):
            Issue.record("the script failed: \(error) (\(script.prefix(80)))", sourceLocation: sourceLocation)
            return .null
        }
    }

    /// The event-logging fixture's log since it was last read.
    func eventLog() async -> [String] {
        let log = await value("JSON.stringify(window.__log.splice(0))")
        guard let text = log.stringValue, let data = text.data(using: .utf8),
            let entries = try? JSONDecoder().decode([String].self, from: data)
        else { return [] }
        return entries
    }

    func clearEvents() { events = [] }

    /// Waits until the console holds a message with this text.
    func consoleHas(_ text: String) async -> Bool {
        await eventually { page.console.list().contains { $0.text == text } }
    }

    static var eventsPage: String { FixtureServer.eventsPage }
}

/// How a test sees that a wait has started watching, instead of sleeping on the chance that it has.
extension BrowserPage {
    /// Starts counting the `observe()` calls of the page world's `MutationObserver`s in the current
    /// document (once per document; later calls only read), and answers the count so far. An in-page
    /// wait (`WaitScripts`) observes as it arms, and so does the DOM tracker behind `--idle` and the
    /// read verbs' `settled`; nothing else in that world does.
    func countingObservers() async -> Int {
        let script = """
            (() => {
              if (!window.__testObserverCount) {
                window.__testObserverCount = { calls: 0 }
                const Base = window.MutationObserver
                window.MutationObserver = class extends Base {
                  observe(...args) {
                    window.__testObserverCount.calls++
                    return super.observe(...args)
                  }
                }
              }
              return window.__testObserverCount.calls
            })()
            """
        if case .success(let count) = await evaluate(script) { return Int(count.intValue ?? 0) }
        return 0
    }

    /// Whether the page world has observed more than `count` times within `timeout`: a wait started
    /// after `countingObservers()` answered `count` is armed.
    func observing(beyond count: Int, timeout: Duration = .seconds(10)) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if case .success(let calls) = await evaluate("window.__testObserverCount?.calls ?? 0"), Int(calls.intValue ?? 0) > count {
                return true
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return false
    }

    /// Whether more than `count` listeners hear the page's events within `timeout`: a host-side wait
    /// (`--url-contains`, the pane-closed watch) started after reading `events.listenerCount` is listening.
    func listening(beyond count: Int, timeout: Duration = .seconds(10)) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while events.listenerCount <= count {
            guard ContinuousClock.now < deadline else { return false }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return true
    }
}
