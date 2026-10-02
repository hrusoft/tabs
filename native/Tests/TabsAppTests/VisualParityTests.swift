import AppKit
import Foundation
import TabsPluginSDK
import Testing

@testable import Tabs
@testable import TabsCore

/// The chrome against the Electron app's: every scenario in `native/Visual/`
/// rendered by the real engine and renderer, its geometry — every pane, bar,
/// tab, title, control, separator, floating pane and drag preview — within
/// half a point of what the Electron renderer laid out (`Visual/golden/`,
/// captured by `Visual/capture-electron.mjs`; `make visual` compares the pixels).
@MainActor
@Suite(.serialized) struct VisualParityTests {
    nonisolated static let visual = URL(filePath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appending(path: "Visual", directoryHint: .isDirectory)

    nonisolated static var scenarios: [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: visual.appending(path: "scenarios").path)) ?? [])
            .filter { $0.hasSuffix(".json") }
            .map { String($0.dropLast(".json".count)) }
            .sorted()
    }

    @Test func everyScenarioHasAGolden() {
        #expect(!Self.scenarios.isEmpty)
        for name in Self.scenarios {
            #expect(
                FileManager.default.fileExists(atPath: Self.visual.appending(path: "golden/\(name).geometry.json").path),
                "\(name): capture it with Visual/capture-electron.mjs and copy it to Visual/golden")
        }
    }

    @Test(arguments: VisualParityTests.scenarios)
    func theGeometryIsTheElectronApps(_ name: String) async throws {
        let scenario = try VisualCapture.decodeScenario(Data(contentsOf: Self.visual.appending(path: "scenarios/\(name).json")))
        // Dates show in UTC, as both captures pin them.
        let zone = ProcessInfo.processInfo.environment["TZ"]
        setenv("TZ", "UTC", 1)
        NSTimeZone.resetSystemTimeZone()
        defer {
            if let zone { setenv("TZ", zone, 1) } else { unsetenv("TZ") }
            NSTimeZone.resetSystemTimeZone()
        }
        let golden = try JSONDecoder().decode(
            JSONValue.self, from: Data(contentsOf: Self.visual.appending(path: "golden/\(name).geometry.json")))
        let staged = try await VisualCapture.stage(scenario)
        defer { staged.tearDown() }
        let differences = GeometryDifferences(golden: golden, native: try await staged.geometryWithContent(), tolerance: 0.5).lines
        #expect(differences.isEmpty, Comment(rawValue: "\(name):\n" + differences.joined(separator: "\n")))
    }
}

/// `compare.py`'s geometry report: both dumps flattened to leaf paths; a rect
/// differs when any edge moved by more than the tolerance.
struct GeometryDifferences {
    let lines: [String]

    init(golden: JSONValue, native: JSONValue, tolerance: Double) {
        let expected = Self.flatten(golden).filter { $0.key != "scenario" }
        let actual = Self.flatten(native).filter { $0.key != "scenario" }
        var lines: [String] = []
        for key in Set(expected.keys).union(actual.keys).sorted() {
            guard let e = expected[key] else {
                lines.append("extra on native: \(key)")
                continue
            }
            guard let n = actual[key] else {
                lines.append("missing on native: \(key)")
                continue
            }
            if let er = Self.rect(e), let nr = Self.rect(n) {
                let deltas = [nr[0] - er[0], nr[1] - er[1], nr[0] + nr[2] - er[0] - er[2], nr[1] + nr[3] - er[1] - er[3]]
                if deltas.contains(where: { abs($0) > tolerance }) { lines.append("rect \(key): electron \(er) native \(nr)") }
            } else if let ev = Self.number(e), let nv = Self.number(n) {
                if abs(ev - nv) > tolerance { lines.append("value \(key): electron \(ev) native \(nv)") }
            } else if e != n {
                lines.append("value \(key): electron \(e) native \(n)")
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
