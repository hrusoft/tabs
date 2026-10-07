import Foundation
import TabsPluginSDK
import Testing

@testable import TabsCore

/// The tree operations. Nodes are values, so identity is value equality: a
/// relocated node is equal to what it was, ids and all.
@Suite struct TreeTests {
    @Suite struct MapLeaves {
        @Test("replaces matching leaves and leaves the rest by reference")
        func replacesMatching() {
            let target = createLeaf("terminal", ["cwd": "~"])
            let other = createLeaf("terminal", ["cwd": "~"])
            let root = createSplit(.horizontal, [target, other])

            let result = Tree.mapLeaves(root) { leaf in
                guard leaf.id == target.id else { return leaf }
                var changed = leaf
                changed.config = ["cwd": "/tmp/x"]
                return changed
            }

            #expect(result.childNodes[safe: 0]?.config?["cwd"] == "/tmp/x")
            #expect(result.childNodes[safe: 1] == other)
        }

        @Test("returns the same root reference when fn changes nothing")
        func unchanged() {
            let root = createSplit(.horizontal, [createLeaf("terminal"), createLeaf("empty")])
            #expect(Tree.mapLeaves(root) { $0 } == root)
        }

        @Test("updates a leaf nested inside a tab group")
        func nested() {
            let tab = createTab("Tab", createLeaf("terminal", ["cwd": "~"]))
            let root = createTabs([tab])

            let result = Tree.mapLeaves(root) { leaf in
                var changed = leaf
                changed.config = ["cwd": "/tmp/y"]
                return changed
            }

            #expect(result.tabItems[safe: 0]?.content != tab.content)
            #expect(result.tabItems[safe: 0]?.content.config?["cwd"] == "/tmp/y")
        }
    }

    @Suite struct AddTab {
        @Test("appends to the target group and activates the new tab")
        func appends() {
            let first = welcomeTab("First")
            let root = createTabs([first])
            let added = welcomeTab("Second")

            let next = Tree.addTab(root, root.id, added)

            #expect(next.titles == ["First", "Second"])
            #expect(next.activeTabID == added.id)
        }

        @Test("inserts at an explicit index")
        func atIndex() {
            let root = createTabs([welcomeTab("A"), welcomeTab("C")])

            let next = Tree.addTab(root, root.id, welcomeTab("B"), at: 1)

            #expect(next.titles == ["A", "B", "C"])
        }
    }

    @Suite struct CloseTab {
        @Test("activates the next tab when closing the active tab")
        func activatesNext() {
            let (a, b, c) = (welcomeTab("A"), welcomeTab("B"), welcomeTab("C"))
            let root = createTabs([a, b, c], active: b.id)

            let next = Tree.closeTab(root, b.id)

            // Three tabs closed down to two: still a group, not a collapse.
            #expect(next.isTabs)
            #expect(next.titles == ["A", "C"])
            #expect(next.activeTabID == c.id)
        }

        @Test("activates the previous tab when closing the last active tab")
        func activatesPrevious() {
            let (a, b, c) = (welcomeTab("A"), welcomeTab("B"), welcomeTab("C"))
            let root = createTabs([a, b, c], active: c.id)

            let next = Tree.closeTab(root, c.id)

            #expect(next.titles == ["A", "B"])
            #expect(next.activeTabID == b.id)
        }

        @Test("leaves activation alone when closing an inactive tab")
        func inactive() {
            let (a, b, c) = (welcomeTab("A"), welcomeTab("B"), welcomeTab("C"))
            let root = createTabs([a, b, c], active: a.id)

            let next = Tree.closeTab(root, c.id)

            #expect(next.titles == ["A", "B"])
            #expect(next.activeTabID == a.id)
        }

        @Test("turns the root into an empty pane after closing its only tab")
        func onlyTab() {
            let only = welcomeTab("Only")
            let root = createTabs([only])

            #expect(Tree.closeTab(root, only.id).kind == "empty")
        }

        @Test("collapses a two-tab group to the surviving tab's own content, preserving its identity")
        func collapsesPair() {
            let (a, b) = (welcomeTab("A"), welcomeTab("B"))
            let root = createTabs([a, b], active: b.id)

            let next = Tree.closeTab(root, b.id)

            // The mirror of openContent's promotion: the group's slot is taken
            // by the survivor's content itself, id and all.
            #expect(!next.isTabs)
            #expect(next == a.content)
        }

        @Test("empties a pane in place instead of collapsing its split")
        func emptiesInPlace() {
            let leftTab = welcomeTab("Left")
            let left = createTabs([leftTab])
            let right = createTabs([welcomeTab("Right")])
            let split = createSplit(.horizontal, [left, right])
            let root = createTabs([createTab("Root", split)])

            let next = Tree.closeTab(root, leftTab.id)
            let nextSplit = next.tabItems[safe: 0]?.content

            // The left pane becomes an empty leaf in its same slot; the split
            // itself, and the untouched right pane, are unaffected.
            #expect(nextSplit?.childNodes.count == 2)
            #expect(nextSplit?.childNodes[safe: 0]?.kind == "empty")
            #expect(nextSplit?.childNodes[safe: 1] == right)
        }

        @Test("collapses a two-tab group inside a split, leaving the split and its sibling untouched")
        func collapsesInSplit() {
            let (leftA, leftB) = (welcomeTab("Left A"), welcomeTab("Left B"))
            let left = createTabs([leftA, leftB])
            let right = createTabs([welcomeTab("Right")])
            let root = createTabs([createTab("Root", createSplit(.horizontal, [left, right]))])

            let nextSplit = Tree.closeTab(root, leftB.id).tabItems[safe: 0]?.content

            #expect(nextSplit?.childNodes.count == 2)
            #expect(nextSplit?.childNodes[safe: 0] == leftA.content)
            #expect(nextSplit?.childNodes[safe: 1] == right)
        }

        @Test("empties a nested tab group without dropping the tab that contains it")
        func emptiesNested() {
            let innerTab = welcomeTab("Inner")
            let inner = createTabs([innerTab])
            let root = createTabs([createTab("Outer", inner)])

            let next = Tree.closeTab(root, innerTab.id)

            #expect(next.titles == ["Outer"])
            #expect(next.tabItems[safe: 0]?.content.kind == "empty")
        }

        @Test("collapses a nested tab group without dropping the outer tab that contains it")
        func collapsesNested() {
            let (innerA, innerB) = (welcomeTab("Inner A"), welcomeTab("Inner B"))
            let inner = createTabs([innerA, innerB])
            let root = createTabs([createTab("Outer", inner)])

            let next = Tree.closeTab(root, innerB.id)

            #expect(next.titles == ["Outer"])
            #expect(next.tabItems[safe: 0]?.content == innerA.content)
        }
    }

    @Suite struct RenameTab {
        @Test("renames the tab in place, leaving its content untouched")
        func renames() {
            let tab = welcomeTab("Old")
            let root = createTabs([tab])

            let next = Tree.renameTab(root, tab.id, "New")

            #expect(next.tabItems[safe: 0]?.title == "New")
            #expect(next.tabItems[safe: 0]?.content == tab.content)
        }

        @Test("is a no-op for an unknown tab id")
        func unknown() {
            let root = createTabs([welcomeTab("A")])
            #expect(Tree.renameTab(root, "missing", "New") == root)
        }

        @Test("is a no-op when the title is unchanged")
        func unchanged() {
            let root = createTabs([welcomeTab("Same")])
            #expect(Tree.renameTab(root, root.tabItems[0].id, "Same") == root)
        }
    }

    @Suite struct RenamePane {
        @Test("sets a title override on a leaf, read back via the leaf itself")
        func sets() {
            let leaf = createLeaf("terminal")
            let root = createSplit(.horizontal, [leaf, createLeaf("welcome")])

            let next = Tree.renamePane(root, leaf.id, "My terminal")

            #expect(next.childNodes[safe: 0]?.leaf?.title == "My terminal")
        }

        @Test("clears an override back to nil")
        func clears() {
            let titled = createLeaf("terminal", title: "Custom")
            #expect(Tree.renamePane(titled, titled.id, nil).leaf?.title == nil)
        }

        @Test("is a no-op for an unknown id")
        func unknown() {
            let root = createLeaf("terminal")
            #expect(Tree.renamePane(root, "missing", "New") == root)
        }

        @Test("is a no-op on a tabs group (no header title of its own)")
        func onTabs() {
            let root = createTabs([welcomeTab("A")])
            #expect(Tree.renamePane(root, root.id, "New") == root)
        }

        @Test("is a no-op on a split (never rendered with a header)")
        func onSplit() {
            let root = createSplit(.horizontal, [createLeaf("terminal"), createLeaf("welcome")])
            #expect(Tree.renamePane(root, root.id, "New") == root)
        }

        @Test("is a no-op when the title is unchanged")
        func unchanged() {
            let leaf = createLeaf("terminal", title: "Same", titleIsManual: true)
            #expect(Tree.renamePane(leaf, leaf.id, "Same") == leaf)
        }

        @Test("marks the pane titleIsManual when setting a title")
        func marksManual() {
            let leaf = createLeaf("terminal")
            #expect(Tree.renamePane(leaf, leaf.id, "My terminal").leaf?.titleIsManual == true)
        }

        @Test("un-marks titleIsManual when clearing the title")
        func unmarksManual() {
            let leaf = createLeaf("terminal", title: "Custom", titleIsManual: true)
            #expect(Tree.renamePane(leaf, leaf.id, nil).leaf?.titleIsManual == false)
        }
    }

    @Suite struct SetLiveTitle {
        @Test("sets a title on a leaf with no existing title")
        func sets() {
            let leaf = createLeaf("terminal")

            let next = Tree.setLiveTitle(leaf, leaf.id, "vim ~/notes.md")

            #expect(next.leaf?.title == "vim ~/notes.md")
            #expect(next.leaf?.titleIsManual == false)
        }

        @Test("updates an existing auto title")
        func updates() {
            let leaf = createLeaf("terminal", title: "old title")
            #expect(Tree.setLiveTitle(leaf, leaf.id, "new title").leaf?.title == "new title")
        }

        @Test("is a no-op when the pane title was set manually")
        func manual() {
            let leaf = createLeaf("terminal", title: "Custom", titleIsManual: true)
            #expect(Tree.setLiveTitle(leaf, leaf.id, "from the process") == leaf)
        }

        @Test("is a no-op when the title is unchanged")
        func unchanged() {
            let leaf = createLeaf("terminal", title: "Same")
            #expect(Tree.setLiveTitle(leaf, leaf.id, "Same") == leaf)
        }

        @Test("treats an empty title the same as clearing it back to nil")
        func emptyClears() {
            let leaf = createLeaf("terminal", title: "Custom")
            let next = Tree.setLiveTitle(leaf, leaf.id, "")
            #expect(next.leaf != nil)
            #expect(next.leaf?.title == nil)
        }

        @Test("is a no-op for an unknown id")
        func unknown() {
            let root = createLeaf("terminal")
            #expect(Tree.setLiveTitle(root, "missing", "New") == root)
        }

        @Test("is a no-op on a tabs group (no header title of its own)")
        func onTabs() {
            let root = createTabs([welcomeTab("A")])
            #expect(Tree.setLiveTitle(root, root.id, "New") == root)
        }

        @Test("is a no-op on a split (never rendered with a header)")
        func onSplit() {
            let root = createSplit(.horizontal, [createLeaf("terminal"), createLeaf("welcome")])
            #expect(Tree.setLiveTitle(root, root.id, "New") == root)
        }
    }

    // There is no leaf-config setter: a live pane's config is read from its
    // plugin when the layout is saved (LayoutEngine.snapshot), not pushed into
    // the tree on every change.

    @Suite struct SplitContent {
        @Test("replaces a leaf with a 50/50 split of [old, new]")
        func replacesLeaf() {
            let leaf = createLeaf("welcome")
            let root = createTabs([createTab("Tab", leaf)])
            let pane = createTabs([welcomeTab()])

            let next = Tree.splitContent(root, leaf.id, .horizontal, pane)
            let split = next.tabItems[safe: 0]?.content

            #expect(split?.isSplit == true)
            #expect(split?.direction == .horizontal)
            #expect(split?.childIDs == [leaf.id, pane.id])
            #expect(split?.sizes == [0.5, 0.5])
        }

        @Test("splices into a same-direction split instead of nesting")
        func splices() {
            let (a, b) = (createLeaf("welcome"), createLeaf("welcome"))
            let root = createTabs([createTab("Tab", createSplit(.horizontal, [a, b], sizes: [0.6, 0.4]))])
            let added = createLeaf("welcome")

            let result = Tree.splitContent(root, a.id, .horizontal, added).tabItems[safe: 0]?.content

            #expect(result?.childIDs == [a.id, added.id, b.id])
            #expect(isClose(result?.sizes[safe: 0], 0.3))
            #expect(isClose(result?.sizes[safe: 1], 0.3))
            #expect(isClose(result?.sizes[safe: 2], 0.4))
            // No nested same-direction split survived.
            #expect(result?.childNodes.contains { $0.direction == .horizontal } == false)
        }

        @Test("splits the root node itself")
        func root() {
            let root = createTabs([welcomeTab()])
            let pane = createTabs([welcomeTab()])

            let next = Tree.splitContent(root, root.id, .vertical, pane)

            #expect(next.isSplit)
            #expect(next.childIDs == [root.id, pane.id])
        }
    }

    @Suite struct ResizeSplit {
        @Test("renormalizes sizes to sum to 1")
        func renormalizes() {
            let split = createSplit(.horizontal, [createLeaf("welcome"), createLeaf("welcome")])

            let next = Tree.resizeSplit(split, split.id, [2, 6])

            #expect(isClose(next.sizes[safe: 0], 0.25))
            #expect(isClose(next.sizes[safe: 1], 0.75))
        }

        @Test("clamps below-minimum sizes")
        func clamps() {
            let split = createSplit(.horizontal, [createLeaf("welcome"), createLeaf("welcome")])

            let next = Tree.resizeSplit(split, split.id, [0.01, 0.99])

            #expect(isClose(next.sizes[safe: 0], Tree.minPaneSize))
            #expect(isClose(next.sizes.reduce(0, +), 1))
        }

        @Test("ignores a sizes array of the wrong length")
        func wrongLength() {
            let split = createSplit(.horizontal, [createLeaf("welcome"), createLeaf("welcome")])
            #expect(Tree.resizeSplit(split, split.id, [1]) == split)
        }
    }

    @Suite struct MoveTab {
        @Test("moves a tab across groups, collapsing the two-tab source to its survivor's content")
        func acrossGroups() {
            let moved = welcomeTab("Moved")
            let stays = welcomeTab("Stays")
            let source = createTabs([moved, stays], active: moved.id)
            let target = createTabs([welcomeTab("Existing")])
            let root = createTabs([createTab("Root", createSplit(.horizontal, [source, target]))])

            let nextSplit = Tree.moveTab(root, moved.id, target.id).tabItems[safe: 0]?.content
            let nextSource = nextSplit?.childNodes[safe: 0]
            let nextTarget = nextSplit?.childNodes[safe: 1]

            // The source group had only two tabs; losing one collapses it to
            // the survivor's own content, unwrapped in place.
            #expect(nextSource?.isTabs == false)
            #expect(nextSource == stays.content)
            #expect(nextTarget?.titles == ["Existing", "Moved"])
            #expect(nextTarget?.activeTabID == moved.id)
            // The tab itself travels, not a copy with a new id.
            #expect(nextTarget?.tabItems[safe: 1] == moved)
        }

        @Test("moves a tab out of a three-tab source, which stays a group and repairs activation")
        func threeTabSource() {
            let moved = welcomeTab("Moved")
            let stays = welcomeTab("Stays")
            let source = createTabs([moved, stays, welcomeTab("Other")], active: moved.id)
            let target = createTabs([welcomeTab("Existing")])
            let root = createTabs([createTab("Root", createSplit(.horizontal, [source, target]))])

            let nextSource = Tree.moveTab(root, moved.id, target.id).tabItems[safe: 0]?.content.childNodes[safe: 0]

            #expect(nextSource?.isTabs == true)
            #expect(nextSource?.titles == ["Stays", "Other"])
            #expect(nextSource?.activeTabID == stays.id)
        }

        @Test("empties the source pane in place instead of collapsing its split")
        func emptiesSource() {
            let only = welcomeTab("Only")
            let source = createTabs([only])
            let target = createTabs([welcomeTab("Existing")])
            let root = createTabs([createTab("Root", createSplit(.horizontal, [source, target]))])

            let nextSplit = Tree.moveTab(root, only.id, target.id).tabItems[safe: 0]?.content

            #expect(nextSplit?.childNodes.count == 2)
            #expect(nextSplit?.childNodes[safe: 0]?.kind == "empty")
            #expect(nextSplit?.childNodes[safe: 1]?.titles == ["Existing", "Only"])
        }

        @Test("refuses to move a tab into a group nested inside itself")
        func intoItself() {
            let inner = createTabs([welcomeTab("Inner")])
            let outerTab = createTab("Outer", inner)
            let root = createTabs([outerTab, welcomeTab("Other")])

            #expect(Tree.moveTab(root, outerTab.id, inner.id) == root)
        }

        @Test("reorders tabs within the same group by index")
        func reorders() {
            let (a, b, c) = (welcomeTab("A"), welcomeTab("B"), welcomeTab("C"))
            let root = createTabs([a, b, c])

            let next = Tree.moveTab(root, a.id, root.id, at: 2)

            #expect(next.titles == ["B", "C", "A"])
            #expect(next.activeTabID == a.id)
        }

        @Test("drops a tab onto an empty pane, converting it into a tabs group of just that tab")
        func ontoEmpty() {
            let moved = welcomeTab("Moved")
            let stays = welcomeTab("Stays")
            let source = createTabs([moved, stays], active: moved.id)
            let empty = createLeaf("empty")
            let root = createTabs([createTab("Root", createSplit(.horizontal, [source, empty]))])

            let nextSplit = Tree.moveTab(root, moved.id, empty.id).tabItems[safe: 0]?.content
            let nextSource = nextSplit?.childNodes[safe: 0]
            let nextTarget = nextSplit?.childNodes[safe: 1]

            // The two-tab source collapses to its survivor's own content.
            #expect(nextSource?.isTabs == false)
            #expect(nextSource == stays.content)
            #expect(nextTarget?.kind == "tabs")
            // The empty pane's own id is preserved: it's the same pane, now full.
            #expect(nextTarget?.id == empty.id)
            #expect(nextTarget?.titles == ["Moved"])
            #expect(nextTarget?.activeTabID == moved.id)
        }

        @Test("collapses the source tab bar to empty when its last tab is dropped on an empty pane")
        func lastTabOntoEmpty() {
            let only = welcomeTab("Only")
            let empty = createLeaf("empty")
            let root = createTabs([createTab("Root", createSplit(.horizontal, [createTabs([only]), empty]))])

            let nextSplit = Tree.moveTab(root, only.id, empty.id).tabItems[safe: 0]?.content

            #expect(nextSplit?.childNodes[safe: 0]?.kind == "empty")
            #expect(nextSplit?.childNodes[safe: 1]?.titles == ["Only"])
        }

        @Test("is a no-op when the target is neither a tabs group nor an empty pane")
        func invalidTarget() {
            let moved = welcomeTab("Moved")
            let other = createLeaf("welcome")
            let root = createTabs([createTab("Root", createSplit(.horizontal, [createTabs([moved]), other]))])

            #expect(Tree.moveTab(root, moved.id, other.id) == root)
        }
    }

    @Suite struct DockTab {
        @Test("splices a right-docked tab into a same-direction split as a new single-tab group")
        func rightSplices() {
            let moved = welcomeTab("Moved")
            let stays = welcomeTab("Stays")
            let source = createTabs([moved, stays], active: moved.id)
            let target = createTabs([welcomeTab("Existing")])
            let root = createSplit(.horizontal, [source, target])

            let next = Tree.dockTab(root, moved.id, target.id, .right, titleOf)

            // Same-direction split: spliced beside the target, taking half its share.
            #expect(next.direction == .horizontal)
            #expect(next.childNodes.count == 3)
            #expect(next.childNodes[safe: 0] == stays.content)
            #expect(next.childNodes[safe: 1] == target)
            #expect(isClose(next.sizes[safe: 0], 0.5))
            #expect(isClose(next.sizes[safe: 1], 0.25))
            #expect(isClose(next.sizes[safe: 2], 0.25))

            // The new pane is a single-tab group holding the tab itself.
            let landed = next.childNodes[safe: 2]
            #expect(landed?.isTabs == true)
            #expect(landed?.tabItems == [moved])
            #expect(landed?.activeTabID == moved.id)
        }

        @Test("left-docks before the target, wrapping a cross-direction pane in a nested split")
        func leftNests() {
            let moved = welcomeTab("Moved")
            let stays = welcomeTab("Stays")
            let source = createTabs([moved, stays])
            let target = createTabs([welcomeTab("Existing")])
            let root = createSplit(.vertical, [source, target])

            let next = Tree.dockTab(root, moved.id, target.id, .left, titleOf)
            let nested = next.childNodes[safe: 1]

            // The collapsed source keeps its slot; the target's slot becomes a
            // horizontal 50/50 split with the new group before it.
            #expect(next.direction == .vertical)
            #expect(next.childNodes[safe: 0] == stays.content)
            #expect(nested?.isSplit == true)
            #expect(nested?.direction == .horizontal)
            #expect(nested?.sizes == [0.5, 0.5])
            #expect(nested?.childNodes[safe: 0]?.tabItems[safe: 0] == moved)
            #expect(nested?.childNodes[safe: 1] == target)
        }

        @Test("maps top and bottom zones to a vertical split before/after the target")
        func topAndBottom() {
            let target = createTabs([welcomeTab("Existing")])
            func buildRoot() -> (moved: Tab, root: LayoutNode) {
                let moved = welcomeTab("Moved")
                return (moved, createSplit(.horizontal, [createTabs([moved, welcomeTab("Stays")]), target]))
            }

            let top = buildRoot()
            let topNested = Tree.dockTab(top.root, top.moved.id, target.id, .top, titleOf).childNodes[safe: 1]
            #expect(topNested?.direction == .vertical)
            #expect(topNested?.childNodes[safe: 0]?.tabItems[safe: 0] == top.moved)
            #expect(topNested?.childNodes[safe: 1] == target)

            let bottom = buildRoot()
            let bottomNested = Tree.dockTab(bottom.root, bottom.moved.id, target.id, .bottom, titleOf).childNodes[safe: 1]
            #expect(bottomNested?.direction == .vertical)
            #expect(bottomNested?.childNodes[safe: 0] == target)
            #expect(bottomNested?.childNodes[safe: 1]?.tabItems[safe: 0] == bottom.moved)
        }

        @Test("edge-docks a tab against its own two-tab group, splitting off the survivor's content")
        func againstOwnGroup() {
            let moved = welcomeTab("Moved")
            let stays = welcomeTab("Stays")
            let root = createTabs([moved, stays])

            let next = Tree.dockTab(root, moved.id, root.id, .right, titleOf)

            // Removing the tab collapses the group to the survivor's content —
            // a different node id — and the split forms against that survivor.
            #expect(next.isSplit)
            #expect(next.direction == .horizontal)
            #expect(next.childNodes[safe: 0] == stays.content)
            #expect(next.childNodes[safe: 1]?.tabItems[safe: 0] == moved)
        }

        @Test("center-docks onto another group, appending the tab and collapsing the source")
        func centerOntoGroup() {
            let moved = welcomeTab("Moved")
            let stays = welcomeTab("Stays")
            let source = createTabs([moved, stays], active: moved.id)
            let target = createTabs([welcomeTab("Existing")])
            let root = createSplit(.horizontal, [source, target])

            let next = Tree.dockTab(root, moved.id, target.id, .center, titleOf)
            let targetGroup = next.childNodes[safe: 1]

            #expect(next.childNodes[safe: 0] == stays.content)
            #expect(targetGroup?.titles == ["Existing", "Moved"])
            #expect(targetGroup?.tabItems[safe: 1] == moved)
            #expect(targetGroup?.activeTabID == moved.id)
        }

        @Test("center-docks onto an empty pane, converting it in place like a drop")
        func centerOntoEmpty() {
            let moved = welcomeTab("Moved")
            let empty = createLeaf("empty")
            let root = createSplit(.horizontal, [createTabs([moved, welcomeTab("Stays")]), empty])

            let landed = Tree.dockTab(root, moved.id, empty.id, .center, titleOf).childNodes[safe: 1]

            // The empty pane's own id is preserved: it's the same pane, now full.
            #expect(landed?.id == empty.id)
            #expect(landed?.tabItems == [moved])
        }

        @Test("center-docks onto a bare leaf, promoting it into a two-tab group by reference")
        func centerOntoLeaf() {
            let moved = welcomeTab("Moved")
            let terminal = createLeaf("terminal")
            let root = createSplit(.horizontal, [createTabs([moved, welcomeTab("Stays")]), terminal])

            let landed = Tree.dockTab(root, moved.id, terminal.id, .center, titleOf).childNodes[safe: 1]

            #expect(landed?.isTabs == true)
            #expect(landed?.tabItems.count == 2)
            // Identity is the contract: a live pane is registered against this node's id.
            #expect(landed?.tabItems[safe: 0]?.content == terminal)
            #expect(landed?.tabItems[safe: 0]?.title == "terminal")
            #expect(landed?.tabItems[safe: 1] == moved)
            #expect(landed?.activeTabID == moved.id)
        }

        @Test("is a no-op for every zone canDockTab declines")
        func declined() {
            let only = welcomeTab("Only")
            let soloGroup = createTabs([only])
            #expect(Tree.dockTab(soloGroup, only.id, soloGroup.id, .right, titleOf) == soloGroup)

            let (a, b) = (welcomeTab("A"), welcomeTab("B"))
            let group = createTabs([a, b])
            #expect(Tree.dockTab(group, a.id, group.id, .center, titleOf) == group)

            // A target nested inside the dragged tab's own content.
            let innerLeaf = createLeaf("welcome")
            let innerSplit = createSplit(.horizontal, [innerLeaf, createLeaf("welcome")])
            let outerTab = createTab("Outer", innerSplit)
            let root = createTabs([outerTab, welcomeTab("Other")])
            #expect(Tree.dockTab(root, outerTab.id, innerLeaf.id, .right, titleOf) == root)
            #expect(Tree.dockTab(root, outerTab.id, innerLeaf.id, .center, titleOf) == root)

            // Unknown ids and split targets.
            #expect(Tree.dockTab(root, "missing", root.id, .left, titleOf) == root)
            #expect(Tree.dockTab(root, outerTab.id, "missing", .left, titleOf) == root)
            #expect(Tree.dockTab(root, root.tabItems[1].id, innerSplit.id, .left, titleOf) == root)
        }
    }

    @Suite struct CanDockTab {
        @Test("accepts zones that would change the layout")
        func accepts() {
            let moved = welcomeTab("Moved")
            let source = createTabs([moved, welcomeTab("Stays")])
            let terminal = createLeaf("terminal")
            let root = createSplit(.horizontal, [source, terminal])

            #expect(Tree.canDockTab(root, moved.id, terminal.id, .left))
            #expect(Tree.canDockTab(root, moved.id, terminal.id, .center))
            // Edge-docking against the tab's own group works while other tabs remain.
            #expect(Tree.canDockTab(root, moved.id, source.id, .bottom))
        }

        @Test("declines self, cyclic, and unresolvable targets")
        func declines() {
            let inner = createLeaf("welcome")
            let draggedTab = createTab("Dragged", createSplit(.horizontal, [inner, createLeaf("welcome")]))
            let root = createTabs([draggedTab])

            // Center on the tab's own group, and edges when it's the only tab.
            #expect(!Tree.canDockTab(root, draggedTab.id, root.id, .center))
            #expect(!Tree.canDockTab(root, draggedTab.id, root.id, .left))
            // Anywhere inside the dragged tab's own content, including the content itself.
            #expect(!Tree.canDockTab(root, draggedTab.id, inner.id, .right))
            #expect(!Tree.canDockTab(root, draggedTab.id, draggedTab.content.id, .center))
            // Unknown ids.
            #expect(!Tree.canDockTab(root, "missing", root.id, .left))
            #expect(!Tree.canDockTab(root, draggedTab.id, "missing", .left))
        }
    }

    @Suite struct ClosePane {
        @Test("removes a split child, collapsing the split to the sibling by reference")
        func splitChild() {
            let left = createLeaf("terminal")
            let right = createLeaf("welcome")
            #expect(Tree.closePane(createSplit(.horizontal, [left, right]), left.id) == right)
        }

        @Test("closes a tab-content pane through its tab, collapsing a two-tab group to the survivor")
        func tabContent() {
            let closed = welcomeTab("Closed")
            let stays = welcomeTab("Stays")
            let root = createTabs([closed, stays])

            // Routed through closeTab: the lone survivor unwraps in place, where a
            // bare removeNode would leave a single-tab group standing.
            #expect(Tree.closePane(root, closed.content.id) == stays.content)
        }

        @Test("activates the right neighbor when closing a tab-content pane in a larger group")
        func rightNeighbour() {
            let (a, b, c) = (welcomeTab("A"), welcomeTab("B"), welcomeTab("C"))
            let root = createTabs([a, b, c], active: b.id)

            let next = Tree.closePane(root, b.content.id)

            #expect(next.tabItems == [a, c])
            #expect(next.activeTabID == c.id)
        }

        @Test("resets the root to a fresh empty pane")
        func root() {
            let root = createLeaf("terminal")

            let next = Tree.closePane(root, root.id)

            #expect(next.kind == "empty")
            #expect(next.id != root.id)
        }

        @Test("returns a closed last child's freed space to its left neighbor in a 3-child split")
        func lastChild() {
            let (p1, a, b) = (createLeaf("terminal"), createLeaf("welcome"), createLeaf("browser"))
            let root = createSplit(.horizontal, [p1, a, b], sizes: [0.5, 0.25, 0.25])

            let next = Tree.closePane(root, b.id)

            #expect(next.childIDs == [p1.id, a.id])
            #expect(isClose(next.sizes[safe: 0], 0.5))
            #expect(isClose(next.sizes[safe: 1], 0.5))
        }

        @Test("returns a closed first child's freed space to its right neighbor")
        func firstChild() {
            let (a, b, c) = (createLeaf("terminal"), createLeaf("welcome"), createLeaf("browser"))
            let root = createSplit(.horizontal, [a, b, c], sizes: [0.3, 0.1, 0.6])

            let next = Tree.closePane(root, a.id)

            #expect(next.childIDs == [b.id, c.id])
            #expect(isClose(next.sizes[safe: 0], 0.4))
            #expect(isClose(next.sizes[safe: 1], 0.6))
        }

        @Test("splits a closed middle child's freed space evenly between both neighbors in a 4-child split")
        func middleChild() {
            let (a, b, c, d) = (createLeaf("terminal"), createLeaf("welcome"), createLeaf("browser"), createLeaf("terminal"))
            let root = createSplit(.horizontal, [a, b, c, d], sizes: [0.1, 0.2, 0.3, 0.4])

            let next = Tree.closePane(root, c.id)

            #expect(next.childIDs == [a.id, b.id, d.id])
            #expect(isClose(next.sizes[safe: 0], 0.1))
            #expect(isClose(next.sizes[safe: 1], 0.35))
            #expect(isClose(next.sizes[safe: 2], 0.55))
        }

        @Test("restores the original pane's exact pre-split size on a split-then-close round trip, with existing siblings")
        func roundTrip() {
            let (p1, p2, a) = (createLeaf("terminal"), createLeaf("welcome"), createLeaf("browser"))
            let root = createSplit(.horizontal, [p1, p2, a], sizes: [0.3, 0.3, 0.4])

            let split = Tree.splitContent(root, a.id, .horizontal, createLeaf("welcome"))
            let newPane = split.childNodes.last!

            let restored = Tree.closePane(split, newPane.id)

            #expect(restored.childIDs == [p1.id, p2.id, a.id])
            #expect(isClose(restored.sizes[safe: 0], 0.3))
            #expect(isClose(restored.sizes[safe: 1], 0.3))
            #expect(isClose(restored.sizes[safe: 2], 0.4))
        }
    }

    @Suite struct WrapInTabs {
        @Test("wraps a split child into a single-tab group by reference, titled by titleOf")
        func splitChild() {
            let terminal = createLeaf("terminal")
            let other = createLeaf("welcome")
            let root = createSplit(.horizontal, [terminal, other])

            let next = Tree.wrapInTabs(root, terminal.id, titleOf)
            let group = next.childNodes[safe: 0]

            #expect(group?.isTabs == true)
            #expect(group?.tabItems.count == 1)
            #expect(group?.tabItems[safe: 0]?.content == terminal)
            #expect(group?.tabItems[safe: 0]?.title == "terminal")
            #expect(group?.activeTabID == group?.tabItems[safe: 0]?.id)
            #expect(next.childNodes[safe: 1] == other)
        }

        @Test("wraps the root, and the single-tab group survives normalize")
        func root() {
            let root = createLeaf("terminal")

            let wrapped = Tree.wrapInTabs(root, root.id, titleOf)

            #expect(wrapped.isTabs)
            #expect(wrapped.tabItems[safe: 0]?.content == root)
            // Only removal paths collapse a lone tab; a deliberate wrap persists.
            #expect(Tree.normalize(wrapped) == wrapped)
        }

        @Test("wraps a tab's content into a nested group without disturbing the outer tab")
        func tabContent() {
            let inner = createLeaf("terminal")
            let outerTab = createTab("Outer", inner)
            let other = welcomeTab("Other")
            let root = createTabs([outerTab, other])

            let next = Tree.wrapInTabs(root, inner.id, titleOf)
            let nested = next.tabItems[safe: 0]?.content

            #expect(next.tabItems[safe: 0]?.id == outerTab.id)
            #expect(next.tabItems[safe: 0]?.title == "Outer")
            #expect(nested?.isTabs == true)
            #expect(nested?.tabItems[safe: 0]?.content == inner)
            #expect(next.tabItems[safe: 1] == other)
        }

        @Test("is a no-op for a missing id")
        func missing() {
            let root = createLeaf("terminal")
            #expect(Tree.wrapInTabs(root, "missing", titleOf) == root)
        }
    }

    @Suite struct UngroupTabs {
        @Test("collapses a single-tab group to that tab's own content, by reference")
        func collapses() {
            let only = welcomeTab("Only")
            let root = createTabs([only])

            let next = Tree.ungroupTabs(root, root.id)

            #expect(!next.isTabs)
            #expect(next == only.content)
        }

        @Test("is a no-op for a group with more than one tab")
        func severalTabs() {
            let root = createTabs([welcomeTab("A"), welcomeTab("B")])
            #expect(Tree.ungroupTabs(root, root.id) == root)
        }

        @Test("collapses a single-tab group inside a split, leaving the split and its sibling untouched")
        func inSplit() {
            let only = welcomeTab("Only")
            let left = createTabs([only])
            let right = createTabs([welcomeTab("Right")])
            let split = createSplit(.horizontal, [left, right])

            let next = Tree.ungroupTabs(split, left.id)

            #expect(next.childNodes.count == 2)
            #expect(next.childNodes[safe: 0] == only.content)
            #expect(next.childNodes[safe: 1] == right)
        }

        @Test("is a no-op for a missing id")
        func missing() {
            let root = createTabs([welcomeTab("Only")])
            #expect(Tree.ungroupTabs(root, "missing") == root)
        }
    }

    @Suite struct CanDockPane {
        @Test("accepts detachable panes against outside targets, wherever they live")
        func accepts() {
            let inner = createLeaf("terminal")
            let innerSplit = createSplit(.vertical, [inner, createLeaf("welcome")])
            let tabContent = createLeaf("welcome")
            let group = createTabs([createTab("T", tabContent)])
            let root = createSplit(.horizontal, [innerSplit, group])

            #expect(Tree.canDockPane(root, group.id, inner.id, .left))
            // A nested split's child is just as detachable as a top-level one.
            #expect(Tree.canDockPane(root, inner.id, group.id, .center))
            // A tab's content travels alone, independent of its tab.
            #expect(Tree.canDockPane(root, tabContent.id, inner.id, .right))
        }

        @Test("declines the root, split targets, self/descendants, and unknown ids")
        func declines() {
            let inner = createLeaf("terminal")
            let innerSplit = createSplit(.vertical, [inner, createLeaf("welcome")])
            let tabContent = createLeaf("welcome")
            let group = createTabs([createTab("T", tabContent)])
            let root = createSplit(.horizontal, [innerSplit, group])

            // The root has nowhere else to go.
            #expect(!Tree.canDockPane(root, root.id, group.id, .left))
            // Splits are containers, not dock targets.
            #expect(!Tree.canDockPane(root, group.id, innerSplit.id, .left))
            // A pane can't land on itself or anything inside its own subtree.
            #expect(!Tree.canDockPane(root, group.id, group.id, .left))
            #expect(!Tree.canDockPane(root, group.id, tabContent.id, .center))
            // Unknown ids.
            #expect(!Tree.canDockPane(root, "missing", group.id, .left))
            #expect(!Tree.canDockPane(root, group.id, "missing", .left))
        }

        @Test("governs docking against the pane's own enclosing group by what would remain")
        func ownGroup() {
            let only = createLeaf("terminal")
            let soloGroup = createTabs([createTab("Only", only)])
            let soloRoot = createSplit(.horizontal, [soloGroup, createLeaf("welcome")])

            // A one-tab group leaves with its pane: nothing to split against.
            #expect(!Tree.canDockPane(soloRoot, only.id, soloGroup.id, .right))
            #expect(!Tree.canDockPane(soloRoot, only.id, soloGroup.id, .center))

            let a = createLeaf("terminal")
            let pairGroup = createTabs([createTab("A", a), createTab("B", createLeaf("welcome"))])

            // With a survivor, an edge split rearranges; center would only
            // re-group what is already grouped.
            #expect(Tree.canDockPane(pairGroup, a.id, pairGroup.id, .right))
            #expect(!Tree.canDockPane(pairGroup, a.id, pairGroup.id, .center))
        }
    }

    @Suite struct CanMovePaneToTabs {
        @Test("accepts groups outside the pane, requiring its own bar to outlive the detach")
        func accepts() {
            let (t1, t2, t3) = (welcomeTab("T1"), welcomeTab("T2"), welcomeTab("T3"))
            let group = createTabs([t1, t2, t3])
            let otherGroup = createTabs([welcomeTab("Other")])
            let root = createSplit(.horizontal, [group, otherGroup])

            #expect(Tree.canMovePaneToTabs(root, t1.content.id, otherGroup.id))
            // Three tabs: the bar survives losing the pane's own tab.
            #expect(Tree.canMovePaneToTabs(root, t1.content.id, group.id))
        }

        @Test("declines bars that would collapse with the detach, subtrees, and non-groups")
        func declines() {
            let (t1, t2) = (welcomeTab("T1"), welcomeTab("T2"))
            let pairGroup = createTabs([t1, t2])
            let nested = createLeaf("welcome")
            let nestedGroup = createTabs([createTab("Nested", nested)])
            let leaf = createLeaf("terminal")
            let root = createSplit(.horizontal, [pairGroup, createSplit(.vertical, [nestedGroup, leaf])])

            // Two tabs: losing the pane's own tab collapses the bar it would join.
            #expect(!Tree.canMovePaneToTabs(root, t1.content.id, pairGroup.id))
            // One tab: the whole group departs with the pane.
            #expect(!Tree.canMovePaneToTabs(root, nested.id, nestedGroup.id))
            // A group inside the dragged pane's own subtree.
            #expect(!Tree.canMovePaneToTabs(root, pairGroup.id, pairGroup.id))
            // Non-group targets, the root, unknown ids.
            #expect(!Tree.canMovePaneToTabs(root, leaf.id, leaf.id))
            #expect(!Tree.canMovePaneToTabs(root, root.id, pairGroup.id))
            #expect(!Tree.canMovePaneToTabs(root, "missing", pairGroup.id))
            #expect(!Tree.canMovePaneToTabs(root, leaf.id, "missing"))
        }
    }

    @Suite struct CanMoveTabToTabs {
        @Test("accepts another group, and the tab’s own bar (a reorder)")
        func accepts() {
            let tab = welcomeTab("Moving")
            let group = createTabs([tab, welcomeTab("Sibling")])
            let otherGroup = createTabs([welcomeTab("Other")])
            let root = createSplit(.horizontal, [group, otherGroup])

            #expect(Tree.canMoveTabToTabs(root, tab.id, otherGroup.id))
            #expect(Tree.canMoveTabToTabs(root, tab.id, group.id))
        }

        @Test("declines a group nested inside the dragged tab’s own content, non-groups, unknown ids")
        func declines() {
            let nestedGroup = createTabs([welcomeTab("Nested")])
            let tab = createTab("Holder", nestedGroup)
            let group = createTabs([tab])
            let leaf = createLeaf("terminal")
            let root = createSplit(.horizontal, [group, leaf])

            #expect(!Tree.canMoveTabToTabs(root, tab.id, nestedGroup.id))
            #expect(!Tree.canMoveTabToTabs(root, tab.id, leaf.id))
            #expect(!Tree.canMoveTabToTabs(root, "missing", group.id))
            #expect(!Tree.canMoveTabToTabs(root, tab.id, "missing"))
        }
    }

    @Suite struct DockPane {
        @Test("splices an edge-docked pane into a same-direction split, landing bare")
        func splicesBare() {
            let a = createLeaf("terminal")
            let b = createLeaf("welcome")
            let c = createTabs([welcomeTab("Existing")])
            let root = createSplit(.horizontal, [a, b, c], sizes: [0.5, 0.25, 0.25])

            let next = Tree.dockPane(root, a.id, c.id, .right, titleOf)

            #expect(next.direction == .horizontal)
            #expect(next.childNodes.count == 3)
            #expect(next.childNodes[safe: 0] == b)
            #expect(next.childNodes[safe: 1] == c)
            // The pane lands bare — it's already standalone content, no group wrapper.
            #expect(next.childNodes[safe: 2] == a)
            // The freed share rescales away; the target's share splits with the pane.
            #expect(isClose(next.sizes[safe: 0], 0.5))
            #expect(isClose(next.sizes[safe: 1], 0.25))
            #expect(isClose(next.sizes[safe: 2], 0.25))
        }

        @Test("top-docks across directions, unwrapping the vacated two-child split")
        func topAcross() {
            let moved = createLeaf("terminal")
            let stays = createLeaf("welcome")
            let root = createSplit(.horizontal, [moved, stays])

            let next = Tree.dockPane(root, moved.id, stays.id, .top, titleOf)

            #expect(next.direction == .vertical)
            #expect(next.childNodes[safe: 0] == moved)
            #expect(next.childNodes[safe: 1] == stays)
            #expect(next.sizes == [0.5, 0.5])
        }

        @Test("center-docks onto a group, appending one tab holding the pane")
        func centerOntoGroup() {
            let moved = createLeaf("terminal")
            let target = createTabs([welcomeTab("Existing")])
            let root = createSplit(.horizontal, [moved, target])

            let next = Tree.dockPane(root, moved.id, target.id, .center, titleOf)

            // The vacated split unwraps down to the target group itself.
            #expect(next.id == target.id)
            #expect(next.tabItems.count == 2)
            #expect(next.tabItems[safe: 1]?.content == moved)
            #expect(next.tabItems[safe: 1]?.title == "terminal")
            #expect(next.activeTabID == next.tabItems[safe: 1]?.id)
        }

        @Test("center-docks a tab-group pane as a single tab holding the whole group")
        func centerGroupPane() {
            let movedGroup = createTabs([welcomeTab("A"), welcomeTab("B")])
            let target = createTabs([welcomeTab("Existing")])
            let root = createSplit(.horizontal, [movedGroup, target])

            let next = Tree.dockPane(root, movedGroup.id, target.id, .center, titleOf)

            #expect(next.id == target.id)
            #expect(next.tabItems.count == 2)
            // Recursive identity: the group nests as one tab — unmerged, whole.
            #expect(next.tabItems[safe: 1]?.content == movedGroup)
        }

        @Test("center-docks onto an empty pane, taking over its slot under the pane's own id")
        func centerOntoEmpty() {
            let moved = createLeaf("terminal")
            let stays = createLeaf("welcome")
            let empty = createLeaf("empty")
            let root = createSplit(.horizontal, [createSplit(.vertical, [moved, stays]), empty])

            let next = Tree.dockPane(root, moved.id, empty.id, .center, titleOf)

            #expect(next.childNodes[safe: 0] == stays)
            // Unlike a tab drop, the travelling node keeps its own id — live
            // content is keyed to it — and the placeholder's id disappears.
            #expect(next.childNodes[safe: 1] == moved)
            #expect(Tree.findNode(next, empty.id) == nil)
        }

        @Test("center-docks onto a bare leaf, promoting both into a two-tab group by reference")
        func centerOntoLeaf() {
            let moved = createLeaf("terminal")
            let target = createLeaf("welcome")
            let root = createSplit(.horizontal, [moved, target])

            let next = Tree.dockPane(root, moved.id, target.id, .center, titleOf)

            #expect(next.isTabs)
            #expect(next.tabItems.count == 2)
            #expect(next.tabItems[safe: 0]?.content == target)
            #expect(next.tabItems[safe: 0]?.title == "welcome")
            #expect(next.tabItems[safe: 1]?.content == moved)
            #expect(next.activeTabID == next.tabItems[safe: 1]?.id)
        }

        @Test("closes the tab it leaves behind, collapsing a two-tab group to the survivor")
        func closesTabBehind() {
            let moved = createLeaf("terminal")
            let stays = createLeaf("welcome")
            let group = createTabs([createTab("Moved", moved), createTab("Stays", stays)])
            let other = createTabs([welcomeTab("Existing")])
            let root = createSplit(.horizontal, [group, other])

            let next = Tree.dockPane(root, moved.id, other.id, .right, titleOf)

            // The pane travelled alone: its tab closed, and the group — down to
            // one tab — collapsed to the survivor's bare content in the same slot.
            #expect(next.childNodes.count == 3)
            #expect(next.childNodes[safe: 0] == stays)
            #expect(next.childNodes[safe: 1] == other)
            #expect(next.childNodes[safe: 2] == moved)
            #expect(Tree.findNode(next, group.id) == nil)
        }

        @Test("dissolves a one-tab group entirely when its pane is dragged out")
        func dissolvesOneTabGroup() {
            let moved = createLeaf("terminal")
            let group = createTabs([createTab("Only", moved)])
            let other = createLeaf("welcome")
            let root = createSplit(.horizontal, [group, other])

            let next = Tree.dockPane(root, moved.id, other.id, .left, titleOf)

            // No husk where the move began: the emptied group gave up its slot,
            // so only the target and the landed pane remain.
            #expect(next.direction == .horizontal)
            #expect(next.childNodes.count == 2)
            #expect(next.childNodes[safe: 0] == moved)
            #expect(next.childNodes[safe: 1] == other)
            #expect(Tree.findNode(next, group.id) == nil)
            #expect(!next.childNodes.contains { $0.kind == "empty" })
        }

        @Test("edge-docks against the pane's own two-tab group by splitting off the survivor")
        func againstOwnGroup() {
            let moved = createLeaf("terminal")
            let stays = createLeaf("welcome")
            let root = createTabs([createTab("Moved", moved), createTab("Stays", stays)])

            let next = Tree.dockPane(root, moved.id, root.id, .right, titleOf)

            // Removing the pane's tab collapses the group to the survivor's
            // content — a different node id — and the split forms against it.
            #expect(next.isSplit)
            #expect(next.direction == .horizontal)
            #expect(next.childNodes[safe: 0] == stays)
            #expect(next.childNodes[safe: 1] == moved)
        }

        @Test("is a no-op for every case canDockPane declines")
        func declined() {
            let tabContent = createLeaf("welcome")
            let group = createTabs([createTab("T", tabContent)])
            let leaf = createLeaf("terminal")
            let root = createSplit(.horizontal, [group, leaf])

            #expect(Tree.dockPane(root, root.id, leaf.id, .left, titleOf) == root)
            #expect(Tree.dockPane(root, leaf.id, leaf.id, .center, titleOf) == root)
            #expect(Tree.dockPane(root, leaf.id, root.id, .left, titleOf) == root)
            #expect(Tree.dockPane(root, group.id, tabContent.id, .center, titleOf) == root)
            // The pane's own one-tab group would leave with it: nothing to dock against.
            #expect(Tree.dockPane(root, tabContent.id, group.id, .right, titleOf) == root)
            #expect(Tree.dockPane(root, "missing", leaf.id, .left, titleOf) == root)
            #expect(Tree.dockPane(root, leaf.id, "missing", .left, titleOf) == root)
        }

        @Test("edge-docking onto a tab's own content splits within that tab, leaving its group untouched")
        func withinTab() {
            let moved = createLeaf("terminal")
            let active = createLeaf("welcome")
            let activeTab = createTab("Active", active)
            let otherTab = createTab("Other", createLeaf("welcome"))
            let group = createTabs([activeTab, otherTab], active: activeTab.id)
            let root = createSplit(.horizontal, [group, moved])

            let next = Tree.dockPane(root, moved.id, active.id, .right, titleOf)

            // The group itself is untouched — same id, same tab count — only the
            // active tab's own content became a split of [active, moved].
            #expect(next.id == group.id)
            #expect(next.tabItems.count == 2)
            #expect(next.tabItems[safe: 1] == otherTab)
            let splitNode = next.tabItems[safe: 0]?.content
            #expect(splitNode?.isSplit == true)
            #expect(splitNode?.direction == .horizontal)
            #expect(splitNode?.childNodes[safe: 0] == active)
            #expect(splitNode?.childNodes[safe: 1] == moved)
        }
    }

    @Suite struct WithPaneDetached {
        @Test("drops a split child's slot and its size entry")
        func splitChild() {
            let (a, b, c) = (createLeaf("terminal"), createLeaf("browser"), createLeaf("terminal"))
            let root = createSplit(.horizontal, [a, b, c], sizes: [0.2, 0.3, 0.5])

            let next = Tree.withPaneDetached(root, b.id)

            #expect(next?.childIDs == [a.id, c.id])
            #expect(next?.sizes == [0.2, 0.5])
        }

        @Test("closes only the tab that held the pane")
        func closesItsTab() {
            let pane = createLeaf("terminal")
            let root = createTabs([welcomeTab("A"), createTab("B", pane), welcomeTab("C")])

            #expect(Tree.withPaneDetached(root, pane.id)?.titles == ["A", "C"])
        }

        @Test("removes a one-tab group entirely, leaving no placeholder behind")
        func oneTabGroup() {
            let pane = createLeaf("terminal")
            let survivor = createLeaf("browser")
            let root = createSplit(.horizontal, [createTabs([createTab("Only", pane)]), survivor])

            #expect(Tree.withPaneDetached(root, pane.id)?.childIDs == [survivor.id])
        }

        @Test("returns nil when the pane is the whole tree")
        func wholeTree() {
            let root = createLeaf("terminal")
            #expect(Tree.withPaneDetached(root, root.id) == nil)
        }
    }

    @Suite struct WithTabDetached {
        @Test("splices the tab out of a multi-tab group")
        func multiTab() {
            let moved = createTab("B", createLeaf("terminal"))
            let root = createTabs([welcomeTab("A"), moved, welcomeTab("C")])

            #expect(Tree.withTabDetached(root, moved.id)?.titles == ["A", "C"])
        }

        @Test("collapses a one-tab group entirely, leaving no placeholder behind")
        func oneTabGroup() {
            let only = createTab("Only", createLeaf("terminal"))
            let survivor = createLeaf("browser")
            let root = createSplit(.horizontal, [createTabs([only]), survivor])

            #expect(Tree.withTabDetached(root, only.id)?.childIDs == [survivor.id])
        }

        @Test("returns nil when the tab is the whole tree")
        func wholeTree() {
            let only = welcomeTab("Only")
            #expect(Tree.withTabDetached(createTabs([only]), only.id) == nil)
        }

        @Test("returns nil when the tab id does not resolve")
        func missing() {
            #expect(Tree.withTabDetached(createTabs([welcomeTab("A")]), "missing") == nil)
        }
    }

    @Suite struct CanDockExternalTarget {
        @Test("accepts a bare leaf")
        func leaf() {
            let target = createLeaf("terminal")
            #expect(Tree.canDockExternalTarget(target, target.id))
        }

        @Test("accepts a tabs group")
        func group() {
            let target = createTabs([welcomeTab()])
            #expect(Tree.canDockExternalTarget(target, target.id))
        }

        @Test("refuses a split — only its children are ever real drop targets")
        func split() {
            let split = createSplit(.horizontal, [createLeaf("terminal"), createLeaf("browser")])
            #expect(!Tree.canDockExternalTarget(split, split.id))
        }

        @Test("refuses an id that does not resolve")
        func missing() {
            #expect(!Tree.canDockExternalTarget(createLeaf("terminal"), "missing"))
        }
    }

    @Suite struct InsertPaneAt {
        @Test("center-inserts onto an empty leaf, taking over its slot under the pane's own id")
        func ontoEmpty() {
            let empty = createLeaf("empty")
            let stays = createLeaf("welcome")
            let root = createSplit(.horizontal, [stays, empty])
            let incoming = createLeaf("terminal")

            let next = Tree.insertPaneAt(root, incoming, empty.id, .center, titleOf)

            #expect(next.childNodes[safe: 0] == stays)
            #expect(next.childNodes[safe: 1] == incoming)
            #expect(Tree.findNode(next, empty.id) == nil)
        }

        @Test("center-inserts onto a tabs group, appending one tab holding the pane")
        func ontoGroup() {
            let target = createTabs([welcomeTab("Existing")])
            let incoming = createLeaf("terminal")

            let next = Tree.insertPaneAt(target, incoming, target.id, .center, titleOf)

            #expect(next.id == target.id)
            #expect(next.tabItems.count == 2)
            #expect(next.tabItems[safe: 1]?.content == incoming)
            #expect(next.activeTabID == next.tabItems[safe: 1]?.id)
        }

        @Test("lands the new tab at a given index rather than appending — a tab-bar drop between tabs")
        func atIndex() {
            let target = createTabs([welcomeTab("First"), welcomeTab("Second")])
            let incoming = createLeaf("terminal")

            let next = Tree.insertPaneAt(target, incoming, target.id, .center, titleOf, at: 1)

            #expect(next.titles == ["First", "terminal", "Second"])
            #expect(next.tabItems[safe: 1]?.content == incoming)
            #expect(next.activeTabID == next.tabItems[safe: 1]?.id)
        }

        @Test("center-inserts onto a bare leaf, promoting both into a two-tab group by reference")
        func ontoLeaf() {
            let target = createLeaf("welcome")
            let incoming = createLeaf("terminal")

            let next = Tree.insertPaneAt(target, incoming, target.id, .center, titleOf)

            #expect(next.tabItems.count == 2)
            #expect(next.tabItems[safe: 0]?.content == target)
            #expect(next.tabItems[safe: 1]?.content == incoming)
        }

        @Test("edge-inserts by splitting the target, the pane landing bare")
        func edge() {
            let target = createLeaf("welcome")
            let incoming = createLeaf("terminal")

            let next = Tree.insertPaneAt(target, incoming, target.id, .right, titleOf)

            #expect(next.direction == .horizontal)
            #expect(next.childNodes[safe: 0] == target)
            #expect(next.childNodes[safe: 1] == incoming)
        }

        @Test("is a no-op against a split target")
        func splitTarget() {
            let split = createSplit(.horizontal, [createLeaf("terminal"), createLeaf("browser")])
            #expect(Tree.insertPaneAt(split, createLeaf("welcome"), split.id, .center, titleOf) == split)
        }

        @Test("is a no-op when the target id does not resolve")
        func missing() {
            let root = createLeaf("welcome")
            #expect(Tree.insertPaneAt(root, createLeaf("terminal"), "missing", .center, titleOf) == root)
        }
    }

    @Suite struct InsertTabAt {
        @Test("center-inserts onto an empty leaf, converting it into a group under the leaf's own id")
        func ontoEmpty() {
            let empty = createLeaf("empty")
            let incoming = createTab("Incoming", createLeaf("terminal"))

            let next = Tree.insertTabAt(empty, incoming, empty.id, .center, titleOf)

            #expect(next.id == empty.id)
            #expect(next.tabItems == [incoming])
            #expect(next.activeTabID == incoming.id)
        }

        @Test("center-inserts onto a tabs group, appending the tab")
        func ontoGroup() {
            let target = createTabs([welcomeTab("Existing")])
            let incoming = createTab("Incoming", createLeaf("terminal"))

            let next = Tree.insertTabAt(target, incoming, target.id, .center, titleOf)

            #expect(next.id == target.id)
            #expect(next.tabItems.map(\.id) == [target.tabItems[0].id, incoming.id])
        }

        @Test("lands the tab at a given index rather than appending — a tab-bar drop between tabs")
        func atIndex() {
            let target = createTabs([welcomeTab("First"), welcomeTab("Second")])
            let incoming = createTab("Incoming", createLeaf("terminal"))

            let next = Tree.insertTabAt(target, incoming, target.id, .center, titleOf, at: 0)

            #expect(next.titles == ["Incoming", "First", "Second"])
            #expect(next.activeTabID == incoming.id)
        }

        @Test("center-inserts onto a bare leaf, promoting both into a two-tab group")
        func ontoLeaf() {
            let target = createLeaf("welcome")
            let incoming = createTab("Incoming", createLeaf("terminal"))

            let next = Tree.insertTabAt(target, incoming, target.id, .center, titleOf)

            #expect(next.tabItems.count == 2)
            #expect(next.tabItems[safe: 0]?.content == target)
            #expect(next.tabItems[safe: 1] == incoming)
        }

        @Test("edge-inserts by splitting the target, the tab landing wrapped in a fresh group")
        func edge() {
            let target = createLeaf("welcome")
            let incoming = createTab("Incoming", createLeaf("terminal"))

            let next = Tree.insertTabAt(target, incoming, target.id, .right, titleOf)

            #expect(next.direction == .horizontal)
            #expect(next.childNodes[safe: 0] == target)
            #expect(next.childNodes[safe: 1]?.tabItems == [incoming])
        }

        @Test("is a no-op against a split target")
        func splitTarget() {
            let split = createSplit(.horizontal, [createLeaf("terminal"), createLeaf("browser")])
            let incoming = createTab("Incoming", createLeaf("welcome"))
            #expect(Tree.insertTabAt(split, incoming, split.id, .center, titleOf) == split)
        }
    }

    @Suite struct MovePaneToTabs {
        @Test("moves a pane into a group as a tab at the index, activated")
        func atIndex() {
            let moved = createLeaf("terminal")
            let target = createTabs([welcomeTab("A"), welcomeTab("B")])
            let root = createSplit(.horizontal, [moved, target])

            let next = Tree.movePaneToTabs(root, moved.id, target.id, titleOf, at: 1)

            // The vacated split unwraps down to the group itself.
            #expect(next.id == target.id)
            #expect(next.titles == ["A", "terminal", "B"])
            #expect(next.tabItems[safe: 1]?.content == moved)
            #expect(next.activeTabID == next.tabItems[safe: 1]?.id)
        }

        @Test("collapses the vacated split and keeps untouched siblings by reference")
        func collapsesVacated() {
            let moved = createLeaf("terminal")
            let stays = createLeaf("welcome")
            let target = createTabs([welcomeTab("Existing")])
            let root = createSplit(.horizontal, [createSplit(.vertical, [moved, stays]), target])

            let next = Tree.movePaneToTabs(root, moved.id, target.id, titleOf)
            let landed = next.childNodes[safe: 1]

            #expect(next.childNodes[safe: 0] == stays)
            #expect(landed?.id == target.id)
            #expect(landed?.tabItems.count == 2)
            #expect(landed?.tabItems[safe: 1]?.content == moved)
        }

        @Test("moves a tab's pane to another bar, closing the tab behind it")
        func closesTabBehind() {
            let moved = createLeaf("terminal")
            let stays = createLeaf("welcome")
            let source = createTabs([createTab("Moved", moved), createTab("Stays", stays)])
            let target = createTabs([welcomeTab("Existing")])
            let root = createSplit(.horizontal, [source, target])

            let next = Tree.movePaneToTabs(root, moved.id, target.id, titleOf)
            let landed = next.childNodes[safe: 1]

            // The pane travelled alone: its tab closed, the two-tab source
            // collapsed to the survivor's content, and only the pane joined the
            // target bar.
            #expect(next.childNodes[safe: 0] == stays)
            #expect(Tree.findNode(next, source.id) == nil)
            #expect(landed?.id == target.id)
            #expect(landed?.tabItems.count == 2)
            #expect(landed?.tabItems[safe: 1]?.content == moved)
            #expect(landed?.tabItems[safe: 1]?.title == "terminal")
        }

        @Test("dissolves a one-tab group when its pane moves to another bar")
        func dissolves() {
            let moved = createLeaf("terminal")
            let group = createTabs([createTab("Only", moved)])
            let target = createTabs([welcomeTab("Existing")])
            let root = createSplit(.horizontal, [group, target])

            let next = Tree.movePaneToTabs(root, moved.id, target.id, titleOf)

            // The emptied group gave up its slot, so the vacated split unwrapped
            // down to the target bar itself — no husk left behind.
            #expect(next.id == target.id)
            #expect(next.tabItems.count == 2)
            #expect(next.tabItems[safe: 1]?.content == moved)
            #expect(Tree.findNode(next, group.id) == nil)
        }

        @Test("declines non-group targets, targets inside the pane, and undetachable panes")
        func declines() {
            let tabContent = createLeaf("welcome")
            let innerGroup = createTabs([createTab("Inner", tabContent)])
            let leaf = createLeaf("terminal")
            let root = createSplit(.horizontal, [innerGroup, leaf])

            #expect(Tree.movePaneToTabs(root, leaf.id, leaf.id, titleOf) == root)
            #expect(Tree.movePaneToTabs(root, root.id, innerGroup.id, titleOf) == root)
            // The pane's own one-tab bar leaves with it: nothing to join.
            #expect(Tree.movePaneToTabs(root, tabContent.id, innerGroup.id, titleOf) == root)
            #expect(Tree.movePaneToTabs(root, innerGroup.id, innerGroup.id, titleOf) == root)
            #expect(Tree.movePaneToTabs(root, "missing", innerGroup.id, titleOf) == root)
            #expect(Tree.movePaneToTabs(root, leaf.id, "missing", titleOf) == root)
        }
    }

    // Repairing hollow nodes off disk and evenly sizing a split with no sizes
    // array are about what a file can hold, so they are decoding tests: see
    // LayoutCodingTests.
    @Suite struct Normalize {
        @Test("flattens nested same-direction splits")
        func flattens() {
            let (a, b, c) = (createLeaf("welcome"), createLeaf("welcome"), createLeaf("welcome"))
            let outer = createSplit(.horizontal, [createSplit(.horizontal, [a, b]), c], sizes: [0.5, 0.5])

            let next = Tree.normalize(outer)

            #expect(next.childIDs == [a.id, b.id, c.id])
            #expect(isClose(next.sizes[safe: 0], 0.25))
            #expect(isClose(next.sizes[safe: 2], 0.5))
        }

        @Test("repairs a stale activeTabId")
        func staleActive() {
            let tab = welcomeTab("A")
            #expect(Tree.normalize(createTabs([tab], active: "gone")).activeTabID == tab.id)
        }

        @Test("falls back to an empty pane when the root collapses entirely")
        func collapses() {
            #expect(Tree.normalize(createSplit(.horizontal, [])).kind == "empty")
        }
    }

    @Suite struct FirstPaneID {
        @Test("returns a tabs/leaf root directly")
        func direct() {
            let root = createTabs([welcomeTab()])
            #expect(Tree.firstPaneID(root) == root.id)
        }

        @Test("descends into the first child of nested splits")
        func descends() {
            let leaf = createLeaf("empty")
            let root = createSplit(.horizontal, [createSplit(.vertical, [leaf, createLeaf("empty")]), createLeaf("empty")])
            #expect(Tree.firstPaneID(root) == leaf.id)
        }
    }

    @Suite struct StructuralSharing {
        @Test("keeps sibling subtrees reference-equal after addTab in the other pane")
        func addTab() {
            let left = createTabs([welcomeTab("Left")])
            let right = createTabs([welcomeTab("Right")])
            let root = createTabs([createTab("Root", createSplit(.horizontal, [left, right]))])

            let next = Tree.addTab(root, left.id, welcomeTab("New"))
            let nextSplit = next.tabItems[safe: 0]?.content

            #expect(next != root)
            #expect(nextSplit?.childNodes[safe: 0] != left)
            #expect(nextSplit?.childNodes[safe: 1] == right)
        }

        @Test("keeps sibling subtrees reference-equal after openContent in the other pane")
        func openContent() {
            let left = createTabs([welcomeTab("Left")])
            let right = createTabs([welcomeTab("Right")])
            let root = createSplit(.horizontal, [left, right])

            let next = Tree.openContent(root, left.id, createLeaf("terminal"), titleOf)

            #expect(next.childNodes[safe: 0] != left)
            #expect(next.childNodes[safe: 1] == right)
        }

        @Test("returns the same root when the target id does not exist")
        func missing() {
            let root = createTabs([welcomeTab()])
            #expect(Tree.addTab(root, "missing", welcomeTab()) == root)
        }
    }

    @Suite struct ReplaceContent {
        @Test("swaps a leaf for new content in place")
        func swaps() {
            let leaf = createLeaf("empty")
            let root = createTabs([createTab("Tab", leaf)])
            let group = createTabs([welcomeTab()])

            #expect(Tree.replaceContent(root, leaf.id, group).tabItems[safe: 0]?.content == group)
        }

        @Test("replaces the root itself")
        func root() {
            let root = createTabs([welcomeTab()])
            let leaf = createLeaf("empty")
            #expect(Tree.replaceContent(root, root.id, leaf) == leaf)
        }
    }

    @Suite struct RemoveNode {
        @Test("removing a split pane collapses the split")
        func collapses() {
            let empty = createLeaf("empty")
            let group = createTabs([welcomeTab()])
            #expect(Tree.removeNode(createSplit(.horizontal, [group, empty]), empty.id) == group)
        }

        @Test("removing the root resets it to an empty pane")
        func root() {
            let root = createTabs([welcomeTab()])

            let next = Tree.removeNode(root, root.id)

            #expect(next.kind == "empty")
            #expect(next.id != root.id)
        }
    }

    @Suite struct OpenContent {
        @Test("promotes an occupied pane into a group holding both, rather than replacing it")
        func promotes() {
            let existing = createLeaf("terminal")
            let added = createLeaf("terminal")

            let next = Tree.openContent(existing, existing.id, added, titleOf)

            #expect(next.isTabs)
            #expect(next.titles == ["terminal", "terminal"])
            #expect(next.tabItems[safe: 1]?.content == added)
            #expect(next.activeTabID == next.tabItems[safe: 1]?.id)
        }

        @Test("preserves the promoted content by reference rather than cloning it")
        func preserves() {
            let existing = createLeaf("terminal", ["cwd": "~"])

            let next = Tree.openContent(existing, existing.id, createLeaf("terminal"), titleOf)

            // Identity is the contract: a live pane is registered against this node's id.
            #expect(next.tabItems[safe: 0]?.content == existing)
        }

        @Test("fills an empty pane in place instead of opening a group beside it")
        func fillsEmpty() {
            let empty = createLeaf("empty")
            let root = createTabs([createTab("Tab", empty)])
            let terminal = createLeaf("terminal")

            let next = Tree.openContent(root, empty.id, terminal, titleOf)

            #expect(next.tabItems.count == 1)
            #expect(next.tabItems[safe: 0]?.content == terminal)
        }

        @Test("opens a blank pane as a group of exactly one tab, dropping the placeholder")
        func blankOntoBlank() {
            let empty = createLeaf("empty")
            let added = createLeaf("empty")

            let next = Tree.openContent(empty, empty.id, added, titleOf)

            #expect(next.isTabs)
            #expect(next.tabItems.count == 1)
            #expect(next.tabItems[safe: 0]?.content == added)
        }

        @Test("adds a sibling tab when the target is a tab's own content")
        func siblingTab() {
            let terminal = createLeaf("terminal")
            let root = createTabs([createTab("Terminal", terminal)])
            let added = createLeaf("terminal")

            let next = Tree.openContent(root, terminal.id, added, titleOf)

            #expect(next.id == root.id)
            #expect(next.tabItems.count == 2)
            #expect(next.tabItems[safe: 0]?.content == terminal)
            #expect(next.tabItems[safe: 1]?.content == added)
            #expect(next.activeTabID == next.tabItems[safe: 1]?.id)
            // The sibling joined this group; no group was nested inside the tab.
            #expect(!next.tabItems.contains { $0.content.isTabs })
        }

        @Test("appends a tab when the target is the group itself")
        func ontoGroup() {
            let root = createTabs([welcomeTab("First")])

            let next = Tree.openContent(root, root.id, createLeaf("terminal"), titleOf)

            #expect(next.titles == ["First", "terminal"])
            #expect(next.activeTabID == next.tabItems[safe: 1]?.id)
        }

        @Test("joins the nearest enclosing group, not an outer one")
        func nearestGroup() {
            let terminal = createLeaf("terminal")
            let inner = createTabs([createTab("Inner", terminal)])
            let outer = createTabs([createTab("Outer", inner)])
            let added = createLeaf("terminal")

            let next = Tree.openContent(outer, terminal.id, added, titleOf)
            let nextInner = next.tabItems[safe: 0]?.content

            #expect(next.tabItems.count == 1)
            #expect(nextInner?.tabItems.count == 2)
            #expect(nextInner?.tabItems[safe: 1]?.content == added)
        }

        @Test("keeps a split intact, sizes and all, when opening in one of its panes")
        func keepsSplit() {
            let left = createLeaf("empty")
            let right = createLeaf("terminal")
            let root = createSplit(.horizontal, [left, right], sizes: [0.3, 0.7])

            let next = Tree.openContent(root, left.id, createLeaf("empty"), titleOf)

            #expect(next.childNodes.count == 2)
            #expect(next.sizes == [0.3, 0.7])
            #expect(next.childNodes[safe: 0]?.isTabs == true)
            #expect(next.childNodes[safe: 1] == right)
        }

        @Test("nests a tab group opened onto occupied content, inside its own new tab")
        func nestsGroup() {
            let terminal = createLeaf("terminal")
            let group = createTabs([createTab("New Tab", createLeaf("empty"))])

            let next = Tree.openContent(terminal, terminal.id, group, titleOf)

            #expect(next.tabItems[safe: 0]?.content == terminal)
            #expect(next.tabItems[safe: 1]?.content == group)
        }

        @Test("returns the same root when the target id does not exist")
        func missing() {
            let root = createTabs([welcomeTab()])
            #expect(Tree.openContent(root, "missing", createLeaf("terminal"), titleOf) == root)
        }
    }

    @Suite struct LookupHelpers {
        @Test("findNode and findTab locate deeply nested nodes")
        func deep() {
            let leaf = createLeaf("welcome")
            let innerTab = createTab("Inner", leaf)
            let inner = createTabs([innerTab])
            let root = createTabs([createTab("Root", createSplit(.vertical, [inner, createTabs([welcomeTab()])]))])

            #expect(Tree.findNode(root, leaf.id) == leaf)
            #expect(Tree.findTab(root, innerTab.id).map { LayoutNode.tabs($0.group) } == inner)
        }
    }

    /// `LayoutNode.leaves`.
    @Suite struct CollectLeaves {
        @Test("returns a single leaf as itself")
        func single() {
            let leaf = createLeaf("terminal")
            #expect(leaf.leaves.map { LayoutNode.leaf($0) } == [leaf])
        }

        @Test("collects every leaf nested across a split and a tab group, depth-first")
        func nested() {
            let tabbed = createLeaf("terminal")
            let other = createLeaf("empty")
            let direct = createLeaf("terminal")
            let root = createSplit(
                .horizontal, [createTabs([createTab("Tab", tabbed), createTab("Other", other)]), direct])

            #expect(root.leaves.map { LayoutNode.leaf($0) } == [tabbed, other, direct])
        }
    }
}
