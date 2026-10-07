import AppKit
import Foundation
import TabsPluginSDK
import Testing
import WebKit

@testable import TabsCore

/// What a page may reach outside its pane (docs/BROWSER.md: F-1…F-4, D-10) and how
/// script is run in it (J-19, J-25), against a real `WKWebView`.
@MainActor
@Suite struct BrowserPolicyTests {
    private func popupBed(controlled: Bool = false) async throws -> (PageBed, Recorded) {
        let box = Recorded()
        let bed = try await PageBed(serving: { server in
            server.page(
                "/popups", title: "Popups",
                body: "<a id=blank target=_blank href='/target'>x</a><a id=mail href='mailto:me@example.com'>m</a>")
            server.page("/target", title: "Target")
            server.page("/other", title: "Other")
        })
        bed.page.openExternal = { box.opened.append($0.absoluteString) }
        bed.page.isControlled = { controlled }
        await bed.load("/popups")
        // From here on, every decision the guards make asks this: what a test counts to know a refused
        // attempt has been decided, instead of sleeping on the chance that it has.
        bed.page.isControlled = {
            box.decisions += 1
            return controlled
        }
        return (bed, box)
    }

    final class Recorded: @unchecked Sendable {
        var opened: [String] = []
        var decisions = 0
    }

    /// F-1: `target=_blank` and `window.open` open the OS's browser (`http`, `https`, `mailto` only), never a window here.
    @Test func popupsGoToTheOSBrowserForAUsersPane() async throws {
        let (bed, box) = try await popupBed()
        await bed.value("(document.getElementById('blank').click(), 1)")
        #expect(await eventually { box.opened == [bed.url("/target")] })
        await bed.value("(window.open('http://example.com/x'), 1)")
        #expect(await eventually { box.opened.last == "http://example.com/x" })
        await bed.value("(window.open('mailto:you@example.com'), 1)")
        #expect(await eventually { box.opened.last == "mailto:you@example.com" })
        await bed.value("(window.open('file:///etc/hosts'), 1)")
        await bed.value("(window.open('ssh://root@example.com'), 1)")
        // Popups are decided in the order the page opens them: once one opened after them is out, they are decided.
        await bed.value("(window.open('http://example.com/sentinel'), 1)")
        #expect(await eventually { box.opened.last == "http://example.com/sentinel" })
        #expect(box.opened.count == 4, "a file: or custom scheme is dropped: \(box.opened)")
        #expect(bed.page.url == bed.url("/popups"), "and the page itself never moved")
    }

    /// F-2: an agent-owned pane's popups are denied, with no external open.
    @Test func aControlledPanesPopupsAreDenied() async throws {
        let (bed, box) = try await popupBed(controlled: true)
        await bed.value("(document.getElementById('blank').click(), 1)")
        await bed.value("(window.open('http://example.com/x'), 1)")
        #expect(await eventually { box.decisions >= 2 }, "both popups were decided")
        #expect(box.opened.isEmpty)
    }

    /// A mail link in the page opens the mail client for a user's pane; the page stays.
    @Test func aMailLinkOpensTheMailClientAndTheStaysWhereItIs() async throws {
        let (bed, box) = try await popupBed()
        await bed.value("(document.getElementById('mail').click(), 1)")
        #expect(await eventually { box.opened == ["mailto:me@example.com"] })
        #expect(bed.page.url == bed.url("/popups"))
        let (controlled, controlledBox) = try await popupBed(controlled: true)
        await controlled.value("(document.getElementById('mail').click(), 1)")
        #expect(await eventually { controlledBox.decisions >= 1 }, "the mail link was decided")
        #expect(controlledBox.opened.isEmpty)
    }

    /// F-4: a navigation the page starts in an agent-owned pane is held to `http`/`https`/`about:blank`.
    /// (Measured: WebKit refuses a page's own navigation to `file:` before it asks the guard, which decides the rest:
    /// a `data:` URL, a custom scheme. The `data:` navigation the page asks for next is decided after the `file:` one
    /// has been, which is how the test knows both are over without sleeping on it.)
    @Test func aPageCannotSteerAControlledPaneOutsideTheSchemeAllowlist() async throws {
        let (bed, box) = try await popupBed(controlled: true)
        // The navigation starts on a timer once the script is done: the page's own later timer comes after it.
        await bed.value("(location.href = 'file:///etc/hosts', new Promise((resolve) => setTimeout(() => resolve(1), 10)))")
        await bed.value("(location.href = 'data:text/html,<title>D</title>', 1)")
        #expect(await eventually { box.decisions >= 1 }, "the data: navigation was decided")
        #expect(bed.page.url == bed.url("/popups"), "cancelled, both")
        #expect(!bed.page.isShowingErrorPage && bed.page.lastLoadError == nil)
        #expect(!bed.page.isLoading)
        await bed.value("(location.href = '/other', 1)")
        #expect(await eventually { bed.page.url == bed.url("/other") }, "an allowed URL goes through")
        await bed.value("(location.href = 'about:blank', 1)")
        #expect(await eventually { bed.page.url == "about:blank" })
    }

    /// F-4: a user's pane is unconstrained.
    @Test func aUsersPaneMayGoAnywhereTheEngineCanLoad() async throws {
        let (bed, _) = try await popupBed()
        bed.page.load("data:text/html,<title>Data page</title>hi")
        #expect(await eventually { bed.page.title == "Data page" })
    }

    /// F-3: ownership can arrive right after the pane exists and still guards its first load.
    @Test func theGuardsApplyToAPanesVeryFirstLoad() async throws {
        let harness = try PluginHarness.browser()
        let pane = try #require(harness.open("browser", config: ["url": "file:///etc/hosts"]))
        let browser = try #require(harness.controller(of: pane.id, as: BrowserPane.self))
        browser.controller = { "the caller" }
        let guarded = browser.page.isControlled
        let box = Recorded()
        browser.page.isControlled = {
            box.decisions += 1
            return guarded()
        }
        #expect(await eventually { box.decisions >= 1 && !browser.page.isLoading }, "the first load was decided, and is over")
        #expect(!browser.page.hasCommitted, "the disallowed first load was cancelled")
        #expect(browser.page.title == "hosts" || browser.page.title.isEmpty)
        #expect(!browser.page.isShowingErrorPage)
    }

    /// F-8: nothing of the app is reachable from the page but the console bridge's private handler.
    @Test func thePageSeesNoHostBridgeButTheConsoleHandler() async throws {
        let (bed, _) = try await popupBed()
        // The page world sees the console handler; the error handler lives in a world of its own.
        let seen = await bed.value("['tabsConsole', 'tabsErrors'].map(name => typeof window.webkit.messageHandlers[name]).join(',')")
        #expect(seen == "object,undefined", "\(seen)")
        #expect(await bed.value("typeof require + typeof process") == "undefinedundefined")
    }

    /// D-10: the page shows no context menu of its own.
    @Test func thePageHasNoContextMenu() throws {
        let web = BrowserWebView(frame: .zero, configuration: WKWebViewConfiguration())
        let event = NSEvent.mouseEvent(
            with: .rightMouseDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0,
            clickCount: 1, pressure: 1)!
        #expect(web.menu(for: event) == nil)
        let menu = NSMenu()
        menu.addItem(withTitle: "Inspect", action: nil, keyEquivalent: "")
        web.willOpenMenu(menu, with: event)
        #expect(menu.items.isEmpty)
    }

    // MARK: Running script

    /// J-25, J-19: values come back as JSON; a page that can't run script is one sentence.
    @Test func evaluateAnswersValuesAndTheEnginesFailuresAsTheSentenceCallersSee() async throws {
        let bed = try await PageBed(serving: { $0.page("/a", title: "A") })
        await bed.load("/a")
        #expect(await bed.value("1 + 2") == 3)
        #expect(await bed.value("'text'") == "text")
        #expect(await bed.value("[1, {a: null}, 'x', true]") == [1, ["a": .null], "x", true])
        #expect(await bed.value("undefined") == .null)
        #expect(await bed.value("Promise.resolve(7)") == 7, "a promise is awaited")
        #expect(await bed.value("new Promise(r => setTimeout(() => r('late'), 100))") == "late")
        #expect(await bed.value("1.5") == 1.5)
        if case .double(let number) = await bed.value("NaN") { #expect(number.isNaN) } else { Issue.record("NaN has a JSON form") }
        switch await bed.page.evaluate("document.body") {
        case .failure(let error):
            #expect(error == .unsupportedResult)
            #expect(error.message == pageScriptUnavailableMessage)
        case .success(let value): Issue.record("a DOM node crossed: \(value)")
        }
        switch await bed.page.evaluate("(() => { throw new Error('plain throw') })()") {
        case .failure(let error): #expect(error == .exception("Error: plain throw") || error.message.contains("plain throw"), "\(error)")
        case .success: Issue.record("a throw returned")
        }
        switch await bed.page.evaluate("this is not javascript") {
        case .failure(let error):
            guard case .exception(let message) = error else { Issue.record("a syntax error is the engine's exception: \(error)"); return }
            #expect(message.lowercased().contains("syntax") || message.contains("Unexpected"), "\(message)")
        case .success: Issue.record("a syntax error ran")
        }
    }

    /// Script runs on a page under a strict CSP: the embedder's injection is not the page's.
    @Test func scriptRunsOnAPageWhoseCSPForbidsIt() async throws {
        let bed = try await PageBed(serving: {
            $0.page("/csp", title: "CSP", body: "locked", headers: ["Content-Security-Policy": "default-src 'none'"])
        })
        await bed.load("/csp")
        #expect(await bed.value("document.title + '!'") == "CSP!")
        #expect(await bed.value(executeScript("1 + 1")) == ["ok": true, "value": 2])
    }

    /// The measured fact behind `PageWait`: a pending evaluation is never settled with a value across a
    /// navigation. Usually it isn't answered at all (so the supervisor must race it against the navigation);
    /// on a busy machine WebKit sometimes answers it with an error.
    @Test func anEvaluationAwaitingAPromiseNeverSettlesWhenThePageNavigatesAway() async throws {
        let bed = try await PageBed(serving: { server in
            server.page("/one", title: "One"); server.page("/two", title: "Two")
        })
        await bed.load("/one")
        let answer = Box<Result<JSONValue, PageScriptError>?>(nil)
        bed.page.evaluate("new Promise(() => {})") { answer.value = $0 }
        try await Task.sleep(for: .milliseconds(200))
        await bed.load("/two")
        try await Task.sleep(for: .milliseconds(200))
        if case .success(let value)? = answer.value {
            Issue.record("settled with \(value): the promise can't have resolved")
        }
    }

    /// J-25: nothing to run script in once the page is destroyed.
    @Test func aDestroyedPageRefusesScript() async throws {
        let bed = try await PageBed()
        bed.page.destroy()
        #expect(await bed.page.evaluate("1") == .failure(.unavailable))
    }
}
