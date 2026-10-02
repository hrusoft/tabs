import Foundation
import TabsPluginSDK
import Testing

@testable import TabsCore

/// The guide `describe --capability browser` serves (docs/BROWSER.md I-4): the Electron app's guide with the
/// network section removed and the engine's differences corrected, in the plugin's own bundle, and never
/// promising a command the app lacks.
@MainActor
@Suite struct BrowserGuideTests {
    /// Every command a shipping app answers to: core's and the browser's.
    static let commands: Set<String> = [
        "ping", "activate-pane", "close-pane", "list-panes", "pane-info", "batch", "capabilities", "describe", "create-browser-pane",
        "navigate", "reload", "go-back", "go-forward", "screenshot", "get-page-text", "read-page", "find", "click", "hover", "type", "key",
        "scroll", "form-input", "read-console", "execute-js", "wait-for", "assert", "save-resource",
    ]

    private func guide() async throws -> String {
        let bed = try await ScriptVerbBed.open()
        let described = ScriptAnswer(await bed.harness.tabsCtl("describe", ["capability": "browser"]))
        return try #require(described.result["guide"]?.stringValue, "\(described.json)")
    }

    /// The guide is in the plugin's bundle at runtime, and `describe` serves all of it.
    @Test func describeServesTheGuideFromThePluginsBundle() async throws {
        let text = try await guide()
        #expect(text.hasPrefix("# Browser panes\n"))
        #expect(text.contains("## Waiting and asserting") && text.contains("## Getting bytes out of a page"))
        #expect(text.utf8.count > 30_000)
    }

    /// I-4: the guide promises no network capture, and names no engine but the one the app has.
    @Test func theGuideNeverPromisesNetworkCapture() async throws {
        let text = try await guide()
        for word in [
            "read-network", "capture-bodies", "--with-bodies", "--body-out", "Network\n", "Electron", "Chromium", "Chrome", "webview",
            "CDP",
        ] {
            #expect(!text.contains(word), "\(word)")
        }
        #expect(text.contains("No network log"))
    }

    /// I-4: every command the guide runs exists.
    @Test func everyCommandTheGuideRunsExists() async throws {
        let text = try await guide()
        let named = Set(text.matches(of: /tabs-ctl ([a-z][a-z-]*)/).map { String($0.1) })
        #expect(named.isSubset(of: Self.commands), "\(named.subtracting(Self.commands))")
        #expect(
            named.isSuperset(of: ["create-browser-pane", "navigate", "wait-for", "assert", "read-console", "execute-js", "save-resource"]))
    }

    /// I-4: the flags the guide's usage lines give each of this family's commands are the flags it declares.
    @Test func theUsageLinesNameTheFlagsTheVerbsDeclare() async throws {
        let bed = try await ScriptVerbBed.open()
        let text = try await guide()
        let verbs = [
            ("wait-for", "browser.waitFor"), ("assert", "browser.assert"), ("read-console", "browser.readConsoleMessages"),
            ("execute-js", "browser.executeJavaScript"), ("save-resource", "browser.saveResource"),
        ]
        for (command, name) in verbs {
            let verb = try #require(bed.verb(name))
            let declared = Set(verb.arguments.map(\.flagName) + ["pane"])
            // The command's usage line, and the continuation line beneath it when the usage wraps.
            let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            guard let start = lines.firstIndex(where: { $0.hasPrefix("tabs-ctl \(command) ") }) else {
                Issue.record("the guide has no usage line for \(command)")
                continue
            }
            var usage = lines[start]
            if lines[start + 1].hasPrefix("    ") { usage += " " + lines[start + 1] }
            let mentioned = Set(usage.matches(of: /--([a-z][a-z-]*)/).map { String($0.1) })
            #expect(mentioned.isSubset(of: declared), "\(command): \(mentioned.subtracting(declared))")
            let required = Set(verb.arguments.filter(\.required).map(\.flagName))
            #expect(required.isSubset(of: mentioned), "\(command) omits a required flag")
        }
    }

    /// I-4: the limits `describe` states are the ones the verbs apply.
    @Test func describeStatesTheLimitsTheVerbsApply() async throws {
        let bed = try await ScriptVerbBed.open()
        let described = ScriptAnswer(await bed.harness.tabsCtl("describe", ["capability": "browser"]))
        let limits = try #require(described.result["limits"])
        #expect(limits["executeResultMax"] == 50_000)
        #expect(limits["waitDefaultTimeoutMs"] == 10_000 && limits["waitMaxTimeoutMs"] == 300_000)
        #expect(limits["waitIdleQuietMs"] == 500 && limits["waitDefaultPollMs"] == 250)
        #expect(limits["pageTextDefaultMax"] == 50_000 && limits["pageTextHardMax"] == 200_000)
    }

    /// J-19..J-22 reference: `describe` lists each verb with its flags (docs verbatim), its wire schema and its result shape.
    @Test func describeReferencesEachVerbWithItsFlagsWireAndResult() async throws {
        let bed = try await ScriptVerbBed.open()
        let described = ScriptAnswer(await bed.harness.tabsCtl("describe", ["capability": "browser"]))
        guard case .array(let commands)? = described.result["commands"] else { Issue.record("no commands: \(described.json)"); return }
        func command(_ name: String) -> JSONValue? { commands.first { $0["command"]?.stringValue == name } }
        let waitFor = try #require(command("wait-for"))
        #expect(waitFor["usage"]?.stringValue?.hasPrefix("tabs-ctl wait-for --pane <pane> ") == true, "\(waitFor["usage"] ?? .null)")
        #expect(
            waitFor["flags"]?["timeout"]?["doc"] == "Default 10000, capped at 300000. Long waits also need the Bash tool timeout raised.")
        #expect(waitFor["wire"]?["properties"]?["timeoutMs"]?["type"] == "number")
        #expect(waitFor["wire"]?["required"] == ["type", "targetPaneId"])
        #expect(waitFor["result"]?["elapsedMs"] == "number")
        let save = try #require(command("save-resource"))
        #expect(save["flags"]?["out"]?["doc"]?.stringValue?.hasPrefix("Where to write it") == true)
        #expect(save["wire"]?["properties"]?["outPath"] == .emptyObject, "a path is a string or true: no type check")
        let execute = try #require(command("execute-js"))
        #expect(execute["flags"]?["code"]?["required"] == true)
        #expect(execute["result"]?["truncated"] == "boolean")
        #expect(command("read-network") == nil && command("capture-bodies") == nil)
    }
}
