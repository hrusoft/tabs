import Foundation
import TabsPluginSDK
import Testing

@testable import TabsCore

@MainActor
@Suite struct ControlTests {
    let runtime = TestSupport.runtime()

    final class Probe: @unchecked Sendable {
        var invocations: [ControlInvocation] = []
        let cancellations = AsyncStream<Void>.makeStream()
    }
    let probe = Probe()

    init() {
        let probe = probe
        runtime.startPlugins(
            from: nil,
            inProcess: [
                TestSupport.candidate(TestSupport.manifest("t")) { context in
                    context.register(
                        ControlVerbContribution(
                            name: "t.echo", summary: "echo",
                            arguments: [
                                ControlArgument("text", .string, required: true),
                                ControlArgument("count", .integer),
                                ControlArgument("file", .path),
                                ControlArgument("flag", .bool),
                            ]
                        ) { invocation in
                            probe.invocations.append(invocation)
                            return .object(invocation.arguments)
                        })
                    context.register(
                        ControlVerbContribution(name: "t.refuse", summary: "refuses") { _ in throw ControlVerbError("not today") })
                    context.register(
                        ControlVerbContribution(name: "t.crash", summary: "throws") { _ in
                            struct Odd: Error {}
                            throw Odd()
                        })
                    context.register(ControlVerbContribution(name: "t.nan", summary: "bad result") { _ in ["x": .double(.nan)] })
                    context.register(
                        ControlVerbContribution(name: "t.slow", summary: "never finishes", timeout: .milliseconds(50)) { _ in
                            do {
                                try await Task.sleep(for: .seconds(60))
                            } catch {
                                probe.cancellations.continuation.yield()
                                throw error
                            }
                            return nil
                        })
                }
            ])
    }

    @Test func validArgumentsReachTheHandlerWithTheEnvelope() async {
        let response = await runtime.control.handle(
            json: #"{"command":"t.echo","args":{"text":"hi","count":2.0,"file":"notes/a.txt","flag":null},"paneId":"p1","cwd":"/work"}"#
        )
        #expect(response == ["ok": true, "result": ["text": "hi", "count": 2, "file": "/work/notes/a.txt"]])
        #expect(probe.invocations.first?.targetPane == "p1")
        #expect(probe.invocations.first?.cwd == URL(filePath: "/work", directoryHint: .isDirectory))
    }

    @Test(arguments: [
        (#"{"command":"t.echo","args":{}}"#, "t.echo: missing required argument \"text\""),
        (
            #"{"command":"t.echo","args":{"text":"a","colour":"red"}}"#,
            "t.echo: unknown argument \"colour\"; it takes text, count, file, flag"
        ),
        (#"{"command":"t.echo","args":{"text":1}}"#, "t.echo: argument \"text\" must be a string"),
        (#"{"command":"t.echo","args":{"text":"a","count":2.5}}"#, "t.echo: argument \"count\" must be an integer"),
        (
            #"{"command":"t.echo","args":{"text":"a","file":"rel/path"}}"#,
            "t.echo: argument \"file\": relative path \"rel/path\" needs the request's \"cwd\""
        ),
        (#"{"command":"t.echo","args":[1]}"#, "t.echo: \"args\" must be an object"),
        (#"{"command":"t.refuse","args":{"x":1}}"#, "t.refuse: unknown argument \"x\"; it takes no arguments"),
        (#"{"command":"t.echo","cwd":"relative"}"#, "\"cwd\" must be an absolute path"),
        (#"{"command":"t.echo","paneId":7}"#, "\"paneId\" must be a string"),
    ])
    func invalidRequestsNeverReachTheHandler(request: String, error: String) async {
        #expect(await runtime.control.handle(json: request) == ControlDispatcher.failure(error))
        #expect(probe.invocations.isEmpty)
    }

    @Test(arguments: [
        (#"{"command":"t.refuse"}"#, "t.refuse: not today"),
        (#"{"command":"t.crash"}"#, "t.crash failed: Odd()"),
        (#"{"command":"t.nan"}"#, "t.nan returned a result that isn't valid JSON (NaN or infinity)"),
        (#"{"command":"t.none"}"#, "unknown command \"t.none\" (tabs.verbs lists them)"),
        (#"{"args":{}}"#, "request has no \"command\" string"),
        ("{", "request is not valid JSON"),
    ])
    func failuresAreStructured(request: String, error: String) async {
        #expect(await runtime.control.handle(json: request) == ControlDispatcher.failure(error))
    }

    @Test func aHandlerThatOutlivesItsTimeoutIsCancelled() async {
        let response = await runtime.control.handle(json: #"{"command":"t.slow"}"#)
        #expect(response["error"]?.stringValue?.contains("t.slow timed out after") == true)
        // Answered at the deadline; the handler then sees its cancellation.
        var cancellations = probe.cancellations.stream.makeAsyncIterator()
        #expect(await cancellations.next() != nil)
    }

    @Test func verbsDescribeThemselves() async throws {
        let response = await runtime.control.handle(json: #"{"command":"tabs.verbs"}"#)
        guard case .array(let verbs)? = response["result"] else {
            Issue.record("no verbs")
            return
        }
        let echo = try #require(verbs.first { $0["name"] == "t.echo" })
        #expect(echo["owner"] == "t")
        #expect(echo["arguments"]?.decodeArray()?.first == ["name": "text", "kind": "string", "required": true, "summary": ""])
        #expect(verbs.contains { $0["name"] == "tabs.plugins" })
    }

    @Test func badVerbSpecsFailThePlugin() {
        let runtime = TestSupport.runtime()
        runtime.startPlugins(
            from: nil,
            inProcess: [
                TestSupport.candidate(TestSupport.manifest("bad")) { context in
                    context.register(
                        ControlVerbContribution(
                            name: "bad.v", summary: "x",
                            arguments: [
                                ControlArgument("dup", .string), ControlArgument("dup", .bool),
                            ]
                        ) { _ in nil })
                }
            ])
        #expect(TestSupport.state(runtime, "bad") == .failed("tabs.controlVerbs \"bad.v\": argument \"dup\" is declared twice"))
    }
}

private extension JSONValue {
    func decodeArray() -> [JSONValue]? {
        if case .array(let values) = self { values } else { nil }
    }
}

@MainActor
@Suite struct ControlCancellationTests {
    @Test func aCancelledCallerIsAnsweredAndTheHandlerCancelled() async {
        let runtime = TestSupport.runtime()
        let started = AsyncStream<Void>.makeStream()
        let cancelled = AsyncStream<Void>.makeStream()
        runtime.startPlugins(
            from: nil,
            inProcess: [
                TestSupport.candidate(TestSupport.manifest("t")) { context in
                    context.register(
                        ControlVerbContribution(name: "t.wait", summary: "waits", timeout: .seconds(60)) { _ in
                            started.continuation.yield()
                            do { try await Task.sleep(for: .seconds(60)) } catch { cancelled.continuation.yield() }
                            return nil
                        })
                }
            ])
        let request = Task { await runtime.control.handle(json: #"{"command":"t.wait"}"#) }
        var startedIterator = started.stream.makeAsyncIterator()
        _ = await startedIterator.next()
        request.cancel()
        #expect(await request.value == ControlDispatcher.failure("t.wait was cancelled"))
        var cancelledIterator = cancelled.stream.makeAsyncIterator()
        #expect(await cancelledIterator.next() != nil)
    }
}

/// The timeout/cancellation race on its own.
@MainActor
@Suite struct ControlRaceTests {
    final class Ran: @unchecked Sendable { var value = false }

    @Test func aRequestCancelledBeforeItRunsNeverStartsItsHandler() async {
        let ran = Ran()
        let verb = ControlVerbContribution(name: "t.side", summary: "has a side effect") { _ in
            ran.value = true
            return nil
        }
        // Cancelled before it gets the main actor: a connection that closed
        // while this request waited in its queue.
        let request = Task { @MainActor in try await ControlDispatcher.run(verb, ControlInvocation(arguments: [:])) }
        request.cancel()
        let result = await request.result
        #expect(throws: CancellationError.self) { try result.get() }
        #expect(!ran.value, "its side effects never happen")
    }
}

/// Verbs that act on a pane: core checks the target, and a handler reaches
/// only its own plugin's panes.
@MainActor
@Suite struct PaneVerbTests {
    let runtime = TestSupport.runtime()
    final class Fixture { var shell: FakeShell? }
    let fixture = Fixture()

    init() {
        runtime.startPlugins(
            from: nil,
            inProcess: [
                TestSupport.candidate(TestSupport.manifest("web", contentTypes: ["web"])) { context in
                    context.register(TestSupport.contentType("web"))
                    context.register(
                        ControlVerbContribution(name: "web.reload", summary: "reload a web pane", target: .pane(ofTypes: ["web"])) {
                            invocation in
                            .bool(invocation.pane(as: StubPane.self) != nil)
                        })
                    context.register(
                        ControlVerbContribution(name: "web.peek", summary: "look at the caller's pane") { invocation in
                            .bool(invocation.pane(as: StubPane.self) != nil)
                        })
                },
                TestSupport.candidate(TestSupport.manifest("other", contentTypes: ["other"])) { context in
                    context.register(TestSupport.contentType("other"))
                },
            ])
        fixture.shell = FakeShell(runtime: runtime.panes)
    }

    private func call(_ command: String, pane: PaneID?) async -> JSONValue {
        await runtime.control.handle(ControlDispatcher.Envelope(command: command, targetPane: pane))
    }

    @Test func aPaneVerbGetsItsPaneAfterCoreChecksIt() async throws {
        let web = try #require(runtime.panes.openPane(PaneRequest(type: "web")))
        let other = try #require(runtime.panes.openPane(PaneRequest(type: "other")))
        #expect(await call("web.reload", pane: web) == ["ok": true, "result": true])
        #expect(await call("web.reload", pane: nil) == ControlDispatcher.failure("web.reload acts on a pane: pass \"paneId\""))
        #expect(await call("web.reload", pane: other) == ControlDispatcher.failure("web.reload: \(other) is not an open web pane"))
        #expect(await call("web.reload", pane: "gone") == ControlDispatcher.failure("web.reload: gone is not an open web pane"))
    }

    @Test func anyOtherVerbSeesOnlyItsOwnPluginsPanes() async throws {
        let web = try #require(runtime.panes.openPane(PaneRequest(type: "web")))
        let other = try #require(runtime.panes.openPane(PaneRequest(type: "other")))
        #expect(await call("web.peek", pane: web) == ["ok": true, "result": true])
        #expect(await call("web.peek", pane: other) == ["ok": true, "result": false], "another plugin's pane: no controller")
    }

    @Test func aVerbMayTargetOnlyItsOwnTypes() {
        let runtime = TestSupport.runtime()
        runtime.startPlugins(
            from: nil,
            inProcess: [
                TestSupport.candidate(TestSupport.manifest("sneaky")) { context in
                    context.register(
                        ControlVerbContribution(name: "sneaky.poke", summary: "s", target: .pane(ofTypes: ["web"])) { _ in nil })
                }
            ])
        #expect(
            TestSupport.state(runtime, "sneaky")
                == .failed("tabs.controlVerbs \"sneaky.poke\": target type \"web\" is not one of this plugin's content types"))
    }
}
