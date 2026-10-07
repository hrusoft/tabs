import Foundation

/// An external-control verb: a JSON request in, a JSON result out. Names are
/// namespaced (`clock.now`); core's own verbs live under `tabs.`.
///
/// Core validates every request against `arguments` before the handler runs —
/// unknown arguments, missing required ones and wrong kinds are refused with a
/// clear message — resolves `path` arguments against the caller's working
/// directory, checks the target pane, and cancels the handler if it outlives
/// `timeout`.
///
/// # Two kinds of verb
///
/// A verb that declares a `wireType` (and its CLI `command`) is part of the
/// **control plane**, the surface `tabs-ctl` drives from a shell inside a
/// pane. It is reached two ways: as CLI flags (`{command: "navigate", args:
/// {"url": "…", "retry-on-redirect": true}, paneId, cwd}`, which core turns
/// into a wire request by its arguments) and as a raw wire request
/// (`{type: "navigate", targetPaneId, url, …}`, a `batch` step). Either way
/// the wire request is validated against a JSON Schema core derives from
/// `arguments`, and:
///
/// - `paneId` is always the **caller's** pane (the shell's `TABS_PANE_ID`),
///   which must be live, else `not running inside a Tabs pane`;
/// - a verb acting on another pane says so with `target: .ownedPane`, names it
///   in the wire request's `targetPaneId` (the CLI's `--pane`), and core
///   requires the caller to own it (a pane the caller's verb created) before
///   the handler runs;
/// - the handler's budget is `timeout` (or `timeoutFor`) plus
///   `ControlBudget.headroom`, and it should answer within the budget itself.
///
/// Any other verb (no `wireType`) is an internal one: arguments are the JSON
/// object under `args` as is, `paneId` is the pane the request is about
/// (`ControlInvocation.targetPane`), and `timeout` is the deadline.
public struct ControlVerbContribution: Contribution {
    public let name: String
    public var summary: String
    public var arguments: [ControlArgument]
    /// What the verb acts on. `.pane(ofTypes:)`: core requires the request's
    /// `paneId` to name an open pane of one of those (your own) types, and the
    /// handler gets its controller from `invocation.pane(as:)`.
    /// `.ownedPane(ofTypes:)` (control-plane verbs): core requires the wire
    /// request's `targetPaneId` to name a pane the caller owns.
    public var target: ControlTarget
    /// A control-plane verb's budget, or an internal verb's deadline.
    public var timeout: Duration
    public var handle: @MainActor (_ invocation: ControlInvocation) async throws -> JSONValue

    // MARK: Control plane

    /// The verb's CLI name (`read-page`), kebab-case: what `tabs-ctl` runs and
    /// `capabilities` lists. Core resolves it, and the qualified `name`
    /// (`browser.readPage`) too; a bare command two verbs share is refused,
    /// naming both. Set together with `wireType`.
    public var command: String?
    /// The wire request's `type` (`readPage`): declared, not derived — several
    /// differ from the command's camelCase. Unique across plugins.
    public var wireType: String?
    /// Whether the verb may be a `batch` step. A verb that registers
    /// something a later step could depend on (a pane's ownership) opts out.
    public var batchable: Bool
    /// The budget for one request, when it depends on the request (a wait:
    /// its own timeout plus headroom). Receives the wire fields (no `type`,
    /// `paneId` or `targetPaneId`; defaults not applied). Overrides `timeout`.
    public var timeoutFor: (@Sendable (_ arguments: [String: JSONValue]) -> Duration)?
    /// What `describe` prints as the result's shape: nested documentation, a
    /// string naming a primitive (`"number"`), `[shape]` an array of it, an
    /// object nesting. Never validated against the actual result.
    public var resultShape: JSONValue?
    /// A composite that turns several flags into one wire field.
    public var composition: ControlFlagComposition?

    public var contributionID: String { name }

    public init(
        name: String,
        summary: String,
        arguments: [ControlArgument] = [],
        target: ControlTarget = .none,
        timeout: Duration = .seconds(30),
        command: String? = nil,
        wireType: String? = nil,
        batchable: Bool = true,
        timeoutFor: (@Sendable (_ arguments: [String: JSONValue]) -> Duration)? = nil,
        resultShape: JSONValue? = nil,
        composition: ControlFlagComposition? = nil,
        handle: @escaping @MainActor (_ invocation: ControlInvocation) async throws -> JSONValue
    ) {
        self.name = name
        self.summary = summary
        self.arguments = arguments
        self.target = target
        self.timeout = timeout
        self.command = command
        self.wireType = wireType
        self.batchable = batchable
        self.timeoutFor = timeoutFor
        self.resultShape = resultShape
        self.composition = composition
        self.handle = handle
    }
}

/// How a control-plane verb's flags are assembled beyond one flag per field.
public enum ControlFlagComposition: Sendable, Equatable {
    /// `--ref`, or `--x` with `--y`, or `--role`/`--name`/`--selector` with an
    /// optional `--nth` — exactly one form — become one wire field `target`
    /// (`{ref}`, `{x, y}` or `{role?, name?, selector?, nth?}`). Core adds the
    /// seven flags (after `--pane`, before the verb's own) and the `target`
    /// wire property, which is required.
    case elementTarget
}

/// Budgets for control-plane verbs.
public enum ControlBudget {
    /// How long past its budget a verb may take before core answers `timed out`
    /// for it: the margin a budget keeps above a wait it must outlive, so the
    /// verb's own bounded answer always beats the deadline. A verb that waits
    /// for something (a page load) declares `wait + headroom` as its budget.
    public static let headroom: Duration = .seconds(5)
    /// A `timeout` that means no deadline (`batch`: each step has its own).
    public static let unbounded: Duration = .seconds(1 << 40)
}

/// What a control verb acts on.
public enum ControlTarget: Sendable, Equatable {
    /// Nothing in particular (the app, the plugin).
    case none
    /// An open pane of one of these types, all the plugin's own, named by the
    /// request's `paneId`. (Internal verbs; a control-plane verb uses
    /// `.ownedPane`.)
    case pane(ofTypes: Set<ContentTypeID>)
    /// A pane the caller owns, named by the wire request's `targetPaneId` (the
    /// CLI's `--pane`, which core adds as a required flag). Before the handler
    /// runs core refuses: no live caller pane (`not running inside a Tabs
    /// pane`), a pane the caller doesn't own (`not the owner of this pane`,
    /// uniform), a pane that is gone (the owner is told it was closed), one of
    /// another type (`target is not a browser pane`). `nil`: any type (core's
    /// own `activate-pane`, `close-pane` and `pane-info`); otherwise all the
    /// plugin's own. The handler reaches the controller with
    /// `invocation.pane(as:)`.
    case ownedPane(ofTypes: Set<ContentTypeID>?)
}

/// One argument a verb accepts. For a control-plane verb the name is the
/// **wire** field (`retryOnRedirect`) and the argument is also a CLI flag.
public struct ControlArgument: Sendable, Equatable {
    public enum Kind: String, Sendable, Equatable {
        case string, integer, number, bool, object, array
        /// A filesystem path: relative values are resolved against the
        /// request's `cwd`; the handler always receives an absolute path. As a
        /// flag, a bare `--out` means "generate one" and arrives as `true`.
        case path
        /// A flag holding a comma-separated list, on the wire an array of
        /// strings (`--modifiers shift,meta`).
        case csv
        /// A flag holding JSON text, on the wire the parsed value (any JSON;
        /// give `schema` to say more).
        case json
    }

    /// The wire field.
    public let name: String
    public let kind: Kind
    public let required: Bool
    /// One line, shown by `describe`.
    public let summary: String
    /// The values the flag may take, checked before it is coerced.
    public var enumValues: [String]?
    /// A numeric floor for a `number` or `integer` flag, refused below it.
    public var minimum: Double?
    /// The value used when the flag is absent (flags only; a raw wire request
    /// gets no defaults).
    public var defaultValue: JSONValue?
    /// A stand-in for the flag's value in the usage line (`--selector <css>`).
    public var placeholder: String?
    /// The CLI flag name, without the dashes, when it isn't the wire name in
    /// kebab-case (`retryOnRedirect` is `--retry-on-redirect` on its own):
    /// `timeoutMs` → `timeout`, `pollMs` → `poll`, `outPath` → `out`.
    public var flag: String?
    /// For a `bool` flag: the wire value a *present* flag stands for, when it
    /// isn't `true` (`--off` → `enabled: false`).
    public var flagValue: JSONValue?
    /// The JSON Schema of the wire field, when the one derived from `kind`
    /// (and `enumValues`, `minimum`) isn't enough: `{type: array, items:
    /// {enum: […]}}`.
    public var schema: JSONValue?

    public init(
        _ name: String,
        _ kind: Kind,
        required: Bool = false,
        summary: String = "",
        enumValues: [String]? = nil,
        minimum: Double? = nil,
        defaultValue: JSONValue? = nil,
        placeholder: String? = nil,
        flag: String? = nil,
        flagValue: JSONValue? = nil,
        schema: JSONValue? = nil
    ) {
        self.name = name
        self.kind = kind
        self.required = required
        self.summary = summary
        self.enumValues = enumValues
        self.minimum = minimum
        self.defaultValue = defaultValue
        self.placeholder = placeholder
        self.flag = flag
        self.flagValue = flagValue
        self.schema = schema
    }

    /// The CLI flag: `flag`, else the wire name in kebab-case.
    public var flagName: String {
        if let flag { return flag }
        var result = ""
        for character in name {
            if character.isUppercase {
                result.append("-")
                result.append(contentsOf: character.lowercased())
            } else {
                result.append(character)
            }
        }
        return result
    }
}

/// A validated request, as a verb handler receives it.
public struct ControlInvocation: Sendable {
    /// The arguments, checked against the verb's spec (paths made absolute).
    /// For a control-plane verb: the wire fields, without `type`, `paneId` and
    /// `targetPaneId`.
    public let arguments: [String: JSONValue]
    /// The pane the request is about. For an internal verb: the request's
    /// `paneId`, e.g. the pane a CLI runs in. For a control-plane verb with an
    /// owned-pane target: the target (`targetPaneId`); nil without one.
    public let targetPane: PaneID?
    /// The request's `paneId` — the pane that made it, the one whose shell ran
    /// the CLI. For a verb that creates a pane, the owner to name in
    /// `PaneRequest.controlledBy`. nil for a request without one.
    public let callerPane: PaneID?
    /// The caller's working directory, if it sent one.
    public let cwd: URL?
    private let ownPane: @MainActor @Sendable (PaneID) -> (any PaneController)?

    public init(arguments: [String: JSONValue], targetPane: PaneID? = nil, callerPane: PaneID? = nil, cwd: URL? = nil) {
        self.init(arguments: arguments, targetPane: targetPane, callerPane: callerPane, cwd: cwd) { _ in nil }
    }

    package init(
        arguments: [String: JSONValue], targetPane: PaneID?, callerPane: PaneID?, cwd: URL?,
        ownPane: @escaping @MainActor @Sendable (PaneID) -> (any PaneController)?
    ) {
        self.arguments = arguments
        self.targetPane = targetPane
        self.callerPane = callerPane
        self.cwd = cwd
        self.ownPane = ownPane
    }

    public subscript(name: String) -> JSONValue? { arguments[name] }

    /// The target pane's controller, if it's one of your plugin's own panes
    /// (always, for a verb whose target is `.pane` or `.ownedPane` of your
    /// types); nil for anyone else's.
    @MainActor
    public func pane<T: PaneController>(as type: T.Type = T.self) -> T? {
        targetPane.flatMap(ownPane) as? T
    }
}

/// Throw this from a verb handler for a clean error message on the wire.
public struct ControlVerbError: Error, CustomStringConvertible {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var description: String { message }
}
