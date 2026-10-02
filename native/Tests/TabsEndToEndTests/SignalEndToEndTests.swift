import Foundation
import TabsPluginSDK
import Testing

/// Pane signals in the running app (docs/PANE-SIGNALS.md): a terminal's bell,
/// raised by a real shell across the real plugin bundle boundary, and core's
/// own cues, drawn by the real chrome, read back over the control socket
/// (`tabs.test.signals`).
extension LaunchedApp {
    func signals() async throws -> JSONValue { try await call("tabs.test.signals") }

    /// Polls `tabs.test.signals` until `condition` holds (or 5s pass); returns the last report.
    func signals(until condition: (JSONValue) -> Bool) async throws -> JSONValue {
        var report = try await signals()
        for _ in 0..<100 where !condition(report) {
            try await Task.sleep(for: .milliseconds(50))
            report = try await signals()
        }
        return report
    }
}

@Suite(.serialized, .sharedApp, .timeLimit(.minutes(2))) struct SignalEndToEndTests {
    /// The first window's tab (id and report) holding `pane`.
    private func tab(holding pane: String, in report: JSONValue) -> (id: String, entry: JSONValue)? {
        guard case .object(let tabs)? = report["windows"]?[0]?["tabs"] else { return nil }
        return tabs.sorted { $0.key < $1.key }.first { _, entry in
            if case .array(let leaves)? = entry["leaves"] { return leaves.contains(.string(pane)) && leaves.count == 1 }
            return false
        }.map { ($0.key, $0.value) }
    }

    @Test func aShellsBellInABackgroundTabRaisesItsSignalAndLookingClearsIt() async throws {
        let app = try await SharedApp.fresh()
        let (terminal, _) = try await app.newTerminal()
        // The shell rings after two seconds; by then it is in the background.
        try await app.call("tabs.test.type", ["text": "sleep 2; printf '\\a'\n"])
        #expect(try await app.call("tabs.test.press", ["key": "t", "modifiers": ["command"]]) == true)
        #expect(try await app.activePane() != terminal)

        let rang = try await app.signals { $0["raised"]?[terminal] == ["terminal.bell"] }
        #expect(rang["raised"]?[terminal] == ["terminal.bell"], "the bell rang in a pane nobody is looking at: \(rang)")
        let tab = try #require(tab(holding: terminal, in: rang), "\(rang)")
        #expect(tab.entry["signals"] == ["terminal.bell"], "its background tab shows the bell")
        #expect(rang["windows"]?[0]?["panes"]?[terminal] == nil, "its header isn't on screen")

        try await app.call("tabs.test.click", ["identifier": .string("tab-\(tab.id)")])
        #expect(try await app.activePane() == terminal)
        let seen = try await app.signals()
        #expect(seen["raised"]?[terminal] == nil, "looking at it cleared it: \(seen)")
        #expect(seen["windows"]?[0]?["panes"]?[terminal]?["header"] == [])
        #expect(self.tab(holding: terminal, in: seen)?.entry["signals"] == [])
    }

    @Test func aStatusShowsInTheVisiblePanesHeaderAndOutlineButNeverOnItsTab() async throws {
        let app = try await SharedApp.fresh()
        let pane = try await app.activePane()
        #expect(try await app.call("tabs.test.signal", ["paneId": .string(pane), "kind": "controlled"]) == true)
        let report = try await app.signals()
        #expect(report["windows"]?[0]?["panes"]?[pane]?["header"] == ["controlled"])
        #expect(report["windows"]?[0]?["panes"]?[pane]?["outline"] == "controlled", "the status replaces the active pane's accent")
        #expect(tab(holding: pane, in: report)?.entry["signals"] == [], "a status never marks its tab")
        try await app.call("tabs.test.signal", ["paneId": .string(pane), "kind": "controlled", "withdraw": true])
        #expect(try await app.signals()["raised"]?[pane] == nil)
    }

    @Test func aBellInTheLookedAtPaneIsDroppedAndOthersBounceTheDockOnce() async throws {
        let app = try await SharedApp.fresh()
        let pane = try await app.activePane()
        try await app.call("tabs.test.focus", ["focused": true])
        #expect(try await app.call("tabs.test.signal", ["paneId": .string(pane), "kind": "bell"]) == false, "looked at: dropped")
        try await app.call("tabs.test.focus", ["focused": false])
        #expect(try await app.call("tabs.test.signal", ["paneId": .string(pane), "kind": "bell"]) == true)
        let report = try await app.signals()
        #expect(report["raised"]?[pane] == ["bell"])
        #expect(report["attentionRequests"] == 1, "only while unfocused")
        try await app.call("tabs.test.focus", ["focused": true])
        #expect(try await app.signals()["raised"]?[pane] == nil, "coming back to the window is looking at its active pane")
    }
}
