import Foundation
import TabsPluginSDK
import Testing

@testable import TabsCore

@Suite struct ManifestTests {
    @Test func decodesAllFieldsFromInfoPlist() throws {
        let manifest = try PluginManifest(infoDictionary: [
            "TabsPlugin": [
                "id": "alpha", "displayName": "Alpha", "summary": "s",
                "contentTypes": ["alpha"], "canDisable": false, "sortOrder": 5,
            ]
        ])
        #expect(
            manifest
                == PluginManifest(
                    id: "alpha", displayName: "Alpha", summary: "s",
                    contentTypes: ["alpha"], canDisable: false, sortOrder: 5
                ))
        #expect(manifest.problems().isEmpty)
    }

    @Test func optionalFieldsDefault() throws {
        let manifest = try PluginManifest(infoDictionary: ["TabsPlugin": ["id": "x", "displayName": "X"]])
        #expect(manifest.contentTypes.isEmpty)
        #expect(manifest.canDisable)
        #expect(manifest.sortOrder == 100)
    }

    @Test func missingManifestIsItsOwnError() {
        #expect(throws: ManifestError.missing) { try PluginManifest(infoDictionary: ["CFBundleName": "x"]) }
    }

    @Test func missingRequiredKeyIsNamed() {
        #expect(throws: ManifestError.malformed("missing key \"displayName\"")) {
            try PluginManifest(infoDictionary: ["TabsPlugin": ["id": "x"]])
        }
    }

    @Test func wrongTypeIsMalformed() {
        #expect(throws: ManifestError.self) {
            try PluginManifest(infoDictionary: ["TabsPlugin": ["id": "x", "displayName": "X", "contentTypes": "alpha"]])
        }
    }

    @Test(arguments: [
        ("Alpha", "must be lowercase"),
        ("tabs", "reserved"),
        ("9lives", "must be lowercase"),
    ])
    func rejectsBadIDs(id: String, problem: String) {
        let problems = PluginManifest(id: PluginID(id), displayName: "X").problems()
        #expect(problems.contains { $0.contains(problem) })
    }

    @Test func flagsEmptyNamesAndBadOrDuplicateTypes() {
        let problems = PluginManifest(id: "a", displayName: " ", contentTypes: ["a.t", "a.t", "bad name", "b"]).problems()
        #expect(
            problems == [
                "displayName is empty", "content type \"bad name\" is not a valid name",
                "content type \"b\" must be \"a\" or start with \"a.\"",
                "contentTypes lists a type twice",
            ])
    }
}
