import Foundation
import TabsPluginSDK

/// Formats a control-plane verb for `capabilities` and `describe` — the port
/// of the Electron app's `controlDescribe.ts`, and the server-side twin of what
/// `tabs-ctl` once did offline. Pure formatting over what the verb declares.
@MainActor
package enum ControlDescribe {
    /// `tabs-ctl <command> --flag <val> [--optional <val>] (target forms)`:
    /// what `capabilities`' index line and `describe`'s `usage` show.
    package static func usage(_ verb: ControlVerbContribution) -> String {
        var parts = ["tabs-ctl \(verb.command ?? verb.name)"]
        for flag in ControlFlag.of(verb) {
            let stand = flag.placeholder ?? flag.enumValues?.joined(separator: "|") ?? flag.name
            let value = flag.coercion == .boolean ? "" : " <\(stand)>"
            parts.append(flag.required ? "--\(flag.name)\(value)" : "[--\(flag.name)\(value)]")
        }
        if verb.composition == .elementTarget { parts.append("(--role/--name/--selector [--nth <n>] | --ref <ref> | --x <n> --y <n>)") }
        return parts.joined(separator: " ")
    }

    /// One line for `capabilities`' compact index: usage plus a one-line summary.
    package static func indexLine(_ verb: ControlVerbContribution) -> String { "\(usage(verb)) — \(verb.summary)" }

    /// `describe`'s per-flag documentation: everything an agent needs to build
    /// a call, nothing it has to guess.
    private static func flags(_ verb: ControlVerbContribution) -> JSONValue {
        var described: [String: JSONValue] = [:]
        for flag in ControlFlag.of(verb) {
            var entry: [String: JSONValue] = ["required": .bool(flag.required)]
            if flag.declaresType { entry["type"] = .string(flag.coercion.rawValue) }
            if let values = flag.enumValues { entry["enum"] = .array(values.map(JSONValue.string)) }
            if let minimum = flag.minimum { entry["min"] = ControlEnvelope.json(minimum) }
            if let defaultValue = flag.defaultValue { entry["default"] = defaultValue }
            if !flag.doc.isEmpty { entry["doc"] = .string(flag.doc) }
            described[flag.name] = .object(entry)
        }
        return .object(described)
    }

    /// `describe`'s full entry for one command: the flags plus the wire schema
    /// and the result shape.
    package static func command(_ verb: ControlVerbContribution) -> JSONValue {
        var entry: [String: JSONValue] = [
            "command": .string(verb.command ?? verb.name), "summary": .string(verb.summary), "usage": .string(usage(verb)),
            "flags": flags(verb),
        ]
        if verb.composition != nil {
            entry["target"] =
                "Pass any of --role/--name/--selector (matched in the page, failing if ambiguous; --nth <n> is a 0-based pick among the matches); or --ref from read-page/find; or both --x and --y (CSS pixels). The three forms do not mix."
        }
        entry["wire"] = ControlSchema.wire(for: verb)
        if let result = verb.resultShape { entry["result"] = result }
        return .object(entry)
    }
}
