import AppKit
import TabsPluginSDK
import Testing
import WebKit

@testable import Tabs
@testable import TabsCore

extension UITests {
    /// The script, wait and resource verbs against a pane the real shell has mounted (docs/BROWSER.md J-18…J-22, E-5):
    /// what needs a window's worth of shell around the page, in the plugin's real bundle. The verbs' logic is the
    /// plugin tier's (`BrowserScriptVerbTests`, `BrowserWaitVerbTests`, `BrowserResourceVerbTests`); the pages come from a
    /// loopback fixture server, and an agent is a `text` pane that owns the browser.
    @MainActor
    @Suite struct BrowserScriptUITests {
        /// The agent's pane "a" and the browser "b" it controls, in tabs: `active` shown.
        private func shell(_ url: String, active: Int = 0) -> UIDriver {
            let leaves = [Fixture.leaf("a", "text"), Fixture.leaf("b", "browser", config: ["url": .string(url)])]
            let ui = UIDriver(layout: Fixture.saved(Fixture.tabsWindow("w", leaves, active: active)))
            ui.runtime.panes.grantOwnership(of: "b", to: "a")
            ui.layoutAll()
            return ui
        }

        /// `tabs-ctl <command> --pane b …flags`, from the agent's pane.
        private func ctl(_ ui: UIDriver, _ command: String, _ flags: [String: JSONValue] = [:]) async -> JSONValue {
            var flags = flags
            flags["pane"] = "b"
            return await ui.runtime.control.handle(
                ControlDispatcher.Envelope(command: command, arguments: .object(flags), targetPane: "a", cwd: URL(filePath: "/tmp")))
        }

        private func server() async throws -> FixtureServer {
            let server = try await FixtureServer.startStandard()
            server.page(
                "/late", title: "Late",
                body: "<p id=p>waiting</p><script>setTimeout(() => { p.textContent = 'ready now' }, 1500)</script>")
            server.route("/sets-cookie") { _ in
                .init(contentType: "text/plain", headers: ["Set-Cookie": "session=abc123; Path=/"], body: "hi")
            }
            server.route("/whoami") { request in .init(contentType: "text/plain", body: request.headers["cookie"] ?? "no cookie") }
            return server
        }

        /// J-20, E-5: a pane in a background tab keeps its page running, so a wait on it resolves on the change it waits for
        /// (a hidden page's timers are throttled, its mutation observer is not), and the verbs read and script it without
        /// revealing it.
        @Test func aWaitResolvesOnABackgroundedPaneWithoutRevealingIt() async throws {
            let server = try await server()
            defer { server.stop() }
            let ui = shell(server.url("/late"))
            #expect(ui.activePane == "a")
            let started = ContinuousClock.now
            let waited = await ctl(ui, "wait-for", ["text": "ready now", "timeout": 20000])
            #expect(waited["ok"] == true, "\(waited)")
            #expect(ContinuousClock.now - started < .seconds(15))
            #expect((waited["result"]?["elapsedMs"]?.intValue ?? 0) >= 1000, "it really was pending")
            #expect(await ctl(ui, "assert", ["text": "ready now"])["ok"] == true)
            let script = await ctl(ui, "execute-js", ["code": "document.title"])
            #expect(script["result"]?["value"] == "Late")
            #expect(ui.activePane == "a", "the verbs read the page; they never reveal it")
        }

        /// J-19, J-26: `--out` from a page in a mounted pane lands in the plugin's own cache directory, and the console the
        /// page wrote is there to read.
        @Test func anExecuteResultAndTheConsoleReadBackFromAMountedPage() async throws {
            let server = try await server()
            defer { server.stop() }
            let ui = shell(server.url("/page"), active: 1)
            #expect(ui.activePane == "b")
            var messages: [String] = []
            for _ in 0..<100 where !messages.contains("delayed message") {
                try await Task.sleep(for: .milliseconds(50))
                if case .array(let list)? = await ctl(ui, "read-console")["result"]?["messages"] {
                    messages = list.compactMap { $0["text"]?.stringValue }
                }
            }
            #expect(
                ["fixture ready", "a warning happened", "an error happened", "delayed message"].allSatisfy(messages.contains), "\(messages)"
            )

            let out = await ctl(ui, "execute-js", ["code": "'y'.repeat(60000)", "out": true])
            #expect(out["ok"] == true, "\(out)")
            let path = try #require(out["result"]?["path"]?.stringValue)
            #expect(path.hasPrefix(ui.runtime.paths.pluginCache("browser").path) && path.contains("agent-output"))
            #expect(try String(contentsOfFile: path, encoding: .utf8).count == 60000)
        }

        /// J-22: a resource fetched by the app carries the cookies of the mounted page's own session: the plugin's web data
        /// store, the one the shell's page uses.
        @Test func saveResourceCarriesTheMountedPagesCookies() async throws {
            let server = try await server()
            defer { server.stop() }
            let ui = shell(server.url("/sets-cookie"), active: 1)
            try await ui.browserState("b") { $0["hasCommitted"] == true && $0["isLoading"] == false }
            let saved = await ctl(ui, "save-resource", ["url": .string(server.url("/whoami"))])
            #expect(saved["ok"] == true, "\(saved)")
            let path = try #require(saved["result"]?["path"]?.stringValue)
            #expect(try String(contentsOfFile: path, encoding: .utf8) == "session=abc123")
        }

        /// I-4: the guide the shipped bundle serves for `describe`, in the app the shell loaded plugins into.
        @Test func theShippedBundleServesTheGuide() async throws {
            let ui = shell("about:blank")
            let described = await ui.runtime.control.handle(
                ControlDispatcher.Envelope(
                    command: "describe", arguments: ["capability": "browser"], targetPane: "a", cwd: URL(filePath: "/tmp")))
            let guide = try #require(described["result"]?["guide"]?.stringValue, "\(described)")
            #expect(guide.hasPrefix("# Browser panes") && !guide.contains("read-network"))
        }
    }
}
