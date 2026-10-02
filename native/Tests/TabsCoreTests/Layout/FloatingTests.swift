import Foundation
import TabsPluginSDK
import Testing

@testable import TabsCore

/// Floating panes — ported from the Electron app's
/// src/shared/model/__tests__/floating.test.ts. What `sanitizeFloating` does
/// with an arbitrary file's contents is split natively: the tree-level
/// repairs (claimed ids, duplicate window ids, normalization) are
/// `Floating.sanitize`, tested here; the shape repairs (a missing id, an
/// unusable rect, a malformed anchor) happen while decoding, in
/// LayoutCodingTests.
@Suite struct FloatingTests {
    static let rect = FloatRect(x: 40, y: 60, width: 500, height: 300)

    static func float(_ content: LayoutNode, _ id: NodeID = "float-1") -> FloatingPane {
        FloatingPane(id: id, content: content, rect: rect, anchor: .root)
    }

    static func detach(_ root: LayoutNode, _ id: NodeID) throws -> (root: LayoutNode, floating: FloatingPane) {
        try #require(Floating.detachForFloat(root, id, rect: rect), "expected a detach")
    }

    @Suite struct CaptureAnchor {
        @Test("anchors a split child by its split, index, size and both neighbours")
        func splitChild() {
            let (a, b, c) = (createLeaf("terminal"), createLeaf("browser"), createLeaf("terminal"))
            let root = createSplit(.horizontal, [a, b, c], sizes: [0.2, 0.3, 0.5])

            #expect(
                Floating.captureAnchor(root, b.id)
                    == .split(.init(splitID: root.id, direction: .horizontal, index: 1, size: 0.3, beforeID: a.id, afterID: c.id)))
        }

        @Test("anchors a tab's content by its group, index and the tab's own title")
        func tabContent() {
            let (a, b) = (createLeaf("terminal"), createLeaf("browser"))
            let (first, second) = (createTab("One", a), createTab("Two", b))
            let root = createTabs([first, second])

            #expect(
                Floating.captureAnchor(root, b.id)
                    == .tab(
                        .init(
                            groupID: root.id, index: 1, title: "Two", beforeTabID: first.id, afterTabID: nil,
                            siblings: [.init(id: first.id, title: "One", contentID: a.id)], wasActive: false, groupAnchor: nil,
                            groupWasRoot: true)))
        }

        @Test("records where a group sat when the anchored tab is its only one, since that group leaves with it")
        func onlyTab() {
            let (left, x) = (createLeaf("terminal"), createLeaf("browser"))
            let group = createTabs([createTab("Only", x)])
            let root = createSplit(.horizontal, [left, group])

            guard case .tab(let anchor)? = Floating.captureAnchor(root, x.id) else {
                Issue.record("expected a tab anchor")
                return
            }
            #expect(anchor.groupID == group.id)
            #expect(anchor.siblings.isEmpty)
            #expect(anchor.wasActive)
            guard case .split(let groupAnchor)? = anchor.groupAnchor else {
                Issue.record("expected the group's own split anchor")
                return
            }
            #expect(groupAnchor.splitID == root.id)
            #expect(groupAnchor.index == 1)
            #expect(groupAnchor.beforeID == left.id)
        }

        @Test("anchors the root as root")
        func root() {
            let root = createLeaf("terminal")
            #expect(Floating.captureAnchor(root, root.id) == .root)
        }

        @Test("returns null for an id that is not in the tree")
        func missing() {
            #expect(Floating.captureAnchor(createLeaf("terminal"), "nope") == nil)
        }
    }

    @Suite struct DetachForFloat {
        @Test("lifts a split child out, collapsing a two-child split to its sibling")
        func splitChild() throws {
            let (a, b) = (createLeaf("terminal"), createLeaf("browser"))

            let result = try detach(createSplit(.horizontal, [a, b]), a.id)

            #expect(result.root.id == b.id)
            #expect(result.floating.content.id == a.id)
        }

        @Test("closes the tab behind a floated pane, keeping the group other tabs")
        func closesTab() throws {
            let (a, b, c) = (createLeaf("terminal"), createLeaf("browser"), createLeaf("terminal"))
            let root = createTabs([createTab("One", a), createTab("Two", b), createTab("Three", c)])

            #expect(try detach(root, b.id).root.titles == ["One", "Three"])
        }

        @Test("removes a one-tab group entirely rather than leaving a placeholder behind")
        func oneTabGroup() throws {
            let (a, c) = (createLeaf("terminal"), createLeaf("browser"))
            let root = createSplit(.horizontal, [createTabs([createTab("One", a)]), c])

            #expect(try detach(root, a.id).root.id == c.id)
        }

        @Test("floats a whole tab group, tabs intact")
        func wholeGroup() throws {
            let (a, b, c) = (createLeaf("terminal"), createLeaf("browser"), createLeaf("terminal"))
            let group = createTabs([createTab("One", a), createTab("Two", b)])
            let root = createSplit(.horizontal, [group, c])

            let result = try detach(root, group.id)

            #expect(result.root.id == c.id)
            #expect(result.floating.content == group)
        }

        @Test("leaves a fresh empty pane behind when the root itself floats")
        func root() throws {
            let root = createLeaf("terminal")

            let result = try detach(root, root.id)

            #expect(result.root.kind == "empty")
            #expect(result.floating.anchor == .root)
        }

        @Test("carries the node by reference, so live content keyed by its id survives")
        func keepsNode() throws {
            let (a, b) = (createLeaf("terminal"), createLeaf("browser"))
            #expect(try detach(createSplit(.horizontal, [a, b]), a.id).floating.content == a)
        }

        @Test("returns null for an unknown id")
        func missing() {
            #expect(Floating.detachForFloat(createLeaf("terminal"), "nope", rect: rect) == nil)
        }
    }

    @Suite struct RestoreFloating {
        @Test("puts a split child back at its old index while the split still exists")
        func splitChild() throws {
            let (a, b, c) = (createLeaf("terminal"), createLeaf("browser"), createLeaf("terminal"))
            let detached = try detach(createSplit(.horizontal, [a, b, c]), b.id)

            let next = Floating.restoreFloating(detached.root, detached.floating, titleOf, fallbackTarget: a.id)

            #expect(next.childIDs == [a.id, b.id, c.id])
        }

        @Test("restores approximately the fraction the pane used to hold")
        func fraction() throws {
            let (a, b) = (createLeaf("terminal"), createLeaf("browser"))
            let detached = try detach(createSplit(.horizontal, [a, b], sizes: [0.25, 0.75]), a.id)

            let next = Floating.restoreFloating(detached.root, detached.floating, titleOf, fallbackTarget: b.id)

            #expect(isClose(next.sizes[safe: 0], 0.25))
            #expect(isClose(next.sizes[safe: 1], 0.75))
        }

        @Test("re-splits against the surviving neighbour when the split collapsed")
        func resplits() throws {
            let (a, b) = (createLeaf("terminal"), createLeaf("browser"))
            let detached = try detach(createSplit(.vertical, [a, b]), a.id)
            // The split is gone entirely — it unwrapped to `b` the moment `a` left.
            #expect(detached.root.id == b.id)

            let next = Floating.restoreFloating(detached.root, detached.floating, titleOf, fallbackTarget: b.id)

            #expect(next.direction == .vertical)
            #expect(next.childIDs == [a.id, b.id])
        }

        @Test("restores a tab at its old index in its old group, under its old title")
        func tab() throws {
            let (a, b, c) = (createLeaf("terminal"), createLeaf("browser"), createLeaf("terminal"))
            let root = createTabs([createTab("One", a), createTab("Two", b), createTab("Three", c)])
            let detached = try detach(root, b.id)

            let next = Floating.restoreFloating(detached.root, detached.floating, titleOf, fallbackTarget: a.id)

            #expect(next.titles == ["One", "Two", "Three"])
            #expect(next.tabItems.map(\.content.id) == [a.id, b.id, c.id])
        }

        @Test("rebuilds a two-tab group its departure collapsed, both tabs back in order under their titles")
        func rebuildsPair() throws {
            // Removing one of two tabs collapses the group into the other's
            // bare content, so neither the group nor its tab ids survive to be found.
            let (left, x, y) = (createLeaf("terminal"), createLeaf("browser"), createLeaf("terminal"))
            let kept = createTab("Kept", y)
            let group = createTabs([createTab("Renamed X", x), kept])
            let root = createSplit(.horizontal, [left, group])
            let detached = try detach(root, x.id)
            #expect(Tree.findNode(detached.root, group.id) == nil)

            let next = Floating.restoreFloating(detached.root, detached.floating, titleOf, fallbackTarget: left.id)

            let rebuilt = next.childNodes[safe: 1]
            #expect(rebuilt?.id == group.id)
            #expect(rebuilt?.titles == ["Renamed X", "Kept"])
            #expect(rebuilt?.tabItems.map(\.content.id) == [x.id, y.id])
            #expect(rebuilt?.tabItems[safe: 1]?.id == kept.id)
        }

        @Test("puts back a group its only tab took with it, at the place the group sat")
        func rebuildsLoneGroup() throws {
            let (left, x) = (createLeaf("terminal"), createLeaf("browser"))
            let group = createTabs([createTab("Only", x)])
            let root = createSplit(.horizontal, [left, group], sizes: [0.7, 0.3])
            let detached = try detach(root, x.id)
            // The group went, and the split with it.
            #expect(detached.root.id == left.id)

            let next = Floating.restoreFloating(detached.root, detached.floating, titleOf, fallbackTarget: left.id)

            #expect(next.childIDs == [left.id, group.id])
            #expect(next.childNodes[safe: 1]?.titles == ["Only"])
            #expect(isClose(next.sizes[safe: 1], 0.3))
        }

        @Test("rebuilds into the single-tab group a collapsed group was rewrapped in, not a nested one")
        func rewrappedRoot() throws {
            // The docked root rewraps what its collapse leaves (ensureTabsRoot):
            // the survivor sits alone in a fresh group, which is the one to rebuild into.
            let (x, y) = (createLeaf("browser"), createLeaf("terminal"))
            let root = createTabs([createTab("Moved", x), createTab("Other", y)])
            let detached = try detach(root, x.id)
            let rewrapped = createTabs([createTab("Other", detached.root)])

            let next = Floating.restoreFloating(rewrapped, detached.floating, titleOf, fallbackTarget: y.id)

            #expect(next.id == rewrapped.id)
            #expect(next.titles == ["Moved", "Other"])
            #expect(next.tabItems.map(\.content.id) == [x.id, y.id])
        }

        @Test("re-pins the docked root's lone content without nesting it in a group of its own")
        func rootsLoneContent() throws {
            // The root group is rewrapped rather than rebuilt: rebuilding it
            // under its old id put a spurious nested tab strip inside the new root.
            let x = createLeaf("browser")
            let detached = try detach(createTabs([createTab("Only", x)]), x.id)
            let placeholder = detached.root
            let rewrapped = createTabs([createTab("Tabs", placeholder)])

            let next = Floating.restoreFloating(rewrapped, detached.floating, titleOf, fallbackTarget: placeholder.id)

            #expect(next.tabItems.map(\.content.id) == [x.id])
        }

        @Test("re-pins a root tab beside the tab it left, without demoting that tab into a nested group")
        func besideRootTab() throws {
            let (x, y, z) = (createLeaf("browser"), createLeaf("terminal"), createLeaf("terminal"))
            let detached = try detach(createTabs([createTab("X", x), createTab("Y", y)]), x.id)
            // The collapsed root, rewrapped, and then a third tab added beside it.
            let now = createTabs([createTab("Y", detached.root), createTab("Z", z)])

            let next = Floating.restoreFloating(now, detached.floating, titleOf, fallbackTarget: y.id)

            #expect(next.id == now.id)
            #expect(next.tabItems.map(\.content.id) == [x.id, y.id, z.id])
        }

        @Test("rebuilds a collapsed group nested in a single-tab group exactly, not flattened into it")
        func nestedCollapse() throws {
            let (x, y) = (createLeaf("browser"), createLeaf("terminal"))
            let inner = createTabs([createTab("X", x), createTab("Y", y)])
            let outer = createTabs([createTab("Outer", inner)])
            let root = createSplit(.horizontal, [createLeaf("terminal"), outer])
            let detached = try detach(root, x.id)

            let next = Floating.restoreFloating(detached.root, detached.floating, titleOf, fallbackTarget: y.id)

            let restoredOuter = next.childNodes[safe: 1]
            #expect(restoredOuter?.tabItems.count == 1)
            let restoredInner = restoredOuter?.tabItems[safe: 0]?.content
            #expect(restoredInner?.id == inner.id)
            #expect(restoredInner?.titles == ["X", "Y"])
        }

        @Test("lands beside the surviving neighbour tab when the group is gone")
        func besideNeighbour() throws {
            let (a, b, c, d) = (createLeaf("terminal"), createLeaf("browser"), createLeaf("terminal"), createLeaf("browser"))
            let first = createTab("One", a)
            let source = createTabs([first, createTab("Two", b), createTab("Three", c)])
            let other = createTabs([createTab("Four", d)])
            let detached = try detach(createSplit(.horizontal, [source, other]), b.id)

            // The source group dissolves once its remaining tabs scatter, but
            // tab "One" itself survives the move — tabs relocate whole.
            let scattered = Tree.moveTab(detached.root, first.id, other.id)
            #expect(Tree.findNode(scattered, source.id) == nil)

            let next = Floating.restoreFloating(scattered, detached.floating, titleOf, fallbackTarget: d.id)

            #expect(Tree.findNode(next, other.id)?.titles == ["Four", "One", "Two"])
        }

        @Test("fills the empty root that a root-anchored float left behind")
        func fillsEmptyRoot() throws {
            let root = createLeaf("terminal")
            let detached = try detach(root, root.id)

            #expect(Floating.restoreFloating(detached.root, detached.floating, titleOf, fallbackTarget: detached.root.id) == root)
        }

        @Test("falls back to opening beside the fallback target when every landmark is gone")
        func fallback() throws {
            let (a, b) = (createLeaf("terminal"), createLeaf("browser"))
            let detached = try detach(createSplit(.horizontal, [a, b]), a.id)
            let unrelated = createLeaf("terminal")

            let next = Floating.restoreFloating(unrelated, detached.floating, titleOf, fallbackTarget: unrelated.id)

            #expect(next.kind == "tabs")
            #expect(next.tabItems.map(\.content.id) == [unrelated.id, a.id])
        }

        @Test("never loses the content, whatever the layout has become")
        func neverLoses() throws {
            let (a, b) = (createLeaf("terminal"), createLeaf("browser"))
            let anchors = [
                try detach(createSplit(.horizontal, [a, b]), a.id),
                try detach(createTabs([createTab("One", a), createTab("Two", b)]), a.id),
                try detach(a, a.id),
            ]
            let mangled: [LayoutNode] = [
                createLeaf("empty"),
                createLeaf("terminal"),
                createTabs([createTab("Elsewhere", createLeaf("browser"))]),
                createSplit(.vertical, [createLeaf("terminal"), createLeaf("browser")]),
            ]

            for detached in anchors {
                for root in mangled {
                    let next = Floating.restoreFloating(root, detached.floating, titleOf, fallbackTarget: root.id)
                    #expect(Tree.findNode(next, a.id) != nil)
                }
            }
        }
    }

    @Suite struct UnpinThenRepin {
        @Test("restores the original tree shape for a split child")
        func splitChild() throws {
            let (a, b) = (createLeaf("terminal"), createLeaf("browser"))
            let detached = try detach(createSplit(.horizontal, [a, b], sizes: [0.4, 0.6]), a.id)

            let next = Floating.restoreFloating(detached.root, detached.floating, titleOf, fallbackTarget: b.id)

            #expect(next.direction == .horizontal)
            #expect(next.childIDs == [a.id, b.id])
            #expect(isClose(next.sizes[safe: 0], 0.4))
        }

        @Test("restores the original tree shape for a pane in a tab group")
        func tabPane() throws {
            let (a, b, c) = (createLeaf("terminal"), createLeaf("browser"), createLeaf("terminal"))
            let root = createTabs([createTab("One", a), createTab("Two", b), createTab("Three", c)])
            let detached = try detach(root, b.id)

            let next = Floating.restoreFloating(detached.root, detached.floating, titleOf, fallbackTarget: a.id)

            #expect(next.id == root.id)
            #expect(next.titles == ["One", "Two", "Three"])
        }

        @Test("restores the original tree shape for the root")
        func root() throws {
            let root = createLeaf("terminal")
            let detached = try detach(root, root.id)

            #expect(Floating.restoreFloating(detached.root, detached.floating, titleOf, fallbackTarget: detached.root.id) == root)
        }

        @Test("restores a whole tab group with its tabs and active tab intact")
        func wholeGroup() throws {
            let (a, b, d) = (createLeaf("terminal"), createLeaf("browser"), createLeaf("terminal"))
            let second = createTab("Two", b)
            let group = createTabs([createTab("One", a), second], active: second.id)
            let detached = try detach(createSplit(.horizontal, [group, d]), group.id)

            let next = Floating.restoreFloating(detached.root, detached.floating, titleOf, fallbackTarget: d.id)
            let restored = next.childNodes[safe: 0]

            #expect(next.childIDs == [group.id, d.id])
            #expect(restored?.titles == ["One", "Two"])
            #expect(restored?.activeTabID == second.id)
        }
    }

    @Suite struct FloatOwning {
        @Test("finds the window whose subtree contains the id")
        func finds() {
            let (a, b) = (createLeaf("terminal"), createLeaf("browser"))
            let list = [float(a, "first"), float(createTabs([createTab("One", b)]), "second")]

            #expect(Floating.owning(list, b.id)?.id == "second")
            #expect(Floating.owning(list, "nope") == nil)
        }
    }

    @Suite struct RaiseFloating {
        @Test("moves the named window to the end of the list")
        func raises() {
            let list = [float(createLeaf("terminal"), "a"), float(createLeaf("browser"), "b")]
            #expect(Floating.raise(list, "a").map(\.id) == ["b", "a"])
        }

        @Test("returns the same array when it is already topmost")
        func topmost() {
            let list = [float(createLeaf("terminal"), "a"), float(createLeaf("browser"), "b")]
            #expect(Floating.raise(list, "b") == list)
        }

        @Test("returns the same array for an unknown id")
        func unknown() {
            let list = [float(createLeaf("terminal"), "a")]
            #expect(Floating.raise(list, "nope") == list)
        }
    }

    // `replaceFloating` has no native counterpart (WindowLayout edits its
    // floating array in place), so its two tests are not ported.

    @Suite struct ClampRect {
        static let viewport = Viewport(width: 1000, height: 800)

        @Test("keeps a window that runs off the right edge partly on screen")
        func rightEdge() {
            var moved = rect
            moved.x = 5000
            let next = Floating.clamp(moved, to: Self.viewport)

            #expect(next.x < Self.viewport.width)
            #expect(next.x + next.width > 0)
        }

        @Test("keeps a window dragged off the left edge grabbable")
        func leftEdge() {
            var moved = rect
            moved.x = -5000
            let next = Floating.clamp(moved, to: Self.viewport)

            #expect(next.x + next.width > 0)
        }

        @Test("never lets the top edge go above zero")
        func topEdge() {
            var moved = rect
            moved.y = -200
            #expect(Floating.clamp(moved, to: Self.viewport).y == 0)
        }

        @Test("raises a below-minimum size to the minimum")
        func minimum() {
            let next = Floating.clamp(FloatRect(x: 0, y: 0, width: 10, height: 10), to: Self.viewport)

            #expect(next.width == Floating.minSize.width)
            #expect(next.height == Floating.minSize.height)
        }

        @Test("never returns a window larger than the viewport")
        func maximum() {
            let next = Floating.clamp(FloatRect(x: 0, y: 0, width: 9000, height: 9000), to: Self.viewport)

            #expect(next.width == Self.viewport.width)
            #expect(next.height == Self.viewport.height)
        }
    }

    @Suite struct SanitizeFloating {
        let root = createLeaf("empty")

        @Test("drops an entry holding a node id the docked root already claims")
        func claimedByRoot() {
            let docked = createSplit(.horizontal, [createLeaf("terminal"), createLeaf("browser")])
            let clash = float(docked.childNodes[0])

            #expect(Floating.sanitize([clash], against: docked).isEmpty)
        }

        @Test("drops a second entry that repeats an earlier one node id")
        func repeated() {
            let shared = createLeaf("terminal")

            let result = Floating.sanitize([float(shared, "a"), float(shared, "b")], against: root)

            #expect(result.map(\.id) == ["a"])
        }

        @Test("normalizes each surviving entry content")
        func normalizes() {
            let tab = createTab("Shell", createLeaf("terminal"))
            let stale = createTabs([tab], active: "gone")

            let result = Floating.sanitize([float(stale)], against: root)

            #expect(result[safe: 0]?.content.activeTabID == tab.id)
        }

        @Test("re-mints a duplicated window id rather than dropping the second window")
        func remintsWindowID() {
            // Everything hanging off a floating pane (its view, gestures, the
            // z-order) is keyed by the window id — two sharing one would leave
            // only the first reachable, but the pane inside the second is worth
            // keeping, so it is repaired the way a broken rect is.
            let result = Floating.sanitize([float(createLeaf("terminal"), "same"), float(createLeaf("browser"), "same")], against: root)

            #expect(result.count == 2)
            #expect(result[safe: 0]?.id == "same")
            #expect(result[safe: 1]?.id != "same")
        }
    }

    @Suite struct SpawnRectIn {
        /// Comfortably bigger than the default float, so every inset is visible.
        static let pane = FloatRect(x: 100, y: 50, width: 1000, height: 700)
        static let spacing = Floating.spawnSpacing

        /// Gap between the pane's trailing edges and the window's, per axis.
        static func trailingGaps(_ rect: FloatRect) -> (x: Double, y: Double) {
            (pane.x + pane.width - (rect.x + rect.width), pane.y + pane.height - (rect.y + rect.height))
        }

        @Test("sizes the window off the origin pane, capped at the default geometry")
        func sizes() {
            let full = Floating.spawnRect(in: Self.pane, at: .topRight)
            #expect(full.width == Floating.defaultRect.width)
            #expect(full.height == Floating.defaultRect.height)

            let modest = Floating.spawnRect(in: FloatRect(x: 0, y: 0, width: 400, height: 300), at: .topRight)
            #expect(modest.width == 400 - Self.spacing * 2)
            #expect(modest.height == 300 - Self.spacing * 2)
        }

        @Test("never asks for a window below the minimum float size")
        func minimum() {
            let tiny = Floating.spawnRect(in: FloatRect(x: 0, y: 0, width: 120, height: 80), at: .topLeft)

            #expect(tiny.width == Floating.minSize.width)
            #expect(tiny.height == Floating.minSize.height)
        }

        @Test("insets an edge-anchored position by the spawn spacing, on that edge")
        func insets() {
            let topLeft = Floating.spawnRect(in: Self.pane, at: .topLeft)
            #expect(topLeft.x - Self.pane.x == Self.spacing)
            #expect(topLeft.y - Self.pane.y == Self.spacing)

            let gaps = Self.trailingGaps(Floating.spawnRect(in: Self.pane, at: .bottomRight))
            #expect(gaps.x == Self.spacing)
            #expect(gaps.y == Self.spacing)
        }

        @Test("still spawns where the hardcoded top-right corner did, at the shipped default")
        func shippedDefault() {
            // The shipped default has to be a visual no-op for anyone who never
            // opens the picker, which means matching the corner that preceded it.
            let rect = Floating.spawnRect(in: Self.pane, at: .default)

            #expect(rect.y - Self.pane.y == Self.spacing)
            #expect(Self.trailingGaps(rect).x == Self.spacing)
        }

        @Test("centers exactly, with no edge inset left over on either side")
        func centers() {
            let rect = Floating.spawnRect(in: Self.pane, at: .middleCenter)

            #expect(rect.x - Self.pane.x == Self.trailingGaps(rect).x)
            #expect(rect.y - Self.pane.y == Self.trailingGaps(rect).y)
        }

        @Test("resolves the two axes independently")
        func independentAxes() {
            let rect = Floating.spawnRect(in: Self.pane, at: .bottomCenter)

            #expect(Self.trailingGaps(rect).y == Self.spacing)
            #expect(rect.x - Self.pane.x == Self.trailingGaps(rect).x)
        }

        @Test("puts each of the nine positions somewhere distinct")
        func distinct() {
            let corners = SpawnPosition.allCases.map { position in
                let rect = Floating.spawnRect(in: Self.pane, at: position)
                return "\(rect.x),\(rect.y)"
            }
            #expect(Set(corners).count == SpawnPosition.allCases.count)
        }

        @Test("overhangs the leading edge when the pane is smaller than the window it spawns")
        func overhangs() {
            // Deliberate: clamping the span at zero instead would make all nine
            // positions identical over a small pane.
            let pane = FloatRect(x: 0, y: 0, width: 200, height: 100)

            let rect = Floating.spawnRect(in: pane, at: .bottomRight)

            #expect(rect.width > pane.width)
            #expect(rect.x < pane.x)
        }

        @Test("stays bottom-anchored after being clamped into the viewport")
        func staysBottomAnchored() {
            // The failure this guards is the setting silently becoming a no-op
            // near a screen edge: the clamp pulling a bottom/right anchor back
            // to a top/left one.
            let viewport = Viewport(width: 1200, height: 800)
            let pane = FloatRect(x: 0, y: 40, width: 1200, height: 760)

            let bottom = Floating.spawnRect(in: pane, at: .bottomRight)
            let top = Floating.spawnRect(in: pane, at: .topRight)

            #expect(Floating.clamp(bottom, to: viewport) == bottom)
            #expect(Floating.clamp(bottom, to: viewport).y > Floating.clamp(top, to: viewport).y)
        }
    }

    // `resolveSpawnPosition`'s fallback test ("falls back to the default for
    // anything a hand-edited settings.json could hold") is not ported: natively
    // the position is a `Codable` enum and no settings value carries it yet.
    @Suite struct ResolveSpawnPosition {
        @Test("passes every known position through unchanged")
        func knownPositions() {
            // The Electron names, in reading order (the picker's order).
            let names = ["top", "middle", "bottom"].flatMap { row in ["left", "center", "right"].map { "\(row)-\($0)" } }
            #expect(SpawnPosition.allCases.map(\.rawValue) == names)
            for name in names { #expect(SpawnPosition(rawValue: name)?.rawValue == name) }
            #expect(SpawnPosition.default == .topRight)
        }
    }
}
