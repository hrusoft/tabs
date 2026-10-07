import Foundation

/// Plugin-owned data that core stores without understanding it: a pane's
/// config, a plugin's settings blob, a control verb's arguments and result.
///
/// Integers and floating-point numbers are distinct cases so 64-bit integers
/// (ids, nanosecond timestamps) survive exactly: an integral JSON number that
/// fits in `Int64` decodes as `.int`, anything else as `.double`. Non-finite
/// doubles have no JSON form: encoding one throws, and core refuses to store a
/// value that contains one (see `isRepresentableInJSON`).
public enum JSONValue: Hashable, Sendable {
    case null
    case bool(Bool)
    case int(Int64)
    case double(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public static let emptyObject: JSONValue = .object([:])
}

extension JSONValue: Codable {
    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int64.self) {
            self = .int(value)
        } else if let value = try? container.decode(Double.self) {
            self = .double(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else {
            self = .object(try container.decode([String: JSONValue].self))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .int(let value): try container.encode(value)
        case .double(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }
}

extension JSONValue: ExpressibleByNilLiteral, ExpressibleByBooleanLiteral,
    ExpressibleByIntegerLiteral, ExpressibleByFloatLiteral, ExpressibleByStringLiteral,
    ExpressibleByArrayLiteral, ExpressibleByDictionaryLiteral
{
    public init(nilLiteral: ()) { self = .null }
    public init(booleanLiteral value: Bool) { self = .bool(value) }
    public init(integerLiteral value: Int64) { self = .int(value) }
    public init(floatLiteral value: Double) { self = .double(value) }
    public init(stringLiteral value: String) { self = .string(value) }
    public init(arrayLiteral elements: JSONValue...) { self = .array(elements) }
    public init(dictionaryLiteral elements: (String, JSONValue)...) {
        self = .object(Dictionary(elements, uniquingKeysWith: { _, last in last }))
    }
}

public extension JSONValue {
    subscript(key: String) -> JSONValue? {
        if case .object(let object) = self { object[key] } else { nil }
    }

    /// The element at `index` of an array; nil for anything else.
    subscript(index: Int) -> JSONValue? {
        if case .array(let values) = self, values.indices.contains(index) { values[index] } else { nil }
    }

    var stringValue: String? { if case .string(let value) = self { value } else { nil } }
    var boolValue: Bool? { if case .bool(let value) = self { value } else { nil } }

    /// An `.int`, or a `.double` that is integral and fits.
    var intValue: Int64? {
        switch self {
        case .int(let value): value
        case .double(let value): Int64(exactly: value)
        default: nil
        }
    }

    /// Any number, as a `Double` (large `.int`s may round).
    var doubleValue: Double? {
        switch self {
        case .int(let value): Double(value)
        case .double(let value): value
        default: nil
        }
    }

    /// Whether this value can be written as JSON: false if it contains a NaN
    /// or an infinity anywhere.
    var isRepresentableInJSON: Bool {
        switch self {
        case .double(let value): value.isFinite
        case .array(let values): values.allSatisfy(\.isRepresentableInJSON)
        case .object(let values): values.values.allSatisfy(\.isRepresentableInJSON)
        case .null, .bool, .int, .string: true
        }
    }

    /// Converts any `Encodable` value (a plugin's config or settings struct).
    init<T: Encodable>(encoding value: T) throws {
        let data = try JSONEncoder().encode(value)
        self = try JSONDecoder().decode(JSONValue.self, from: data)
    }

    /// Decodes a typed value back out.
    func decode<T: Decodable>(_ type: T.Type = T.self) throws -> T {
        let data = try JSONEncoder().encode(self)
        return try JSONDecoder().decode(T.self, from: data)
    }

    /// Deep merge: keys in `self` win; objects merge recursively; anything
    /// else in `self` replaces `base` wholesale. This is how stored settings
    /// are laid over defaults, so a key added in a later build gets its
    /// default instead of failing to decode.
    func merged(over base: JSONValue) -> JSONValue {
        guard case .object(let top) = self, case .object(var result) = base else { return self }
        for (key, value) in top {
            result[key] = result[key].map { value.merged(over: $0) } ?? value
        }
        return .object(result)
    }

    /// Stable, human-readable encoding for files core writes.
    func encodedData(pretty: Bool = true) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = pretty ? [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes] : [.sortedKeys]
        return try encoder.encode(self)
    }
}
