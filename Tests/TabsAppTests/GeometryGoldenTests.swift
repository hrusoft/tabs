import AppKit
import Foundation
import TabsPluginSDK
import Testing

@testable import Tabs
@testable import TabsCore

/// The chrome held in place: every scenario — core's in `Visual/`, each
/// plugin's in `Plugins/<Name>/Visual/` — rendered by the real engine and
/// renderer, its geometry (every pane, bar, tab, title, control, separator,
/// floating pane and drag preview, and what plugins report of their panes)
/// within half a point of its golden (`golden/` beside `scenarios/`, recorded
/// from the app by `make visual-golden`; `make visual` compares the pixels with
/// a baseline capture).
@MainActor
@Suite(.serialized) struct GeometryGoldenTests {
    /// The repository, from this file's own path.
    nonisolated static let root = URL(filePath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    /// Every folder of scenarios and their goldens: `Visual`, and each plugin's `Plugins/<Name>/Visual`.
    nonisolated static var visualFolders: [URL] {
        let plugins =
            (try? FileManager.default.contentsOfDirectory(at: root.appending(path: "Plugins"), includingPropertiesForKeys: nil)) ?? []
        return ([root.appending(path: "Visual")] + plugins.sorted { $0.path < $1.path }.map { $0.appending(path: "Visual") })
            .filter { FileManager.default.fileExists(atPath: $0.appending(path: "scenarios").path) }
    }

    /// Every scenario's name and the folder holding it, in folder order.
    nonisolated static var found: [(name: String, folder: URL)] {
        visualFolders.flatMap { folder in
            ((try? FileManager.default.contentsOfDirectory(atPath: folder.appending(path: "scenarios").path)) ?? [])
                .filter { $0.hasSuffix(".json") }
                .map { (name: String($0.dropLast(".json".count)), folder: folder) }
        }
    }

    nonisolated static var scenarios: [String] { found.map(\.name).sorted() }

    nonisolated static func folder(of name: String) throws -> URL {
        try #require(found.first { $0.name == name }?.folder, "no scenario \(name)")
    }

    @Test func everyScenarioHasAGolden() throws {
        #expect(!Self.scenarios.isEmpty)
        for name in Self.scenarios {
            #expect(
                FileManager.default.fileExists(atPath: try Self.folder(of: name).appending(path: "golden/\(name).geometry.json").path),
                "\(name): record it with `make visual-golden`")
        }
    }

    /// Captures and goldens are keyed by name, wherever the scenario lives.
    @Test func noTwoScenariosShareAName() {
        #expect(Set(Self.scenarios).count == Self.scenarios.count, "\(Self.found.map { "\($0.folder.path)/\($0.name)" })")
    }

    @Test(arguments: GeometryGoldenTests.scenarios)
    func theGeometryMatchesTheGolden(_ name: String) async throws {
        let folder = try Self.folder(of: name)
        let scenario = try VisualCapture.decodeScenario(Data(contentsOf: folder.appending(path: "scenarios/\(name).json")))
        // Dates show in UTC, as `make visual-golden` records them.
        let zone = ProcessInfo.processInfo.environment["TZ"]
        setenv("TZ", "UTC", 1)
        NSTimeZone.resetSystemTimeZone()
        defer {
            if let zone { setenv("TZ", zone, 1) } else { unsetenv("TZ") }
            NSTimeZone.resetSystemTimeZone()
        }
        let golden = try JSONDecoder().decode(
            JSONValue.self, from: Data(contentsOf: folder.appending(path: "golden/\(name).geometry.json")))
        let staged = try await VisualCapture.stage(scenario)
        defer { staged.tearDown() }
        defer { TestSupport.discardWebData(of: staged.runtime) }
        let differences = GeometryDifferences(golden: golden, actual: try await staged.geometryWithContent(), tolerance: 0.5).lines
        #expect(differences.isEmpty, Comment(rawValue: "\(name):\n" + differences.joined(separator: "\n")))
    }
}

/// `compare.py`'s geometry report: both dumps flattened to leaf paths; a rect
/// differs when any edge moved by more than the tolerance.
struct GeometryDifferences {
    let lines: [String]

    init(golden: JSONValue, actual dump: JSONValue, tolerance: Double) {
        let expected = Self.flatten(golden)
        let actual = Self.flatten(dump)
        var lines: [String] = []
        for key in Set(expected.keys).union(actual.keys).sorted() {
            guard let e = expected[key] else {
                lines.append("not in the golden: \(key)")
                continue
            }
            guard let n = actual[key] else {
                lines.append("missing: \(key)")
                continue
            }
            if let er = Self.rect(e), let nr = Self.rect(n) {
                let deltas = [nr[0] - er[0], nr[1] - er[1], nr[0] + nr[2] - er[0] - er[2], nr[1] + nr[3] - er[1] - er[3]]
                if deltas.contains(where: { abs($0) > tolerance }) { lines.append("rect \(key): golden \(er), now \(nr)") }
            } else if let ev = Self.number(e), let nv = Self.number(n) {
                if abs(ev - nv) > tolerance { lines.append("value \(key): golden \(ev), now \(nv)") }
            } else if e != n {
                lines.append("value \(key): golden \(e), now \(n)")
            }
        }
        self.lines = lines
    }

    private static func number(_ value: JSONValue) -> Double? {
        if case .bool = value { return nil }
        return value.doubleValue
    }

    private static func rect(_ value: JSONValue) -> [Double]? {
        guard case .array(let items) = value, items.count == 4 else { return nil }
        let numbers = items.compactMap(number)
        return numbers.count == 4 ? numbers : nil
    }

    static func flatten(_ value: JSONValue, _ prefix: String = "") -> [String: JSONValue] {
        switch value {
        case .object(let fields):
            var out: [String: JSONValue] = [:]
            for (key, child) in fields { out.merge(flatten(child, prefix.isEmpty ? key : "\(prefix).\(key)")) { $1 } }
            return out
        case .array(let items) where rect(value) == nil:
            if items.isEmpty { return [prefix: value] }
            var out: [String: JSONValue] = [:]
            for (index, child) in items.enumerated() { out.merge(flatten(child, "\(prefix)[\(index)]")) { $1 } }
            return out
        default:
            return [prefix: value]
        }
    }
}
