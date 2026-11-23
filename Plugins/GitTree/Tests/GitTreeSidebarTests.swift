import AppKit
import TabsPluginSDK
import Testing

@testable import TabsCore

// The branches sidebar against scripted git: the pane's state, the outline
// it shows, and the divider beside it. Case ids are docs/GIT-TREE.md's.

private let tip = "ttttttt0000000000000000000000000000000a"
private let onFeature = "fffffff0000000000000000000000000000000a"
private let base = "bbbbbbb0000000000000000000000000000000a"
/// A commit no page has read: past Load more, or outside the branch scope.
private let unread = "uuuuuuu0000000000000000000000000000000a"

private func commit(_ hash: String, _ subject: String, _ parents: [String] = [], _ refs: [String] = []) -> Commit {
    Commit(hash: hash, parents: parents, author: "Ann", date: "2026-01-02T03:04:05Z", refs: refs, subject: subject)
}

private let history = [
    commit(tip, "on main", [base], ["HEAD", "main", "origin/main"]),
    commit(onFeature, "on feature", [base], ["my/feature"]),
    commit(base, "base", [], ["tag: v1.0"]),
]

private func ref(_ refname: String, _ hash: String, remotes: [String] = ["origin"]) -> GitRef {
    Git.ref(refname: refname, hash: hash, remoteNames: remotes)!
}

/// Local main and my/feature, origin's main, my/feature and old/gone (at a
/// commit not read), tag v1.0.
private let refs = GitRefs(
    remotes: ["origin"],
    refs: [
        ref("refs/heads/main", tip), ref("refs/heads/my/feature", onFeature), ref("refs/remotes/origin/main", tip),
        ref("refs/remotes/origin/my/feature", onFeature), ref("refs/remotes/origin/old/gone", unread), ref("refs/tags/v1.0", base),
    ])

extension GitTreeTestBed {
    /// A repository with `refs` in its sidebar.
    func openWithRefs(_ answer: GitRefs = refs, extra: [String: JSONValue] = [:]) async throws -> (id: PaneID, pane: GitTreePane) {
        git.refsAnswer = answer
        return try await openRepo(history, extra: extra)
    }
}

extension BranchSidebarView {
    /// The outline's row showing `id`, opening what it's under.
    func row(_ id: String) -> Int {
        shownRows.first { $0.item.node.id == id }?.row ?? -1
    }
}

// MARK: - The tree and its reads

@MainActor
@Suite(.serialized) struct GitTreeSidebarTests {
    let bed: GitTreeTestBed

    init() throws { bed = try GitTreeTestBed() }

    /// BR-1
    @Test("sits left of the list, as tall as it, with the details the body's width below both") func layout() async throws {
        let (_, pane) = try await bed.openWithRefs()
        let view = bed.view(of: pane)
        let layout = view.computeLayout()
        #expect(layout.sidebar == CGRect(x: 0, y: 0, width: 200, height: 300))
        #expect(layout.list == CGRect(x: 200, y: 0, width: 400, height: 300))
        #expect(layout.detail == CGRect(x: 0, y: 300, width: 600, height: 200))
        #expect(view.sidebar.frame == CGRect(x: 0, y: 0, width: 199, height: 300), "its right border is the last point")
        #expect(view.listScroll.frame == CGRect(x: 200, y: 0, width: 400, height: 300))
        #expect(!view.sidebar.isHidden)
    }

    /// BR-1
    @Test("is hidden while the history is read, and on a failure") func onlyWithTheList() async throws {
        bed.git.failure = .notARepo(path: "/repo")
        let (_, pane) = try #require(bed.open(config: ["cwd": "/repo"]))
        let view = bed.view(of: pane)
        #expect(view.sidebar.isHidden)
        #expect(await eventually { pane.log != nil })
        #expect(view.sidebar.isHidden && view.sidebarDivider.isHidden)
        #expect(view.computeLayout().sidebar == nil)
    }

    /// BR-2, BR-3, BR-9: sources open, folders closed.
    @Test("lists each source with its refs' names split into folders, the outline showing the same rows") func tree() async throws {
        let (_, pane) = try await bed.openWithRefs()
        #expect(pane.testState["branches"] == ["Local", "  main", "  my", "origin", "  main", "  my", "  old", "Tags", "  v1.0"])
        let view = bed.view(of: pane)
        #expect(view.sidebar.shownRows.map { .string($0.item.node.id) } == pane.testState["branchRows"]?.arrayElements)
    }

    /// BR-6
    @Test("sets HEAD's branch semibold with its icon in the accent, and follows HEAD") func headBranch() async throws {
        let (_, pane) = try await bed.openWithRefs()
        let view = bed.view(of: pane)
        func cell(_ id: String) -> BranchCellView? {
            view.sidebar.outline.view(atColumn: 0, row: view.sidebar.row(id), makeIfNecessary: true) as? BranchCellView
        }
        #expect(cell("refs/heads/main")?.label.font == BranchCellView.currentFont)
        #expect(cell("refs/heads/main")?.icon.contentTintColor == pane.pane.theme.accent)
        #expect(cell("refs/remotes/origin/main")?.label.font == BranchCellView.font, "only the local branch HEAD is on")
        pane.setBranchExpanded("local:my/", true)
        await pane.checkoutBranch("refs/heads/my/feature")
        #expect(await eventually { pane.head == .branch(name: "my/feature") })
        #expect(await eventually { cell("refs/heads/my/feature")?.label.font == BranchCellView.currentFont })
        #expect(cell("refs/heads/main")?.label.font == BranchCellView.font)
    }

    /// BR-7
    @Test("reads the refs with every first page, never with Load more") func readsWithTheFirstPage() async throws {
        bed.git.refsAnswer = refs
        let (_, pane) = try await bed.openRepo(history, hasMore: true)
        #expect(bed.git.refsCalls == ["/repo"])
        pane.refresh()
        #expect(await bed.settled(pane))
        #expect(bed.git.refsCalls.count == 2)
        pane.loadMore()
        await quietPeriod()
        #expect(bed.git.refsCalls.count == 2)
        pane.chooseBranchScope(.local)
        #expect(await bed.settled(pane))
        #expect(bed.git.refsCalls.count == 3)
    }

    /// BR-7: a directory's sidebar never shows another's refs.
    @Test("empties the sidebar while another directory's refs are read") func directoryChange() async throws {
        let (_, pane) = try await bed.openWithRefs()
        bed.git.refsGate.isHeld = true
        pane.chooseDirectory("/other")
        #expect(pane.refs == nil)
        #expect(pane.branchTree.isEmpty)
        #expect(await eventually { bed.git.refsCalls.last == "/other" })
        bed.git.refsGate.isHeld = false
        bed.git.refsGate.release()
        #expect(await eventually { pane.refs != nil })
    }

    /// BR-8
    @Test("a failed read says so in place of the tree, and the history stands") func failedRead() async throws {
        bed.git.refsFailure = .failed(message: "fatal: bad refs")
        let (_, pane) = try await bed.openRepo(history)
        let view = bed.view(of: pane)
        #expect(pane.commits.count == 3)
        #expect(view.sidebar.note == "fatal: bad refs")
        #expect(view.sidebar.scroll.isHidden)
        #expect(pane.testState["branchesNotice"] == "fatal: bad refs")
    }

    /// BR-9
    @Test("opening a folder or closing a source in the outline is saved, and shown again after a re-read") func expansion() async throws {
        let (id, pane) = try await bed.openWithRefs()
        let sidebar = bed.view(of: pane).sidebar
        let folder = try #require(sidebar.shownRows.first { $0.item.node.id == "remote:origin:my/" }?.item)
        sidebar.outline.expandItem(folder)
        #expect(bed.config(id)["branchesExpandedFolders"] == ["remote:origin:my/"])
        let tags = try #require(sidebar.shownRows.first { $0.item.node.id == "tags" }?.item)
        sidebar.outline.collapseItem(tags)
        #expect(bed.config(id)["branchesCollapsedSources"] == ["tags"])
        #expect(pane.testState["branches"] == ["Local", "  main", "  my", "origin", "  main", "  my", "    feature", "  old", "Tags"])
        pane.refresh()
        #expect(await bed.settled(pane))
        #expect(sidebar.shownRows.map(\.item.node.title) == ["Local", "main", "my", "origin", "main", "my", "feature", "old", "Tags"])
        let shown = try #require(sidebar.shownRows.first { $0.item.node.id == "remote:origin:my/" }?.item)
        #expect(shown === folder, "a re-read finding the same refs keeps the rows")
        sidebar.outline.collapseItem(shown)
        #expect(bed.config(id)["branchesExpandedFolders"] == nil, "a key holding nothing goes")
    }

    /// BR-9: a relaunch opens the tree as it was left.
    @Test("opens as the config says, dropping on the next save what the tree no longer has") func savedExpansion() async throws {
        let (id, pane) = try await bed.openWithRefs(extra: [
            "branchesExpandedFolders": ["local:my/", "local:deleted/"], "branchesCollapsedSources": ["remote:origin"],
        ])
        let sidebar = bed.view(of: pane).sidebar
        #expect(sidebar.shownRows.map(\.item.node.title) == ["Local", "main", "my", "feature", "origin", "Tags", "v1.0"])
        pane.setBranchExpanded("tags", false)
        #expect(bed.config(id)["branchesExpandedFolders"] == ["local:my/"])
    }

    /// BR-10
    @Test("selecting a branch selects its tip in the history, and the details follow") func selectsTip() async throws {
        let (_, pane) = try await bed.openWithRefs()
        let sidebar = bed.view(of: pane).sidebar
        pane.setBranchExpanded("local:my/", true)
        sidebar.outline.selectRowIndexes([sidebar.row("refs/heads/my/feature")], byExtendingSelection: false)
        #expect(pane.selectedBranchID == "refs/heads/my/feature")
        #expect(pane.selectedHash == onFeature)
        #expect(await eventually { pane.detail?.hash == onFeature })
        sidebar.outline.selectRowIndexes([sidebar.row("refs/tags/v1.0")], byExtendingSelection: false)
        #expect(pane.selectedHash == base)
    }

    /// BR-10
    @Test("a tip the history hasn't read, and a folder, select only the sidebar's row") func selectsOnlyTheRow() async throws {
        let (_, pane) = try await bed.openWithRefs()
        pane.setBranchExpanded("remote:origin:old/", true)
        pane.selectBranch("refs/remotes/origin/old/gone")
        #expect(pane.selectedBranchID == "refs/remotes/origin/old/gone")
        #expect(pane.selectedHash == tip)
        pane.selectBranch("local:my/")
        #expect(pane.selectedHash == tip)
        let sidebar = bed.view(of: pane).sidebar
        #expect(sidebar.outline.selectedRow == sidebar.row("local:my/"))
    }

    /// BR-10
    @Test("scrolls the tip to the middle of the list unless it's in full view") func reveal() async throws {
        let long = (0..<100).map { index in
            commit(
                String(format: "%07d", index) + String(repeating: "0", count: 33), "commit \(index)",
                index < 99 ? [String(format: "%07d", index + 1) + String(repeating: "0", count: 33)] : [])
        }
        bed.git.refsAnswer = GitRefs(remotes: [], refs: [ref("refs/heads/deep", long[80].hash, remotes: [])])
        let (_, pane) = try await bed.openRepo(long)
        let view = bed.view(of: pane)
        pane.selectBranch("refs/heads/deep")
        let row = view.list.rowRect(80)
        #expect(view.list.visibleRect.contains(row))
        #expect(abs(view.list.visibleRect.midY - row.midY) < 1)
    }

    /// BR-14
    @Test("pane activation leaves the keyboard in the sidebar if it has it, else gives it to the list") func focus() async throws {
        let (_, pane) = try await bed.openWithRefs()
        let view = bed.view(of: pane)
        let window = hostWindow(view)
        window.makeFirstResponder(view.sidebar.outline)
        pane.focus()
        #expect(window.firstResponder === view.sidebar.outline)
        #expect(view.sidebar.outline.focusRingType == .none)
        window.makeFirstResponder(nil)
        pane.focus()
        #expect(window.firstResponder === view.list)
    }

    /// BR-11
    @Test("the sidebar's selection goes when the list's is moved, or its row is gone after a re-read") func selectionClears() async throws {
        let (_, pane) = try await bed.openWithRefs()
        let view = bed.view(of: pane)
        pane.selectBranch("refs/tags/v1.0")
        press(.upArrow, on: view.list)
        #expect(pane.selectedBranchID == nil)
        #expect(view.sidebar.outline.selectedRow == -1)
        pane.selectBranch("refs/tags/v1.0")
        bed.git.refsAnswer = GitRefs(remotes: ["origin"], refs: [ref("refs/heads/main", tip)])
        pane.refresh()
        #expect(await bed.settled(pane))
        #expect(pane.selectedBranchID == nil)
        #expect(pane.selectedHash == base, "the history's selection stays")
    }
}

// MARK: - Checking out and the menu

@MainActor
@Suite(.serialized) struct GitTreeSidebarCheckoutTests {
    let bed: GitTreeTestBed

    init() throws { bed = try GitTreeTestBed() }

    private var renderer: FakeRenderer { bed.harness.renderer }
    private var dialogs: [PaneDialog] { renderer.dialogs.map(\.dialog) }

    /// The pane with every folder open, so each ref has a row.
    private func open() async throws -> (pane: GitTreePane, sidebar: BranchSidebarView) {
        let (_, pane) = try await bed.openWithRefs(extra: [
            "branchesExpandedFolders": ["local:my/", "remote:origin:my/", "remote:origin:old/"]
        ])
        return (pane, bed.view(of: pane).sidebar)
    }

    /// BR-12
    @Test("a double-click on a local branch switches to it, and the pane refreshes to the new HEAD") func local() async throws {
        let (pane, sidebar) = try await open()
        sidebar.activate(row: sidebar.row("refs/heads/my/feature"))
        #expect(await eventually { bed.git.checkoutCalls == [.branch(name: "my/feature")] })
        #expect(await eventually { pane.head == .branch(name: "my/feature") })
        #expect(dialogs.isEmpty)
    }

    /// BR-12
    @Test("nothing to do on HEAD's own branch") func headBranch() async throws {
        let (pane, _) = try await open()
        await pane.checkoutBranch("refs/heads/main")
        #expect(bed.git.checkoutCalls.isEmpty)
    }

    /// BR-12
    @Test("a remote-tracking branch is its local branch when one has its name, read fresh, else a new branch tracking it") func remote()
        async throws
    {
        let (pane, _) = try await open()
        let before = bed.git.refsCalls.count
        // Held at the switch: the refresh after it reads the refs too.
        bed.git.checkoutGate.isHeld = true
        let first = Task { await pane.checkoutBranch("refs/remotes/origin/my/feature") }
        #expect(await eventually { bed.git.checkoutCalls.count == 1 })
        #expect(bed.git.refsCalls.count == before + 1, "the local branches are read fresh")
        bed.git.checkoutGate.isHeld = false
        bed.git.checkoutGate.release()
        await first.value
        await pane.checkoutBranch("refs/remotes/origin/old/gone")
        #expect(
            bed.git.checkoutCalls == [
                .branch(name: "my/feature"),
                .remoteBranch(RemoteRefInfo(remote: "origin", name: "old/gone", ref: "origin/old/gone")),
            ])
    }

    /// BR-12, C-8
    @Test("a failed fresh read is an alert, and checks nothing out") func remoteReadFails() async throws {
        let (pane, _) = try await open()
        bed.git.refsFailure = .failed(message: "fatal: no refs")
        await pane.checkoutBranch("refs/remotes/origin/old/gone")
        #expect(dialogs == [.alert(PaneAlert(title: "Checkout failed", message: "fatal: no refs"))])
        #expect(bed.git.checkoutCalls.isEmpty)
    }

    /// BR-12
    @Test("a tag asks before leaving HEAD detached at its commit; Cancel checks nothing out") func tag() async throws {
        let (pane, _) = try await open()
        renderer.answerDialog = { _ in .confirmed(false) }
        await pane.checkoutBranch("refs/tags/v1.0")
        #expect(
            dialogs == [
                .confirm(
                    PaneConfirm(
                        title: "Checkout", message: "Checking out tag v1.0 will leave HEAD detached — it won't be on any branch. Continue?",
                        confirmLabel: "Checkout"))
            ])
        #expect(bed.git.checkoutCalls.isEmpty)
        renderer.answerDialog = { _ in .confirmed(true) }
        await pane.checkoutBranch("refs/tags/v1.0")
        #expect(bed.git.checkoutCalls == [.commit(hash: base)])
    }

    /// BR-12, C-7
    @Test("one checkout at a time, shared with the history's") func inFlight() async throws {
        let (pane, _) = try await open()
        bed.git.checkoutGate.isHeld = true
        let first = Task { await pane.checkoutBranch("refs/heads/my/feature") }
        #expect(await eventually { bed.git.checkoutCalls.count == 1 })
        await pane.checkoutBranch("refs/tags/v1.0")
        await pane.checkout(onFeature)
        #expect(bed.git.checkoutCalls.count == 1)
        bed.git.checkoutGate.release()
        await first.value
    }

    /// BR-12
    @Test("a double-click on a folder or source opens or closes it") func folder() async throws {
        let (pane, sidebar) = try await open()
        sidebar.activate(row: sidebar.row("local:my/"))
        #expect(!pane.branchExpansion.expandedFolders.contains("local:my/"))
        sidebar.activate(row: sidebar.row("tags"))
        #expect(pane.branchExpansion.collapsedSources == ["tags"])
        #expect(bed.git.checkoutCalls.isEmpty)
    }

    /// BR-13
    @Test("right-click selects the branch, then offers Checkout and Copy Branch Name; a tag Copy Tag Name") func menu() async throws {
        let (pane, sidebar) = try await open()
        sidebar.openMenu(atRow: sidebar.row("refs/heads/my/feature"), at: CGPoint(x: 4, y: 5))
        let menu = try #require(renderer.contextMenus.first)
        #expect(menu.items.map(\.title) == ["Checkout", "Copy Branch Name"])
        #expect(menu.items.map(\.isEnabled) == [true, true])
        #expect(pane.selectedBranchID == "refs/heads/my/feature")
        #expect(pane.selectedHash == onFeature)
        let head = try #require(pane.branchNode("refs/heads/main")?.ref)
        #expect(
            sidebar.menuItems(for: head, id: "refs/heads/main").map(\.isEnabled) == [false, true], "HEAD's branch has nothing to check out")
        let tag = try #require(pane.branchNode("refs/tags/v1.0")?.ref)
        #expect(sidebar.menuItems(for: tag, id: "refs/tags/v1.0").map(\.title) == ["Checkout", "Copy Tag Name"])
    }

    /// BR-13
    @Test("Copy Branch Name copies git's short name: a remote-tracking branch with its remote") func copy() async throws {
        let (pane, sidebar) = try await open()
        var copied: [String] = []
        bed.services.copiedOverride = { copied.append($0) }
        for id in ["refs/heads/my/feature", "refs/remotes/origin/my/feature", "refs/tags/v1.0"] {
            let ref = try #require(pane.branchNode(id)?.ref)
            sidebar.menuItems(for: ref, id: id)[1].action()
        }
        #expect(copied == ["my/feature", "origin/my/feature", "v1.0"])
    }

    /// BR-13
    @Test("no menu on a folder or source") func noMenu() async throws {
        let (_, sidebar) = try await open()
        sidebar.openMenu(atRow: sidebar.row("local:my/"), at: .zero)
        sidebar.openMenu(atRow: sidebar.row("local"), at: .zero)
        #expect(renderer.contextMenus.isEmpty)
    }
}

// MARK: - The sidebar's divider

@MainActor
@Suite(.serialized) struct GitTreeSidebarDividerTests {
    let bed: GitTreeTestBed

    init() throws { bed = try GitTreeTestBed() }

    /// The body is laid out 600 wide.
    private func open(_ extra: [String: JSONValue] = [:]) async throws -> (id: PaneID, pane: GitTreePane, view: GitTreeView) {
        let (id, pane) = try await bed.openWithRefs(extra: extra)
        return (id, pane, bed.view(of: pane))
    }

    private func relayout(_ view: GitTreeView) {
        view.needsLayout = true
        view.layoutSubtreeIfNeeded()
    }

    /// SV-1
    @Test("an untouched pane's sidebar is 200 wide and open, and nothing is saved") func untouched() async throws {
        let (id, pane, view) = try await open()
        #expect(pane.sidebar == SidebarSplit(width: 200, collapsed: false))
        #expect(view.sidebarDivider.frame == CGRect(x: 196, y: 0, width: 7, height: 300))
        #expect(bed.config(id)["branchesWidth"] == nil)
    }

    /// SV-2
    @Test("a saved width is what the pane opens with") func saved() async throws {
        let (_, _, view) = try await open(["branchesWidth": 260])
        #expect(view.computeLayout().sidebar?.width == 260)
        #expect(view.computeLayout().list?.minX == 260)
    }

    /// SV-3
    @Test("dragging it previews every move, and saves the width on release") func drag() async throws {
        let (id, pane, view) = try await open()
        #expect(view.sidebarDivider.begin(at: 200))
        view.sidebarDivider.move(to: 310)
        #expect(pane.sidebar.width == 310)
        #expect(bed.config(id)["branchesWidth"] == nil)
        view.sidebarDivider.finish()
        #expect(bed.config(id)["branchesWidth"] == 310.0)
        #expect(bed.config(id)["branchesCollapsed"] == false)
    }

    /// SV-3
    @Test("a press that moves nothing saves nothing") func stillPress() async throws {
        let (id, _, view) = try await open()
        view.sidebarDivider.begin(at: 200)
        view.sidebarDivider.finish()
        #expect(bed.config(id)["branchesWidth"] == nil)
        #expect(bed.config(id)["branchesCollapsed"] == nil)
    }

    /// SV-4, SV-6
    @Test("dragging it to the left edge collapses the sidebar to a bar, and dragging the bar out reopens it") func collapseAndReopen()
        async throws
    {
        let (id, pane, view) = try await open()
        view.sidebarDivider.begin(at: 200)
        view.sidebarDivider.move(to: 40)
        view.sidebarDivider.finish()
        relayout(view)
        #expect(bed.config(id)["branchesCollapsed"] == true)
        #expect(pane.sidebar == SidebarSplit(width: 200, collapsed: true), "the last open width is kept")
        #expect(view.sidebar.isHidden)
        let layout = view.computeLayout()
        #expect(layout.sidebarCollapsed)
        #expect(layout.sidebarDivider == CGRect(x: 0, y: 0, width: 8, height: 300))
        #expect(layout.list == CGRect(x: 8, y: 0, width: 592, height: 300))
        #expect(view.sidebarDivider.frame == CGRect(x: 0, y: 0, width: 12, height: 300))

        view.sidebarDivider.begin(at: 4)
        view.sidebarDivider.move(to: 254)
        view.sidebarDivider.finish()
        relayout(view)
        #expect(bed.config(id)["branchesWidth"] == 258.0)
        #expect(bed.config(id)["branchesCollapsed"] == false)
        #expect(!view.sidebar.isHidden)
    }

    /// SV-5
    @Test("a pane too narrow for the saved width shows less, and the saved width comes back as it widens") func narrowPane() async throws {
        let (_, pane, _) = try await open(["branchesWidth": 300])
        let narrow = bed.view(of: pane, width: 400)
        #expect(narrow.computeLayout().sidebar?.width == 200)
        let wide = bed.view(of: pane, width: 900)
        #expect(wide.computeLayout().sidebar?.width == 300)
    }

    /// SV-3, V-6
    @Test("a release it never saw ends the drag where it was last shown") func unseenRelease() async throws {
        let (id, pane, view) = try await open()
        view.sidebarDivider.begin(at: 200)
        view.sidebarDivider.move(to: 250)
        view.sidebarDivider.finish()
        #expect(bed.config(id)["branchesWidth"] == 250.0)
        view.sidebarDivider.move(to: 400)
        #expect(pane.sidebar.width == 250)
    }
}

extension JSONValue {
    /// An array's elements (tests compare them).
    fileprivate var arrayElements: [JSONValue]? {
        if case .array(let values) = self { values } else { nil }
    }
}
