import Foundation
import TabsPluginSDK
import os

/// Routes external-control requests to core's verbs and to plugins'
/// `ControlVerbContribution`s. Transport-agnostic: `--control` feeds it today,
/// a socket server can tomorrow.
///
/// Request:  `{"command": "clock.now", "args": {...}, "paneId": "...", "cwd": "/abs/path"}`
/// Response: `{"ok": true, "result": ...}` or `{"ok": false, "error": "..."}`
///
/// Every request is validated against the verb's argument spec before its
/// handler runs, `path` arguments are made absolute against `cwd`, the handler
/// is cancelled if it outlives the verb's timeout, and a result that isn't
/// valid JSON is refused rather than half-written.
///
/// A verb with a `wireType` belongs to the **control plane** (`ControlPlane.swift`):
/// its envelope is CLI flags, turned into a wire request that goes through
/// `dispatch(wire:)` — caller, ownership, schema, target, budget — the same way
/// a `batch` step does. Every other verb is handled here as it always was.
@MainActor
package final class ControlDispatcher {
    package struct Envelope: Sendable {
        package var command: String
        package var arguments: JSONValue
        package var targetPane: PaneID?
        package var cwd: URL?

        package init(command: String, arguments: JSONValue = .emptyObject, targetPane: PaneID? = nil, cwd: URL? = nil) {
            self.command = command
            self.arguments = arguments
            self.targetPane = targetPane
            self.cwd = cwd
        }
    }

    let registry: ContributionRegistry
    let panes: PaneRuntime
    let plugins: PluginHost
    private var coreVerbs: [String: ControlVerbContribution] = [:]
    /// How long past its budget a control-plane verb may take before it is
    /// answered `timed out`: `ControlBudget.headroom` (tests shorten it).
    package var headroom = ControlBudget.headroom

    package init(registry: ContributionRegistry, panes: PaneRuntime, plugins: PluginHost) {
        self.registry = registry
        self.panes = panes
        self.plugins = plugins
        addCoreVerb(
            ControlVerbContribution(
                name: "tabs.verbs", summary: "Every control verb: owner, summary, arguments and timeout"
            ) { [unowned self] _ in
                .array(self.verbs().map { Self.describe($0.verb, owner: $0.owner) })
            })
        installControlPlane()
    }

    /// Core's own verbs meet the same rules as plugins'.
    package func addCoreVerb(_ verb: ControlVerbContribution) {
        precondition(verb.name.hasPrefix("tabs."), "core verbs live under tabs.")
        precondition(CoreExtensionPoints.problem(with: verb) == nil, "\(verb.name): \(CoreExtensionPoints.problem(with: verb) ?? "")")
        precondition(coreVerbs[verb.name] == nil, "\(verb.name) added twice")
        coreVerbs[verb.name] = verb
    }

    package func verbs() -> [(verb: ControlVerbContribution, owner: PluginID)] {
        let core = coreVerbs.values.map { (verb: $0, owner: PluginID("tabs")) }
        let plugins = registry.contributions(to: .controlVerbs).map { (verb: $0.value, owner: $0.owner) }
        return (core + plugins).sorted { $0.verb.name < $1.verb.name }
    }

    func verb(named name: String) -> (verb: ControlVerbContribution, owner: PluginID)? {
        if let verb = coreVerbs[name] { return (verb, "tabs") }
        return registry.contribution(to: .controlVerbs, id: name).map { ($0.value, $0.owner) }
    }

    /// The verb a request's `command` names: a verb's qualified name
    /// (`browser.navigate`, `tabs.info`), else a control-plane verb's CLI
    /// command (`navigate`). A bare command two verbs share is refused.
    enum Resolution {
        case found(verb: ControlVerbContribution, owner: PluginID)
        case ambiguous([String])
        case none
    }

    func resolve(command: String) -> Resolution {
        if let (verb, owner) = verb(named: command) { return .found(verb: verb, owner: owner) }
        let matches = verbs().filter { $0.verb.command == command }
        switch matches.count {
        case 0: return .none
        case 1: return .found(verb: matches[0].verb, owner: matches[0].owner)
        default: return .ambiguous(matches.map(\.verb.name))
        }
    }

    /// The control-plane verb whose wire request `type` is `type`.
    func verb(wireType type: String) -> (verb: ControlVerbContribution, owner: PluginID)? {
        verbs().first { $0.verb.wireType == type }
    }

    // MARK: Handling

    package func handle(json: String) async -> JSONValue {
        switch Self.parse(json) {
        case .success(let envelope): await handle(envelope)
        case .failure(let error): Self.failure(error.message)
        }
    }

    package func handle(_ envelope: Envelope) async -> JSONValue {
        let verb: ControlVerbContribution
        let owner: PluginID
        switch resolve(command: envelope.command) {
        case .found(let found, let foundOwner):
            verb = found
            owner = foundOwner
        case .ambiguous(let names):
            return Self.failure(
                "command \"\(envelope.command)\" is ambiguous (\(names.sorted().joined(separator: ", "))); use a qualified name")
        case .none:
            // A qualified name is a verb `tabs.verbs` lists; a bare command is
            // `tabs-ctl`'s, and `capabilities` lists those.
            if envelope.command.contains(".") {
                return Self.failure("unknown command \"\(envelope.command)\" (tabs.verbs lists them)")
            }
            return Self.failure(
                "unknown command: \(envelope.command.isEmpty ? "(none)" : envelope.command) — run capabilities to list them")
        }
        if verb.wireType != nil { return await handleControlPlane(verb, command: envelope.command, envelope) }
        let arguments: [String: JSONValue]
        switch Self.validate(envelope.arguments, against: verb.arguments, cwd: envelope.cwd) {
        case .success(let valid): arguments = valid
        case .failure(let error): return Self.failure("\(verb.name): \(error.message)")
        }
        if case .pane(let types) = verb.target {
            guard let pane = envelope.targetPane else { return Self.failure("\(verb.name) acts on a pane: pass \"paneId\"") }
            guard let type = panes.contentType(of: pane), types.contains(type) else {
                return Self.failure("\(verb.name): \(pane) is not an open \(types.map(\.rawValue).sorted().joined(separator: " or ")) pane")
            }
        }
        // The handler reaches a pane's controller only if its plugin made it.
        let invocation = ControlInvocation(
            arguments: arguments, targetPane: envelope.targetPane, callerPane: envelope.targetPane, cwd: envelope.cwd
        ) { [weak panes] id in
            guard let pane = panes?.pane(id), pane.isAttached, pane.owner == owner else { return nil }
            return pane.controller
        }
        do {
            let result = try await Self.run(verb, invocation)
            guard result.isRepresentableInJSON else {
                return Self.failure("\(verb.name) returned a result that isn't valid JSON (NaN or infinity)")
            }
            return ["ok": true, "result": result]
        } catch let error as ControlVerbError {
            return Self.failure("\(verb.name): \(error.message)")
        } catch is TimedOut {
            return Self.failure("\(verb.name) timed out after \(verb.timeout) and was cancelled")
        } catch is CancellationError {
            return Self.failure("\(verb.name) was cancelled")
        } catch {
            return Self.failure("\(verb.name) failed: \(error)")
        }
    }

    struct TimedOut: Error {}

    private struct Race: Sendable {
        var answered = false
        var cancelled = false
        var work: Task<Void, Never>?
        var timer: Task<Void, Never>?
        var answer: (@Sendable (Result<JSONValue, any Error>) -> Void)?
    }

    /// Races the handler against its timeout and the caller's cancellation.
    /// Whichever comes first answers the request, exactly once, and the rest
    /// are cancelled: on timeout or caller cancellation the caller is answered
    /// right away even if the handler ignores cancellation (its late result is
    /// discarded, its side effects are not undone — handlers should honor
    /// cancellation); a handler that finishes cancels its timer.
    ///
    /// Limit: everything here runs on the main actor, so a handler that blocks
    /// it without ever suspending can't be interrupted by anything.
    static func run(_ verb: ControlVerbContribution, _ invocation: ControlInvocation) async throws -> JSONValue {
        try await run(verb, invocation, deadline: verb.timeout)
    }

    /// `run`, answering `timed out` at `deadline` (nil: never).
    static func run(_ verb: ControlVerbContribution, _ invocation: ControlInvocation, deadline: Duration?) async throws -> JSONValue {
        let handle = verb.handle
        let race = OSAllocatedUnfairLock(initialState: Race())
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let answer: @Sendable (Result<JSONValue, any Error>) -> Void = { result in
                    let losers = race.withLock { state -> [Task<Void, Never>]? in
                        guard !state.answered else { return nil }
                        state.answered = true
                        let losers = [state.work, state.timer].compactMap { $0 }
                        // The state holds this closure and the tasks that hold
                        // it: let go of them, or every request leaks them all.
                        state.work = nil
                        state.timer = nil
                        state.answer = nil
                        return losers
                    }
                    guard let losers else { return }
                    for task in losers { task.cancel() }
                    continuation.resume(with: result)
                }
                // Already cancelled (the connection closed while this request
                // waited): answer without running the handler at all.
                let cancelledAlready = race.withLock { state -> Bool in
                    state.answer = answer
                    return state.cancelled
                }
                if cancelledAlready {
                    answer(.failure(CancellationError()))
                    return
                }
                let work = Task { @MainActor in
                    // A cancellation that won the race before this got to run
                    // means the handler never starts.
                    guard !race.withLock({ $0.answered }) else { return }
                    do { answer(.success(try await handle(invocation))) } catch { answer(.failure(error)) }
                }
                let timer = deadline.map { deadline in
                    Task {
                        do { try await Task.sleep(for: deadline) } catch { return }
                        answer(.failure(TimedOut()))
                    }
                }
                // Keep them for cancelling — unless the race is already over
                // (a handler that answered at once), in which case holding them
                // would only keep them alive.
                let settled = race.withLock { state -> Bool in
                    guard !state.answered else { return true }
                    state.work = work
                    state.timer = timer
                    return false
                }
                if settled { timer?.cancel() }
            }
        } onCancel: {
            let answer = race.withLock { state -> (@Sendable (Result<JSONValue, any Error>) -> Void)? in
                state.cancelled = true
                return state.answer
            }
            answer?(.failure(CancellationError()))
        }
    }

    // MARK: Parsing and validation

    package struct RequestError: Error, Equatable {
        package let message: String
        init(_ message: String) { self.message = message }
    }

    package static func parse(_ json: String) -> Result<Envelope, RequestError> {
        guard let request = try? JSONDecoder().decode(JSONValue.self, from: Data(json.utf8)) else {
            return .failure(.init("request is not valid JSON"))
        }
        guard let command = request["command"]?.stringValue else {
            return .failure(.init("request has no \"command\" string"))
        }
        var envelope = Envelope(command: command, arguments: request["args"] ?? .emptyObject)
        switch request["paneId"] {
        case nil, .null?: break
        case .string(let id)?: envelope.targetPane = PaneID(id)
        default: return .failure(.init("\"paneId\" must be a string"))
        }
        switch request["cwd"] {
        case nil, .null?: break
        case .string(let path)? where path.hasPrefix("/"): envelope.cwd = URL(filePath: path, directoryHint: .isDirectory)
        default: return .failure(.init("\"cwd\" must be an absolute path"))
        }
        return .success(envelope)
    }

    /// Checks `arguments` against `spec`: an object, no unknown names, every
    /// required one present, each of its declared kind. Paths come back
    /// absolute; `null` counts as absent.
    package static func validate(_ arguments: JSONValue, against spec: [ControlArgument], cwd: URL?) -> Result<
        [String: JSONValue], RequestError
    > {
        let given: [String: JSONValue]
        switch arguments {
        case .object(let object): given = object.filter { $0.value != .null }
        case .null: given = [:]
        default: return .failure(.init("\"args\" must be an object"))
        }
        let known = Dictionary(spec.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
        if let unknown = given.keys.sorted().first(where: { known[$0] == nil }) {
            let accepted = spec.isEmpty ? "it takes no arguments" : "it takes " + spec.map(\.name).joined(separator: ", ")
            return .failure(.init("unknown argument \"\(unknown)\"; \(accepted)"))
        }
        if let missing = spec.first(where: { $0.required && given[$0.name] == nil }) {
            return .failure(.init("missing required argument \"\(missing.name)\""))
        }
        var valid: [String: JSONValue] = [:]
        for (name, value) in given {
            guard let argument = known[name] else { continue }
            if let allowed = argument.enumValues, case .string(let text) = value, !allowed.contains(text) {
                return .failure(.init("argument \"\(name)\" must be one of \(allowed.joined(separator: ", "))"))
            }
            if let minimum = argument.minimum, let number = value.doubleValue, number < minimum {
                return .failure(.init("argument \"\(name)\" must be at least \(ControlSchema.number(minimum))"))
            }
            switch (argument.kind, value) {
            case (.string, .string), (.bool, .bool), (.object, .object), (.array, .array), (.csv, .array), (.json, _),
                (.number, .int), (.number, .double), (.integer, .int):
                valid[name] = value
            case (.integer, .double(let number)) where Int64(exactly: number) != nil:
                valid[name] = .int(Int64(exactly: number)!)
            case (.path, .string(let raw)) where !raw.isEmpty:
                switch resolve(path: raw, cwd: cwd) {
                case .success(let absolute): valid[name] = .string(absolute)
                case .failure(let error): return .failure(.init("argument \"\(name)\": \(error.message)"))
                }
            default:
                return .failure(.init("argument \"\(name)\" must be \(article(argument.kind)) \(argument.kind.rawValue)"))
            }
        }
        return .success(valid)
    }

    package static func resolve(path: String, cwd: URL?) -> Result<String, RequestError> {
        let expanded = (path as NSString).expandingTildeInPath
        if expanded.hasPrefix("/") { return .success(URL(filePath: expanded).standardizedFileURL.path) }
        guard let cwd else { return .failure(.init("relative path \"\(path)\" needs the request's \"cwd\"")) }
        return .success(cwd.appending(path: expanded).standardizedFileURL.path)
    }

    private static func article(_ kind: ControlArgument.Kind) -> String {
        [.integer, .object, .array].contains(kind) ? "an" : "a"
    }

    // MARK: Output

    static func describe(_ verb: ControlVerbContribution, owner: PluginID) -> JSONValue {
        let target: JSONValue =
            switch verb.target {
            case .none: .null
            case .pane(let types): ["pane": .array(types.map(\.rawValue).sorted().map(JSONValue.string))]
            case .ownedPane(let types):
                ["ownedPane": types.map { .array($0.map(\.rawValue).sorted().map(JSONValue.string)) } ?? .string("any")]
            }
        var entry: [String: JSONValue] = [
            "name": .string(verb.name),
            "owner": .string(owner.rawValue),
            "summary": .string(verb.summary),
            "target": target,
            "timeoutSeconds": .double(Double(verb.timeout.components.seconds) + Double(verb.timeout.components.attoseconds) / 1e18),
            "arguments": .array(
                verb.arguments.map { argument in
                    var described: [String: JSONValue] = [
                        "name": .string(argument.name), "kind": .string(argument.kind.rawValue),
                        "required": .bool(argument.required), "summary": .string(argument.summary),
                    ]
                    // Only what the argument sets: a control-plane flag's extras.
                    if let values = argument.enumValues { described["enum"] = .array(values.map(JSONValue.string)) }
                    if let minimum = argument.minimum { described["minimum"] = ControlEnvelope.json(minimum) }
                    if let defaultValue = argument.defaultValue { described["default"] = defaultValue }
                    if verb.wireType != nil { described["flag"] = .string(argument.flagName) }
                    return .object(described)
                }),
        ]
        if let command = verb.command { entry["command"] = .string(command) }
        if let wireType = verb.wireType {
            entry["wireType"] = .string(wireType)
            entry["batchable"] = .bool(verb.batchable)
        }
        return .object(entry)
    }

    package static func failure(_ message: String) -> JSONValue {
        ["ok": false, "error": .string(message)]
    }
}
