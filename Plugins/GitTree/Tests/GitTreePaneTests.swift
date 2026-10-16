import AppKit
import TabsPluginSDK
import Testing

@testable import TabsCore

// The pane's behaviour against scripted git: assertions on the pane's state
// and its views' layout. Case ids are docs/GIT-TREE.md's.
//
// Each suite is `.serialized` (suites still run beside each other): its tests
// all run on the main actor, with scripted git that answers at once, so
// running a hundred of them together gains nothing and only queues each wait
// behind every other test's work (seconds, on a busy machine).

private let merge = "mmmmmmm0000000000000000000000000000000a"
private let onFeature = "ccccccc0000000000000000000000000000000a"
private let onMain = "bbbbbbb0000000000000000000000000000000a"
private let root = "aaaaaaa0000000000000000000000000000000a"

private func commit(_ hash: String, _ subject: String, _ parents: [String] = [], _ refs: [String] = []) -> Commit {
    Commit(hash: hash, parents: parents, author: "Ann", date: "2026-01-02T03:04:05Z", refs: refs, subject: subject)
}

/// A small history with a merge.
private let history = [
    commit(merge, "merge feature", [onMain, onFeature], ["HEAD", "main"]),
    commit(onFeature, "on feature", [root], ["feature"]),
    commit(onMain, "on main", [root]),
    commit(root, "root commit"),
]

private func workingTreeDetail(_ path: String, insertions: Int = 1, deletions: Int = 0) -> CommitDetail {
    CommitDetail(
        hash: "", parents: [merge], author: "", authorEmail: "", date: "", refs: [], message: "Uncommitted changes",
        files: [ChangedFile(path: path, insertions: insertions, deletions: deletions)], filesTruncated: false)
}

/// Lets scripted git answer what a test hopes was never asked: it answers
/// within a few turns of the main actor, so a short wait shows nothing came.
@MainActor
func quietPeriod() async {
    try? await Task.sleep(for: .milliseconds(25))
}

/// The git tree plugin in a harness with scripted git, its details read as
/// soon as the selection moves (no debounce, but in the test that pins it).
@MainActor
final class GitTreeTestBed {
    let harness: PluginHarness
    let plugin: GitTreePlugin
    let git = ScriptedGitSource()

    init(alongside: [PluginCandidate] = [], testFile: String = #filePath) throws {
        let made = Ref<GitTreePlugin?>(nil)
        harness = try PluginHarness(alongside: alongside, testFile: testFile) {
            let plugin = GitTreePlugin()
            made.value = plugin
            return plugin
        }
        guard let plugin = made.value else { throw TestFailure("the plugin wasn't made") }
        self.plugin = plugin
        services.sourceOverride = git
        services.detailDebounceOverride = .zero
    }

    var services: GitTreeServices { plugin.services! }

    /// Opens a git tree (as `openPane` does) and returns it with its controller.
    func open(config: JSONValue? = nil, placement: PanePlacement = .automatic, origin: PaneID? = nil) -> (id: PaneID, pane: GitTreePane)? {
        guard let id = harness.runtime.panes.openPane(PaneRequest(type: "git-tree", config: config, placement: placement, origin: origin)),
            let pane = harness.controller(of: id, as: GitTreePane.self)
        else { return nil }
        return (id, pane)
    }

    /// Opens a pane on `/repo` answering `commits`, and waits for its list and
    /// its default selection's details.
    func openRepo(
        _ commits: [Commit] = history, cwd: String = "/repo", hasMore: Bool = false, dirty: Bool = false, extra: [String: JSONValue] = [:],
        sourceLocation: SourceLocation = #_sourceLocation
    ) async throws -> (id: PaneID, pane: GitTreePane) {
        git.setLog(commits, root: cwd, hasMore: hasMore, hasUncommittedChanges: dirty)
        var config: [String: JSONValue] = ["cwd": .string(cwd)]
        for (key, value) in extra { config[key] = value }
        let opened = try #require(open(config: .object(config)), sourceLocation: sourceLocation)
        #expect(await settled(opened.pane, sourceLocation: sourceLocation), sourceLocation: sourceLocation)
        return opened
    }

    /// The log read, and unless collapsed, the selected row's details too.
    func settled(_ pane: GitTreePane, sourceLocation: SourceLocation = #_sourceLocation) async -> Bool {
        await eventually(sourceLocation: sourceLocation) {
            pane.log != nil && !pane.fetchPending
                && (pane.split.collapsed || pane.selectedHash == nil || pane.detail?.hash == pane.selectedHash)
        }
    }

    /// The pane's view, laid out at a size (the tests' window).
    func view(of pane: GitTreePane, width: Double = 600, height: Double = 500) -> GitTreeView {
        let view = pane.view as! GitTreeView
        view.frame = CGRect(x: 0, y: 0, width: width, height: height)
        view.layoutSubtreeIfNeeded()
        return view
    }

    func title(_ id: PaneID) -> String { harness.engine.paneTitle(of: id) }

    func config(_ id: PaneID) -> [String: JSONValue] {
        if case .object(let object)? = harness.config(of: id) { object } else { [:] }
    }
}

// MARK: - The list, selection and keys

@MainActor
@Suite(.serialized) struct GitTreeListTests {
    let bed: GitTreeTestBed

    init() throws { bed = try GitTreeTestBed() }

    /// H-1, H-2
    @Test("renders one row per commit, newest first, with its hash, subject and refs") func rows() async throws {
        let (_, pane) = try await bed.openRepo()
        #expect(pane.commits.map(\.subject) == ["merge feature", "on feature", "on main", "root commit"])
        let view = bed.view(of: pane)
        let first = view.list.layout(ofRow: 0)
        #expect(first.hashText == "mmmmmmm")
        #expect(first.pills.map(\.text) == ["HEAD", "main"])
        #expect(first.subjectText == "merge feature")
    }

    /// R-2
    @Test("draws a gutter as wide as the graph actually needs") func gutter() async throws {
        let (_, pane) = try await bed.openRepo()
        #expect(bed.view(of: pane).list.layout(ofRow: 0).gutter.width == 24)
        let (_, linear) = try await bed.openRepo([commit("aaa", "only commit")])
        #expect(bed.view(of: linear).list.layout(ofRow: 0).gutter.width == 12)
    }

    /// S-1, P-7
    @Test("selects the newest commit so the detail panel is never empty beside a full list") func selectsNewest() async throws {
        let (_, pane) = try await bed.openRepo()
        #expect(pane.selectedHash == merge)
        #expect(pane.detail?.message == "merge feature")
    }

    /// S-3: through the list's own key handling.
    @Test("arrow keys move the selection, and stop at both ends") func arrows() async throws {
        let (_, pane) = try await bed.openRepo()
        let list = bed.view(of: pane).list
        press(.downArrow, on: list)
        #expect(pane.selectedHash == onFeature)
        press(.downArrow, on: list)
        press(.downArrow, on: list)
        #expect(pane.selectedHash == root)
        press(.downArrow, on: list)
        #expect(pane.selectedHash == root, "clamped, not wrapped")
        for _ in 0..<4 { press(.upArrow, on: list) }
        #expect(pane.selectedHash == merge)
    }

    @Test("Home and End jump to the ends of the list") func homeEnd() async throws {
        let (_, pane) = try await bed.openRepo()
        let list = bed.view(of: pane).list
        press(.end, on: list)
        #expect(pane.selectedHash == root)
        press(.home, on: list)
        #expect(pane.selectedHash == merge)
    }

    /// S-6: the list takes the keyboard as a whole, in a window.
    @Test("keeps the keyboard on the list as the selection moves") func listKeepsFocus() async throws {
        let (_, pane) = try await bed.openRepo()
        let view = bed.view(of: pane)
        let window = hostWindow(view)
        view.focusList()
        #expect(window.firstResponder === view.list)
        press(.downArrow, on: view.list)
        #expect(window.firstResponder === view.list)
        #expect(pane.selectedHash == onFeature)
    }

    /// S-6: activation focuses the list while it has no rows too (still
    /// reading, or a failure's notice in its place), and its keys move nothing.
    @Test("takes the keyboard on activation with no rows, and its keys move nothing") func listFocusWithoutRows() async throws {
        bed.git.failure = .notARepo(path: "/tmp/nowhere")
        let (_, pane) = try #require(bed.open(config: ["cwd": "/tmp/nowhere"]))
        #expect(await bed.settled(pane))
        let view = bed.view(of: pane)
        let window = hostWindow(view)
        pane.focus()
        #expect(window.firstResponder === view.list)
        for key: NSEvent.SpecialKey in [.downArrow, .upArrow, .home, .end] { press(key, on: view.list) }
        #expect(pane.selectedHash == nil)
        #expect(view.state == .notice)
        #expect(window.firstResponder === view.list)
        window.orderOut(nil)
    }

    /// S-5, P-1
    @Test("clicking a row selects it and swaps the detail panel") func clickSelects() async throws {
        let (_, pane) = try await bed.openRepo()
        pane.select(onMain)
        #expect(pane.selectedHash == onMain)
        #expect(await eventually { pane.detail?.message == "on main" })
    }

    /// P-1, P-2
    @Test("the detail panel shows the full hash, author with email, and changed files") func detail() async throws {
        bed.git.details[onMain] = CommitDetail(
            hash: onMain, parents: [root], author: "Ann", authorEmail: "ann@example.com", date: "2026-01-02T03:04:05Z", refs: [],
            message: "on main\n\nWith a body.",
            files: [
                ChangedFile(path: "src/a.ts", insertions: 12, deletions: 3), ChangedFile(path: "logo.png", insertions: nil, deletions: nil),
            ],
            filesTruncated: false)
        let (_, pane) = try await bed.openRepo()
        pane.select(onMain)
        #expect(await eventually { pane.detail?.hash == onMain })
        let layout = CommitDetailLayout(detail: pane.detail, width: 600)
        let texts = layout.runs.map(\.text)
        #expect(texts.contains(onMain))
        #expect(texts.contains("Ann <ann@example.com>"))
        #expect(texts.contains("With a body."))
        #expect(layout.files.count == 2)
        #expect(texts.contains("src/a.ts") && texts.contains("+12") && texts.contains("−3"))
        #expect(layout.files[1].binary != nil && layout.files[1].insertions == nil)
        #expect(!texts.contains("+0"))
    }

    /// P-19
    @Test("the fields end with the lines added and deleted across the files, coloured as a file's stat") func totals() throws {
        let detail = CommitDetail(
            hash: onMain, parents: [root], author: "Ann", authorEmail: "ann@example.com", date: "2026-01-02T03:04:05Z", refs: ["main"],
            message: "on main",
            files: [
                ChangedFile(path: "src/a.ts", insertions: 12, deletions: 3), ChangedFile(path: "logo.png", insertions: nil, deletions: nil),
                ChangedFile(path: "src/b.ts", insertions: 8, deletions: 1),
            ],
            filesTruncated: false)
        let layout = CommitDetailLayout(detail: detail, width: 600)
        let totals = try #require(layout.totals)
        let label = try #require(layout.runs.first { $0.text == "Lines" })
        let plus = try #require(layout.runs.first { $0.text == "+20" })
        let minus = try #require(layout.runs.first { $0.text == "−4" })
        #expect(layout.fields.count == 6, "Commit, Author, Date, Parent, Refs, Lines")
        #expect(layout.fields.last?.dt == label.box && layout.fields.last?.dd == plus.box.union(minus.box))
        #expect(plus.box == totals.insertions && minus.box == totals.deletions)
        #expect(plus.color == .fixed(GitTreeColors.insertions) && minus.color == .fixed(GitTreeColors.deletions))
        #expect(minus.box.minY == plus.box.minY && minus.box.minX == plus.box.maxX + GitTreeMetrics.fileStatGap)
        let border = try #require(layout.filesBorder)
        #expect(layout.fields[4].dd.maxY < label.box.minY && minus.box.maxY < border.minY)

        // Too narrow for both on a line: the deletions go under the insertions.
        let narrow = try #require(CommitDetailLayout(detail: detail, width: 90).totals)
        #expect(narrow.deletions.minX == narrow.insertions.minX && narrow.deletions.minY == narrow.insertions.maxY)
    }

    /// P-4, P-5, P-7, P-19
    @Test func theDetailPanelsDimLinesSayWhatsMissing() {
        #expect(CommitDetailLayout(detail: nil, width: 600).runs.map(\.text) == ["Select a commit."])
        var empty = CommitDetail(
            hash: onMain, parents: [root], author: "A", authorEmail: "a@b", date: "", refs: [], message: "m", files: [],
            filesTruncated: false)
        #expect(CommitDetailLayout(detail: empty, width: 600).runs.map(\.text).contains("No files changed against the first parent."))
        // No counts to total, no Lines.
        #expect(CommitDetailLayout(detail: empty, width: 600).totals == nil)
        var binaries = empty
        binaries.files = [ChangedFile(path: "logo.png", insertions: nil, deletions: nil)]
        #expect(!CommitDetailLayout(detail: binaries, width: 600).runs.map(\.text).contains("Lines"))
        empty.hash = ""
        #expect(CommitDetailLayout(detail: empty, width: 600).runs.map(\.text).contains("No uncommitted changes."))
        empty.filesTruncated = true
        #expect(CommitDetailLayout(detail: empty, width: 600).runs.map(\.text).contains("Only the first files are listed."))
        let merged = CommitDetail(
            hash: merge, parents: [onMain, onFeature], author: "A", authorEmail: "a@b", date: "", refs: ["HEAD", "main"], message: "m",
            files: [], filesTruncated: false)
        let texts = CommitDetailLayout(detail: merged, width: 600).runs.map(\.text)
        #expect(texts.contains("Parents") && texts.contains("bbbbbbb, ccccccc") && texts.contains("HEAD, main"))
    }

    /// H-10
    @Test("Load more appears only when there is more, and asks for another page") func loadMore() async throws {
        let (_, pane) = try await bed.openRepo(hasMore: true)
        #expect(bed.view(of: pane).list.loadMoreRect != nil)
        let before = bed.git.logCalls.count
        pane.loadMore()
        #expect(await eventually { bed.git.logCalls.count > before })
        #expect(bed.git.logSkips.last == 4)
        let (_, done) = try await bed.openRepo()
        #expect(bed.view(of: done).list.loadMoreRect == nil)
    }

    /// H-7
    @Test("author and date columns are hidden by default") func columnsHidden() async throws {
        let (_, pane) = try await bed.openRepo()
        let row = bed.view(of: pane).list.layout(ofRow: 0)
        #expect(row.author == nil && row.date == nil)
    }

    @Test("the settings toggles show the author and date columns once enabled") func columnsShown() async throws {
        let (_, pane) = try await bed.openRepo()
        pane.settings.update {
            $0.showAuthorColumn = true
            $0.showDateColumn = true
        }
        let list = bed.view(of: pane).list
        for index in 0..<4 {
            let row = list.layout(ofRow: index)
            #expect(row.author != nil && row.date != nil)
        }
        #expect(list.layout(ofRow: 0).authorText == "Ann")
    }

    /// H-4, H-6
    @Test("uncommitted changes render as a dimmed row connected into the graph above HEAD") func workingTreeRow() async throws {
        let (_, pane) = try await bed.openRepo(dirty: true)
        #expect(pane.commits.count == 5)
        let row = pane.graph.rows[0]
        #expect(row.commit.hash == uncommittedChangesHash)
        #expect(row.commit.subject == "Uncommitted changes")
        #expect(row.commit.parents == [merge])
        #expect(row.outgoing == [0], "connected into the graph")
        let list = bed.view(of: pane).list
        #expect(list.layout(ofRow: 0).hashText == "")
        #expect(list.layout(ofRow: 0).gutter.width == list.layout(ofRow: 1).gutter.width)
        #expect(list.layout(ofRow: 1).gutter.width == 24)
        #expect(pane.selectedHash == merge, "the default selection stays on real history")
    }

    /// P-6, P-19
    @Test("selecting the working-tree row shows its own changed files, like a commit") func selectWorkingTree() async throws {
        bed.git.workingTreeDetail = workingTreeDetail("src/a.ts", insertions: 4, deletions: 1)
        let (_, pane) = try await bed.openRepo(dirty: true)
        pane.select("")
        #expect(await eventually { pane.detail?.hash == "" })
        let texts = CommitDetailLayout(detail: pane.detail, width: 600).runs.map(\.text)
        #expect(texts.contains("Uncommitted changes") && texts.contains("src/a.ts") && texts.contains("+4") && texts.contains("−1"))
        #expect(!texts.contains("Commit"))
        #expect(texts.contains("Parent") && texts.contains(String(merge.prefix(7))))
        // Lines totals the listed files: the one file's counts, twice.
        #expect(texts.contains("Lines") && texts.filter { $0 == "+4" }.count == 2 && texts.filter { $0 == "−1" }.count == 2)
    }

    /// P-9
    @Test("Cmd/Ctrl+R re-reads the working-tree detail, the one row whose detail changes") func refreshWorkingTree() async throws {
        bed.git.workingTreeDetail = workingTreeDetail("before.ts")
        let (_, pane) = try await bed.openRepo(dirty: true)
        pane.select("")
        #expect(await eventually { pane.detail?.files.first?.path == "before.ts" })
        bed.git.workingTreeDetail = workingTreeDetail("after.ts")
        #expect(bed.harness.perform("git-tree.refresh"))
        #expect(await eventually { pane.detail?.files.first?.path == "after.ts" })
        #expect(pane.selectedHash == "")
    }

    /// P-8, with the app's own debounce: a held arrow (each key a turn of the
    /// main actor apart, well inside the debounce) reads only the row the
    /// selection rests on; a row re-read keeps its detail up meanwhile.
    @Test func aHeldArrowReadsOnlyTheRowItRestsOn() async throws {
        bed.services.detailDebounceOverride = nil
        #expect(GitTreePane.detailDebounce == .milliseconds(100))
        bed.git.workingTreeDetail = workingTreeDetail("kept.ts")
        let (_, pane) = try await bed.openRepo(dirty: true)
        let list = bed.view(of: pane).list
        let before = bed.git.detailReads.count
        for _ in 0..<3 {
            press(.downArrow, on: list)
            // A pending read starts (and, debounced, waits) before the next key.
            for _ in 0..<3 { await Task.yield() }
        }
        #expect(pane.selectedHash == root)
        #expect(await bed.settled(pane))
        #expect(Array(bed.git.detailReads.dropFirst(before)) == [root], "one read, where the selection rests")

        press(.home, on: list)
        #expect(await eventually { pane.detail?.files.first?.path == "kept.ts" })
        let version = pane.logVersion
        pane.refresh()
        #expect(await eventually { pane.logVersion > version })
        #expect(pane.detail?.files.first?.path == "kept.ts", "the same row's detail stays up while it's read again")
        #expect(await bed.settled(pane))
    }

    @Test("Home reaches the working-tree row, and arrow keys walk into and out of it") func homeReachesWorkingTree() async throws {
        let (_, pane) = try await bed.openRepo(dirty: true)
        let list = bed.view(of: pane).list
        press(.home, on: list)
        #expect(pane.selectedHash == "")
        press(.downArrow, on: list)
        #expect(pane.selectedHash == merge)
    }

    /// H-5
    @Test("no working-tree row when the working tree is clean") func cleanTree() async throws {
        let (_, pane) = try await bed.openRepo()
        #expect(pane.commits.count == 4)
        #expect(!pane.commits.contains { $0.hash == "" })
    }

    /// T-1
    @Test("the pane's title becomes the repository's own name") func title() async throws {
        let (id, _) = try await bed.openRepo(cwd: "/home/ann/projects/tabs")
        #expect(bed.title(id) == "tabs")
    }

    /// S-2
    @Test func theSelectionSurvivesARereadWhileItsCommitIsThere() async throws {
        let (_, pane) = try await bed.openRepo()
        pane.select(onMain)
        bed.git.setLog([commit("nnnnnnn", "new", [merge])] + history, root: "/repo")
        pane.refresh()
        #expect(await eventually { pane.commits.count == 5 })
        #expect(pane.selectedHash == onMain)
        bed.git.setLog([commit("zzz", "only")], root: "/repo")
        pane.refresh()
        #expect(await eventually { pane.commits.count == 1 })
        #expect(pane.selectedHash == "zzz")
    }
}

// MARK: - Failures

@MainActor
@Suite(.serialized) struct GitTreeFailureTests {
    let bed: GitTreeTestBed

    init() throws { bed = try GitTreeTestBed() }

    private func open(failing reason: GitFailure, cwd: String) async throws -> (id: PaneID, pane: GitTreePane) {
        bed.git.failure = reason
        let opened = try #require(bed.open(config: ["cwd": .string(cwd)]))
        #expect(await bed.settled(opened.pane))
        return opened
    }

    private func notice(_ pane: GitTreePane) -> [String] {
        let view = bed.view(of: pane)
        #expect(view.state == .notice)
        return view.notice.lines(width: 600).map { $0.map(\.text).joined(separator: " ") }
    }

    /// T-2
    @Test("moving to a directory that isn't a repository stops the title naming the old one") func titleFollows() async throws {
        let (id, pane) = try await bed.openRepo(cwd: "/home/ann/projects/tabs")
        #expect(bed.title(id) == "tabs")
        bed.git.failure = .notARepo(path: "/tmp/nowhere")
        pane.applyPath("/tmp/nowhere")
        #expect(await eventually { bed.title(id) == "nowhere" })
    }

    /// E-1, E-6
    @Test("a directory that is not a repository is a sentence, not an error") func notARepo() async throws {
        let (_, pane) = try await open(failing: .notARepo(path: "/tmp/nowhere"), cwd: "/tmp/nowhere")
        #expect(
            notice(pane) == [
                "No git repository at /tmp/nowhere.", "Type a directory above, or use the folder button to choose one.",
            ])
        #expect(!bed.view(of: pane).toolbar.isHidden, "the path bar is the way out")
    }

    /// E-2
    @Test("an empty repository says so rather than claiming it is not a repository") func noCommits() async throws {
        let (_, pane) = try await open(failing: .noCommits(root: "/repo"), cwd: "/repo")
        #expect(notice(pane).first == "/repo is a git repository, but has no commits yet.")
    }

    /// E-3
    @Test("a missing git binary names itself") func gitMissing() async throws {
        let (_, pane) = try await open(failing: .gitMissing, cwd: "/repo")
        #expect(notice(pane).first?.contains("git isn’t installed") == true)
    }

    /// E-4
    @Test("a nonexistent directory names itself, not git") func noSuchDirectory() async throws {
        let (_, pane) = try await open(failing: .noSuchDirectory(path: "/tmp/gone"), cwd: "/tmp/gone")
        #expect(notice(pane).first == "No directory at /tmp/gone.")
        #expect(notice(pane).first?.contains("installed") == false)
    }

    /// E-5
    @Test("an unclassified git failure still reaches the user as words") func unclassified() async throws {
        let (_, pane) = try await open(failing: .failed(message: "fatal: bad object HEAD"), cwd: "/repo")
        #expect(notice(pane).first == "fatal: bad object HEAD")
    }

    /// H-12
    @Test func aFailedLoadMoreReplacesTheList() async throws {
        let (_, pane) = try await bed.openRepo(hasMore: true)
        bed.git.failure = .failed(message: "fatal: gone")
        pane.loadMore()
        #expect(await eventually { if case .failure = pane.log { true } else { false } })
    }
}

// MARK: - Directory, path bar, branch scope

@MainActor
@Suite(.serialized) struct GitTreeDirectoryTests {
    let bed: GitTreeTestBed

    init() throws { bed = try GitTreeTestBed() }

    /// D-7, PS-1
    @Test("typing a directory into the path bar re-reads that repository") func pathBar() async throws {
        let (id, pane) = try await bed.openRepo()
        pane.applyPath("  /other  ")
        #expect(bed.config(id)["cwd"] == "/other")
        #expect(await eventually { bed.git.logCalls.contains("/other") })
        // Empty or unchanged text does nothing.
        let calls = bed.git.logCalls.count
        pane.applyPath("   ")
        pane.applyPath("/other")
        #expect(bed.git.logCalls.count == calls)
    }

    /// D-8, D-9, D-10, D-7 through the real field, in a window.
    @Test("a directory arriving while the path bar is being typed in does not replace it") func typingWins() async throws {
        let (_, pane) = try await bed.openRepo()
        let view = bed.view(of: pane)
        let window = hostWindow(view)
        let toolbar = view.toolbar
        #expect(window.makeFirstResponder(toolbar.pathField))
        #expect(toolbar.isEditingPath)
        toolbar.pathField.stringValue = "/typed"
        toolbar.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: toolbar.pathField))
        pane.chooseDirectory("/arrived-late")
        #expect(toolbar.pathField.stringValue == "/typed")
        #expect(toolbar.pathValue == "/typed")
        // Return submits what was typed.
        let editor = try #require(toolbar.pathField.currentEditor() as? NSTextView)
        #expect(toolbar.control(toolbar.pathField, textView: editor, doCommandBy: #selector(NSResponder.insertNewline(_:))))
        #expect(await eventually { bed.git.logCalls.contains("/typed") })
        // Escape puts the configured directory back.
        toolbar.pathField.stringValue = "/half"
        #expect(toolbar.control(toolbar.pathField, textView: editor, doCommandBy: #selector(NSResponder.cancelOperation(_:))))
        #expect(toolbar.pathField.stringValue == "/typed")
        window.orderOut(nil)
    }

    /// D-9: keys typed in the path bar go to its editor, never the list.
    @Test("arrow keys inside the path bar move the caret, not the selection") func pathBarKeys() async throws {
        let (_, pane) = try await bed.openRepo()
        let view = bed.view(of: pane)
        let window = hostWindow(view)
        view.focusList()
        press(.downArrow, on: view.list)
        #expect(pane.selectedHash == onFeature)
        #expect(window.makeFirstResponder(view.toolbar.pathField))
        for _ in 0..<2 { window.sendEvent(keyEvent(.downArrow, window: window)) }
        #expect(pane.selectedHash == onFeature)
        window.orderOut(nil)
    }

    /// D-11
    @Test("the browse button opens the picker at the current directory, and adopts the directory it returns") func browseAdopts()
        async throws
    {
        let (id, pane) = try await bed.openRepo()
        let renderer = bed.harness.renderer
        renderer.answerPicker = { _ in URL(filePath: "/picked", directoryHint: .isDirectory) }
        await pane.browse()
        #expect(
            renderer.pickers.map(\.picker) == [
                PanePicker(kind: .directory, title: "Choose a repository", startingAt: URL(filePath: "/repo", directoryHint: .isDirectory))
            ])
        #expect(bed.config(id)["cwd"] == "/picked")
        #expect(await eventually { bed.git.logCalls.contains("/picked") })
    }

    @Test("cancelling the browse dialog changes nothing") func browseCancelled() async throws {
        let (id, pane) = try await bed.openRepo()
        let calls = bed.git.logCalls.count
        await pane.browse()
        #expect(bed.harness.renderer.pickers.count == 1)
        #expect(bed.config(id)["cwd"] == "/repo")
        #expect(bed.git.logCalls.count == calls)
    }

    @Test("the folder button is in the toolbar, named and pressable, and takes its room from the path bar") func browseButton() async throws
    {
        let (_, pane) = try await bed.openRepo()
        let toolbar = bed.view(of: pane).toolbar
        let button = toolbar.browse
        #expect(button.accessibilityIdentifier() == "git-tree-browse-button")
        #expect(button.accessibilityLabel() == "Choose a repository")
        #expect(button.toolTip == "Choose a repository")
        let layout = toolbar.computeLayout(width: 600)
        #expect(layout.browse.size == CGSize(width: 23, height: 17))
        #expect(layout.path.maxX + 8 == layout.browse.minX)
        _ = button.accessibilityPerformPress()
        #expect(await eventually { bed.harness.renderer.pickers.count == 1 })
    }

    /// D-4, D-10
    @Test("a pane created with no directory adopts the default one") func adoptsDefault() async throws {
        bed.git.setLog(history, root: "/default-repo")
        bed.git.defaultDirectoryAnswer = "/default-repo"
        let (id, pane) = try #require(bed.open())
        _ = bed.view(of: pane)
        #expect(await eventually { bed.git.logCalls.contains("/default-repo") })
        #expect(bed.config(id)["cwd"] == "/default-repo")
        #expect(await eventually { (pane.view as! GitTreeView).toolbar.pathValue == "/default-repo" })
    }

    /// D-5
    @Test func aChoiceMadeWhileTheDefaultIsPendingWins() async throws {
        bed.git.defaultDirectoryAnswer = "/default-repo"
        let (id, pane) = try #require(bed.open())
        pane.chooseDirectory("/chosen")
        await quietPeriod()
        #expect(bed.config(id)["cwd"] == "/chosen")
        #expect(!bed.git.logCalls.contains("/default-repo"))
    }

    /// B-1
    @Test("the branch-scope select offers the three filters and defaults to all branches") func scopeOptions() async throws {
        let (_, pane) = try await bed.openRepo()
        #expect(pane.branchScope == .all)
        #expect(GitTreeToolbar.scopeOptions.map(\.0) == [.current, .local, .all])
        #expect(GitTreeToolbar.scopeOptions.map(\.1) == ["Current branch", "All local branches", "All branches"])
        #expect(
            bed.view(of: pane).toolbar.select.scopeItems().map(\.title) == ["Current branch", "All local branches", "All branches"])
    }

    /// B-2
    @Test("choosing a branch scope re-reads the log with it and persists it to the pane") func chooseScope() async throws {
        let (id, pane) = try await bed.openRepo()
        bed.view(of: pane).toolbar.select.scopeItems()[1].action()
        #expect(await eventually { bed.git.logScopes.last == .local })
        #expect(bed.config(id)["branchScope"] == "local")
    }

    /// B-3
    @Test("a pane restored with a branch scope already chosen opens reading it") func restoredScope() async throws {
        let (_, pane) = try await bed.openRepo(extra: ["branchScope": "current"])
        #expect(pane.branchScope == .current)
        #expect(bed.git.logScopes.last == .current)
    }

    /// B-4
    @Test func theHeadLabelReadsTheBranchOrDetached() async throws {
        let (_, pane) = try await bed.openRepo()
        let toolbar = bed.view(of: pane).toolbar
        #expect(toolbar.headLabel() == "main")
        bed.git.head = .detached(hash: root)
        pane.refresh()
        #expect(await eventually { toolbar.headLabel() == "detached at aaaaaaa" })
    }

    /// T-3: the toolbar is the header's title, laid out in the slot core gives it.
    @Test("the toolbar is the pane's header title, and the body has no strip above it") func toolbarIsTheHeaderTitle() async throws {
        let (_, pane) = try await bed.openRepo()
        let view = bed.view(of: pane)
        #expect(pane.headerTitle === view.toolbar)
        #expect(view.toolbar.superview == nil, "core, not the pane's view, hosts it")
        #expect(view.computeLayout().content == CGRect(x: 0, y: 0, width: 600, height: 500))
        // It fills the slot: the path bar takes what the other three leave, with the bar's 8pt gaps.
        let toolbar = view.toolbar
        let layout = toolbar.computeLayout(width: 400)
        #expect(layout.path.minX == 0)
        #expect(layout.path.height == 20)
        #expect(layout.select.maxX == 400)
        #expect(layout.browse.minX == layout.path.maxX + 8)
        // The slot's fractional origin moves every box; the HEAD label's cap is 40% of the bar, not of the slot.
        bed.git.head = .branch(name: String(repeating: "long-branch-name-", count: 8))
        pane.refresh()
        #expect(await eventually { toolbar.headLabel() != "main" })
        toolbar.paneHeaderSlotDidChange(PaneHeaderSlot(barContentWidth: 500, fractionalOffset: CGPoint(x: 0.25, y: -0.25)))
        let capped = toolbar.computeLayout(width: 400)
        #expect(capped.head?.width == 200)
        #expect(capped.path.minX == 0.25)
        #expect(capped.path.minY == 2 - 0.25)
        #expect(capped.select.maxX == 400.25)
    }

    /// The palette copy is gone: the views paint with the theme core pushes.
    @Test func theViewsPaintWithTheThemeCoreTellsThePane() async throws {
        let (id, pane) = try await bed.openRepo()
        let view = bed.view(of: pane)
        #expect(view.theme == .placeholder, "before core says anything: the placeholder")
        bed.harness.runtime.panes.appearanceDidChange(id, theme: .standInLight, depth: 1)
        #expect(view.theme == .standInLight)
        #expect(view.list.theme == .standInLight && view.detail.theme == .standInLight && view.divider.theme == .standInLight)
        #expect(pane.toolbar.theme == .standInLight)
        #expect(pane.pane.theme == .standInLight && pane.pane.depth == 1)
        bed.harness.runtime.panes.appearanceDidChange(id, theme: .standInDark, depth: 1)
        #expect(pane.toolbar.theme == .standInDark && view.theme == .standInDark)
    }

    @Test func aViewBuiltAfterTheThemeWasToldStartsWithIt() async throws {
        let opened = try #require(bed.open(config: ["cwd": "/repo"]))
        bed.harness.runtime.panes.appearanceDidChange(opened.id, theme: .standInLight, depth: 0)
        let view = bed.view(of: opened.pane)
        #expect(view.theme == .standInLight && view.list.theme == .standInLight && opened.pane.toolbar.theme == .standInLight)
    }

    /// PS-1: a config that isn't an object is refused, not replaced.
    @Test func anUnreadableConfigIsRefused() throws {
        let id = bed.harness.runtime.panes.openPane(PaneRequest(type: "git-tree", config: ["cwd": 3]))
        #expect(id.flatMap { bed.harness.controller(of: $0, as: GitTreePane.self) } == nil)
    }
}

// MARK: - Refreshing

@MainActor
@Suite(.serialized) struct GitTreeRefreshTests {
    let bed: GitTreeTestBed

    init() throws {
        let standIn = TestSupport.candidate(TestSupport.manifest("stand-in", contentTypes: ["stand-in"])) { context in
            context.register(TestSupport.contentType("stand-in"))
        }
        bed = try GitTreeTestBed(alongside: [standIn])
    }

    /// F-1, K-1
    @Test("Cmd/Ctrl+R re-reads the current directory and shows what changed") func refresh() async throws {
        let (_, pane) = try await bed.openRepo()
        let before = bed.git.logCalls.count
        bed.git.setLog([commit("nnnnnnn0000000000000000000000000000000a", "new commit")] + history, root: "/repo")
        #expect(bed.harness.perform("git-tree.refresh"))
        #expect(await eventually { pane.commits.count == 5 })
        #expect(bed.git.logCalls.count > before)
        #expect(bed.git.logCalls.last == "/repo")
        #expect(pane.log != nil, "no Reading history… flash")
    }

    /// F-2
    @Test("Cmd/Ctrl+R does nothing when no git tree pane is active") func refreshElsewhere() async throws {
        bed.git.setLog(history, root: "/repo")
        #expect(bed.harness.runtime.panes.openPane(PaneRequest(type: "stand-in")) != nil)
        let before = bed.git.logCalls.count
        #expect(!bed.harness.perform("git-tree.refresh"))
        #expect(bed.git.logCalls.count == before)
    }

    @Test func refreshIsAViewCommandOnCommandRForGitTreesOnly() throws {
        let command = try #require(bed.harness.runtime.commands.command("git-tree.refresh"))
        #expect(command.value.title == "Refresh")
        #expect(command.value.menu == .view)
        #expect(command.value.defaultChord == KeyChord("r", [.command]))
        #expect(command.value.appliesTo == "git-tree")
    }

    /// The core focus hooks a test drives: which windows have the focus (the
    /// fake renderer's), then the engine told the window gained or lost it.
    private func focusWindow(_ gained: Bool, of pane: GitTreePane) {
        let window = pane.pane.windowID
        bed.harness.renderer.focusedWindows = gained ? [window] : []
        if gained { bed.harness.engine.windowDidGainFocus(window) } else { bed.harness.engine.windowDidLoseFocus(window) }
    }

    private func activate(_ id: PaneID, of pane: GitTreePane) {
        _ = bed.harness.engine.perform(in: pane.pane.windowID) { layout, _ in layout.setActivePane(NodeID(id.rawValue)) }
    }

    /// F-6: the window regaining focus with the pane active (core's
    /// `paneDidBecomeAttended`).
    @Test("auto-refresh-on-focus re-reads the pane when the window regains focus, only when enabled") func autoRefreshOn() async throws {
        let (_, pane) = try await bed.openRepo()
        pane.settings.update { $0.autoRefreshOnFocus = true }
        let before = bed.git.logCalls.count
        focusWindow(true, of: pane)
        #expect(await eventually { bed.git.logCalls.count > before })
    }

    @Test("...and does not, with the setting at its off-by-default value") func autoRefreshOff() async throws {
        let (_, pane) = try await bed.openRepo()
        let before = bed.git.logCalls.count
        focusWindow(true, of: pane)
        await quietPeriod()
        #expect(bed.git.logCalls.count == before)
    }

    @Test func losingTheWindowFocusRefreshesNothing() async throws {
        let (_, pane) = try await bed.openRepo()
        pane.settings.update { $0.autoRefreshOnFocus = true }
        focusWindow(true, of: pane)
        #expect(await bed.settled(pane))
        let after = bed.git.logCalls.count
        focusWindow(false, of: pane)
        await quietPeriod()
        #expect(bed.git.logCalls.count == after)
    }

    /// F-5: activation while the window is focused.
    @Test func autoRefreshReReadsWhenThePaneBecomesActive() async throws {
        let (id, pane) = try await bed.openRepo()
        _ = bed.view(of: pane)
        pane.settings.update { $0.autoRefreshOnFocus = true }
        #expect(bed.harness.runtime.panes.openPane(PaneRequest(type: "stand-in", placement: .tab(near: id))) != nil)
        focusWindow(true, of: pane)
        #expect(await bed.settled(pane))
        let before = bed.git.logCalls.count
        activate(id, of: pane)
        #expect(await eventually { bed.git.logCalls.count > before })
        // Not while the window isn't focused.
        focusWindow(false, of: pane)
        #expect(await bed.settled(pane))
        let after = bed.git.logCalls.count
        activate(id, of: pane)
        await quietPeriod()
        #expect(bed.git.logCalls.count == after)
    }

    /// F-6: another pane of the window active: not attended.
    @Test func windowRefocusDoesNothingWhenAnotherPaneIsActive() async throws {
        let (id, pane) = try await bed.openRepo()
        pane.settings.update { $0.autoRefreshOnFocus = true }
        #expect(bed.harness.runtime.panes.openPane(PaneRequest(type: "stand-in", placement: .tab(near: id))) != nil)
        let before = bed.git.logCalls.count
        focusWindow(true, of: pane)
        await quietPeriod()
        #expect(bed.git.logCalls.count == before)
    }

    /// F-7: a read already in flight isn't doubled by auto-refresh.
    @Test func autoRefreshIsSkippedWhileAReadIsInFlight() async throws {
        bed.git.setLog(history, root: "/repo")
        let (_, pane) = try #require(bed.open(config: ["cwd": "/repo"]))
        pane.settings.update { $0.autoRefreshOnFocus = true }
        #expect(pane.fetchPending)
        let before = bed.git.logCalls.count
        focusWindow(true, of: pane)
        #expect(bed.git.logCalls.count == before)
    }

    /// F-3: only the latest read commits.
    @Test func onlyTheLatestFirstPageReadCommits() async throws {
        let (_, pane) = try await bed.openRepo()
        bed.git.setLog([commit("x1", "first")], root: "/repo")
        pane.refresh()
        bed.git.setLog([commit("x2", "second")], root: "/repo")
        pane.refresh()
        #expect(await bed.settled(pane))
        #expect(pane.commits.map(\.subject) == ["second"])
    }
}

// MARK: - Checking out, and the menu

@MainActor
@Suite(.serialized) struct GitTreeCheckoutTests {
    let bed: GitTreeTestBed

    init() throws { bed = try GitTreeTestBed() }

    private var renderer: FakeRenderer { bed.harness.renderer }

    /// What checkout dialogs the user was shown.
    private var dialogs: [PaneDialog] { renderer.dialogs.map(\.dialog) }

    /// X-1
    @Test("right-click opens a context menu with Checkout then Copy SHA-1, and selects the row it opens on") func menu() async throws {
        let (_, pane) = try await bed.openRepo()
        pane.select(onFeature)
        bed.view(of: pane).list.openMenu(forRow: 0, at: CGPoint(x: 4, y: 5))
        let menu = try #require(renderer.contextMenus.first)
        #expect(menu.items.map(\.title) == ["Checkout", "Copy SHA-1"])
        #expect(menu.items.map(\.isEnabled) == [true, true], "Checkout is always offered: it asks when it must")
        #expect(pane.selectedHash == pane.graph.rows[0].commit.hash)
    }

    /// C-10, X-3
    @Test("neither trigger does anything on the synthetic uncommitted-changes row") func workingTreeRow() async throws {
        let (_, pane) = try await bed.openRepo(dirty: true)
        let before = bed.git.branchesAtCommitCalls.count
        let list = bed.view(of: pane).list
        list.openMenu(forRow: 0, at: .zero)
        await pane.checkout("")
        #expect(bed.git.branchesAtCommitCalls.count == before)
        #expect(renderer.contextMenus.isEmpty)
        #expect(pane.selectedHash == merge, "the menu didn't open on it either")
    }

    /// X-2
    @Test("right-click → Copy SHA-1 copies the full hash of the row right-clicked, not the one selected before") func copy() async throws {
        let (_, pane) = try await bed.openRepo()
        var copied: [String] = []
        bed.services.copiedOverride = { copied.append($0) }
        pane.select(onFeature)
        let menu = bed.view(of: pane).list.commitItems(for: onMain)
        let before = bed.git.branchesAtCommitCalls.count
        menu[1].action()
        #expect(copied == [onMain])
        #expect(bed.git.branchesAtCommitCalls.count == before)
    }

    /// C-2
    @Test("one local branch at the commit: checks out immediately with no dialog, and the pane refreshes to the new HEAD") func oneBranch()
        async throws
    {
        let (_, pane) = try await bed.openRepo()
        bed.git.branchesAtCommitAnswers[onFeature] = BranchesAtCommit(
            local: ["feature"], remotes: [], allLocalBranches: ["feature", "main"])
        await pane.checkout(onFeature)
        #expect(bed.git.checkoutCalls == [.branch(name: "feature")])
        #expect(await eventually { pane.head == .branch(name: "feature") })
        #expect(dialogs.isEmpty)
    }

    @Test("right-click → Checkout behaves the same as double-click for the one-branch case") func menuCheckout() async throws {
        let (_, pane) = try await bed.openRepo()
        bed.git.branchesAtCommitAnswers[onFeature] = BranchesAtCommit(local: ["feature"], remotes: [], allLocalBranches: ["feature"])
        let menu = bed.view(of: pane).list.commitItems(for: onFeature)
        menu[0].action()
        #expect(await eventually { bed.git.checkoutCalls == [.branch(name: "feature")] })
    }

    /// C-4
    @Test("several local branches at the commit: opens a choose dialog naming the commit, defaulted to the first in refname order")
    func severalBranches() async throws {
        let (_, pane) = try await bed.openRepo()
        bed.git.branchesAtCommitAnswers[onMain] = BranchesAtCommit(
            local: ["main", "stable"], remotes: [], allLocalBranches: ["main", "stable"])
        await pane.checkout(onMain)
        #expect(
            dialogs == [
                .choose(
                    PaneChoose(
                        title: "Checkout", message: "Several branches point at bbbbbbb — on main. Which one?",
                        options: ["main", "stable"], confirmLabel: "Checkout"))
            ])
        #expect(bed.git.checkoutCalls == [.branch(name: "main")], "the untouched dialog answers its first option")
    }

    @Test("picking a branch in the choose dialog checks that one out; Cancel leaves the repo untouched") func pickingABranch() async throws
    {
        let (_, pane) = try await bed.openRepo()
        bed.git.branchesAtCommitAnswers[onMain] = BranchesAtCommit(
            local: ["main", "stable"], remotes: [], allLocalBranches: ["main", "stable"])
        renderer.answerDialog = { _ in .chose(1) }
        await pane.checkout(onMain)
        #expect(bed.git.checkoutCalls == [.branch(name: "stable")])
        renderer.answerDialog = { _ in .chose(nil) }
        await pane.checkout(onMain)
        #expect(bed.git.checkoutCalls.count == 1)
    }

    /// C-3
    @Test("a lone remote-tracking branch is offered only when there is no local branch, and creates a tracking branch") func remote()
        async throws
    {
        let (_, pane) = try await bed.openRepo()
        let info = RemoteRefInfo(remote: "origin", name: "feature-x", ref: "origin/feature-x")
        bed.git.branchesAtCommitAnswers[onFeature] = BranchesAtCommit(local: [], remotes: [info], allLocalBranches: ["main"])
        await pane.checkout(onFeature)
        #expect(bed.git.checkoutCalls == [.remoteBranch(info)])
    }

    /// C-5
    @Test("no branch at all: opens a detached-HEAD confirm naming the commit; Cancel leaves the repo untouched") func noBranch()
        async throws
    {
        let (_, pane) = try await bed.openRepo()
        renderer.answerDialog = { _ in .confirmed(false) }
        await pane.checkout(root)
        #expect(
            dialogs == [
                .confirm(
                    PaneConfirm(
                        title: "Checkout",
                        message: "Checking out aaaaaaa — root commit will leave HEAD detached — it won't be on any branch. Continue?",
                        confirmLabel: "Checkout"))
            ])
        #expect(bed.git.checkoutCalls.isEmpty)
        #expect(pane.head == .branch(name: "main"))
        renderer.answerDialog = { _ in .confirmed(true) }
        await pane.checkout(root)
        #expect(bed.git.checkoutCalls == [.commit(hash: root)])
    }

    /// C-7
    @Test("a second checkout trigger while one is in flight is ignored outright — no second branchesAtCommit read either")
    func inFlight() async throws {
        let (_, pane) = try await bed.openRepo()
        bed.git.branchesAtCommitAnswers[onFeature] = BranchesAtCommit(local: ["feature"], remotes: [], allLocalBranches: ["feature"])
        bed.git.checkoutGate.isHeld = true
        let first = Task { await pane.checkout(onFeature) }
        #expect(await eventually { bed.git.checkoutCalls.count == 1 })
        let reads = bed.git.branchesAtCommitCalls.count
        await pane.checkout(onFeature)
        #expect(bed.git.checkoutCalls.count == 1)
        #expect(bed.git.branchesAtCommitCalls.count == reads)
        bed.git.checkoutGate.release()
        await first.value
        #expect(await eventually { pane.head == .branch(name: "feature") })
        bed.git.checkoutGate.isHeld = false
        bed.git.branchesAtCommitAnswers[onMain] = BranchesAtCommit(local: ["main"], remotes: [], allLocalBranches: ["main"])
        await pane.checkout(onMain)
        #expect(bed.git.checkoutCalls.count == 2)
    }

    /// C-6
    @Test("a failed checkout shows the full refusal text in a one-button alert, and still refreshes") func refusal() async throws {
        let (_, pane) = try await bed.openRepo()
        bed.git.branchesAtCommitAnswers[onFeature] = BranchesAtCommit(local: ["feature"], remotes: [], allLocalBranches: ["feature"])
        let refusal =
            "error: Your local changes to the following files would be overwritten by checkout:\n\tconflict.txt\nPlease commit your changes or stash them before you switch branches."
        bed.git.checkoutFailure = GitError(.failed(message: "error: local changes would be overwritten"), detail: refusal)
        let before = bed.git.logCalls.count
        await pane.checkout(onFeature)
        #expect(dialogs == [.alert(PaneAlert(title: "Checkout failed", message: refusal))])
        #expect(await eventually { bed.git.logCalls.count > before })
        // Without git's full text, the one-line reason.
        bed.git.checkoutFailure = GitError(.gitMissing)
        await pane.checkout(onFeature)
        #expect(dialogs.last == .alert(PaneAlert(title: "Checkout failed", message: "git isn’t installed, or isn’t on this app’s PATH.")))
    }

    /// C-8
    @Test("a failed ref read still surfaces the alert instead of failing silently, and a later checkout still works")
    func refReadFails() async throws {
        let (_, pane) = try await bed.openRepo()
        bed.git.branchesAtCommitFailure = .failed(message: "invoke failed")
        await pane.checkout(onFeature)
        #expect(dialogs == [.alert(PaneAlert(title: "Checkout failed", message: "invoke failed"))])
        bed.git.branchesAtCommitFailure = nil
        bed.git.branchesAtCommitAnswers[onFeature] = BranchesAtCommit(local: ["feature"], remotes: [], allLocalBranches: ["feature"])
        await pane.checkout(onFeature)
        #expect(bed.git.checkoutCalls == [.branch(name: "feature")])
        #expect(dialogs.count == 1)
    }

    /// C-9
    @Test("checking out in one pane refreshes another git tree pane pointed at the exact same directory") func refreshesSibling()
        async throws
    {
        let (a, first) = try await bed.openRepo()
        let second = try #require(bed.open(config: ["cwd": "/repo"], placement: .split(a, edge: .trailing)))
        #expect(await bed.settled(second.pane))
        bed.git.branchesAtCommitAnswers[onFeature] = BranchesAtCommit(local: ["feature"], remotes: [], allLocalBranches: ["feature"])
        await first.checkout(onFeature)
        #expect(await eventually { first.head == .branch(name: "feature") && second.pane.head == .branch(name: "feature") })
    }

    @Test("a git tree pane pointed at a different directory is not refreshed by another pane's checkout") func notOtherDirectory()
        async throws
    {
        let (a, first) = try await bed.openRepo()
        let other = try #require(bed.open(config: ["cwd": "/other-repo"], placement: .split(a, edge: .trailing)))
        #expect(await bed.settled(other.pane))
        let before = bed.git.logCalls.filter { $0 == "/other-repo" }.count
        bed.git.branchesAtCommitAnswers[onFeature] = BranchesAtCommit(local: ["feature"], remotes: [], allLocalBranches: ["feature"])
        await first.checkout(onFeature)
        #expect(bed.git.checkoutCalls == [.branch(name: "feature")])
        await quietPeriod()
        #expect(bed.git.logCalls.filter { $0 == "/other-repo" }.count == before)
    }
}

// MARK: - The divider

@MainActor
@Suite(.serialized) struct GitTreeDividerTests {
    let bed: GitTreeTestBed

    init() throws { bed = try GitTreeTestBed() }

    /// The body is laid out 500 tall.
    private func open(_ extra: [String: JSONValue] = [:]) async throws -> (id: PaneID, pane: GitTreePane, view: GitTreeView) {
        let (id, pane) = try await bed.openRepo(extra: extra)
        return (id, pane, bed.view(of: pane))
    }

    private func relayout(_ view: GitTreeView) {
        view.needsLayout = true
        view.layoutSubtreeIfNeeded()
    }

    /// V-1
    @Test("an untouched pane keeps the 60/40 it always had, details open") func untouched() async throws {
        let (id, pane, view) = try await open()
        #expect(pane.split == DetailSplit(fraction: 0.4, collapsed: false))
        let layout = view.computeLayout()
        #expect(layout.detail?.height == 200)
        #expect(!view.detailScroll.isHidden)
        #expect(bed.config(id)["detailFraction"] == nil)
    }

    /// V-2
    @Test("a saved split is what the pane opens with") func saved() async throws {
        let (_, _, view) = try await open(["detailFraction": 0.25])
        #expect(view.computeLayout().detail?.height == 125)
    }

    /// P-10
    @Test("a saved collapse shows only the history, and reads no detail it would not show") func savedCollapse() async throws {
        let before = bed.git.detailReads.count
        let (_, pane, view) = try await open(["detailCollapsed": true])
        #expect(view.computeLayout().dividerCollapsed)
        #expect(view.detailScroll.isHidden)
        press(.downArrow, on: view.list)
        await quietPeriod()
        #expect(bed.git.detailReads.count == before)
        #expect(pane.selectedHash == onFeature)
    }

    /// V-3
    @Test("dragging it previews every move, and saves the split on release") func drag() async throws {
        let (id, pane, view) = try await open()
        #expect(view.divider.begin(atY: 300))
        view.divider.move(toY: 200)
        #expect(pane.split.fraction == 0.6)
        #expect(bed.config(id)["detailFraction"] == nil)
        view.divider.finish()
        #expect(bed.config(id)["detailFraction"] == 0.6)
        #expect(bed.config(id)["detailCollapsed"] == false)
        #expect(pane.split.fraction == 0.6)
    }

    /// V-4, V-5
    @Test("dragging it to the bottom collapses the details, and back up reopens them on the selected commit") func collapseAndReopen()
        async throws
    {
        let (id, pane, view) = try await open()
        view.divider.begin(atY: 300)
        view.divider.move(toY: 490)
        view.divider.finish()
        relayout(view)
        #expect(view.detailScroll.isHidden)
        #expect(view.computeLayout().dividerCollapsed)
        #expect(bed.config(id)["detailCollapsed"] == true)

        view.divider.begin(atY: 496)
        view.divider.move(toY: 296)
        view.divider.finish()
        relayout(view)
        #expect(!view.computeLayout().dividerCollapsed)
        #expect(bed.config(id)["detailFraction"] == 0.416)
        #expect(bed.config(id)["detailCollapsed"] == false)
        #expect(await eventually { pane.detail?.message == "merge feature" })
    }

    @Test("a press that moves nothing saves nothing") func stillPress() async throws {
        let (id, _, view) = try await open()
        view.divider.begin(atY: 300)
        view.divider.finish()
        #expect(bed.config(id)["detailFraction"] == nil)
        #expect(bed.config(id)["detailCollapsed"] == nil)
    }

    /// V-6: the release is the last shown frame; later moves do nothing.
    @Test("a release it never saw ends the drag where it was last shown") func unseenRelease() async throws {
        let (id, pane, view) = try await open()
        view.divider.begin(atY: 300)
        view.divider.move(toY: 250)
        view.divider.finish()
        #expect(bed.config(id)["detailFraction"] == 0.5)
        view.divider.move(toY: 100)
        #expect(pane.split.fraction == 0.5)
    }

    // "a press a split separator already claimed is left to it" (V-7): core's
    // split separators sit above the pane's view and take the press before it
    // reaches the divider; there's nothing in the plugin to test.
}

// MARK: - Opening: where a new pane looks

@MainActor
@Suite(.serialized) struct GitTreeInheritanceTests {
    let bed: GitTreeTestBed
    let offered: Ref<URL?>

    init() throws {
        let offered = Ref<URL?>(URL(filePath: "/origin/repo", directoryHint: .isDirectory))
        self.offered = offered
        let standIn = TestSupport.candidate(TestSupport.manifest("stand-in", contentTypes: ["stand-in", "stand-in.plain"])) { context in
            context.register(
                ContentTypeContribution(id: "stand-in", displayName: "Stand-in", icon: .symbol("square")) { pane in
                    pane.offer(.workingDirectory, offered.value)
                    return StubPane(config: pane.initialConfig)
                })
            context.register(TestSupport.contentType("stand-in.plain"))
        }
        bed = try GitTreeTestBed(alongside: [standIn])
        bed.git.defaultDirectoryAnswer = "/fallback/default"
        bed.git.setLog(history, root: "/fallback/default")
    }

    private func openFrom(_ type: ContentTypeID) throws -> (id: PaneID, pane: GitTreePane) {
        let origin = try #require(bed.harness.runtime.panes.openPane(PaneRequest(type: type)))
        return try #require(bed.open(placement: .tab(near: origin), origin: origin))
    }

    /// D-2
    @Test("a git tree created from a pane that exposes a directory opens on it") func inherits() async throws {
        let (id, pane) = try openFrom("stand-in")
        #expect(await eventually { bed.git.logCalls.contains("/origin/repo") })
        #expect(bed.config(id)["cwd"] == "/origin/repo")
        #expect(await bed.settled(pane))
        #expect(!bed.git.logCalls.contains("/fallback/default"))
    }

    /// D-3
    @Test("an origin that exposes no directory falls back to the default, not to a blank pane") func noDirectory() async throws {
        let (id, _) = try openFrom("stand-in.plain")
        #expect(await eventually { bed.git.logCalls.contains("/fallback/default") })
        #expect(bed.config(id)["cwd"] == "/fallback/default")
    }

    @Test("an origin that exposes a directory only sometimes still degrades cleanly") func sometimes() async throws {
        offered.value = nil
        let (id, _) = try openFrom("stand-in")
        #expect(await eventually { bed.config(id)["cwd"] == "/fallback/default" })
    }

    @Test("a git tree created from an empty pane falls through to its default directory") func fromNothing() async throws {
        let (id, pane) = try #require(bed.open())
        #expect(await eventually { bed.config(id)["cwd"] == "/fallback/default" })
        #expect(await bed.settled(pane))
        if case .failure = pane.log { Issue.record("expected the history, not a notice") }
    }

    /// D-6
    @Test("the git tree offers its configured directory") func offersItsDirectory() async throws {
        let (id, _) = try await bed.openRepo(cwd: "/repo")
        #expect(bed.harness.runtime.panes.capability(.workingDirectory, of: id)?.path == "/repo")
        bed.git.defaultDirectoryAnswer = "/slow"
        let (fresh, _) = try #require(bed.open())
        #expect(bed.harness.runtime.panes.capability(.workingDirectory, of: fresh) == nil, "none while the default is pending")
    }

    @Test func theInitialConfigCarriesTheOriginsDirectory() throws {
        let contribution = try #require(bed.harness.runtime.registry.contribution(to: .contentTypes, id: "git-tree"))
        #expect(contribution.value.initialConfig(PaneCreation(origin: nil)) == .emptyObject)
        let origin = try #require(bed.harness.runtime.panes.openPane(PaneRequest(type: "stand-in")))
        #expect(contribution.value.initialConfig(PaneCreation(origin: origin)) == ["cwd": "/origin/repo"])
    }
}

// MARK: - Expanded files

private let fileA = ChangedFile(path: "src/a.swift", insertions: 1, deletions: 2)
private let fileB = ChangedFile(path: "README.md", insertions: 1, deletions: 0)

/// A 30-line file with lines 15 and 16 changed to one: 9 unchanged lines
/// hidden before the hunk and 9 after, the old file's lines there to show.
private func thirtyLineDiff() -> FileDiff {
    var diff = Git.parsePatch(
        "@@ -10,12 +10,11 @@\n" + (10...14).map { " line \($0)\n" }.joined() + "-line 15\n-line 16\n+line 15-16\n"
            + (17...21).map { " line \($0)\n" }.joined())
    diff.base = (1...30).map { "line \($0)" }
    return diff
}

/// A one-line file with a line added: nothing hidden, no old file.
private let smallDiff = Git.parsePatch("@@ -1 +1,2 @@\n x\n+y\n")

@MainActor
@Suite(.serialized) struct GitTreeFileDiffTests {
    let bed: GitTreeTestBed

    init() throws { bed = try GitTreeTestBed() }

    private func detail(_ hash: String, files: [ChangedFile]) -> CommitDetail {
        CommitDetail(
            hash: hash, parents: hash == uncommittedChangesHash ? [merge] : [onMain, onFeature], author: "Ann",
            authorEmail: "ann@example.com", date: "2026-01-02T03:04:05Z", refs: [],
            message: hash == uncommittedChangesHash ? "Uncommitted changes" : "merge feature", files: files, filesTruncated: false)
    }

    /// A pane on `cwd` (root `/repo`) whose newest commit, selected, lists
    /// `fileA` and `fileB`, each with a diff.
    private func openWithFiles(cwd: String = "/repo", root: String = "/repo") async throws -> GitTreePane {
        bed.git.details[merge] = detail(merge, files: [fileA, fileB])
        bed.git.fileDiffs[merge] = [fileA.path: thirtyLineDiff(), fileB.path: smallDiff]
        bed.git.setLog(history, root: root)
        let opened = try #require(bed.open(config: .object(["cwd": .string(cwd)])))
        #expect(await bed.settled(opened.pane))
        #expect(opened.pane.detail?.hash == merge)
        return opened.pane
    }

    private func read(_ pane: GitTreePane, _ path: String) async -> Bool {
        await eventually { if case .read = pane.expandedFiles[path]?.diff { true } else { false } }
    }

    /// P-11, P-12
    @Test("clicking a file row opens its diff, read from the repository's root; clicking again closes it") func toggle() async throws {
        let pane = try await openWithFiles(cwd: "/repo/sub")
        pane.toggleFile(fileA)
        #expect(await read(pane, fileA.path))
        let asked = try #require(bed.git.fileDiffReads.last)
        #expect(asked.root == "/repo", "pathspecs and the files' paths are the root's")
        #expect(asked.hash == merge && asked.file == fileA)
        #expect(pane.expandedFiles[fileA.path]?.shown == thirtyLineDiff())
        pane.toggleFile(fileA)
        #expect(pane.expandedFiles.isEmpty)
    }

    /// P-11
    @Test("several files stay open at once") func several() async throws {
        let pane = try await openWithFiles()
        pane.toggleFile(fileA)
        pane.toggleFile(fileB)
        #expect(await read(pane, fileA.path))
        #expect(await read(pane, fileB.path))
        #expect(pane.expandedFiles.keys.sorted() == [fileB.path, fileA.path].sorted())
    }

    /// P-13
    @Test("a file being read says so in its box; one that failed shows why") func readingAndFailed() async throws {
        let pane = try await openWithFiles()
        let view = bed.view(of: pane)
        bed.git.fileDiffGate.isHeld = true
        pane.toggleFile(fileA)
        #expect(await eventually { bed.git.fileDiffReads.count == 1 })
        #expect(view.detail.layout(width: 600).runs.map(\.text).contains("Reading diff…"))
        #expect(view.detail.layout(width: 600).files[0].diff?.rows.isEmpty == true)
        bed.git.fileDiffGate.isHeld = false
        bed.git.fileDiffGate.release()
        #expect(await read(pane, fileA.path))
        #expect(!view.detail.layout(width: 600).runs.map(\.text).contains("Reading diff…"))

        bed.git.fileDiffs[merge]?[fileB.path] = nil
        pane.toggleFile(fileB)
        #expect(await eventually { pane.expandedFiles[fileB.path]?.diff == .failed("no diff for README.md") })
        #expect(view.detail.layout(width: 600).runs.map(\.text).contains("no diff for README.md"))
    }

    /// P-17
    @Test("another selection closes every open file, and a read still under way lands nowhere") func selectionCloses() async throws {
        let pane = try await openWithFiles()
        pane.toggleFile(fileB)
        #expect(await read(pane, fileB.path))
        bed.git.fileDiffGate.isHeld = true
        pane.toggleFile(fileA)
        #expect(await eventually { bed.git.fileDiffReads.count == 2 })
        pane.select(onMain)
        #expect(pane.expandedFiles.isEmpty)
        bed.git.fileDiffGate.isHeld = false
        bed.git.fileDiffGate.release()
        await quietPeriod()
        #expect(pane.expandedFiles.isEmpty)
        pane.select(merge)
        #expect(await eventually { pane.detail?.hash == merge })
        #expect(pane.expandedFiles.isEmpty, "coming back opens nothing by itself")
    }

    /// P-17
    @Test("a commit's open files stay open across a refresh, not read again") func commitRefreshKeeps() async throws {
        let pane = try await openWithFiles()
        pane.toggleFile(fileA)
        #expect(await read(pane, fileA.path))
        pane.revealGap(fileA.path, 0)
        let reads = bed.git.fileDiffReads.count
        pane.refresh()
        #expect(await bed.settled(pane))
        await quietPeriod()
        #expect(bed.git.fileDiffReads.count == reads)
        #expect(pane.expandedFiles[fileA.path]?.revealed == [0])
    }

    /// P-17, P-9
    @Test("⌘R on the working tree reads its open files again, the old diff shown meanwhile, and closes those it no longer lists")
    func workingTreeRefresh() async throws {
        bed.git.workingTreeDetail = detail(uncommittedChangesHash, files: [fileA, fileB])
        bed.git.fileDiffs[uncommittedChangesHash] = [fileA.path: thirtyLineDiff(), fileB.path: smallDiff]
        let (_, pane) = try await bed.openRepo(dirty: true)
        pane.select(uncommittedChangesHash)
        #expect(await eventually { pane.detail?.hash == uncommittedChangesHash })
        pane.toggleFile(fileA)
        pane.toggleFile(fileB)
        #expect(await read(pane, fileA.path))
        #expect(await read(pane, fileB.path))
        pane.revealGap(fileA.path, 0)

        bed.git.workingTreeDetail.files = [fileA]
        bed.git.fileDiffGate.isHeld = true
        pane.refresh()
        #expect(await eventually { pane.expandedFiles[fileB.path] == nil })
        #expect(pane.expandedFiles[fileA.path]?.diff == .reading(previous: thirtyLineDiff()))
        #expect(pane.expandedFiles[fileA.path]?.shown == thirtyLineDiff(), "the old diff stays up")
        bed.git.fileDiffGate.isHeld = false
        bed.git.fileDiffGate.release()
        #expect(await read(pane, fileA.path))
        #expect(pane.expandedFiles[fileA.path]?.revealed == [], "a partly open file closes its runs: they may have moved")

        pane.toggleFullFile(fileA.path)
        pane.refresh()
        #expect(await eventually { bed.git.fileDiffReads.count == 4 })
        #expect(await read(pane, fileA.path))
        #expect(pane.expandedFiles[fileA.path]?.showsFullFile == true, "everything open stays open")
    }

    /// P-15, P-16
    @Test("a hidden run opens on a click; Show full file opens them all and Show changes only closes them") func hiddenRuns() async throws {
        let pane = try await openWithFiles()
        let view = bed.view(of: pane)
        pane.toggleFile(fileA)
        pane.toggleFile(fileB)
        #expect(await read(pane, fileA.path))
        #expect(await read(pane, fileB.path))
        var block = try #require(view.detail.layout(width: 600).files[0].diff)
        #expect(block.rows.first?.kind == .hidden)
        #expect(block.rows.first?.label == "9 unchanged lines")
        #expect(block.rows.last?.label == "9 unchanged lines")
        #expect(block.fullFile?.label == "Show full file")
        let hidden = try #require(block.rows.first?.rect)
        let point = CGPoint(x: hidden.midX, y: hidden.midY + view.detail.fractionalOffset)
        #expect(view.detail.target(at: point) == .gap(file: 0, row: 0))
        #expect(view.detail.fileIndex(at: point) == nil, "a right-click on the diff opens no menu")
        view.detail.activate(.gap(file: 0, row: 0))
        #expect(pane.expandedFiles[fileA.path]?.revealed == [0])
        block = try #require(view.detail.layout(width: 600).files[0].diff)
        #expect(block.rows.first?.kind == .context)
        #expect(block.rows.filter { $0.kind == .hidden }.count == 1)

        view.detail.activate(.fullFile(0))
        block = try #require(view.detail.layout(width: 600).files[0].diff)
        #expect(block.rows.allSatisfy { $0.kind != .hidden })
        #expect(block.rows.count == 9 + 13 + 9)
        #expect(block.fullFile?.label == "Show changes only")
        view.detail.activate(.fullFile(0))
        #expect(pane.expandedFiles[fileA.path]?.revealed == [])
        #expect(view.detail.layout(width: 600).files[0].diff?.rows.filter { $0.kind == .hidden }.count == 2)

        #expect(view.detail.layout(width: 600).files[1].diff?.fullFile == nil, "nothing hidden to show: no Show full file")
    }

    /// P-11, L-27, L-29, L-30
    @Test("an open file's diff sits under its row and pushes the rows after it down; the chevron's column moves the stat") func layout()
        async throws
    {
        let pane = try await openWithFiles()
        let closed = CommitDetailLayout(detail: pane.detail, width: 600)
        let row = closed.files[0].row
        #expect(closed.files[0].disclosure == CGRect(x: 10, y: row.minY, width: 14, height: 17))
        #expect(closed.files[0].stat.minX == 24)
        #expect(!closed.files[0].expanded)
        pane.toggleFile(fileA)
        #expect(await read(pane, fileA.path))
        let open = CommitDetailLayout(detail: pane.detail, expanded: pane.expandedFiles, width: 600)
        let diff = try #require(open.files[0].diff)
        #expect(open.files[0].expanded)
        #expect(diff.box.minY == open.files[0].row.maxY + 2)
        #expect(diff.box.minX == 10 && diff.box.width == 580)
        #expect(open.files[1].row.minY == diff.box.maxY + 6)
        #expect(open.height > closed.height)
        let removed = try #require(diff.rows.first { $0.kind == .removed })
        #expect(removed.old != nil && removed.new == nil)
        let added = try #require(diff.rows.first { $0.kind == .added })
        #expect(added.old == nil && added.new != nil)
        #expect(removed.rect.height == 15)
    }

    /// P-18
    @Test("a renamed file's row reads as git prints it") func renameRow() async throws {
        let renamed = ChangedFile(path: "src/new/a.txt", insertions: 1, deletions: 1, oldPath: "src/old/a.txt")
        let layout = CommitDetailLayout(detail: detail(merge, files: [renamed]), width: 600)
        #expect(layout.runs.map(\.text).contains("src/{old => new}/a.txt"))
    }

    /// P-11, S-6
    @Test("a click on a file row opens it and leaves the keyboard on the list") func clickKeepsTheKeyboard() async throws {
        let pane = try await openWithFiles()
        let view = bed.view(of: pane)
        let window = hostWindow(view)
        view.focusList()
        let row = view.detail.layout(width: view.detail.bounds.width).files[0].row
        let point = CGPoint(x: 300, y: row.midY + view.detail.fractionalOffset)
        let event = try #require(
            NSEvent.mouseEvent(
                with: .leftMouseDown, location: view.detail.convert(point, to: nil), modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        view.detail.mouseDown(with: event)
        #expect(pane.expandedFiles[fileA.path] != nil)
        #expect(window.firstResponder === view.list)
    }

    /// X-4, X-5
    @Test("right-click on a file row: Show in Finder, then Open, on the file under the root as it is now; both disabled when it's gone")
    func menu() async throws {
        let dir = TestTemporary.directory("git-tree-menu").path
        try FileManager.default.createDirectory(atPath: dir + "/src", withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: dir + "/src/a.swift", contents: Data())
        let pane = try await openWithFiles(cwd: dir, root: dir)
        var actions: [(action: GitTreeServices.FileAction, url: URL)] = []
        bed.services.fileActionOverride = { actions.append(($0, $1)) }
        let view = bed.view(of: pane)
        view.detail.openMenu(forFile: 0, at: CGPoint(x: 4, y: 5))
        let menu = try #require(bed.harness.renderer.contextMenus.first)
        #expect(menu.items.map(\.title) == ["Show in Finder", "Open"])
        #expect(menu.items.map(\.isEnabled) == [true, true])
        menu.items[0].action()
        menu.items[1].action()
        #expect(actions.map(\.action) == [.reveal, .open])
        #expect(actions.map(\.url.path) == [dir + "/src/a.swift", dir + "/src/a.swift"])

        let gone = view.detail.fileItems(for: fileB)
        #expect(gone.map(\.title) == ["Show in Finder", "Open"])
        #expect(gone.map(\.isEnabled) == [false, false], "README.md isn't on disk")
        gone[0].action()
        gone[1].action()
        #expect(actions.count == 2)
    }
}

// MARK: - Input helpers

/// A keyDown for a cursor key, as AppKit makes it.
@MainActor
func keyEvent(_ key: NSEvent.SpecialKey, window: NSWindow? = nil) -> NSEvent {
    let character = String(Character(Unicode.Scalar(UInt32(key.rawValue))!))
    return NSEvent.keyEvent(
        with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window?.windowNumber ?? 0, context: nil,
        characters: character, charactersIgnoringModifiers: character, isARepeat: false, keyCode: 0)!
}

@MainActor
func press(_ key: NSEvent.SpecialKey, on list: CommitListView) {
    list.keyDown(with: keyEvent(key))
}

/// A never-shown window holding `view`.
@MainActor
func hostWindow(_ view: NSView) -> NSWindow {
    let window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = view
    return window
}

/// A never-shown window holding a git tree under its header title, as core lays a pane out.
@MainActor
func hostWindow(_ view: GitTreeView) -> NSWindow {
    let bar = view.toolbar
    let content = GitFlippedView(frame: CGRect(x: 0, y: 0, width: view.frame.width, height: 24 + view.frame.height))
    bar.frame = CGRect(x: 0, y: 0, width: view.frame.width, height: 24)
    view.frame.origin.y = 24
    content.addSubview(bar)
    content.addSubview(view)
    return hostWindow(content)
}
