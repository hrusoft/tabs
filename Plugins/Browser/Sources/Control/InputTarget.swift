import Foundation
import TabsPluginSDK

/// The wire form of an element target (`ElementTarget`) and what an input verb reports back about
/// an element. Core has already checked the request against the verb's schema (a ref, a coordinate
/// or a semantic match: exactly one form, blank criteria and all), so what is parsed here is
/// well-shaped; what the schema can't say (a blank criterion, a negative or fractional `nth`) is
/// left for `Targeting.semanticTargetError`, which words it.
enum InputTarget {
    /// The `target` wire field as the target it names. A wire value that is none of the three
    /// forms (a request that skipped the schema) is refused as such.
    static func parse(_ value: JSONValue?) -> Result<ElementTarget, VerbFailure> {
        guard case .object(let fields)? = value else {
            return .failure(VerbFailure("a target is a ref, a coordinate (x and y) or a semantic match (role, name, selector)"))
        }
        if let ref = fields["ref"]?.stringValue { return .success(.ref(ref)) }
        if let x = fields["x"]?.doubleValue, let y = fields["y"]?.doubleValue { return .success(.point(x: x, y: y)) }
        var semantic = SemanticTarget(
            role: fields["role"]?.stringValue, name: fields["name"]?.stringValue, selector: fields["selector"]?.stringValue)
        if let raw = fields["nth"] {
            // `nth` is a number on the wire, so 1.5 arrives; the model holds an integer. What is not
            // a whole number of matches reads as a negative one, which `semanticTargetError`
            // refuses in the same words: "a non-negative integer".
            semantic.nth = raw.intValue.map { Int($0) } ?? -1
        }
        guard semantic.role != nil || semantic.name != nil || semantic.selector != nil else {
            return .failure(VerbFailure("a semantic target needs at least one of role, name, selector"))
        }
        return .success(.semantic(semantic))
    }

    /// `{role, name, tag}` from an element description a guest script answered, or nil for none.
    static func description(of value: JSONValue?) -> ElementDescription? {
        guard case .object(let fields)? = value else { return nil }
        return ElementDescription(
            role: fields["role"]?.stringValue ?? "", name: fields["name"]?.stringValue ?? "", tag: fields["tag"]?.stringValue ?? "")
    }

    /// An element description as a result reports it.
    static func json(_ element: ElementDescription) -> JSONValue {
        .object(["role": .string(element.role), "name": .string(element.name), "tag": .string(element.tag)])
    }

    /// A coordinate as JSON reads it: `50`, never `50.0`.
    static func json(_ number: Double) -> JSONValue {
        Int64(exactly: number).map(JSONValue.int) ?? .double(number)
    }
}
