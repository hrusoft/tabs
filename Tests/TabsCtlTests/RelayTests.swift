import Foundation
import Testing

/// `tabs-ctl`'s rules (Relay.swift), compiled into this bundle: argv into flags, the request
/// line, the exit code. The relay against a running app: ControlPlaneEndToEndTests.
@Suite struct RelayTests {
    @Test func aFlagTakesTheNextWordUnlessThatIsAFlagToo() {
        #expect(Relay.flags(["--pane", "p1", "--wait"]) == ["pane": .text("p1"), "wait": .present])
        #expect(Relay.flags(["--wait", "--pane", "p1"]) == ["wait": .present, "pane": .text("p1")])
        #expect(Relay.flags(["--last"]) == ["last": .present])
    }

    @Test func equalsPassesAValueThatLooksLikeAFlag() {
        #expect(Relay.flags(["--text=--help"]) == ["text": .text("--help")])
        #expect(Relay.flags(["--text="]) == ["text": .text("")])
        #expect(Relay.flags(["--url=a=b"]) == ["url": .text("a=b")])
    }

    @Test func strayWordsAreIgnoredAndALaterFlagWins() {
        #expect(Relay.flags(["stray", "--pane", "a", "loose", "--pane", "b"]) == ["pane": .text("b")])
        #expect(Relay.flags([]).isEmpty)
    }

    @Test func aValueKeepsWhateverItHolds() {
        #expect(Relay.flags(["--code", "-1"]) == ["code": .text("-1")])
        #expect(Relay.flags(["--text", "🙂 é\nline"]) == ["text": .text("🙂 é\nline")])
    }

    @Test func theRequestIsTheCommandItsFlagsThePaneAndTheDirectory() throws {
        let data = try Relay.envelope(
            command: "navigate", flags: ["url": .text("https://example.com/a"), "wait": .present], paneId: "p1", cwd: "/tmp/x")
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["command"] as? String == "navigate")
        #expect(object["paneId"] as? String == "p1")
        #expect(object["cwd"] as? String == "/tmp/x")
        let args = try #require(object["args"] as? [String: Any])
        #expect(args["url"] as? String == "https://example.com/a")
        #expect(args["wait"] as? Bool == true)
        #expect(!data.contains(UInt8(ascii: "\n")), "one line on the wire")
        #expect(String(decoding: data, as: UTF8.self).contains("https://example.com/a"), "slashes unescaped")
    }

    @Test func onlyAnOkAnswerWithNothingFailedInsideExitsZero() throws {
        func code(_ json: String) throws -> Int32 {
            Relay.exitCode(for: try JSONSerialization.jsonObject(with: Data(json.utf8), options: [.fragmentsAllowed]))
        }
        #expect(try code(#"{"ok":true}"#) == 0)
        #expect(try code(#"{"ok":true,"result":{"panes":[]}}"#) == 0)
        #expect(try code(#"{"ok":false,"error":"no"}"#) == 1)
        #expect(try code(#"{"ok":1}"#) == 1, "true, not a number")
        #expect(try code(#""ok""#) == 1)
        // A batch that ran is ok: true; a failed step still fails the exit code, skipped ones after it too.
        #expect(try code(#"{"ok":true,"result":{"steps":[{"type":"ping","ok":true}]}}"#) == 0)
        #expect(try code(#"{"ok":true,"result":{"steps":[{"ok":true},{"ok":false},{"skipped":true}]}}"#) == 1)
        // Per-part failures (form-input's errors) fail it only when there are some.
        #expect(try code(#"{"ok":true,"result":{"errors":[]}}"#) == 0)
        #expect(try code(#"{"ok":true,"result":{"errors":[{"index":0,"error":"x"}]}}"#) == 1)
    }

    @Test func theAnswerIsTheFirstLineOrAllOfItWithoutOne() {
        #expect(Relay.firstLine(Data("{\"ok\":true}\n{\"later\":1}\n".utf8)) == Data("{\"ok\":true}".utf8))
        #expect(Relay.firstLine(Data("{\"ok\":true}".utf8)) == Data("{\"ok\":true}".utf8))
        #expect(Relay.firstLine(Data()).isEmpty)
    }

    @Test func aFailureIsOneLineOfJSON() throws {
        let data = Relay.failure("could not reach Tabs: \"x\" / y")
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["ok"] as? Bool == false)
        #expect(object["error"] as? String == "could not reach Tabs: \"x\" / y")
        #expect(!data.contains(UInt8(ascii: "\n")))
    }
}
