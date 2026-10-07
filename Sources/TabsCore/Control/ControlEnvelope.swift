import Foundation
import TabsPluginSDK

/// Turns a dumb CLI's `{command, args}` envelope into a wire request.
/// `tabs-ctl` carries no knowledge of any command: it sends flags as raw
/// strings (and a bare flag as `true`) and the app does the rest — resolves
/// the command, coerces each flag by the verb's declared arguments, and
/// composes an element target. What comes out is exactly the request a
/// `batch` step is written as, and goes through the same validated dispatch,
/// so a coercion bug can never let an envelope-built request skip a check a
/// hand-typed one gets.
///
/// Messages name the flag and are written to be clear, not to match a frozen
/// contract. The one sentence the skill quotes verbatim is a handler's, not a
/// coercion's.
@MainActor
package enum ControlEnvelope {
    /// What building a request produced: the wire request (with `paneId`) or
    /// the error to answer with.
    package struct Built: Equatable {
        package var request: JSONValue?
        package var error: String?

        static func failed(_ message: String) -> Built { Built(request: nil, error: message) }
    }

    /// `verb`'s wire request for `args` — flags as the CLI sent them — from
    /// the caller `paneId`, resolving path flags against `cwd`.
    package static func build(
        _ verb: ControlVerbContribution, command: String, args: [String: JSONValue], paneId: PaneID, cwd: URL?
    ) -> Built {
        // `null` counts as absent, as it does for every other argument.
        let args = args.filter { $0.value != .null }
        let flags = ControlFlag.of(verb)
        let known = flags.map(\.name) + (verb.composition == .elementTarget ? ControlFlag.elementTargetFlagNames : [])
        var seen: Set<String> = []
        let accepted = known.filter { seen.insert($0).inserted }
        if let unknown = args.keys.sorted().first(where: { !accepted.contains($0) }) {
            let valid = accepted.map { "--\($0)" }.joined(separator: ", ")
            return .failed("unknown flag --\(unknown) for \(command); accepts: \(valid.isEmpty ? "(none)" : valid)")
        }

        var request: [String: JSONValue] = ["type": .string(verb.wireType ?? verb.name), "paneId": .string(paneId.rawValue)]
        for flag in flags where !flag.composed {
            guard let raw = args[flag.name] ?? flag.defaultValue else {
                if flag.required { return .failed("--\(flag.name) is required\(flag.coercion == .json ? " (JSON)" : "")") }
                continue
            }
            // A flag given no value arrives as `true`: right for a boolean and
            // for a path ("generate one"), and for every other kind the caller
            // forgot the value. Letting it through would corrupt the request
            // (`Number(true)` is 1: a bare `--timeout` would send `timeoutMs: 1`).
            if raw == .bool(true), flag.coercion != .boolean, flag.coercion != .path {
                return .failed("--\(flag.name) needs a value")
            }
            if let allowed = flag.enumValues, !allowed.contains(text(of: raw)) {
                return .failed("--\(flag.name) must be one of \(allowed.joined(separator: ", ")) (got \(text(of: raw)))")
            }
            switch flag.coercion {
            case .number:
                guard let value = number(of: raw) else { return .failed("--\(flag.name) must be a number (got \(text(of: raw)))") }
                if let minimum = flag.minimum, value < minimum {
                    return .failed("--\(flag.name) must be at least \(ControlSchema.number(minimum)) (got \(text(of: raw)))")
                }
                request[flag.wire] = json(value)
            case .boolean:
                // A present flag is its value: `true`, or what an inverting flag declares.
                request[flag.wire] = flag.flagValue ?? true
            case .csv:
                request[flag.wire] = .array(text(of: raw).split(separator: ",").map { .string(String($0)) })
            case .json:
                switch raw {
                case .string(let source):
                    do {
                        request[flag.wire] = try JSONDecoder().decode(JSONValue.self, from: Data(source.utf8))
                    } catch {
                        return .failed("--\(flag.name) is not valid JSON: \(Self.reason(of: error))")
                    }
                default:
                    // A raw socket client may send the value itself.
                    request[flag.wire] = raw
                }
            case .path:
                // Bare `--out` is `true`, "generate one", and rides the wire
                // as `true`; a value is resolved against the caller's own cwd.
                if raw == .bool(true) {
                    request[flag.wire] = true
                } else {
                    switch ControlDispatcher.resolve(path: text(of: raw), cwd: cwd) {
                    case .success(let absolute): request[flag.wire] = .string(absolute)
                    case .failure(let error): return .failed("--\(flag.name): \(error.message)")
                    }
                }
            case .string:
                request[flag.wire] = raw
            }
        }

        if verb.composition == .elementTarget {
            switch composeElementTarget(args) {
            case .success(let target): request["target"] = target
            case .failure(let error): return .failed(error.message)
            }
        }
        return Built(request: .object(request), error: nil)
    }

    /// The wire `target` from `--ref` | `--x`+`--y` | `--role`/`--name`/
    /// `--selector` [`--nth`]: the one flag composition the protocol has. The
    /// three forms are exclusive; `--nth` only makes sense with the semantic
    /// one.
    package static func composeElementTarget(_ args: [String: JSONValue]) -> Result<JSONValue, ControlDispatcher.RequestError> {
        typealias Failure = ControlDispatcher.RequestError
        // None of these flags is boolean or a path, so a bare one (`true`) is
        // a forgotten value — refused here, before `--ref`/`--x`/`--y` are
        // ever turned into `"true"` or `1`. These flags bypass the generic
        // per-flag loop, so the rule is restated for them.
        for flag in ["ref", "x", "y", "nth"] where args[flag] == .bool(true) { return .failure(Failure("--\(flag) needs a value")) }

        let hasRef = args["ref"] != nil
        let hasCoordinate = args["x"] != nil || args["y"] != nil
        let semantic = ["role", "name", "selector"].filter { args[$0] != nil }
        var forms: [String] = []
        if hasRef { forms.append("--ref") }
        if hasCoordinate { forms.append("--x/--y") }
        if !semantic.isEmpty { forms.append(semantic.map { "--\($0)" }.joined(separator: "/")) }
        if forms.count > 1 { return .failure(Failure("\(forms.joined(separator: " and ")) are different target forms — pass only one")) }
        if args["nth"] != nil, semantic.isEmpty { return .failure(Failure("--nth only applies to --role/--name/--selector targeting")) }

        if hasRef, let ref = args["ref"] { return .success(["ref": .string(text(of: ref))]) }

        if hasCoordinate {
            guard let rawX = args["x"], let rawY = args["y"] else { return .failure(Failure("a coordinate target needs both --x and --y")) }
            guard let x = number(of: rawX), let y = number(of: rawY) else {
                return .failure(Failure("--x and --y must be numbers (got \(text(of: rawX)), \(text(of: rawY)))"))
            }
            return .success(["x": json(x), "y": json(y)])
        }

        if !semantic.isEmpty {
            var target: [String: JSONValue] = [:]
            for flag in semantic {
                guard let value = args[flag], case .string = value else { return .failure(Failure("--\(flag) needs a value")) }
                target[flag] = value
            }
            if let rawNth = args["nth"] {
                guard let nth = number(of: rawNth), nth == nth.rounded(), nth >= 0 else {
                    return .failure(Failure("--nth must be a non-negative integer (got \(text(of: rawNth)))"))
                }
                target["nth"] = json(nth)
            }
            return .success(.object(target))
        }
        return .failure(Failure("--role/--name/--selector, --ref, or both --x and --y is required"))
    }

    // MARK: JavaScript's coercions

    /// `String(raw)`.
    static func text(of raw: JSONValue) -> String {
        switch raw {
        case .string(let value): value
        case .bool(let value): value ? "true" : "false"
        case .int(let value): String(value)
        case .double(let value): ControlSchema.number(value)
        case .null: "null"
        case .array, .object: ControlSchema.compact(raw)
        }
    }

    /// `Number(raw)`, nil for NaN (and for infinities, which have no JSON form).
    static func number(of raw: JSONValue) -> Double? {
        let value: Double?
        switch raw {
        case .int(let number): value = Double(number)
        case .double(let number): value = number
        case .bool(let flag): value = flag ? 1 : 0
        case .string(let text):
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            value = trimmed.isEmpty ? 0 : Double(trimmed)
        case .null: value = 0
        case .array, .object: value = nil
        }
        guard let value, value.isFinite else { return nil }
        return value
    }

    /// A number as JSON: an integer when it is one.
    static func json(_ value: Double) -> JSONValue {
        if let whole = Int64(exactly: value) { .int(whole) } else { .double(value) }
    }

    private static func reason(of error: any Error) -> String {
        if let decoding = error as? DecodingError, case .dataCorrupted(let context) = decoding {
            return context.debugDescription
        }
        return (error as NSError).localizedDescription
    }
}
