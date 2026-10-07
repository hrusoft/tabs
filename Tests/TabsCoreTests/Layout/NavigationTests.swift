import Foundation
import TabsPluginSDK
import Testing

@testable import TabsCore

/// Keyboard navigation and focus choices.
@Suite struct NavigationTests {
    static func rect(_ left: Double, _ top: Double, _ right: Double, _ bottom: Double) -> NavRect {
        NavRect(left: left, top: top, right: right, bottom: bottom)
    }

    /// `ancestorTabSteps`' pairs, comparable.
    static func steps(_ root: LayoutNode, _ id: NodeID) -> [[NodeID]] {
        Navigation.ancestorTabSteps(root, id).map { [$0.groupID, $0.tabID] }
    }

    @Suite struct PickSpatialTarget {
        // Panes in one window share edges give or take a splitter, so fixtures
        // use a 4pt gap (the splitter) or a 1pt overlap (adjoining borders).
        let current = rect(0, 0, 100, 100)

        @Test("returns nil when no candidate lies in the direction")
        func none() {
            #expect(Navigation.pickSpatialTarget(current, [], .right) == nil)
            #expect(Navigation.pickSpatialTarget(current, [(id: "l", rect: rect(-104, 0, -4, 100))], .right) == nil)
        }

        @Test("picks the pane across the splitter gap")
        func acrossGap() {
            #expect(Navigation.pickSpatialTarget(current, [(id: "r", rect: rect(104, 0, 200, 100))], .right) == "r")
        }

        @Test("tolerates a 1pt border overlap at the shared edge")
        func borderOverlap() {
            #expect(Navigation.pickSpatialTarget(current, [(id: "r", rect: rect(99, 0, 200, 100))], .right) == "r")
        }

        @Test("rejects a pane that substantially overlaps the current one")
        func overlap() {
            #expect(Navigation.pickSpatialTarget(current, [(id: "o", rect: rect(50, 0, 150, 100))], .right) == nil)
        }

        @Test("picks the topmost pane in the adjacent column")
        func topmost() {
            let candidates: [(id: NodeID, rect: NavRect)] = [
                (id: "low", rect: rect(104, 200, 200, 300)), (id: "high", rect: rect(104, 0, 200, 100)),
            ]
            #expect(Navigation.pickSpatialTarget(current, candidates, .right) == "high")
        }

        @Test("prefers the adjacent column over a farther column, even one with a higher pane")
        func adjacentColumn() {
            // "Pick the topmost" applies within the nearest column: a literal
            // global topmost would vault over the neighbor to the far column's top pane.
            let tall = rect(0, 0, 100, 300)
            let candidates: [(id: NodeID, rect: NavRect)] = [
                (id: "near-low", rect: rect(104, 200, 200, 300)), (id: "far-high", rect: rect(204, 0, 300, 100)),
            ]
            #expect(Navigation.pickSpatialTarget(tall, candidates, .right) == "near-low")
        }

        @Test("treats columns within the tie epsilon as one and takes the topmost")
        func tieEpsilon() {
            let candidates: [(id: NodeID, rect: NavRect)] = [
                (id: "nearer-low", rect: rect(100, 50, 200, 100)), (id: "barely-farther-high", rect: rect(103, 0, 200, 40)),
            ]
            #expect(Navigation.pickSpatialTarget(current, candidates, .right) == "barely-farther-high")
        }

        @Test("mirrors for leftward movement")
        func leftward() {
            let candidates: [(id: NodeID, rect: NavRect)] = [
                (id: "low", rect: rect(0, 50, 96, 100)), (id: "high", rect: rect(0, 0, 96, 40)),
            ]
            #expect(Navigation.pickSpatialTarget(rect(100, 0, 200, 100), candidates, .left) == "high")
        }

        @Test("picks the leftmost pane in the adjacent row when moving down")
        func downward() {
            let candidates: [(id: NodeID, rect: NavRect)] = [
                (id: "right", rect: rect(100, 104, 200, 200)), (id: "left", rect: rect(0, 104, 96, 200)),
            ]
            #expect(Navigation.pickSpatialTarget(rect(0, 0, 200, 100), candidates, .down) == "left")
        }

        @Test("mirrors for upward movement")
        func upward() {
            let candidates: [(id: NodeID, rect: NavRect)] = [
                (id: "right", rect: rect(100, 0, 200, 96)), (id: "left", rect: rect(0, 0, 96, 96)),
            ]
            #expect(Navigation.pickSpatialTarget(rect(0, 100, 200, 200), candidates, .up) == "left")
        }

        @Test("breaks a tie by proximity to the current pane’s own row, not always topmost (2x2 grid)")
        func tieByRow() {
            // From the bottom-left pane of a 2x2 grid, moving right should land
            // on the bottom-right pane, not vault to the top-right one.
            let candidates: [(id: NodeID, rect: NavRect)] = [
                (id: "top-right", rect: rect(104, 0, 200, 100)), (id: "bottom-right", rect: rect(104, 104, 200, 204)),
            ]
            #expect(Navigation.pickSpatialTarget(rect(0, 104, 100, 204), candidates, .right) == "bottom-right")
        }

        @Test("breaks a tie by proximity to the current pane’s own column, not always leftmost (2x2 grid)")
        func tieByColumn() {
            // From the top-right pane of a 2x2 grid, moving down should land on
            // the bottom-right pane, not the bottom-left one.
            let candidates: [(id: NodeID, rect: NavRect)] = [
                (id: "bottom-left", rect: rect(0, 104, 100, 200)), (id: "bottom-right", rect: rect(104, 104, 204, 200)),
            ]
            #expect(Navigation.pickSpatialTarget(rect(104, 0, 204, 100), candidates, .down) == "bottom-right")
        }
    }

    @Suite struct PickWrapTarget {
        let current = rect(0, 0, 100, 100)
        let row: [(id: NodeID, rect: NavRect)] = [(id: "right", rect: rect(200, 0, 300, 100)), (id: "left", rect: rect(0, 0, 100, 100))]
        let column: [(id: NodeID, rect: NavRect)] = [(id: "bottom", rect: rect(0, 200, 100, 300)), (id: "top", rect: rect(0, 0, 100, 100))]

        @Test("returns nil when there are no other panes")
        func none() {
            #expect(Navigation.pickWrapTarget(current, [], .right) == nil)
        }

        @Test("picks the leftmost pane when wrapping rightward")
        func rightward() { #expect(Navigation.pickWrapTarget(current, row, .right) == "left") }

        @Test("picks the rightmost pane when wrapping leftward")
        func leftward() { #expect(Navigation.pickWrapTarget(current, row, .left) == "right") }

        @Test("picks the topmost pane when wrapping downward")
        func downward() { #expect(Navigation.pickWrapTarget(current, column, .down) == "top") }

        @Test("picks the bottommost pane when wrapping upward")
        func upward() { #expect(Navigation.pickWrapTarget(current, column, .up) == "bottom") }

        @Test("breaks a wrap tie by proximity to the current row, not always topmost (2x2 grid)")
        func tieByRow() {
            // Wrapping right from the bottom row continues on the bottom row.
            let candidates: [(id: NodeID, rect: NavRect)] = [
                (id: "top-left", rect: rect(0, 0, 100, 100)), (id: "bottom-left", rect: rect(0, 104, 100, 204)),
            ]
            #expect(Navigation.pickWrapTarget(rect(104, 104, 204, 204), candidates, .right) == "bottom-left")
        }

        @Test("breaks a wrap tie by proximity to the current column, not always leftmost (2x2 grid)")
        func tieByColumn() {
            // Wrapping down from the right column continues on the right column.
            let candidates: [(id: NodeID, rect: NavRect)] = [
                (id: "top-left", rect: rect(0, 0, 100, 100)), (id: "top-right", rect: rect(104, 0, 204, 100)),
            ]
            #expect(Navigation.pickWrapTarget(rect(104, 104, 204, 204), candidates, .down) == "top-right")
        }

        @Test("breaks a horizontal-wrap tie toward the current pane’s own row")
        func horizontalTie() {
            let candidates: [(id: NodeID, rect: NavRect)] = [
                (id: "low", rect: rect(0, 200, 100, 300)), (id: "high", rect: rect(0, 0, 100, 100)),
            ]
            // `current`'s own row (top 0) sits right against 'high'.
            #expect(Navigation.pickWrapTarget(current, candidates, .right) == "high")
            #expect(Navigation.pickWrapTarget(current, candidates, .left) == "high")
        }

        @Test("breaks a vertical-wrap tie toward the current pane’s own column")
        func verticalTie() {
            // `current`'s own column (left 0) sits right against 'left'.
            #expect(Navigation.pickWrapTarget(current, row, .down) == "left")
            #expect(Navigation.pickWrapTarget(current, row, .up) == "left")
        }
    }

    @Suite struct EntryPaneID {
        @Test("lands on a leaf itself regardless of direction")
        func leaf() {
            let leaf = createLeaf("welcome")
            for direction in NavDirection.allCases { #expect(Navigation.entryPaneID(leaf, direction) == leaf.id) }
        }

        @Test("enters a horizontal split from the side the movement crossed")
        func horizontal() {
            let (a, b, c) = (createLeaf("welcome"), createLeaf("welcome"), createLeaf("welcome"))
            let split = createSplit(.horizontal, [a, b, c])

            #expect(Navigation.entryPaneID(split, .right) == a.id)  // entering rightward → leftmost
            #expect(Navigation.entryPaneID(split, .left) == c.id)  // entering leftward → rightmost
            // Vertical movement crosses the top/bottom edge, which every column
            // touches equally: the leftmost wins the tie.
            #expect(Navigation.entryPaneID(split, .down) == a.id)
            #expect(Navigation.entryPaneID(split, .up) == a.id)
        }

        @Test("enters a vertical split from the side the movement crossed")
        func vertical() {
            let (a, b) = (createLeaf("welcome"), createLeaf("welcome"))
            let split = createSplit(.vertical, [a, b])

            #expect(Navigation.entryPaneID(split, .down) == a.id)  // entering downward → topmost
            #expect(Navigation.entryPaneID(split, .up) == b.id)  // entering upward → bottommost
            #expect(Navigation.entryPaneID(split, .right) == a.id)
            #expect(Navigation.entryPaneID(split, .left) == a.id)
        }

        @Test("recurses through nested splits toward the crossed edge")
        func nested() {
            let (a, b, c) = (createLeaf("welcome"), createLeaf("welcome"), createLeaf("welcome"))
            let root = createSplit(.horizontal, [createSplit(.vertical, [a, b]), c])

            // Entering upward: any horizontal child touches the bottom edge, so
            // the first (leftmost) column is entered, then its bottommost pane.
            #expect(Navigation.entryPaneID(root, .up) == b.id)
            // Entering leftward: the rightmost column is the plain leaf.
            #expect(Navigation.entryPaneID(root, .left) == c.id)
        }

        @Test("descends into the visible tab of a tab group")
        func visibleTab() {
            let (x, y) = (createLeaf("welcome"), createLeaf("welcome"))
            let shown = createTab("Shown", createSplit(.horizontal, [x, y]))
            let group = createTabs([welcomeTab("Behind"), shown], active: shown.id)

            #expect(Navigation.entryPaneID(group, .right) == x.id)
            #expect(Navigation.entryPaneID(group, .left) == y.id)
        }

        @Test("descends into the first tab when the active one has gone stale")
        func staleActive() {
            let (x, y) = (createLeaf("welcome"), createLeaf("welcome"))
            let group = createTabs([createTab("X", x), createTab("Y", y)], active: "gone")
            #expect(Navigation.entryPaneID(group, .right) == x.id)
        }

        @Test("falls back to the group itself only when it has no tabs at all")
        func noTabs() {
            let group = createTabs([])
            #expect(Navigation.entryPaneID(group, .right) == group.id)
        }

        @Test("drills to the first child/active tab when called with no direction")
        func noDirection() {
            let (a, b) = (createLeaf("welcome"), createLeaf("welcome"))
            #expect(Navigation.entryPaneID(createSplit(.horizontal, [a, b])) == a.id)

            let (x, y) = (createLeaf("welcome"), createLeaf("welcome"))
            let shown = createTab("Shown", createSplit(.horizontal, [x, y]))
            #expect(Navigation.entryPaneID(createTabs([welcomeTab("Behind"), shown], active: shown.id)) == x.id)

            let leaf = createLeaf("welcome")
            #expect(Navigation.entryPaneID(leaf) == leaf.id)
        }
    }

    @Suite struct AncestorTabSteps {
        @Test("returns one step per ancestor tab, innermost first")
        func innermostFirst() {
            let leaf = createLeaf("browser")
            let innerTab = createTab("Inner", leaf)
            // The inner tab is deliberately not the active one: the steps say
            // which tabs *would need* activating, regardless of visibility.
            let innerGroup = createTabs([welcomeTab("Front"), innerTab])
            let outerTab = createTab("Outer", createSplit(.horizontal, [innerGroup, createLeaf("welcome")]))
            let outerGroup = createTabs([outerTab, welcomeTab("Other")])

            #expect(steps(outerGroup, leaf.id) == [[innerGroup.id, innerTab.id], [outerGroup.id, outerTab.id]])
        }

        @Test("is empty for a pane under no tab, the root itself, and an absent id")
        func empty() {
            let leaf = createLeaf("welcome")
            let root = createSplit(.horizontal, [leaf, createLeaf("welcome")])

            #expect(steps(root, leaf.id).isEmpty)
            #expect(steps(root, root.id).isEmpty)
            #expect(steps(root, "missing").isEmpty)
        }
    }

    @Suite struct NavTarget {
        @Test("hands over to the next child of a split laid out along the pressed axis")
        func alongAxis() {
            let (a, b, c) = (createLeaf("welcome"), createLeaf("welcome"), createLeaf("welcome"))
            let root = createSplit(.horizontal, [a, b, c])

            #expect(Navigation.navTarget(root, a.id, .right) == Navigation.Target(node: b, tabSwitch: nil, wrapped: false))
            #expect(Navigation.navTarget(root, b.id, .left)?.node == a)
        }

        @Test("walks up past a split laid out across the pressed axis")
        func acrossAxis() {
            let (a, b, c) = (createLeaf("welcome"), createLeaf("welcome"), createLeaf("welcome"))
            let column = createSplit(.vertical, [a, b])
            let root = createSplit(.horizontal, [column, c])

            // The column can't move sideways, so the row above it hands over instead.
            #expect(Navigation.navTarget(root, b.id, .right)?.node == c)
            // Within the column, moving down is a plain step.
            #expect(Navigation.navTarget(root, a.id, .down)?.node == b)
            // And entering it from the right is the column as a whole.
            #expect(Navigation.navTarget(root, c.id, .left)?.node == column)
        }

        @Test("steps to the next tab before leaving the group for its sibling")
        func tabBeforeSibling() {
            let (p, q, r) = (createLeaf("welcome"), createLeaf("welcome"), createLeaf("welcome"))
            let (first, second) = (createTab("One", p), createTab("Two", q))
            let group = createTabs([first, second], active: first.id)
            let root = createSplit(.horizontal, [group, r])

            // `r` sits right there on screen, but the rest of the group comes first.
            let target = Navigation.navTarget(root, p.id, .right)
            #expect(target?.node == q)
            #expect(target?.tabSwitch?.groupID == group.id)
            #expect(target?.tabSwitch?.tabID == second.id)
            #expect(target?.wrapped == false)

            // Only once the group is exhausted does focus leave it.
            let onward = Navigation.navTarget(root, q.id, .right)
            #expect(onward?.node == r)
            #expect(onward != nil && onward?.tabSwitch == nil)
        }

        @Test("never switches tabs for up/down")
        func noTabSwitchVertically() {
            let (a, b) = (welcomeTab("A"), welcomeTab("B"))
            let root = createTabs([a, b], active: a.id)

            // A tab group holding one pane per tab has nothing above or below.
            #expect(Navigation.navTarget(root, a.content.id, .down) == nil)
            #expect(Navigation.navTarget(root, a.content.id, .up) == nil)
            #expect(Navigation.navTarget(root, a.content.id, .right)?.node == b.content)
        }

        @Test("moves between a pane and the tab group beside it without cycling its tabs")
        func paneAndGroup() {
            let above = createLeaf("welcome")
            let (first, second) = (welcomeTab("One"), welcomeTab("Two"))
            let group = createTabs([first, second], active: second.id)
            let root = createSplit(.vertical, [above, group])

            // Downward hands over the group itself — the caller enters its visible tab.
            #expect(Navigation.navTarget(root, above.id, .down)?.node == group)
            let back = Navigation.navTarget(root, second.content.id, .up)
            #expect(back?.node == above)
            #expect(back != nil && back?.tabSwitch == nil)
        }

        @Test("walks up past a single-tab group to the multi-tab one above it")
        func pastSingleTabGroup() {
            let leaf = createLeaf("welcome")
            let inner = createTabs([createTab("Only", leaf)])
            let other = welcomeTab("Other")
            let root = createTabs([createTab("Nested", inner), other])

            let target = Navigation.navTarget(root, leaf.id, .right)
            #expect(target?.node == other.content)
            #expect(target?.tabSwitch?.groupID == root.id)
            #expect(target?.tabSwitch?.tabID == other.id)
        }

        @Test("wraps the outermost container along the axis when nothing lies ahead")
        func wraps() {
            let (a, b, c) = (createLeaf("welcome"), createLeaf("welcome"), createLeaf("welcome"))
            let root = createSplit(.horizontal, [a, b, c])

            #expect(Navigation.navTarget(root, c.id, .right) == Navigation.Target(node: a, tabSwitch: nil, wrapped: true))
            #expect(Navigation.navTarget(root, a.id, .left)?.node == c)
        }

        @Test("wraps the outermost tab group rather than a split nested inside it")
        func wrapsOutermostGroup() {
            let (x, y) = (createLeaf("welcome"), createLeaf("welcome"))
            let first = welcomeTab("One")
            let second = createTab("Two", createSplit(.horizontal, [x, y]))
            let root = createTabs([first, second], active: second.id)

            // The inner split could wrap back to `x`, but the group's edge is
            // the one the press ran into.
            let target = Navigation.navTarget(root, y.id, .right)
            #expect(target?.tabSwitch?.groupID == root.id)
            #expect(target?.tabSwitch?.tabID == first.id)
            #expect(target?.wrapped == true)
            // Vertically the group is transparent, so there is nowhere to wrap at all.
            #expect(Navigation.navTarget(root, y.id, .down) == nil)
        }

        @Test("cycles a focused tab group itself, the same as its content would")
        func focusedGroup() {
            let (a, b) = (welcomeTab("A"), welcomeTab("B"))
            let root = createTabs([a, b], active: a.id)

            #expect(Navigation.navTarget(root, root.id, .right)?.node == b.content)
            #expect(Navigation.navTarget(root, root.id, .left)?.wrapped == true)
        }

        @Test("returns nil when no ancestor can move in that direction")
        func none() {
            let leaf = createLeaf("welcome")
            #expect(Navigation.navTarget(leaf, leaf.id, .right) == nil)

            let single = createTabs([createTab("Only", leaf)])
            #expect(Navigation.navTarget(single, leaf.id, .right) == nil)
        }
    }

    @Suite struct FocusAfterClose {
        @Test("lands on the left neighbor when closing the last child of a 3-way split")
        func lastChild() {
            let (a, b, c) = (createLeaf("welcome"), createLeaf("welcome"), createLeaf("welcome"))
            let root = createSplit(.horizontal, [a, b, c])
            let next = Tree.closePane(root, c.id)
            #expect(Navigation.focusAfterClose(root, next, c.id) == b.id)
        }

        @Test("lands on the right neighbor when closing the middle child of a 3-way split")
        func middleChild() {
            let (a, b, c) = (createLeaf("welcome"), createLeaf("welcome"), createLeaf("welcome"))
            let root = createSplit(.horizontal, [a, b, c])
            let next = Tree.closePane(root, b.id)
            #expect(Navigation.focusAfterClose(root, next, b.id) == c.id)
        }

        @Test("still lands on the sole survivor when a 2-way split collapses")
        func survivor() {
            let (a, b) = (createLeaf("welcome"), createLeaf("welcome"))
            let root = createSplit(.horizontal, [a, b])
            let next = Tree.closePane(root, b.id)
            #expect(Navigation.focusAfterClose(root, next, b.id) == a.id)
        }

        @Test("lands on the next tab's content when closing the active middle tab of a 3-tab group")
        func nextTab() {
            let (a, b, c) = (welcomeTab("A"), welcomeTab("B"), welcomeTab("C"))
            let root = createTabs([a, b, c], active: b.id)
            let next = Tree.closePane(root, b.content.id)
            #expect(Navigation.focusAfterClose(root, next, b.content.id) == c.content.id)
        }

        @Test("falls back to the fresh leaf that replaces a 1-tab group nested in a split")
        func freshLeafInSplit() throws {
            let leaf = createLeaf("welcome")
            let group = createTabs([createTab("Only", leaf)])
            let root = createSplit(.horizontal, [group, createLeaf("welcome")])

            let next = Tree.closePane(root, leaf.id)
            let replacement = try #require(next.childNodes[safe: 0])

            #expect(replacement.id != group.id)
            #expect(Navigation.focusAfterClose(root, next, leaf.id) == replacement.id)
        }

        @Test("falls back to the fresh leaf when a 1-tab group sits inside another tab's content")
        func freshLeafInTab() throws {
            let leaf = createLeaf("welcome")
            let inner = createTabs([createTab("Only", leaf)])
            let outerTab = createTab("Outer", inner)
            let root = createTabs([outerTab, welcomeTab("Sibling")])

            let next = Tree.closePane(root, leaf.id)
            let replacement = try #require(next.tabItems.first { $0.id == outerTab.id }, "expected the outer tab to survive the close")
                .content

            #expect(replacement.id != inner.id)
            #expect(Navigation.focusAfterClose(root, next, leaf.id) == replacement.id)
        }

        @Test("returns nil when the closed pane was the whole tree, deferring to the default fallback")
        func wholeTree() {
            let root = createLeaf("terminal")
            let next = Tree.closePane(root, root.id)
            #expect(Navigation.focusAfterClose(root, next, root.id) == nil)
        }
    }
}
