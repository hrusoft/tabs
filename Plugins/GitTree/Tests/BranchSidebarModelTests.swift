import Foundation
import TabsPluginSDK
import Testing

// The branches sidebar's pure logic: its tree, the refs read, what's open,
// how wide. Case ids are docs/GIT-TREE.md's.

private func local(_ name: String, _ hash: String = "a") -> GitRef {
    GitRef(kind: .local, refname: "refs/heads/\(name)", name: name, hash: hash)
}

private func remote(_ remote: String, _ name: String, _ hash: String = "a") -> GitRef {
    GitRef(kind: .remote, refname: "refs/remotes/\(remote)/\(name)", remote: remote, name: name, hash: hash)
}

private func tag(_ name: String, _ hash: String = "a") -> GitRef {
    GitRef(kind: .tag, refname: "refs/tags/\(name)", name: name, hash: hash)
}

/// Every row, depth first, its title indented two spaces a level.
private func outline(_ tree: [BranchNode]) -> [String] {
    var lines: [String] = []
    func walk(_ nodes: [BranchNode], _ level: Int) {
        for node in nodes {
            lines.append(String(repeating: "  ", count: level) + node.title)
            walk(node.children, level + 1)
        }
    }
    walk(tree, 0)
    return lines
}

@Suite("the branch tree") struct BranchTreeTests {
    /// BR-2
    @Test("lists Local, each remote, then Tags, every one even when empty") func sources() {
        let tree = buildBranchTree(GitRefs(remotes: ["origin", "upstream"], refs: [local("main")]))
        #expect(tree.map(\.title) == ["Local", "origin", "upstream", "Tags"])
        #expect(tree.map(\.id) == ["local", "remote:origin", "remote:upstream", "tags"])
        #expect(tree[1].children.isEmpty && tree[3].children.isEmpty)
    }

    /// BR-2
    @Test("adds a remote a ref names that isn't configured, after the configured ones") func unconfiguredRemote() {
        let tree = buildBranchTree(GitRefs(remotes: ["origin"], refs: [remote("gone", "old"), remote("origin", "main")]))
        #expect(tree.map(\.title) == ["Local", "origin", "gone", "Tags"])
        #expect(tree[2].children.map(\.title) == ["old"])
    }

    /// BR-3
    @Test("splits names at slashes: each segment but the last is a folder") func folders() {
        let tree = buildBranchTree(
            GitRefs(remotes: ["origin"], refs: [remote("origin", "my/branch/name"), remote("origin", "my/other"), local("main")]))
        #expect(
            outline(tree) == [
                "Local", "  main",
                "origin", "  my", "    branch", "      name", "    other",
                "Tags",
            ])
        let my = tree[1].children.first
        #expect(my?.id == "remote:origin:my/")
        #expect(my?.kind == .folder)
        #expect(my?.children.first?.id == "remote:origin:my/branch/")
        #expect(tree[1].find("refs/remotes/origin/my/branch/name")?.ref?.name == "my/branch/name")
    }

    /// BR-3: one folder per source, whatever the other sources hold.
    @Test("keeps the same folder name apart in each source") func foldersPerSource() {
        let tree = buildBranchTree(
            GitRefs(remotes: ["origin"], refs: [local("feature/a"), remote("origin", "feature/a"), tag("feature/v1")]))
        #expect(tree.map { $0.children.first?.id } == ["local:feature/", "remote:origin:feature/", "tags:feature/"])
    }

    /// BR-4
    @Test("orders each level as Finder does: by name, numbers by value, case ignored, folders among the refs") func order() {
        let tree = buildBranchTree(
            GitRefs(remotes: [], refs: [tag("v10"), tag("v2"), tag("V3"), tag("release/1"), tag("alpha"), tag("v1")]))
        #expect(tree[1].children.map(\.title) == ["alpha", "release", "v1", "v2", "V3", "v10"])
    }

    @Test("finds a row by id anywhere under it") func find() {
        let tree = buildBranchTree(GitRefs(remotes: [], refs: [local("a/b/c")]))
        #expect(tree[0].find("refs/heads/a/b/c")?.title == "c")
        #expect(tree[0].find("local:a/b/")?.title == "b")
        #expect(tree[0].find("nothing") == nil)
    }
}

@Suite("the refs read") struct ParseRefListTests {
    private let sep = "\u{1f}"

    /// BR-2, BR-5
    @Test("reads branches, remote-tracking branches and tags; an annotated tag by the commit it peels to") func kinds() {
        let stdout = [
            "c1\(sep)refs/heads/main\(sep)",
            "c2\(sep)refs/remotes/origin/feature/x\(sep)",
            "c1\(sep)refs/remotes/origin/HEAD\(sep)",
            "t1\(sep)refs/tags/v1.0\(sep)c3",
            "c4\(sep)refs/tags/light\(sep)",
            "c5\(sep)refs/notes/commits\(sep)",
        ].joined(separator: "\n")
        let refs = Git.parseRefList(stdout, remoteNames: ["origin"])
        #expect(refs.remotes == ["origin"])
        #expect(
            refs.refs == [
                local("main", "c1"), remote("origin", "feature/x", "c2"), tag("v1.0", "c3"), tag("light", "c4"),
            ])
    }

    /// BR-3: a remote whose own name has a slash, split as checkout splits it.
    @Test("splits a remote-tracking ref against the configured remotes, longest first") func remoteWithASlash() {
        let refs = Git.parseRefList("c1\(sep)refs/remotes/team/a/feature\(sep)", remoteNames: ["team", "team/a"])
        #expect(refs.refs.first?.remote == "team/a")
        #expect(refs.refs.first?.name == "feature")
        #expect(refs.refs.first?.shortName == "team/a/feature")
    }

    @Test("reads one remote name a line") func remoteNames() {
        #expect(Git.parseRemoteNames("origin\n  upstream \n\n") == ["origin", "upstream"])
    }
}

@Suite("what's open in the branch tree") struct BranchExpansionTests {
    private let tree = buildBranchTree(GitRefs(remotes: ["origin"], refs: [local("a/b"), remote("origin", "c/d")]))

    /// BR-9
    @Test("opens every source and no folder until toggled") func defaults() {
        let expansion = BranchExpansion()
        #expect(tree.allSatisfy(expansion.isExpanded))
        #expect(!expansion.isExpanded(tree[0].children[0]))
        #expect(visibleBranchRows(tree, expansion).map(\.node.title) == ["Local", "a", "origin", "c", "Tags"])
    }

    /// BR-9
    @Test("keeps a closed source and an open folder, and lists only rows under open ones") func toggles() {
        var expansion = BranchExpansion()
        expansion.set(tree[0].children[0], expanded: true)
        expansion.set(tree[1], expanded: false)
        #expect(expansion == BranchExpansion(collapsedSources: ["remote:origin"], expandedFolders: ["local:a/"]))
        #expect(visibleBranchRows(tree, expansion).map(\.node.title) == ["Local", "a", "b", "origin", "Tags"])
        #expect(visibleBranchRows(tree, expansion).map(\.level) == [0, 1, 2, 0, 0])
    }

    /// BR-9
    @Test("drops the rows the tree no longer has") func pruned() {
        let expansion = BranchExpansion(collapsedSources: ["remote:gone", "tags"], expandedFolders: ["local:a/", "local:old/"])
        #expect(expansion.pruned(to: tree) == BranchExpansion(collapsedSources: ["tags"], expandedFolders: ["local:a/"]))
    }

    /// BR-9: the config's keys, absent while they hold nothing.
    @Test("round-trips through the config, ignoring what isn't a list of strings") func config() {
        let expansion = BranchExpansion(collapsedSources: ["tags"], expandedFolders: ["local:b/", "local:a/"])
        #expect(expansion.config == ["branchesCollapsedSources": ["tags"], "branchesExpandedFolders": ["local:a/", "local:b/"]])
        #expect(BranchExpansion().config == ["branchesCollapsedSources": .null, "branchesExpandedFolders": .null])
        #expect(readBranchExpansion(.object(expansion.config)) == expansion)
        #expect(
            readBranchExpansion(["branchesCollapsedSources": "tags", "branchesExpandedFolders": [1, "local:a/"]])
                == BranchExpansion(expandedFolders: ["local:a/"]))
    }
}

@Suite("reading the saved sidebar") struct ReadSidebarSplitTests {
    /// SV-1
    @Test("an untouched pane's sidebar is 200 wide and open") func untouched() {
        #expect(readSidebarSplit(.object([:])) == SidebarSplit(width: 200, collapsed: false))
    }

    /// SV-2
    @Test("takes a saved width and collapse as they are") func saved() {
        #expect(readSidebarSplit(["branchesWidth": 260, "branchesCollapsed": true]) == SidebarSplit(width: 260, collapsed: true))
    }

    /// SV-2
    @Test("refuses a width that's not more than 0, and a collapse that's not literally true") func refused() {
        #expect(readSidebarSplit(["branchesWidth": 0]).width == 200)
        #expect(readSidebarSplit(["branchesWidth": -5]).width == 200)
        #expect(readSidebarSplit(["branchesWidth": "wide"]).width == 200)
        #expect(readSidebarSplit(["branchesCollapsed": 1]).collapsed == false)
        #expect(readSidebarSplit(["branchesCollapsed": "true"]).collapsed == false)
    }
}

@Suite("dragging the sidebar's divider") struct ResolveSidebarDragTests {
    private let open = SidebarSplit(width: 200, collapsed: false)

    /// SV-4
    @Test("takes any width between its minimum and the list's") func between() {
        #expect(resolveSidebarDrag(width: 250, bodyWidth: 800, previous: open) == SidebarSplit(width: 250, collapsed: false))
        #expect(resolveSidebarDrag(width: 700, bodyWidth: 800, previous: open) == SidebarSplit(width: 600, collapsed: false))
    }

    /// SV-4
    @Test("holds at 120 down to 60, and collapses below that, keeping the last open width") func collapse() {
        #expect(resolveSidebarDrag(width: 90, bodyWidth: 800, previous: open) == SidebarSplit(width: 120, collapsed: false))
        #expect(resolveSidebarDrag(width: 60, bodyWidth: 800, previous: open) == SidebarSplit(width: 120, collapsed: false))
        #expect(resolveSidebarDrag(width: 59, bodyWidth: 800, previous: open) == SidebarSplit(width: 200, collapsed: true))
    }

    /// SV-4
    @Test("keeps its minimum in a body too narrow for both, and changes nothing in a body with no width") func narrow() {
        #expect(resolveSidebarDrag(width: 250, bodyWidth: 280, previous: open) == SidebarSplit(width: 120, collapsed: false))
        #expect(resolveSidebarDrag(width: 10, bodyWidth: 0, previous: open) == open)
    }
}

@Suite("the sidebar's shown width") struct ShownSidebarWidthTests {
    /// SV-5
    @Test("is the saved width while the list keeps 200, else narrower, but never below 120 or past the body") func shown() {
        let split = SidebarSplit(width: 300, collapsed: false)
        #expect(shownSidebarWidth(split, bodyWidth: 900) == 300)
        #expect(shownSidebarWidth(split, bodyWidth: 400) == 200)
        #expect(shownSidebarWidth(split, bodyWidth: 250) == 120)
        #expect(shownSidebarWidth(split, bodyWidth: 100) == 100)
    }
}
