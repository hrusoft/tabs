import AppKit
import Foundation
import TabsPluginSDK
import Testing

@testable import TabsCore

/// A pane of the fixture "web" content type: what an agent creates and drives.
@MainActor
final class WebPane: PaneController {
    let view = NSView()
    var url: String
    var describes: PaneControlDescription = .fields(["isLoading": false])
    /// Whether `list-panes` shows it.
    var listed = true
    /// What closing it would lose.
    var warning: String?
    var closeWarning: String? { warning }
    /// Who controlled it when its controller was built: an owned pane must
    /// know before its first load.
    let controllerAtInit: PaneID?
    let context: any PaneContext
    init(context: any PaneContext) {
        self.context = context
        controllerAtInit = context.controller
        url = context.initialConfig["url"]?.stringValue ?? "about:blank"
    }
    func currentConfig() -> JSONValue { ["url": .string(url)] }
    var controlSummary: JSONValue? { listed ? ["url": .string(url)] : nil }
    func controlDescription() async -> PaneControlDescription { describes }
}

/// A plugin whose verbs are shaped like the Electron browser's, to check the
/// control plane with (nothing here is the real browser), and a second plugin
/// with a "term" content type: the shells that run `tabs-ctl`.
@MainActor
final class ControlFixture {
    /// What the fixture's verbs saw and did.
    final class Log {
        var invocations: [(command: String, invocation: ControlInvocation)] = []
        var openedPanes: [PaneID] = []
        /// Handlers that saw their cancellation.
        var cancellations = 0
        var refusedOpen = 0
    }

    let runtime = TestSupport.runtime()
    let renderer = FakeRenderer()
    let engine: LayoutEngine
    let log = Log()

    static let wireTypes: [String: String] = [
        "navigate": "navigate", "reload": "reload", "click": "click", "type": "type", "scroll": "scroll",
        "get-page-text": "getPageText", "read-console": "readConsoleMessages", "key": "key", "capture-bodies": "captureNetworkBodies",
        "read-network": "readNetworkRequests", "execute-js": "executeJavaScript", "save-resource": "saveResource", "wait-for": "waitFor",
        "create-web-pane": "createWebPane", "steal-pane": "stealPane", "hang": "hang", "slow": "slow", "nap": "nap",
    ]

    /// - Parameters:
    ///   - windows: the layout to start from; nil makes window "w" with terminals `t1` and `t2`.
    ///   - extra: more plugins.
    init(windows: [WindowLayout]? = nil, extra: [PluginCandidate] = [], webIsDisabled: Bool = false) {
        let log = log
        runtime.startPlugins(
            from: nil,
            inProcess: [
                TestSupport.candidate(TestSupport.manifest("term", contentTypes: ["term"])) { context in
                    context.register(TestSupport.contentType("term"))
                },
                TestSupport.candidate(TestSupport.manifest("web", contentTypes: ["web"])) { context in
                    let workspace = context.workspace
                    context.register(
                        ContentTypeContribution(id: "web", displayName: "Web", icon: .symbol("globe")) { pane in
                            WebPane(context: pane)
                        })
                    context.register(
                        ControlCapabilityContribution(
                            id: "web", displayName: "Web", guide: "Web panes. Read the page before you click.", limits: ["maxText": 50_000])
                    )
                    Self.registerVerbs(context, workspace: workspace, log: log)
                },
            ] + extra)
        engine = LayoutEngine(runtime: runtime)
        engine.renderer = renderer
        engine.restore(SavedLayout(windows: windows ?? [Self.terminals("t1", "t2")]))
        if webIsDisabled { runtime.host.setUserEnabled(false, for: "web") }
    }

    /// Window "w": one tab per terminal, the first shown.
    static func terminals(_ ids: PaneID..., id: WindowID = "w") -> WindowLayout {
        let tabs = ids.map { Tab(title: "Term", content: .leaf(LayoutLeaf(id: $0, type: "term"))) }
        return WindowLayout(id: id, root: .tabs(TabGroup(tabs: tabs, activeTabID: tabs[0].id)), active: ids[0])
    }

    // MARK: Calling

    /// What `tabs-ctl <command> …flags` sends from the shell in `caller`.
    func ctl(_ command: String, _ flags: [String: JSONValue] = [:], from caller: PaneID = "t1", cwd: URL? = URL(filePath: "/work")) async
        -> JSONValue
    {
        await runtime.control.handle(
            ControlDispatcher.Envelope(command: command, arguments: .object(flags), targetPane: caller, cwd: cwd))
    }

    /// A raw wire request from `caller` (a batch step, or a client speaking the protocol).
    func wire(_ request: [String: JSONValue], from caller: PaneID = "t1", cwd: URL? = URL(filePath: "/work")) async -> JSONValue {
        var request = request
        request["paneId"] = .string(caller.rawValue)
        return await runtime.control.dispatch(wire: .object(request), cwd: cwd)
    }

    /// `create-web-pane` from `caller`: the new pane's id.
    @discardableResult
    func createPane(from caller: PaneID = "t1", url: String = "about:blank") async throws -> PaneID {
        let response = await ctl("create-web-pane", ["url": .string(url)], from: caller)
        return PaneID(try #require(response["result"]?["paneId"]?.stringValue, "created: \(response)"))
    }

    func web(_ pane: PaneID) -> WebPane? { engine.live(pane)?.controller as? WebPane }

    // MARK: Verbs

    private static let paneFlag: ControlTarget = .ownedPane(ofTypes: ["web"])

    private static func registerVerbs(_ context: any PluginContext, workspace: any Workspace, log: Log) {
        func verb(
            _ name: String, _ command: String, _ summary: String, arguments: [ControlArgument] = [], target: ControlTarget = paneFlag,
            timeout: Duration = .seconds(15), batchable: Bool = true, timeoutFor: (@Sendable ([String: JSONValue]) -> Duration)? = nil,
            composition: ControlFlagComposition? = nil, result: JSONValue? = nil,
            handle: (@MainActor (ControlInvocation) async throws -> JSONValue)? = nil
        ) {
            context.register(
                ControlVerbContribution(
                    name: "web.\(name)", summary: summary, arguments: arguments, target: target, timeout: timeout, command: command,
                    wireType: wireTypes[command], batchable: batchable, timeoutFor: timeoutFor, resultShape: result,
                    composition: composition
                ) { invocation in
                    log.invocations.append((command, invocation))
                    if let handle { return try await handle(invocation) }
                    return ["echo": .object(invocation.arguments)]
                })
        }
        verb(
            "createWebPane", "create-web-pane", "Open a web pane and wait for its first page.",
            arguments: [ControlArgument("url", .string, required: true, summary: "http://, https://, or about:blank.")],
            target: .none, batchable: false, result: ["paneId": "string"],
            handle: { invocation in
                let url = invocation["url"]?.stringValue ?? ""
                guard
                    let pane = workspace.openPane(
                        PaneRequest(
                            type: "web", config: ["url": .string(url)], placement: .tab(near: invocation.callerPane), activates: false,
                            controlledBy: invocation.callerPane))
                else {
                    log.refusedOpen += 1
                    throw ControlVerbError("the pane could not be opened")
                }
                log.openedPanes.append(pane)
                return ["paneId": .string(pane.rawValue), "loaded": true]
            })
        verb(
            "stealPane", "steal-pane", "Open a web pane controlled by whichever pane you name.",
            arguments: [ControlArgument("controller", .string, required: true)], target: .none, batchable: false,
            handle: { invocation in
                let controller = PaneID(invocation["controller"]?.stringValue ?? "")
                guard let pane = workspace.openPane(PaneRequest(type: "web", controlledBy: controller)) else {
                    log.refusedOpen += 1
                    throw ControlVerbError("the pane could not be opened")
                }
                return ["paneId": .string(pane.rawValue)]
            })
        verb(
            "navigate", "navigate", "Load a URL into a pane you own and wait for it to settle.",
            arguments: [
                ControlArgument("url", .string, required: true, summary: "http://, https://, or about:blank."),
                ControlArgument("retryOnRedirect", .bool, summary: "Re-issue the navigation once if it lands elsewhere."),
            ], result: ["loaded": "boolean", "url": "string"])
        verb("reload", "reload", "Reload the current page and wait for it to settle.")
        verb("click", "click", "Click an element or a viewport coordinate.", timeout: .seconds(5), composition: .elementTarget)
        verb(
            "type", "type", "Type text at the target.",
            arguments: [
                ControlArgument("text", .string, required: true, summary: "Printable text only."),
                ControlArgument("submit", .bool, summary: "Press Enter after the text."),
            ], composition: .elementTarget)
        verb(
            "scroll", "scroll", "Scroll the document.",
            arguments: [
                ControlArgument("direction", .string, required: true, enumValues: ["up", "down", "left", "right"]),
                ControlArgument("amount", .number),
            ])
        verb(
            "getPageText", "get-page-text", "Rendered page text.",
            arguments: [ControlArgument("maxLength", .number, summary: "Default 50000.", minimum: 1)])
        verb(
            "readConsole", "read-console", "The console messages.",
            arguments: [ControlArgument("pattern", .string), ControlArgument("sinceSeq", .number, minimum: 0)])
        verb(
            "key", "key", "Send one key.",
            arguments: [
                ControlArgument("key", .string, summary: "The key to press."),
                ControlArgument(
                    "modifiers", .csv, placeholder: "shift,control,alt,meta",
                    schema: ["type": "array", "items": ["enum": ["shift", "control", "alt", "meta"]]]),
                ControlArgument("command", .string, enumValues: ["select-all", "undo", "redo", "delete"]),
            ])
        verb(
            "captureBodies", "capture-bodies", "Capture response bodies.",
            arguments: [ControlArgument("enabled", .bool, flag: "off", flagValue: false)])
        verb("readNetwork", "read-network", "Network requests.", arguments: [ControlArgument("failed", .bool)])
        verb(
            "executeJs", "execute-js", "Run one expression.",
            arguments: [
                ControlArgument("code", .string, required: true),
                ControlArgument("outPath", .path, summary: "Write the result here.", flag: "out"),
            ])
        verb(
            "saveResource", "save-resource", "Save a resource.",
            arguments: [ControlArgument("url", .string), ControlArgument("outPath", .path, flag: "out")], timeout: .seconds(30))
        verb(
            "waitFor", "wait-for", "Wait for a condition.",
            arguments: [
                ControlArgument("text", .string), ControlArgument("timeoutMs", .number, flag: "timeout"),
                ControlArgument("gone", .bool),
            ],
            timeoutFor: { arguments in
                .milliseconds(min(arguments["timeoutMs"]?.intValue ?? 10_000, 300_000)) + ControlBudget.headroom
            })
        // A handler that never answers, and one that answers slowly.
        verb(
            "hang", "hang", "Never answers.", timeout: .milliseconds(20),
            handle: { _ in
                await withCheckedContinuation { (_: CheckedContinuation<Void, Never>) in }
                return nil
            })
        verb(
            "slow", "slow", "Answers after a while, if not cancelled.", timeout: .milliseconds(20),
            handle: { _ in
                do { try await Task.sleep(for: .seconds(60)) } catch {
                    log.cancellations += 1
                    throw error
                }
                return nil
            })
        verb(
            "nap", "nap", "Answers after `ms`.", arguments: [ControlArgument("ms", .integer, required: true)],
            timeout: .milliseconds(20),
            handle: { invocation in
                try await Task.sleep(for: .milliseconds(invocation["ms"]?.intValue ?? 0))
                return ["napped": true]
            })
    }
}

// MARK: - Comparing JSON

/// `toMatchObject`: every key of `subset` is in `actual`, recursively; arrays
/// compare element by element with the same rule; anything else is equal.
func matches(_ actual: JSONValue?, _ subset: JSONValue) -> Bool {
    switch (actual, subset) {
    case (.object(let actual)?, .object(let subset)):
        return subset.allSatisfy { key, value in matches(actual[key], value) }
    case (.array(let actual)?, .array(let subset)):
        return actual.count == subset.count && zip(actual, subset).allSatisfy { matches($0, $1) }
    default:
        return actual == subset
    }
}
