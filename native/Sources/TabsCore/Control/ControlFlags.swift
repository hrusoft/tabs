import Foundation
import TabsPluginSDK

/// One CLI flag of a control-plane verb, as `tabs-ctl` users see it and
/// `describe` documents it: the verb's arguments, plus the `--pane` flag an
/// owned-pane target implies, plus the seven an element-target composition
/// adds.
package struct ControlFlag: Equatable {
    package enum Coercion: String {
        case string, number, boolean, json, csv, path
    }

    /// The flag, without dashes.
    package var name: String
    /// The wire field it becomes.
    package var wire: String
    package var coercion: Coercion
    /// Whether `describe` states the coercion (the Electron specs leave a
    /// plain string's `type` out).
    package var declaresType: Bool
    package var required: Bool
    package var enumValues: [String]?
    package var minimum: Double?
    package var defaultValue: JSONValue?
    package var flagValue: JSONValue?
    package var placeholder: String?
    package var doc: String
    /// A flag of the element-target composition: `composeElementTarget` is its
    /// only authority, and it never becomes a wire field of its own.
    package var composed = false

    /// The flags of `verb`, in the order `describe` and the usage line show
    /// them: `--pane` first, the composition's next, then the arguments.
    package static func of(_ verb: ControlVerbContribution) -> [ControlFlag] {
        var flags: [ControlFlag] = []
        if case .ownedPane = verb.target {
            flags.append(
                ControlFlag(
                    name: "pane", wire: "targetPaneId", coercion: .string, declaresType: false, required: true, doc: "A pane id you own."))
        }
        if verb.composition == .elementTarget { flags += elementTarget }
        for argument in verb.arguments {
            let coercion: Coercion
            switch argument.kind {
            case .string: coercion = .string
            case .integer, .number: coercion = .number
            case .bool: coercion = .boolean
            case .object, .array, .json: coercion = .json
            case .path: coercion = .path
            case .csv: coercion = .csv
            }
            flags.append(
                ControlFlag(
                    name: argument.flagName, wire: argument.name, coercion: coercion, declaresType: argument.kind != .string,
                    required: argument.required, enumValues: argument.enumValues, minimum: argument.minimum,
                    defaultValue: argument.defaultValue, flagValue: argument.flagValue, placeholder: argument.placeholder,
                    doc: argument.summary))
        }
        return flags
    }

    /// `--ref`, `--x`, `--y`, `--role`, `--name`, `--selector`, `--nth`.
    package static let elementTargetFlagNames = ["ref", "x", "y", "role", "name", "selector", "nth"]

    private static let elementTarget: [ControlFlag] = [
        ControlFlag(
            name: "ref", wire: "ref", coercion: .string, declaresType: false, required: false,
            doc: "An opaque ref from a previous read-page/find.",
            composed: true),
        ControlFlag(
            name: "x", wire: "x", coercion: .number, declaresType: true, required: false, doc: "Viewport CSS-pixel x — pair with --y.",
            composed: true),
        ControlFlag(
            name: "y", wire: "y", coercion: .number, declaresType: true, required: false, doc: "Viewport CSS-pixel y — pair with --x.",
            composed: true),
        ControlFlag(
            name: "role", wire: "role", coercion: .string, declaresType: false, required: false,
            doc: "Match by ARIA role (button, link, textbox, …), combined with --name/--selector.", composed: true),
        ControlFlag(
            name: "name", wire: "name", coercion: .string, declaresType: false, required: false,
            doc: "Match by accessible name, combined with --role/--selector.", composed: true),
        ControlFlag(
            name: "selector", wire: "selector", coercion: .string, declaresType: false, required: false, placeholder: "css",
            doc: "Match by CSS selector, combined with --role/--name.", composed: true),
        ControlFlag(
            name: "nth", wire: "nth", coercion: .number, declaresType: true, required: false, minimum: 0,
            doc: "0-based pick among several matches of the strictest tier.", composed: true),
    ]
}
