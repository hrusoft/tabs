import AppKit
import Foundation
import TabsPluginSDK
import Testing

@testable import Tabs
@testable import TabsCore

/// A throwaway repository on disk, built with the user's git under a fixed
/// identity and a scratch HOME (so global config can't interfere), like the
/// Electron tier's `e2e/helpers/gitRepo.ts`.
struct ScratchRepo {
    let path: String

    init(commits: [String] = ["first", "second"]) throws {
        let base = FileManager.default.temporaryDirectory.appending(path: "tabs-git-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: base, withIntermediateDirectories: true)
        // The real path: the tree reports `rev-parse --show-toplevel`'s answer.
        path =
            realpath(base, nil).map { pointer in
                defer { free(pointer) }
                return String(cString: pointer)
            } ?? base
        try git("init", "-q", "-b", "main")
        for (index, subject) in commits.enumerated() {
            try "\(index)\n".write(toFile: "\(path)/file\(index).txt", atomically: true, encoding: .utf8)
            try git("add", ".")
            try git("commit", "-q", "-m", subject)
        }
    }

    @discardableResult
    func git(_ args: String...) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git"] + args
        process.currentDirectoryURL = URL(fileURLWithPath: path)
        var environment = ProcessInfo.processInfo.environment
        environment["HOME"] = path
        environment["GIT_CONFIG_NOSYSTEM"] = "1"
        for (key, value) in [
            ("GIT_AUTHOR_NAME", "Ann"), ("GIT_AUTHOR_EMAIL", "ann@example.com"), ("GIT_COMMITTER_NAME", "Ann"),
            ("GIT_COMMITTER_EMAIL", "ann@example.com"),
        ] { environment[key] = value }
        process.environment = environment
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw ScratchRepoError(description: "git \(args.joined(separator: " ")) failed") }
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func remove() { try? FileManager.default.removeItem(atPath: path) }
}

struct ScratchRepoError: Error, CustomStringConvertible { let description: String }

extension UIDriver {
    /// The Debug verb's view of a git tree pane.
    func gitTree(_ pane: PaneID) async throws -> JSONValue { try await call("git-tree.test.state", pane: pane) }

    /// Polls the git tree until `condition` holds; records an issue on timeout.
    @discardableResult
    func gitTree(
        _ pane: PaneID, within seconds: Double = 10, sourceLocation: SourceLocation = #_sourceLocation,
        until condition: (JSONValue) -> Bool
    ) async throws -> JSONValue {
        let deadline = Date().addingTimeInterval(seconds)
        var state = try await gitTree(pane)
        while !condition(state) {
            guard Date() < deadline else {
                Issue.record("timed out; the git tree: \(state)", sourceLocation: sourceLocation)
                return state
            }
            try await Task.sleep(for: .milliseconds(50))
            layoutAll()
            state = try await gitTree(pane)
        }
        return state
    }
}

extension UITests {
    @MainActor
    @Suite struct GitTreeUITests {
        static func one(_ cwd: String) -> SavedLayout {
            Fixture.saved(Fixture.window("w", Fixture.leaf("g", "git-tree", config: ["cwd": .string(cwd)])))
        }

        /// D-1, H-1, B-4, T-1: a pane on a real repository shows its history
        /// newest first, HEAD's branch, and is titled after the repository.
        @Test func aPaneShowsARealRepository() async throws {
            let repo = try ScratchRepo(commits: ["first", "second", "third"])
            defer { repo.remove() }
            let ui = UIDriver(layout: Self.one(repo.path))
            let state = try await ui.gitTree("g") { $0["subjects"] == ["third", "second", "first"] }
            #expect(state["head"] == "main")
            #expect(ui.engine.paneTitle(of: "g") == URL(fileURLWithPath: repo.path).lastPathComponent)
        }

        /// F-1, K-1: ⌘R (View ▸ Refresh) re-reads after a commit lands behind the pane's back.
        @Test func commandRReReadsTheActivePane() async throws {
            let repo = try ScratchRepo()
            defer { repo.remove() }
            let ui = UIDriver(layout: Self.one(repo.path))
            try await ui.gitTree("g") { $0["rows"]?.arrayCount == 2 }
            try "x".write(toFile: "\(repo.path)/late.txt", atomically: true, encoding: .utf8)
            try repo.git("add", ".")
            try repo.git("commit", "-q", "-m", "late")
            #expect(try ui.press(KeyChord("r", [.command])))
            try await ui.gitTree("g") { $0["subjects"]?[0] == "late" }
        }

        /// S-5, P-1: clicking a row selects it and its details follow.
        @Test func clickingARowSelectsIt() async throws {
            let repo = try ScratchRepo(commits: ["first", "second"])
            defer { repo.remove() }
            let ui = UIDriver(layout: Self.one(repo.path))
            let state = try await ui.gitTree("g") { $0["detailHash"] != .null }
            let second = try #require(state["rows"]?[1]?.stringValue)
            let list = try ui.view("git-tree-list")
            try ui.click(at: NSPoint(x: 200, y: 24 * 1.5), in: list)
            try await ui.gitTree("g") { $0["selected"]?.stringValue == second && $0["detailHash"]?.stringValue == second }
            #expect(try await ui.gitTree("g")["listFocused"] == true, "a click gives the list the keyboard")
        }

        /// C-1, C-2: double-clicking a commit with one local branch checks it
        /// out with no prompt, and the pane reads the new HEAD.
        @Test func doubleClickChecksOutTheOneBranch() async throws {
            let repo = try ScratchRepo(commits: ["first", "second"])
            defer { repo.remove() }
            let first = try repo.git("rev-parse", "HEAD~1")
            try repo.git("branch", "old", first)
            let ui = UIDriver(layout: Self.one(repo.path))
            try await ui.gitTree("g") { $0["rows"]?.arrayCount == 2 }
            let list = try ui.view("git-tree-list")
            try ui.click(at: NSPoint(x: 200, y: 24 * 1.5), in: list, count: 2)
            try await ui.gitTree("g") { $0["head"] == "old" }
            #expect(try repo.git("symbolic-ref", "--short", "HEAD") == "old")
        }

        /// X-1: right-clicking a row selects it and opens core's context menu
        /// (Checkout, then Copy SHA-1); Checkout acts on the row right-clicked.
        @Test func rightClickSelectsTheRowAndOffersCheckoutThenCopy() async throws {
            let repo = try ScratchRepo(commits: ["first", "second"])
            defer { repo.remove() }
            let first = try repo.git("rev-parse", "HEAD~1")
            try repo.git("branch", "old", first)
            let ui = UIDriver(layout: Self.one(repo.path))
            let state = try await ui.gitTree("g") { $0["rows"]?.arrayCount == 2 }
            #expect(try #require(state["rows"]?[1]?.stringValue) == first)
            try ui.click(at: NSPoint(x: 200, y: 24 * 1.5), in: try ui.view("git-tree-list"), right: true)
            let deadline = Date().addingTimeInterval(10)
            while ui.contextMenuCount != 2, Date() < deadline {
                try await Task.sleep(for: .milliseconds(50))
                ui.layoutAll()
            }
            #expect(ui.contextMenuCount == 2, "Checkout, Copy SHA-1")
            #expect(try await ui.gitTree("g")["selected"]?.stringValue == first, "the right-click selected its row")
            try ui.chooseContextItem(0)
            try await ui.gitTree("g") { $0["head"] == "old" }
            #expect(ui.contextMenu == nil, "choosing closes the menu")
        }

        /// C-5: a commit no branch points at asks before detaching HEAD, in the
        /// dialog card; Cancel leaves the repository alone, Checkout detaches.
        @Test func doubleClickOnABranchlessCommitAsksBeforeDetaching() async throws {
            let repo = try ScratchRepo(commits: ["first", "second"])
            defer { repo.remove() }
            let ui = UIDriver(layout: Self.one(repo.path))
            ui.renderer.showsDialogCardsUnattended = true
            try await ui.gitTree("g") { $0["rows"]?.arrayCount == 2 }
            let first = try repo.git("rev-parse", "HEAD~1")
            let list = try ui.view("git-tree-list")
            try ui.click(at: NSPoint(x: 200, y: 24 * 1.5), in: list, count: 2)
            let card = try await ui.waitForDialog()
            #expect(card.title == "Checkout")
            #expect(
                card.message == "Checking out \(first.prefix(7)) — first will leave HEAD detached — it won't be on any branch. Continue?")
            #expect(card.buttons.map { $0.accessibilityIdentifier() } == ["dialog-cancel", "dialog-confirm"])
            try ui.pressDialogButton("dialog-cancel")
            #expect(ui.dialog == nil)
            try await Task.sleep(for: .milliseconds(200))
            #expect(try repo.git("symbolic-ref", "--short", "HEAD") == "main")
            // Asked again, and this time agreed to.
            try ui.click(at: NSPoint(x: 200, y: 24 * 1.5), in: list, count: 2)
            _ = try await ui.waitForDialog()
            try ui.pressDialogButton("dialog-confirm")
            try await ui.gitTree("g") { $0["head"]?.stringValue == "detached at \(first.prefix(7))" }
            #expect(try repo.git("rev-parse", "HEAD") == first)
        }

        /// C-4: several branches at the commit ask which one, in the card's select.
        @Test func doubleClickOnSeveralBranchesAsksWhichOne() async throws {
            let repo = try ScratchRepo(commits: ["first", "second"])
            defer { repo.remove() }
            let first = try repo.git("rev-parse", "HEAD~1")
            try repo.git("branch", "old", first)
            try repo.git("branch", "older", first)
            let ui = UIDriver(layout: Self.one(repo.path))
            ui.renderer.showsDialogCardsUnattended = true
            try await ui.gitTree("g") { $0["rows"]?.arrayCount == 2 }
            try ui.click(at: NSPoint(x: 200, y: 24 * 1.5), in: try ui.view("git-tree-list"), count: 2)
            let card = try await ui.waitForDialog()
            #expect(card.message == "Several branches point at \(first.prefix(7)) — first. Which one?")
            #expect(card.options == ["old", "older"])
            #expect(card.selection == 0, "the first, in refname order")
            try ui.chooseDialogOption(1)
            #expect(card.selection == 1)
            try ui.pressDialogButton("dialog-confirm")
            try await ui.gitTree("g") { $0["head"] == "older" }
            #expect(try repo.git("symbolic-ref", "--short", "HEAD") == "older")
        }

        /// C-6: git's own refusal reaches the user in a one-button alert.
        @Test func aRefusedCheckoutIsAnAlertWithGitsWords() async throws {
            let repo = try ScratchRepo(commits: ["first", "second"])
            defer { repo.remove() }
            let first = try repo.git("rev-parse", "HEAD~1")
            try repo.git("branch", "old", first)
            // A local change to a file the switch would remove: git refuses.
            try "changed\n".write(toFile: "\(repo.path)/file1.txt", atomically: true, encoding: .utf8)
            let ui = UIDriver(layout: Self.one(repo.path))
            ui.renderer.showsDialogCardsUnattended = true
            // Rows: the uncommitted changes, second, first.
            try await ui.gitTree("g") { $0["rows"]?.arrayCount == 3 }
            try ui.click(at: NSPoint(x: 200, y: 24 * 2.5), in: try ui.view("git-tree-list"), count: 2)
            let card = try await ui.waitForDialog()
            #expect(card.title == "Checkout failed")
            #expect(card.message.contains("file1.txt"), "git's own text, not a summary")
            #expect(card.buttons.map { $0.accessibilityIdentifier() } == ["dialog-ok"])
            try ui.pressDialogButton("dialog-ok")
            #expect(ui.dialog == nil)
        }

        /// D-2: ⌘P ▸ Git tree ▸ Tab from a terminal opens on the shell's
        /// live directory (the terminal offers it; the git tree asks core).
        @Test func aGitTreeFromATerminalOpensWhereTheShellIs() async throws {
            let repo = try ScratchRepo()
            defer { repo.remove() }
            let ui = UIDriver(layout: Fixture.saved(Fixture.window("w", Fixture.leaf("t", "terminal"))))
            try await ui.shellReady("t")
            try await ui.runAndWait("cd '\(repo.path)'", in: "t")
            // The terminal's offered directory follows the shell.
            let deadline = Date().addingTimeInterval(10)
            while ui.runtime.panes.capability(.workingDirectory, of: "t")?.path != repo.path, Date() < deadline {
                try await Task.sleep(for: .milliseconds(50))
            }
            try ui.createViaPalette("Git tree")
            let pane = try #require(ui.activePane)
            #expect(ui.contentType(of: pane) == "git-tree")
            try await ui.gitTree(pane) { $0["cwd"]?.stringValue == repo.path }
        }

        /// D-6: a terminal made from a git tree starts in its repository.
        @Test func aTerminalFromAGitTreeStartsInItsRepository() async throws {
            let repo = try ScratchRepo()
            defer { repo.remove() }
            let ui = UIDriver(layout: Self.one(repo.path))
            try await ui.gitTree("g") { $0["rows"]?.arrayCount == 2 }
            try ui.createViaPalette("Terminal")
            let pane = try #require(ui.activePane)
            try await ui.shellReady(pane)
            let state = try await ui.runAndWait("pwd", in: pane)
            #expect(state.buffer.contains(repo.path))
        }

        /// T-3, the Electron test "a git tree pane's header controls do not
        /// start a pane drag": the toolbar is the header's title, so a press on
        /// one of its controls activates the pane and never picks it up, and
        /// there is no title to edit.
        @Test func theHeadersControlsDoNotStartAPaneDrag() async throws {
            let repo = try ScratchRepo()
            defer { repo.remove() }
            let ui = UIDriver(
                layout: Fixture.saved(
                    Fixture.window(
                        "w",
                        Fixture.split(
                            "s", .horizontal, [Fixture.leaf("g", "git-tree", config: ["cwd": .string(repo.path)]), Fixture.leaf("e")]),
                        active: "e")))
            try await ui.gitTree("g") { $0["rows"]?.arrayCount == 2 }
            let header = try #require(try ui.paneView("g").header)
            let title = try #require(header.titleView, "the toolbar is the header's title")
            ui.renderer.pickerOverride = { _ in nil }
            let before = try ui.layout.rootNode
            // The path bar is an NSTextField, which takes a press only in a key
            // window (these are never shown): here it is enough that the press
            // lands on it, inside the header.
            let path = try ui.view("git-tree-path-input")
            #expect(path.isDescendant(of: title))
            for identifier in ["git-tree-browse-button", "git-tree-branch-scope"] {
                let control = try ui.view(identifier)
                #expect(control.isDescendant(of: header), "\(identifier) is in the header")
                let (pane, target) = try ui.spot("e", 0.9, 0.55)
                try ui.drag(control, from: NSPoint(x: control.bounds.midX, y: control.bounds.midY), to: target, in: pane)
                ui.settle(0.1)
                #expect(!ui.renderer.drag.isDragging, "\(identifier) did not start a drag")
                #expect(try ui.layout.rootNode == before, "\(identifier): nothing moved")
                #expect(ui.activePane == "g", "\(identifier): the pane is active")
                if ui.contextMenu != nil { try ui.press(KeyChord(.escape, [])) }
                ui.engine.focus("e")
                #expect(ui.activePane == "e")
            }
            try ui.click(at: NSPoint(x: title.bounds.maxX - 12, y: title.bounds.midY), in: title, right: true)
            #expect(ui.contextMenuCount == 1, "Unpin only: no Edit title")
        }

        /// D-7, D-9: typing a directory into the path bar and pressing Return
        /// re-reads that repository.
        @Test func thePathBarReadsWhatIsTyped() async throws {
            let first = try ScratchRepo(commits: ["a"])
            let second = try ScratchRepo(commits: ["b1", "b2"])
            defer {
                first.remove()
                second.remove()
            }
            let ui = UIDriver(layout: Self.one(first.path))
            try await ui.gitTree("g") { $0["subjects"] == ["a"] }
            let field = try #require(try ui.view("git-tree-path-input") as? NSTextField)
            try ui.click(field)
            let window = try #require(ui.window.window)
            #expect(window.makeFirstResponder(field))
            field.currentEditor()?.selectAll(nil)
            try ui.type(second.path + "\n")
            try await ui.gitTree("g") { $0["subjects"] == ["b2", "b1"] }
            #expect(ui.config(of: "g")?["cwd"] == .string(second.path))
        }
    }
}

extension JSONValue {
    var arrayCount: Int? { if case .array(let items) = self { items.count } else { nil } }
}
