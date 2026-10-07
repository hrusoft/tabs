import Foundation
import TabsPluginSDK
import Testing

@testable import TabsCore

@Suite struct JSONValueTests {
    struct Sample: Codable, Equatable {
        var name: String
        var size: Double
        var tags: [String]
    }

    @Test func roundTripsTypedValues() throws {
        let sample = Sample(name: "a", size: 2.5, tags: ["x"])
        let json = try JSONValue(encoding: sample)
        #expect(json == ["name": "a", "size": 2.5, "tags": ["x"]])
        #expect(try json.decode(Sample.self) == sample)
    }

    @Test func mergeKeepsTopAndFillsFromBase() {
        let base: JSONValue = ["a": 1, "nested": ["x": 1, "y": 2], "keep": true]
        let top: JSONValue = ["a": 9, "nested": ["y": 3], "extra": "e"]
        #expect(top.merged(over: base) == ["a": 9, "nested": ["x": 1, "y": 3], "keep": true, "extra": "e"])
    }

    @Test func boolsAndNumbersStayDistinct() throws {
        let decoded = try JSONDecoder().decode(JSONValue.self, from: Data(#"[true, 1, 0, "1", null]"#.utf8))
        #expect(decoded == [true, 1, 0, "1", nil])
    }
}

@Suite struct JSONNumberTests {
    @Test func sixtyFourBitIntegersSurviveExactly() throws {
        let data = Data(#"{"ns": 1727200000123456789, "neg": -9223372036854775808, "big": 18446744073709551615}"#.utf8)
        let value = try JSONDecoder().decode(JSONValue.self, from: data)
        #expect(value["ns"] == .int(1_727_200_000_123_456_789))
        #expect(value["neg"] == .int(.min))
        #expect(value["big"]?.intValue == nil, "beyond Int64: a double")
        struct Stamp: Codable, Equatable { var ns: Int64 }
        #expect(try JSONValue(encoding: Stamp(ns: 1_727_200_000_123_456_789)).decode(Stamp.self) == Stamp(ns: 1_727_200_000_123_456_789))
    }

    @Test func nonFiniteNumbersAreDetectedAnywhere() {
        #expect(JSONValue.object(["a": [1, 2.5, "x"]]).isRepresentableInJSON)
        #expect(!JSONValue.object(["a": [1, .double(.nan)]]).isRepresentableInJSON)
        #expect(!JSONValue.array([.object(["b": .double(.infinity)])]).isRepresentableInJSON)
        #expect(throws: (any Error).self) { try JSONValue.double(.nan).encodedData() }
    }

    @Test func accessorsBridgeTheTwoNumberCases() {
        #expect(JSONValue.double(3).intValue == 3)
        #expect(JSONValue.double(3.5).intValue == nil)
        #expect(JSONValue.int(7).doubleValue == 7)
    }
}
