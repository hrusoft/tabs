import Foundation
import TabsPluginSDK

/// The wire request's JSON Schema, and the small evaluator that checks a
/// request against it, over exactly the subset the control protocol needs —
/// `type`, `properties`/`required`/`additionalProperties`, `enum`/`const`/
/// `minimum`, a shallow `items`, and `oneOf`/`anyOf`. Deliberately no library:
/// adding a feature here should mean the protocol needs it.
///
/// Each verb's schema is derived from its `arguments`
/// (`ControlSchema.wire(for:)`), so the two cannot drift, and `describe`
/// prints the derived schema.
package enum ControlSchema {
    // MARK: Deriving the wire schema

    /// The schema of a control-plane verb's wire request: an object closed
    /// with `additionalProperties: false`, the verb's own `type`, `targetPaneId`
    /// for an owned-pane target, and one property per argument (plus `target`
    /// for an element-target composition). `paneId` never appears: core fills
    /// it in, and validation strips it first.
    package static func wire(for verb: ControlVerbContribution) -> JSONValue {
        var properties: [String: JSONValue] = ["type": ["const": .string(verb.wireType ?? verb.name)]]
        var required: [JSONValue] = ["type"]
        if case .ownedPane = verb.target {
            properties["targetPaneId"] = ["type": "string"]
            required.append("targetPaneId")
        }
        if verb.composition == .elementTarget {
            properties["target"] = elementTarget
            required.append("target")
        }
        for argument in verb.arguments {
            properties[argument.name] = schema(of: argument)
            if argument.required { required.append(.string(argument.name)) }
        }
        return [
            "type": "object", "properties": .object(properties), "required": .array(required), "additionalProperties": false,
        ]
    }

    /// One argument's property schema.
    package static func schema(of argument: ControlArgument) -> JSONValue {
        if let schema = argument.schema { return schema }
        if let values = argument.enumValues, argument.kind == .string { return ["enum": .array(values.map(JSONValue.string))] }
        var schema: [String: JSONValue]
        switch argument.kind {
        case .string: schema = ["type": "string"]
        case .integer: schema = ["type": "integer"]
        case .number: schema = ["type": "number"]
        case .bool: schema = ["type": "boolean"]
        case .object: schema = ["type": "object"]
        case .array: schema = ["type": "array"]
        // A path's wire value is a string or `true` ("generate one"), and a
        // json value is anything: no type check, only that the property exists.
        case .path, .json: schema = [:]
        case .csv: schema = ["type": "array", "items": ["type": "string"]]
        }
        if let minimum = argument.minimum, argument.kind == .number || argument.kind == .integer {
            schema["minimum"] = Int64(exactly: minimum).map(JSONValue.int) ?? .double(minimum)
        }
        return .object(schema)
    }

    /// `ElementTarget`'s wire shape: a ref, a coordinate, or a semantic match
    /// (role, name and selector, at least one, plus an optional nth).
    package static let elementTarget: JSONValue = [
        "oneOf": [
            ["type": "object", "properties": ["ref": ["type": "string"]], "required": ["ref"], "additionalProperties": false],
            [
                "type": "object", "properties": ["x": ["type": "number"], "y": ["type": "number"]], "required": ["x", "y"],
                "additionalProperties": false,
            ],
            [
                "type": "object",
                "properties": [
                    "role": ["type": "string"], "name": ["type": "string"], "selector": ["type": "string"], "nth": ["type": "number"],
                ],
                "anyOf": [
                    ["type": "object", "required": ["role"]], ["type": "object", "required": ["name"]],
                    ["type": "object", "required": ["selector"]],
                ],
                "additionalProperties": false,
            ],
        ]
    ]

    // MARK: Validating

    /// Validates `value` against `schema`, returning the first violation as a
    /// plain-language message naming `path`, or nil when it validates.
    ///
    /// Checks run in a fixed order — const/enum, type, numeric bounds, object
    /// shape, array items, then the combinators, with object keys walked
    /// sorted — so two runs against the same invalid value report the same
    /// thing.
    package static func validate(_ value: JSONValue, against schema: JSONValue, path: String = "value") -> String? {
        guard case .object(let schema) = schema else { return nil }
        if let constant = schema["const"], value != constant {
            return "\(path) must be \(compact(constant)) (got \(compact(value)))"
        }
        if case .array(let allowed)? = schema["enum"], !allowed.contains(value) {
            return "\(path) must be one of \(allowed.map(plain).joined(separator: ", ")) (got \(compact(value)))"
        }
        let type = schema["type"]?.stringValue
        if let type {
            if type == "integer" {
                if !isInteger(value) { return "\(path) must be an integer (got \(value.doubleValue.map(number) ?? typeName(value)))" }
            } else if typeName(value) != type {
                return "\(path) must be a \(type) (got \(typeName(value)))"
            }
        }
        if type == "number" || type == "integer", let minimum = schema["minimum"]?.doubleValue, let actual = value.doubleValue,
            actual < minimum
        {
            return "\(path) must be at least \(number(minimum)) (got \(number(actual)))"
        }
        if type == "object", case .object(let object) = value {
            if case .array(let required)? = schema["required"] {
                for case .string(let key) in required where object[key] == nil { return "\(path) is missing required field \"\(key)\"" }
            }
            var properties: [String: JSONValue] = [:]
            if case .object(let declared)? = schema["properties"] { properties = declared }
            if schema["additionalProperties"] == false, let unexpected = object.keys.sorted().first(where: { properties[$0] == nil }) {
                return "\(path) has an unexpected field \"\(unexpected)\""
            }
            for key in properties.keys.sorted() {
                guard let member = object[key], let propertySchema = properties[key] else { continue }
                if let problem = validate(member, against: propertySchema, path: "\(path).\(key)") { return problem }
            }
        }
        if type == "array", case .array(let items) = value, let itemSchema = schema["items"] {
            for (index, item) in items.enumerated() {
                if let problem = validate(item, against: itemSchema, path: "\(path)[\(index)]") { return problem }
            }
        }
        if case .array(let branches)? = schema["oneOf"] {
            let matches = branches.filter { validate(value, against: $0, path: path) == nil }.count
            if matches != 1 { return "\(path) must match exactly one of its allowed shapes (matched \(matches))" }
        }
        if case .array(let branches)? = schema["anyOf"], !branches.contains(where: { validate(value, against: $0, path: path) == nil }) {
            return "\(path) must match at least one of its allowed shapes"
        }
        return nil
    }

    /// JSON's own type vocabulary.
    static func typeName(_ value: JSONValue) -> String {
        switch value {
        case .array: "array"
        case .null: "null"
        case .object: "object"
        case .string: "string"
        case .bool: "boolean"
        case .int, .double: "number"
        }
    }

    private static func isInteger(_ value: JSONValue) -> Bool { value.intValue != nil }

    /// JSON.stringify.
    static func compact(_ value: JSONValue) -> String {
        (try? value.encodedData(pretty: false)).flatMap { String(data: $0, encoding: .utf8) } ?? "?"
    }

    /// A string as is, anything else as JSON — `Array.join`'s rendering.
    private static func plain(_ value: JSONValue) -> String { value.stringValue ?? compact(value) }

    /// A number as JavaScript prints it: whole numbers without a fraction.
    static func number(_ value: Double) -> String {
        value == value.rounded() && abs(value) < 1e15 ? String(Int64(value)) : String(value)
    }
}
