import Foundation
import TabsPluginSDK
import Testing

@testable import TabsCore

/// The JSON Schema evaluator, messages included, and the wire schemas derived
/// from verbs' arguments.
@MainActor
@Suite struct ControlSchemaTests {
    private func check(_ value: JSONValue, _ schema: JSONValue, path: String = "request") -> String? {
        ControlSchema.validate(value, against: schema, path: path)
    }

    // MARK: The evaluator

    @Test func aConstMustMatchExactly() {
        #expect(check("click", ["const": "navigate"]) == "request must be \"navigate\" (got \"click\")")
        #expect(check("navigate", ["const": "navigate"]) == nil)
    }

    @Test func anEnumNamesItsChoices() {
        #expect(check("sideways", ["enum": ["up", "down"]]) == "request must be one of up, down (got \"sideways\")")
        #expect(check("up", ["enum": ["up", "down"]]) == nil)
        #expect(check(3, ["enum": ["up", "down"]]) == "request must be one of up, down (got 3)")
    }

    @Test func aTypeIsJSONsOwnVocabulary() {
        #expect(check("x", ["type": "number"]) == "request must be a number (got string)")
        #expect(check([1], ["type": "object"]) == "request must be a object (got array)")
        #expect(check(nil, ["type": "object"]) == "request must be a object (got null)")
        #expect(check(true, ["type": "string"]) == "request must be a string (got boolean)")
        #expect(check(2.5, ["type": "number"]) == nil)
        #expect(check(.array([]), ["type": "array"]) == nil)
    }

    @Test func anIntegerIsANumberWithNoFraction() {
        #expect(check(3, ["type": "integer"]) == nil)
        #expect(check(.double(3.0), ["type": "integer"]) == nil)
        #expect(check(2.5, ["type": "integer"]) == "request must be an integer (got 2.5)")
        #expect(check("3", ["type": "integer"]) == "request must be an integer (got string)")
    }

    @Test func aMinimumRefusesBelowIt() {
        #expect(check(0, ["type": "number", "minimum": 1]) == "request must be at least 1 (got 0)")
        #expect(check(.double(0.5), ["type": "number", "minimum": 1]) == "request must be at least 1 (got 0.5)")
        #expect(check(1, ["type": "number", "minimum": 1]) == nil)
    }

    @Test func anObjectNamesTheFieldItIsMissingOrDoesNotExpect() {
        let schema: JSONValue = [
            "type": "object", "properties": ["url": ["type": "string"]], "required": ["url"], "additionalProperties": false,
        ]
        #expect(check([:], schema) == "request is missing required field \"url\"")
        #expect(check(["url": "x", "extra": 1], schema) == "request has an unexpected field \"extra\"")
        #expect(check(["url": "x"], schema) == nil)
        #expect(check(["url": 5], schema) == "request.url must be a string (got number)")
    }

    @Test func aNullFieldIsPresentButIsNotAString() {
        let schema: JSONValue = ["type": "object", "properties": ["url": ["type": "string"]], "required": ["url"]]
        #expect(check(["url": nil], schema) == "request.url must be a string (got null)")
    }

    @Test func nestedPathsNameTheFieldsAndIndexes() {
        let schema: JSONValue = [
            "type": "object",
            "properties": ["items": ["type": "array", "items": ["type": "object", "properties": ["n": ["type": "number"]]]]],
        ]
        #expect(check(["items": [["n": 1], ["n": "two"]]], schema) == "request.items[1].n must be a number (got string)")
    }

    @Test func oneOfWantsExactlyOneShape() {
        let schema: JSONValue = ["oneOf": [["type": "string"], ["type": "number"]]]
        #expect(check(true, schema) == "request must match exactly one of its allowed shapes (matched 0)")
        #expect(check("a", schema) == nil)
        let both: JSONValue = ["oneOf": [["type": "number"], ["minimum": 0]]]
        #expect(check(1, both) == "request must match exactly one of its allowed shapes (matched 2)")
    }

    @Test func anyOfWantsAtLeastOneShape() {
        let schema: JSONValue = ["anyOf": [["type": "object", "required": ["a"]], ["type": "object", "required": ["b"]]]]
        #expect(check([:], schema) == "request must match at least one of its allowed shapes")
        #expect(check(["b": 1], schema) == nil)
    }

    @Test func aSchemaThatIsNotAnObjectAllowsAnything() {
        #expect(check(1, "nonsense") == nil)
        #expect(check(1, [:]) == nil)
    }

    @Test func theChecksRunInAFixedOrder() {
        // const before enum before type before bounds before shape.
        #expect(check("x", ["const": "y", "type": "number"]) == "request must be \"y\" (got \"x\")")
        #expect(check("x", ["enum": ["y"], "type": "number"]) == "request must be one of y (got \"x\")")
    }

    // MARK: The element target

    @Test func anElementTargetIsARefACoordinateOrASemanticMatch() {
        let schema = ControlSchema.elementTarget
        #expect(check(["ref": "e1"], schema) == nil)
        #expect(check(["x": 1, "y": 2], schema) == nil)
        #expect(check(["role": "button"], schema) == nil)
        #expect(check(["role": "button", "name": "Save", "nth": 1], schema) == nil)
        #expect(check(["selector": "a"], schema) == nil)
        #expect(check(["x": 1], schema) != nil, "a coordinate needs both axes")
        #expect(check(["nth": 1], schema) != nil, "nth alone matches nothing")
        #expect(check(["ref": "e1", "role": "button"], schema) != nil, "the forms don't mix")
        #expect(check([:], schema) != nil)
    }

    // MARK: Deriving a verb's wire schema

    private func verb(
        _ arguments: [ControlArgument], target: ControlTarget = .ownedPane(ofTypes: ["web"]), composition: ControlFlagComposition? = nil
    ) -> ControlVerbContribution {
        ControlVerbContribution(
            name: "web.probe", summary: "probe", arguments: arguments, target: target, command: "probe", wireType: "probeIt",
            composition: composition
        ) { _ in nil }
    }

    @Test func aVerbsSchemaIsItsArgumentsAndNothingElse() {
        let schema = ControlSchema.wire(
            for: verb([
                ControlArgument("url", .string, required: true), ControlArgument("count", .integer, minimum: 1),
                ControlArgument("ratio", .number), ControlArgument("on", .bool), ControlArgument("out", .path),
                ControlArgument("tags", .csv), ControlArgument("blob", .json), ControlArgument("mode", .string, enumValues: ["a", "b"]),
            ]))
        #expect(
            schema == [
                "type": "object",
                "properties": [
                    "type": ["const": "probeIt"], "targetPaneId": ["type": "string"], "url": ["type": "string"],
                    "count": ["type": "integer", "minimum": 1], "ratio": ["type": "number"], "on": ["type": "boolean"], "out": [:],
                    "tags": ["type": "array", "items": ["type": "string"]], "blob": [:], "mode": ["enum": ["a", "b"]],
                ],
                "required": ["type", "targetPaneId", "url"], "additionalProperties": false,
            ])
    }

    @Test func aVerbWithNoTargetHasNoTargetPaneId() {
        let schema = ControlSchema.wire(for: verb([], target: .none))
        #expect(schema["properties"]?["targetPaneId"] == nil)
        #expect(schema["required"] == ["type"])
    }

    @Test func anElementTargetCompositionAddsARequiredTargetProperty() {
        let schema = ControlSchema.wire(for: verb([ControlArgument("text", .string, required: true)], composition: .elementTarget))
        #expect(schema["properties"]?["target"] == ControlSchema.elementTarget)
        #expect(schema["required"] == ["type", "targetPaneId", "target", "text"])
    }

    @Test func anArgumentsOwnSchemaWins() {
        let schema = ControlSchema.wire(
            for: verb([ControlArgument("modifiers", .csv, schema: ["type": "array", "items": ["enum": ["shift", "meta"]]])]))
        #expect(schema["properties"]?["modifiers"] == ["type": "array", "items": ["enum": ["shift", "meta"]]])
    }

    @Test func aWireRequestIsCheckedAgainstItsDerivedSchema() {
        let schema = ControlSchema.wire(for: verb([ControlArgument("url", .string, required: true)]))
        #expect(check(["type": "probeIt", "targetPaneId": "p", "url": "x"], schema) == nil)
        #expect(check(["type": "probeIt", "targetPaneId": "p"], schema) == "request is missing required field \"url\"")
        #expect(check(["type": "probeIt", "targetPaneId": "p", "url": "x", "wat": 1], schema) == "request has an unexpected field \"wat\"")
        #expect(check(["type": "other", "targetPaneId": "p", "url": "x"], schema) == "request.type must be \"probeIt\" (got \"other\")")
    }
}
