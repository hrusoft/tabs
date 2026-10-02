import Foundation
import TabsPluginSDK

/// The control plane: what an agent's `tabs-ctl` reaches, ported from the
/// Electron app's `src/main/externalControl.ts` (`dispatchTypedRequest`,
/// `handleBatch`, the core verbs) and `controlVerbs.ts` (budgets).
///
/// Two layers. CLI flags become a typed **wire request** (`ControlEnvelope`),
/// which a `batch` step also is: `{type, paneId, targetPaneId?, …}`. `paneId` on
/// the wire is always the CALLER's pane (the shell's `TABS_PANE_ID`), never a
/// claim over the wire; a verb that acts on another pane names it in
/// `targetPaneId` and core requires the caller to own it. `dispatch(wire:)` is
/// the one path both take, in a fixed order:
///
/// 1. the request type is a verb's (`unknown request type`);
/// 2. the caller is a live pane (`not running inside a Tabs pane`) — uniform,
///    before anything else, whatever the verb, so a socket client with no pane
///    can do nothing and learns nothing;
/// 3. a named target is one the caller owns (`not the owner of this pane`),
///    checked once here, so a verb a plugin adds cannot ship without it;
/// 4. the wire request is valid against the verb's schema (`request.<field> …`);
/// 5. the target is still there, and of the verb's type;
/// 6. the handler runs, on its budget.
extension ControlDispatcher {
    /// What a verb aimed at a pane that is gone answers with — quoted verbatim
    /// in the skill's SKILL.md, which is why it is a constant. Two producers:
    /// the ledger's tombstone for a pane its owner closed, and a target that
    /// no longer resolves to a live pane (the user closed it by hand).
    package static let paneGoneError = "target pane no longer exists — it was closed; listOwnedPanes shows the panes still open"

    /// How many sub-requests one `batch` may carry.
    package static let maxBatchSize = 50

    /// The budget for verbs that price themselves at a store read or a tree
    /// change, which answer in single-digit milliseconds.
    static let quickBudget: Duration = .seconds(5)

    // MARK: From an envelope

    func handleControlPlane(_ verb: ControlVerbContribution, command: String, _ envelope: Envelope) async -> JSONValue {
        let args: [String: JSONValue]
        switch envelope.arguments {
        case .object(let object): args = object
        case .null: args = [:]
        default: return Self.failure("\"args\" must be an object")
        }
        let built = ControlEnvelope.build(verb, command: command, args: args, paneId: envelope.targetPane ?? "", cwd: envelope.cwd)
        guard let request = built.request else { return Self.failure(built.error ?? "could not build a request from that envelope") }
        return await dispatch(wire: request, cwd: envelope.cwd)
    }

    /// The flags of `command`, as a wire request: `buildRequestFromEnvelope`.
    package func buildRequest(command: String, args: [String: JSONValue], paneId: PaneID, cwd: URL?) -> ControlEnvelope.Built {
        switch resolve(command: command) {
        case .found(let verb, _) where verb.wireType != nil:
            return ControlEnvelope.build(verb, command: command, args: args, paneId: paneId, cwd: cwd)
        case .ambiguous(let names):
            return .failed("command \"\(command)\" is ambiguous (\(names.sorted().joined(separator: ", "))); use a qualified name")
        case .found, .none:
            return .failed("unknown command: \(command.isEmpty ? "(none)" : command) — run capabilities to list them")
        }
    }

    // MARK: Dispatch

    /// Validates a wire request, enforces the boundary checks every verb
    /// shares, then runs the verb. What arrives is untyped: a `batch` step
    /// assembled from a caller's JSON, or a request `ControlEnvelope` built.
    package func dispatch(wire request: JSONValue, cwd: URL?) async -> JSONValue {
        guard case .object(var fields) = request, let type = fields["type"]?.stringValue, let (verb, owner) = verb(wireType: type) else {
            return Self.failure("unknown request type: \(request["type"]?.stringValue ?? "(none)")")
        }
        let caller = PaneID(fields["paneId"]?.stringValue ?? "")
        guard panes.contentType(of: caller) != nil else { return Self.failure("not running inside a Tabs pane") }

        // Ownership: every request that names a `targetPaneId` may act only on
        // a pane this caller created — the one boundary that keeps a control
        // session from reading or driving the user's panes, or another agent's.
        if let named = fields["targetPaneId"] {
            guard case .string(let id) = named, panes.ownership.owner(of: PaneID(id)) == caller else {
                // The one exception, for the caller who already knew this pane
                // existed: it created it, and it has since closed. "Not the
                // owner" would send it hunting an auth problem instead of
                // reading the documented "it's gone, list and reopen"
                // recovery. Everyone else, one that never owned it included,
                // still gets the uniform refusal, so this leaks nothing about
                // panes that aren't the asker's own.
                if case .string(let id) = named, panes.ownership.wasClosed(PaneID(id), by: caller) {
                    return Self.failure(Self.paneGoneError)
                }
                return Self.failure("not the owner of this pane")
            }
        }

        // Structural validation against the verb's own wire schema, the one
        // check every verb gets. `paneId` is real on every request but absent
        // from every schema (core fills it in from the caller, and a batch step
        // has it overwritten), so it goes before a schema that closes the
        // object.
        fields["paneId"] = nil
        if let problem = ControlSchema.validate(.object(fields), against: ControlSchema.wire(for: verb), path: "request") {
            return Self.failure(problem)
        }

        var target: PaneID?
        if case .ownedPane(let types) = verb.target, let id = fields["targetPaneId"]?.stringValue {
            let pane = PaneID(id)
            guard let live = panes.pane(pane), live.isAttached else { return Self.failure(Self.paneGoneError) }
            if let types, !types.contains(live.contentType) {
                return Self.failure("target is not a \(types.map(\.rawValue).sorted().joined(separator: " or ")) pane")
            }
            target = pane
        }

        // What the handler gets: the wire fields, `path`s absolute.
        fields["type"] = nil
        fields["targetPaneId"] = nil
        for argument in verb.arguments where argument.kind == .path {
            guard case .string(let raw)? = fields[argument.name] else { continue }
            switch Self.resolve(path: raw, cwd: cwd) {
            case .success(let absolute): fields[argument.name] = .string(absolute)
            case .failure(let error): return Self.failure("request.\(argument.name): \(error.message)")
            }
        }

        let invocation = ControlInvocation(arguments: fields, targetPane: target, callerPane: caller, cwd: cwd) {
            [weak panes] id in
            guard let pane = panes?.pane(id), pane.isAttached, pane.owner == owner else { return nil }
            return pane.controller
        }
        return await run(controlPlane: verb, owner: owner, invocation)
    }

    /// The budget for one request: the verb's own, or its function of the
    /// request (`ControlBudget.unbounded`: none).
    static func budget(of verb: ControlVerbContribution, _ arguments: [String: JSONValue]) -> Duration {
        verb.timeoutFor?(arguments) ?? verb.timeout
    }

    /// Runs a control-plane verb on its budget. A verb's own bounded answer
    /// must beat the deadline — a wait declares its longest wait plus
    /// `ControlBudget.headroom` — so `timed out` is only ever what a handler that
    /// never answers earns, and it is answered at the deadline even when the
    /// handler ignores cancellation (its late answer is dropped).
    private func run(controlPlane verb: ControlVerbContribution, owner: PluginID, _ invocation: ControlInvocation) async -> JSONValue {
        let type = verb.wireType ?? verb.name
        let budget = Self.budget(of: verb, invocation.arguments)
        let deadline: Duration? = budget >= ControlBudget.unbounded ? nil : budget + headroom
        // While it is being answered, this verb's plugin may name the caller
        // as the controller of a pane it opens — and not once the verb has
        // been answered (timed out, say), whatever its handler still does.
        if let caller = invocation.callerPane { panes.ownership.verbBegan(of: owner, for: caller) }
        defer { if let caller = invocation.callerPane { panes.ownership.verbEnded(of: owner, for: caller) } }
        do {
            let result = try await Self.run(verb, invocation, deadline: deadline)
            guard result.isRepresentableInJSON else {
                return Self.failure("\(type) returned a result that isn't valid JSON (NaN or infinity)")
            }
            return result == .null ? ["ok": true] : ["ok": true, "result": result]
        } catch let error as ControlVerbError {
            return Self.failure(error.message)
        } catch is TimedOut {
            let milliseconds = budget.components.seconds * 1000 + budget.components.attoseconds / 1_000_000_000_000_000
            return Self.failure("\(type) timed out after \(milliseconds)ms")
        } catch is CancellationError {
            return Self.failure("\(type) was cancelled")
        } catch {
            return Self.failure("\(error)")
        }
    }

    // MARK: Core's verbs

    /// Liveness, the batching envelope, the pane-tree operations that name only
    /// pane ids, and protocol discovery. Core's rather than any plugin's even
    /// where a plugin is what answers: `pane-info` asks the pane's controller,
    /// `close-pane` and `list-panes` touch the ledger.
    func installControlPlane() {
        let quick = Self.quickBudget
        addCoreVerb(
            ControlVerbContribution(
                name: "tabs.ping", summary: "Check that the control socket is reachable.", timeout: quick, command: "ping",
                wireType: "ping"
            ) { _ in nil })

        addCoreVerb(
            ControlVerbContribution(
                name: "tabs.activatePane",
                summary:
                    "Bring a pane you own to the front of its tab group without capturing it. screenshot does this itself when needed.",
                target: .ownedPane(ofTypes: nil), timeout: quick, command: "activate-pane", wireType: "activatePane"
            ) { [unowned self] invocation in
                // Visible, never active: the user's keyboard stays where it is.
                if let pane = invocation.targetPane { self.panes.revealPane(pane) }
                return nil
            })

        addCoreVerb(
            ControlVerbContribution(
                name: "tabs.closePane", summary: "Close a pane you own and give up ownership of it.",
                target: .ownedPane(ofTypes: nil), timeout: quick, command: "close-pane", wireType: "closePane"
            ) { [unowned self] invocation in
                guard let pane = invocation.targetPane else { return nil }
                // Ownership ends only once the pane is really gone (the pane
                // runtime releases it then), so a close the user declined
                // doesn't strand a live pane as unownable.
                guard self.panes.closePane(pane) else { throw ControlVerbError("the pane was not closed") }
                return nil
            })

        addCoreVerb(
            ControlVerbContribution(
                name: "tabs.listPanes", summary: "List the panes you created. Never includes the user’s own panes.", timeout: quick,
                command: "list-panes", wireType: "listOwnedPanes",
                resultShape: ["panes": [["paneId": "string", "type": "string", "title": "string"]]]
            ) { [unowned self] invocation in
                // Every window: an owned pane may have been dragged into another.
                guard let caller = invocation.callerPane else { return nil }
                return ["panes": .array(self.panes.controlListing(ownedBy: caller))]
            })

        addCoreVerb(
            ControlVerbContribution(
                name: "tabs.paneInfo", summary: "Live state of a pane you own — the fields depend on its content type.",
                target: .ownedPane(ofTypes: nil), timeout: quick, command: "pane-info", wireType: "getPaneInfo",
                resultShape: ["paneId": "string", "type": "string", "title": "string"]
            ) { [unowned self] invocation in
                guard let id = invocation.targetPane, let pane = self.panes.pane(id), pane.isAttached else {
                    throw ControlVerbError(Self.paneGoneError)
                }
                switch await pane.controller.controlDescription() {
                case .unsupported: throw ControlVerbError("\(pane.contentType.rawValue) panes cannot be inspected with getPaneInfo")
                case .error(let message): throw ControlVerbError(message)
                case .fields(let fields):
                    var result: [String: JSONValue] = [
                        "paneId": .string(id.rawValue), "type": .string(pane.contentType.rawValue),
                        "title": .string(self.panes.controlTitle(of: id)),
                    ]
                    for (key, value) in fields { result[key] = value }
                    return .object(result)
                }
            })

        addCoreVerb(
            ControlVerbContribution(
                name: "tabs.batch",
                summary: "Run several requests in order as one transcript. Stops at the first failure unless --continue-on-error.",
                arguments: [
                    // Raw wire requests, not flags: a batch's whole point is
                    // sending several at once, so this is the one command whose
                    // payload is the protocol itself.
                    ControlArgument(
                        "requests", .json, required: true,
                        summary: "A JSON array of wire requests — see describe --capability <name> for each verb’s wire shape.",
                        schema: ["type": "array"]),
                    ControlArgument(
                        "continueOnError", .bool,
                        summary: "Run every step even after one fails; failures stay visible per step."),
                ],
                // No deadline of its own: every step runs on its own verb's
                // budget, a wait step's budget is the caller's to size, and
                // cutting a batch off midway would discard the transcript that
                // is its whole point.
                timeout: ControlBudget.unbounded, command: "batch", wireType: "batch", batchable: false,
                resultShape: ["steps": ["object"], "stoppedAt": "number"]
            ) { [unowned self] invocation in try await self.runBatch(invocation) })

        addCoreVerb(
            ControlVerbContribution(
                name: "tabs.capabilities", summary: "One line per command, grouped by capability (core plus every content type).",
                timeout: quick, command: "capabilities", wireType: "capabilities",
                resultShape: [
                    "capabilities": [["id": "string", "displayName": "string", "enabled": "boolean", "commands": ["string"]]]
                ]
            ) { [unowned self] _ in self.capabilities() })

        addCoreVerb(
            ControlVerbContribution(
                name: "tabs.describe",
                summary: "Full command reference for one capability — flags, wire schema, result shape, and its guide.",
                arguments: [
                    ControlArgument(
                        "capability", .string, required: true,
                        summary: "A capability id from capabilities — \"core\", or a content type like \"browser\".")
                ],
                timeout: quick, command: "describe", wireType: "describe",
                resultShape: [
                    "capability": "string", "guide": "string", "limits": "object",
                    "commands": [
                        [
                            "command": "string", "summary": "string", "usage": "string", "flags": "object", "wire": "object",
                            "result": "object",
                        ]
                    ],
                ]
            ) { [unowned self] invocation in try self.describe(capability: invocation["capability"]?.stringValue ?? "") })
    }

    /// Core's commands, in the order `capabilities` and `describe` list them.
    private static let coreCommandOrder = [
        "tabs.ping", "tabs.activatePane", "tabs.closePane", "tabs.listPanes", "tabs.paneInfo", "tabs.batch", "tabs.capabilities",
        "tabs.describe",
    ]

    /// Core's own numbers, served by `describe --capability core`.
    static let coreLimits: [String: JSONValue] = ["maxBatchRequests": .int(Int64(maxBatchSize))]

    private var coreCommands: [ControlVerbContribution] { Self.coreCommandOrder.compactMap { verb(named: $0)?.verb } }

    /// A capability's commands: its plugin's control-plane verbs, in registration order.
    private func commands(of plugin: PluginID) -> [ControlVerbContribution] {
        registry.contributions(to: .controlVerbs).filter { $0.owner == plugin && $0.value.command != nil }.map(\.value)
    }

    /// Every capability but core, in UI order.
    private var pluginCapabilities: [Owned<ControlCapabilityContribution>] {
        registry.contributions(to: .controlCapabilities).enumerated()
            .sorted { a, b in
                let ra = plugins.rank(of: a.element.owner)
                let rb = plugins.rank(of: b.element.owner)
                return ra != rb ? ra < rb : a.offset < b.offset
            }
            .map(\.element)
    }

    private func capabilities() -> JSONValue {
        var entries: [JSONValue] = [
            [
                "id": "core", "displayName": "Core", "enabled": true,
                "commands": .array(coreCommands.map { .string(ControlDescribe.indexLine($0)) }),
            ]
        ]
        for capability in pluginCapabilities {
            entries.append([
                "id": .string(capability.value.id), "displayName": .string(capability.value.displayName),
                // The gate that offers creating its panes; disabled, its verbs
                // still answer for the panes that exist.
                "enabled": .bool(plugins.offersCreation(capability.owner)),
                "commands": .array(commands(of: capability.owner).map { .string(ControlDescribe.indexLine($0)) }),
            ])
        }
        return ["capabilities": .array(entries)]
    }

    private func describe(capability id: String) throws -> JSONValue {
        // Core has no guide: SKILL.md's own preamble covers its verbs, and a
        // second copy would only be something to drift.
        if id == "core" {
            return [
                "capability": "core", "limits": .object(Self.coreLimits),
                "commands": .array(coreCommands.map(ControlDescribe.command)),
            ]
        }
        guard let capability = pluginCapabilities.first(where: { $0.value.id == id }) else {
            throw ControlVerbError("unknown capability \"\(id)\" — run capabilities to list them")
        }
        var result: [String: JSONValue] = [
            "capability": .string(id),
            "commands": .array(commands(of: capability.owner).map(ControlDescribe.command)),
        ]
        if !capability.value.guide.isEmpty { result["guide"] = .string(capability.value.guide) }
        if !capability.value.limits.isEmpty { result["limits"] = .object(capability.value.limits) }
        return .object(result)
    }

    // MARK: Batch

    /// Runs a batch's sub-requests in order and answers with a transcript: one
    /// `steps` entry per request, aligned index-for-index — what ran, whether it
    /// succeeded, how long it took, and its result.
    ///
    /// By default the first failure stops the batch, because a batch is usually
    /// a *sequence* — click this, then read what it produced — where continuing
    /// past a failed step reports confidently on a state that was never
    /// reached. `stoppedAt` names the failed index and every later entry is a
    /// `{skipped: true}` marker rather than absent, so the transcript stays
    /// aligned to what was sent. `continueOnError` is for the other kind of
    /// batch — many independent reads of one page: every step runs, failures
    /// stay visible per entry, and `stoppedAt` is absent.
    ///
    /// Two shapes are refused outright. A nested `batch` buys nothing over a flat
    /// one and makes the size bound meaningless. And a verb that opts out of
    /// batching is refused by the name its plugin gave it (`create-browser-pane`
    /// registers a new pane's ownership partway through, so whether a later step
    /// may target it would depend on evaluation order) — core names no verb to
    /// say so.
    ///
    /// Each step runs as the batch's own caller: `paneId` is overwritten rather
    /// than trusted, so a batch can't smuggle a request that claims to come from
    /// some other pane.
    private func runBatch(_ invocation: ControlInvocation) async throws -> JSONValue {
        guard case .array(let requests)? = invocation["requests"] else { throw ControlVerbError("batch requires a list of requests") }
        if requests.count > Self.maxBatchSize { throw ControlVerbError("a batch may hold at most \(Self.maxBatchSize) requests") }
        for step in requests {
            // Ahead of the generic unbatchable test so nesting keeps its own
            // message, which SKILL.md quotes.
            let type = step["type"]?.stringValue
            if type == "batch" { throw ControlVerbError("a batch cannot contain another batch") }
            if let type, let (verb, _) = verb(wireType: type), !verb.batchable {
                throw ControlVerbError("\(type) cannot be used inside a batch")
            }
        }

        let continueOnError = invocation["continueOnError"] == true
        let caller = JSONValue.string(invocation.callerPane?.rawValue ?? "")
        var steps: [JSONValue] = []
        var stoppedAt: Int?
        let clock = ContinuousClock()
        for (index, step) in requests.enumerated() {
            let type = step["type"]?.stringValue.map(JSONValue.string)
            if stoppedAt != nil {
                steps.append(.object(["skipped": true].merging(type.map { ["type": $0] } ?? [:]) { first, _ in first }))
                continue
            }
            try Task.checkCancellation()
            var wire: [String: JSONValue] = step.objectValue ?? [:]
            wire["paneId"] = caller
            let started = clock.now
            let response = await dispatch(wire: .object(wire), cwd: invocation.cwd)
            let elapsed = started.duration(to: clock.now)
            var entry: [String: JSONValue] = response.objectValue ?? [:]
            if let type { entry["type"] = type }
            entry["durationMs"] = .int(elapsed.components.seconds * 1000 + elapsed.components.attoseconds / 1_000_000_000_000_000)
            steps.append(.object(entry))
            // `ok` on the batch itself reports that the batch *ran*, not that
            // every step succeeded — a failed step as `ok: false` would discard
            // the transcript already collected. tabs-ctl still exits non-zero
            // when any step failed, so the shell contract holds.
            if response["ok"] != true, !continueOnError { stoppedAt = index }
        }
        var result: [String: JSONValue] = ["steps": .array(steps)]
        if let stoppedAt { result["stoppedAt"] = .int(Int64(stoppedAt)) }
        return .object(result)
    }
}

private extension JSONValue {
    var objectValue: [String: JSONValue]? { if case .object(let object) = self { object } else { nil } }
}
