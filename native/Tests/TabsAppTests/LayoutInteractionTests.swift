import AppKit
import TabsPluginSDK
import Testing

@testable import Tabs
@testable import TabsCore

extension UITests {
    // MARK: - Dragging within a window

    @MainActor
    @Suite struct DragAndDrop {
        /// Empty pane A beside group G of two empty tabs, X and Y (Y shown).
        static let tabs = TabStrip.splitWithGroup

        /// Two live panes side by side.
        static let pair = Fixture.saved(
            Fixture.window("w", Fixture.split("s", .horizontal, [Fixture.leaf("a", "inert"), Fixture.leaf("b", "inert")]), active: "a"))

        /// Live pane A beside group G of live tabs X and Y (Y shown).
        static let paneAndGroup = Fixture.saved(
            Fixture.window(
                "w",
                Fixture.split(
                    "s", .horizontal,
                    [
                        Fixture.leaf("a", "inert"),
                        Fixture.tabs(
                            "g", [Fixture.tab(Fixture.leaf("x", "inert")), Fixture.tab(Fixture.leaf("y", "inert"))], active: "t-y"),
                    ]), active: "a"))

        @Test func aTabReordersWithinItsBar() throws {
            let ui = UIDriver(layout: Self.tabs)
            let (tab, start) = try ui.grip(tab: "t-y")
            let target = try ui.tabView("t-x")
            try ui.drag(tab, from: start, to: NSPoint(x: target.bounds.width * 0.25, y: target.bounds.midY), in: target)
            #expect(try ui.layout.tabIDs("g") == ["t-y", "t-x"])
            #expect(ui.activeNode == "g", "the group it landed in is active")
        }

        @Test func aTabMovesToAnotherBarAtTheSlotItWasDroppedIn() throws {
            let ui = UIDriver(
                layout: Fixture.saved(
                    Fixture.window(
                        "w",
                        Fixture.split(
                            "s", .horizontal,
                            [
                                Fixture.tabs("g1", [Fixture.tab(Fixture.leaf("l1")), Fixture.tab(Fixture.leaf("l2"))]),
                                Fixture.tabs("g2", [Fixture.tab(Fixture.leaf("l3")), Fixture.tab(Fixture.leaf("l4"))]),
                            ]))))
            let (tab, start) = try ui.grip(tab: "t-l1")
            let target = try ui.tabView("t-l3")
            try ui.drag(tab, from: start, to: NSPoint(x: target.bounds.width * 0.75, y: target.bounds.midY), in: target)
            let layout = try ui.layout
            #expect(layout.tabIDs("g2") == ["t-l3", "t-l1", "t-l4"], "after the tab it was dropped on the right half of")
            #expect(layout.node("g1") == nil, "the bar it left, down to one tab, collapsed")
            #expect(layout.node("s")?.splitNode?.children.map(\.id) == ["l2", "g2"])
        }

        @Test func aTabDroppedOnAnEmptyPaneBecomesItsGroup() throws {
            let ui = UIDriver(layout: Self.tabs)
            let (tab, start) = try ui.grip(tab: "t-x")
            let (pane, middle) = try ui.spot("a", 0.5, 0.55)
            try ui.drag(tab, from: start, to: middle, in: pane)
            let layout = try ui.layout
            #expect(layout.node("a")?.group?.tabs.map(\.id) == ["t-x"], "the empty pane became a group of the tab, under its own id")
            #expect(layout.node("s")?.splitNode?.children.map(\.id) == ["a", "y"], "G, down to one tab, collapsed")
        }

        @Test(arguments: [DockZone.left, .right, .top, .bottom])
        func aTabDocksAtAPanesEdge(_ zone: DockZone) throws {
            let ui = UIDriver(layout: Self.tabs)
            let (tab, start) = try ui.grip(tab: "t-x")
            let at: (CGFloat, CGFloat) =
                switch zone {
                case .left: (0.1, 0.55)
                case .right: (0.9, 0.55)
                case .top: (0.5, 0.1)
                case .bottom: (0.5, 0.9)
                case .center: (0.5, 0.55)
                }
            let (pane, point) = try ui.spot("a", at.0, at.1)
            // The preview shows while the drag is in flight.
            let controller = try ui.window
            ui.renderer.drag.simulate(
                from: try ui.contentPoint(start, in: tab), to: try ui.contentPoint(point, in: pane), in: controller)
            #expect(controller.dragVisuals.target == .dock(targetID: "a", zone: zone))
            let preview = try #require(controller.root.docked.overlay.previewFrame, "no preview")
            let box = try ui.paneView("a")
            let insets = box.borderInsets
            let padding = CGRect(
                x: box.layoutFrame.minX + insets.left, y: box.layoutFrame.minY + insets.top,
                width: box.layoutFrame.width - insets.left - insets.right, height: box.layoutFrame.height - insets.top - insets.bottom)
            let half: CGRect =
                switch zone {
                case .left: CGRect(x: padding.minX, y: padding.minY, width: padding.width / 2, height: padding.height)
                case .right: CGRect(x: padding.midX, y: padding.minY, width: padding.width / 2, height: padding.height)
                case .top: CGRect(x: padding.minX, y: padding.minY, width: padding.width, height: padding.height / 2)
                default: CGRect(x: padding.minX, y: padding.midY, width: padding.width, height: padding.height / 2)
                }
            #expect(preview == half, "half the pane, inside its border")
            ui.renderer.drag.endSimulation()

            try ui.drag(tab, from: start, to: point, in: pane)
            let layout = try ui.layout
            let docked = try #require(layout.findTab("t-x")?.group.id, "the tab is somewhere")
            let children = try #require(layout.node("s")?.splitNode?.children)
            switch zone {
            case .left: #expect(children.map(\.id) == [docked, "a", "y"])
            case .right: #expect(children.map(\.id) == ["a", docked, "y"])
            case .top: #expect(children.first?.splitNode?.children.map(\.id) == [docked, "a"])
            default: #expect(children.first?.splitNode?.children.map(\.id) == ["a", docked])
            }
            #expect(ui.activeNode == docked, "its new group is active")
        }

        @Test func aTabDockedAtAPanesCenterJoinsItInAGroup() throws {
            let ui = UIDriver(layout: Self.paneAndGroup)
            let (tab, start) = try ui.grip(tab: "t-y")
            let (pane, middle) = try ui.spot("a", 0.5, 0.55)
            let controller = try ui.window
            ui.renderer.drag.simulate(from: try ui.contentPoint(start, in: tab), to: try ui.contentPoint(middle, in: pane), in: controller)
            #expect(controller.dragVisuals.target == .dock(targetID: "a", zone: .center))
            ui.renderer.drag.endSimulation()
            try ui.drag(tab, from: start, to: middle, in: pane)
            let group = try #require(try ui.layout.node("s")?.splitNode?.children.first?.group)
            #expect(group.tabs.map(\.content.id) == ["a", "y"])
            #expect(group.tabs.map(\.title) == ["Inert", "New Tab"])
        }

        @Test func theWindowsOwnEdgeIsNoDropTarget() throws {
            let ui = UIDriver(layout: Fixture.saved(Fixture.tabsWindow("w", [Fixture.leaf("a", "inert"), Fixture.leaf("b", "inert")])))
            let before = try ui.layout
            let (tab, start) = try ui.grip(tab: "t-b")
            let edge = NSPoint(x: 5, y: 400)
            let controller = try ui.window
            ui.renderer.drag.simulate(from: try ui.contentPoint(start, in: tab), to: edge, in: controller)
            #expect(controller.dragVisuals.target == nil, "the docked root can't be split out of itself")
            #expect(controller.root.docked.overlay.previewFrame == nil)
            ui.renderer.drag.endSimulation()
            try ui.drag(tab, from: start, to: edge, in: controller.root)
            ui.settle()
            #expect(try ui.layout.rootNode == before.rootNode, "declined: nothing moved")
        }

        @Test func aPaneDraggedByItsHeaderDocksAtAnEdge() throws {
            let ui = UIDriver(layout: Self.pair)
            let (header, start) = try ui.grip("a")
            let (pane, edge) = try ui.spot("b", 0.9, 0.55)
            try ui.drag(header, from: start, to: edge, in: pane)
            #expect(try ui.layout.shownContent?.splitNode?.children.map(\.id) == ["b", "a"])
            #expect(ui.activePane == "a", "the pane keeps the focus in its new place")
        }

        @Test func aPaneDroppedAtAnotherPanesCenterMergesIntoAGroup() throws {
            let ui = UIDriver(layout: Self.pair)
            let (header, start) = try ui.grip("a")
            let (pane, middle) = try ui.spot("b", 0.5, 0.55)
            try ui.drag(header, from: start, to: middle, in: pane)
            let group = try #require(try ui.layout.shownContent?.group, "the split collapsed around a new group")
            #expect(group.tabs.map(\.content.id) == ["b", "a"])
            #expect(group.activeTab?.content.id == "a")
        }

        @Test func aPaneDroppedOnATabBarBecomesATabThere() throws {
            let ui = UIDriver(layout: Self.paneAndGroup)
            let (header, start) = try ui.grip("a")
            let bar = try #require(try ui.paneView("g").tabBar)
            try ui.drag(header, from: start, to: NSPoint(x: bar.strip.frame.maxX - 4, y: bar.bounds.height / 2), in: bar)
            let layout = try ui.layout
            #expect(layout.tabContents("g") == ["x", "y", "a"], "appended where it was dropped")
            #expect(layout.shownContent?.id == "g", "the split it left collapsed")
        }

        @Test func aPaneDroppedOnAnEmptyPaneTakesItsPlace() throws {
            let ui = UIDriver(
                layout: Fixture.sideBySide(Fixture.leaf("a", "inert"), Fixture.leaf("e")))
            let (header, start) = try ui.grip("a")
            let (pane, middle) = try ui.spot("e", 0.5, 0.55)
            try ui.drag(header, from: start, to: middle, in: pane)
            #expect(try ui.layout.shownContent?.id == "a", "bare, in the empty pane's slot; the split collapsed")
            #expect(try ui.layout.node("e") == nil)
        }

        @Test func holdingADragOverATabOpensItSoItsContentTakesTheDrop() throws {
            let ui = UIDriver(layout: Self.paneAndGroup)
            let (header, start) = try ui.grip("a")
            let tab = try ui.tabView("t-x")
            let over = try ui.point(NSPoint(x: tab.titleRect.midX, y: tab.titleRect.midY), of: tab, from: header)
            let bar = try ui.paneView("g")
            // X's content lies where Y's is now; its right edge band, clear of the group's own.
            let inside = try ui.point(NSPoint(x: bar.bounds.width * 0.82, y: bar.bounds.height * 0.55), of: bar, from: header)
            try ui.drag(from: start, in: header, [.move(to: over), .wait(0.8), .move(to: inside), .release])
            let layout = try ui.layout
            #expect(layout.node("g")?.group?.activeTabID == "t-x", "the hovered tab opened")
            #expect(layout.findTab("t-x")?.tab.content.splitNode?.children.map(\.id) == ["x", "a"], "and A split X within its tab")
        }

        @Test(arguments: [DockZone.left, .right, .top, .bottom])
        func aPaneFromASiblingTabDocksIntoTheTabItOpensAndShows(_ zone: DockZone) throws {
            // The window's two tabs, X and Y, Y shown.
            let ui = UIDriver(
                layout: Fixture.saved(Fixture.tabsWindow("w", [Fixture.leaf("x", "inert"), Fixture.leaf("y", "inert")], active: 1)))
            let (header, start) = try ui.grip("y")
            let tab = try ui.tabView("t-x")
            let over = try ui.point(NSPoint(x: tab.titleRect.midX, y: tab.titleRect.midY), of: tab, from: header)
            // X's edge band, where Y's content is now.
            let pane = try ui.paneView("x")
            let at: (CGFloat, CGFloat) =
                switch zone {
                case .left: (0.15, 0.55)
                case .right: (0.85, 0.55)
                case .top: (0.5, 0.18)
                default: (0.5, 0.85)
                }
            let inside = try ui.point(NSPoint(x: pane.bounds.width * at.0, y: pane.bounds.height * at.1), of: pane, from: header)
            try ui.drag(from: start, in: header, [.move(to: over), .wait(0.8), .move(to: inside), .release])
            let split = try #require(try ui.layout.shownContent?.splitNode, "X's tab opened and Y split it")
            #expect(split.children.map(\.id) == (zone == .left || zone == .top ? ["y", "x"] : ["x", "y"]))
            for id: PaneID in ["x", "y"] {
                #expect(!(try ui.paneView(id).isHiddenOrHasHiddenAncestor), "\(id) is on screen")
                #expect(try ui.body(id).content != nil, "\(id)'s content is built")
            }
        }

        @Test func aReleaseWithNoTargetChangesNothing() throws {
            let ui = UIDriver(layout: Self.tabs)
            let before = try ui.layout
            let (tab, start) = try ui.grip(tab: "t-x")
            let controller = try ui.window
            try ui.drag(tab, from: start, to: NSPoint(x: -300, y: 400), in: controller.root)
            #expect(ui.renderer.drag.isDragging, "the ghost flies home first")
            ui.settle(0.4)
            #expect(!ui.renderer.drag.isDragging)
            #expect(try ui.layout.rootNode == before.rootNode)
        }

        @Test func escapeCancelsADrag() throws {
            let ui = UIDriver(layout: Self.tabs)
            let before = try ui.layout
            let (tab, start) = try ui.grip(tab: "t-x")
            let (pane, middle) = try ui.spot("a", 0.5, 0.55)
            try ui.drag(tab, from: start, to: middle, in: pane, finish: .escape)
            #expect(!ui.renderer.drag.isDragging)
            #expect(try ui.layout.rootNode == before.rootNode)
            let (again, point) = try ui.grip(tab: "t-x")
            try ui.drag(again, from: point, to: middle, in: pane)
            #expect(try ui.layout.node("a")?.isTabs == true, "and the next drag works")
        }

        @Test func aPaneInAFloatingWindowStaysInIt() throws {
            let floating = Fixture.floating(
                "f", Fixture.split("fs", .horizontal, [Fixture.leaf("f1", "inert"), Fixture.leaf("f2", "inert")]),
                FloatRect(x: 500, y: 200, width: 600, height: 300))
            let ui = UIDriver(layout: Fixture.saved(Fixture.window("w", Fixture.leaf("d", "inert"), floating: [floating])))
            let (header, start) = try ui.grip("f1")
            let controller = try ui.window
            try ui.drag(header, from: start, to: NSPoint(x: 150, y: 600), in: controller.root)
            ui.settle(0.4)
            #expect(try ui.layout.node("fs")?.splitNode?.children.map(\.id) == ["f1", "f2"], "the docked pane isn't a target")
            #expect(try ui.layout.shownContent?.id == "d")
            let (again, point) = try ui.grip("f1")
            let (pane, edge) = try ui.spot("f2", 0.9, 0.55)
            try ui.drag(again, from: point, to: edge, in: pane)
            #expect(try ui.layout.floating.first?.content.splitNode?.children.map(\.id) == ["f2", "f1"], "within its own window it docks")
        }
    }

    // MARK: - Between windows

    @MainActor
    @Suite struct CrossWindow {
        static let left = WindowFrame(x: 100, y: 100, width: 800, height: 600)
        static let right = WindowFrame(x: 1000, y: 100, width: 800, height: 600)

        @Test func aTabLandsBetweenAnotherWindowsTabs() throws {
            let ui = UIDriver(
                layout: Fixture.saved(
                    Fixture.tabsWindow("w", [Fixture.leaf("a", "inert"), Fixture.leaf("b", "inert")], active: 1, frame: Self.left),
                    Fixture.tabsWindow("v", [Fixture.leaf("c", "inert"), Fixture.leaf("d", "inert")], frame: Self.right)))
            let (tab, start) = try ui.grip(tab: "t-b", in: try ui.window("w"))
            let target = try ui.tabView("t-c", in: try ui.window("v"))
            try ui.drag(tab, from: start, to: NSPoint(x: target.bounds.width * 0.75, y: target.bounds.midY), in: target)
            #expect(ui.engine.model.window("v")?.root.tabs.map(\.content.id) == ["c", "b", "d"])
            #expect(ui.engine.model.window("w")?.leaves.map(\.id) == ["a"])
            #expect(ui.engine.model.window("v")?.activeLeafID == "b")
        }

        @Test func aPaneDocksAtAnotherWindowsPaneEdge() throws {
            let ui = UIDriver(
                layout: Fixture.saved(
                    Fixture.window(
                        "w", Fixture.split("s", .horizontal, [Fixture.leaf("a", "inert"), Fixture.leaf("b", "inert")]), frame: Self.left),
                    Fixture.window("v", Fixture.leaf("c", "inert"), frame: Self.right)))
            let (header, start) = try ui.grip("a", in: try ui.window("w"))
            let (pane, edge) = try ui.spot("c", 0.85, 0.55, in: try ui.window("v"))
            try ui.drag(header, from: start, to: edge, in: pane)
            #expect(ui.engine.model.window("v")?.shownContent?.splitNode?.children.map(\.id) == ["c", "a"])
            #expect(ui.engine.model.window("w")?.shownContent?.id == "b")
        }

        @Test func aWindowsOnlyTabLeavesAnEmptyPaneBehind() throws {
            let ui = UIDriver(
                layout: Fixture.saved(
                    Fixture.window("w", Fixture.leaf("a", "inert"), frame: Self.left),
                    Fixture.tabsWindow("v", [Fixture.leaf("c", "inert")], frame: Self.right)))
            let (tab, start) = try ui.grip(tab: "t-w", in: try ui.window("w"))
            let bar = try #require(try ui.paneView("root-v", in: try ui.window("v")).tabBar)
            try ui.drag(tab, from: start, to: NSPoint(x: bar.strip.frame.maxX - 4, y: 20), in: bar)
            #expect(ui.engine.model.window("v")?.root.tabs.map(\.content.id) == ["c", "a"])
            let left = try #require(ui.engine.model.window("w"))
            #expect(left.leaves.count == 1 && left.leaves[0].isEmpty, "a fresh empty pane, and the window stays")
        }

        @Test func floatingContentCantLeaveItsWindow() throws {
            let floating = Fixture.floating(
                "f", Fixture.split("fs", .horizontal, [Fixture.leaf("f1", "inert"), Fixture.leaf("f2", "inert")]),
                FloatRect(x: 100, y: 100, width: 500, height: 300))
            let ui = UIDriver(
                layout: Fixture.saved(
                    Fixture.window("w", Fixture.leaf("d", "inert"), floating: [floating], frame: Self.left),
                    Fixture.window("v", Fixture.leaf("c", "inert"), frame: Self.right)))
            let (header, start) = try ui.grip("f1", in: try ui.window("w"))
            let (pane, middle) = try ui.spot("c", 0.5, 0.55, in: try ui.window("v"))
            try ui.drag(header, from: start, to: middle, in: pane)
            ui.settle(0.4)
            #expect(ui.engine.model.window("v")?.leaves.map(\.id) == ["c"])
            #expect(ui.engine.model.window("w")?.floating.first?.content.leaves.map(\.id) == ["f1", "f2"])
        }
    }

    // MARK: - Resizing splits

    @MainActor
    @Suite struct SplitResize {
        static func near(_ a: [Double]?, _ b: [Double], _ tolerance: Double = 0.002) -> Bool {
            guard let a, a.count == b.count else { return false }
            return zip(a, b).allSatisfy { abs($0 - $1) <= tolerance }
        }

        func sizes(_ ui: UIDriver, _ split: NodeID) -> [Double]? {
            guard let node = try? ui.layout.node(split) else { return nil }
            return node.splitNode?.sizes
        }

        /// Presses at `from` (content coordinates) and drags to `to`.
        func drag(_ ui: UIDriver, _ from: NSPoint, _ to: NSPoint) throws {
            let root = try ui.window.root
            try ui.drag(from: from, in: root, [.move(to: to, steps: 12), .release])
        }

        @Test func aSeparatorDragResizesOnRelease() throws {
            let ui = UIDriver(layout: Fixture.sideBySide(Fixture.leaf("a"), Fixture.leaf("b")))
            // The split spans x 1…1199; its separator is at 600.
            try drag(ui, NSPoint(x: 600, y: 400), NSPoint(x: 700, y: 400))
            #expect(Self.near(sizes(ui, "s"), [699.0 / 1198, 499.0 / 1198]))
            #expect(abs(try ui.paneView("a").layoutFrame.width - 699) < 0.5, "and the views follow")
        }

        @Test func aPaneNeverGoesBelowFivePercentAndThePushCarriesOn() throws {
            let three = Fixture.sideBySide(Fixture.leaf("a"), Fixture.leaf("b"), Fixture.leaf("c"))
            let ui = UIDriver(layout: three)
            let separator = 1 + 1198.0 / 3
            try drag(ui, NSPoint(x: separator, y: 400), NSPoint(x: 1190, y: 400))
            #expect(Self.near(sizes(ui, "s"), [0.9, 0.05, 0.05]), "B stops at 5%, then C does")
            let other = UIDriver(layout: three)
            try drag(other, NSPoint(x: separator, y: 400), NSPoint(x: 5, y: 400))
            let third = 1.0 / 3
            let grown: Double = third + (third - 0.05)
            #expect(Self.near(sizes(other, "s"), [0.05, grown, third]))
        }

        @Test func aPressWhereSeparatorsCrossMovesEveryOne() throws {
            let ui = UIDriver(
                layout: Fixture.saved(
                    Fixture.window(
                        "w",
                        Fixture.split(
                            "s", .horizontal,
                            [
                                Fixture.split("l", .vertical, [Fixture.leaf("a"), Fixture.leaf("b")]),
                                Fixture.split("r", .vertical, [Fixture.leaf("c"), Fixture.leaf("d")]),
                            ]))))
            // Columns meet at x 600; each column's rows at y 31 + 384.
            try drag(ui, NSPoint(x: 600, y: 415), NSPoint(x: 700, y: 515))
            #expect(Self.near(sizes(ui, "s"), [699.0 / 1198, 499.0 / 1198]))
            #expect(Self.near(sizes(ui, "l"), [484.0 / 768, 284.0 / 768]))
            #expect(Self.near(sizes(ui, "r"), [484.0 / 768, 284.0 / 768]))
        }

        /// Row 0 at 50/50, row 1 at 30/70.
        static func rows(snap: Bool) -> UIDriver {
            var settings = SettingsStore.PaneSettings()
            settings.snapResizeSeparators = snap
            return UIDriver(
                layout: Fixture.saved(
                    Fixture.window(
                        "w",
                        Fixture.split(
                            "s", .vertical,
                            [
                                Fixture.split("r0", .horizontal, [Fixture.leaf("a"), Fixture.leaf("b")]),
                                Fixture.split("r1", .horizontal, [Fixture.leaf("c"), Fixture.leaf("d")], sizes: [0.3, 0.7]),
                            ]))), panes: settings)
        }

        @Test func aSeparatorSnapsToAnAlignedOneWithinEightPoints() throws {
            let ui = Self.rows(snap: true)
            try drag(ui, NSPoint(x: 1 + 0.3 * 1198, y: 607), NSPoint(x: 595, y: 607))
            #expect(Self.near(sizes(ui, "r1"), [0.5, 0.5], 0.0005), "onto row 0's separator at x 600")
            #expect(Self.near(sizes(ui, "r0"), [0.5, 0.5]), "which doesn't move")
        }

        @Test func noSnappingWhenTheSettingIsOff() throws {
            let ui = Self.rows(snap: false)
            try drag(ui, NSPoint(x: 1 + 0.3 * 1198, y: 607), NSPoint(x: 595, y: 607))
            #expect(Self.near(sizes(ui, "r1"), [594.0 / 1198, 604.0 / 1198]))
        }

        @Test(arguments: [true, false])
        func aDragAtARowBoundaryCarriesEveryAlignedRow(snap: Bool) throws {
            var settings = SettingsStore.PaneSettings()
            settings.snapResizeSeparators = snap
            let rows = (0..<4).map { index in
                Fixture.split(NodeID("row\(index)"), .horizontal, [Fixture.leaf(PaneID("l\(index)")), Fixture.leaf(PaneID("r\(index)"))])
            }
            let ui = UIDriver(layout: Fixture.saved(Fixture.window("w", Fixture.split("s", .vertical, rows))), panes: settings)
            // Rows are 192 tall from y 31: rows 0 and 1 meet at y 223, on the columns' x 600.
            try drag(ui, NSPoint(x: 600, y: 223), NSPoint(x: 720, y: 223))
            for index in 0..<4 {
                #expect(Self.near(sizes(ui, NodeID("row\(index)")), [719.0 / 1198, 479.0 / 1198]), "row \(index)")
            }
            #expect(Self.near(sizes(ui, "s"), [0.25, 0.25, 0.25, 0.25]), "the rows themselves kept their heights")
        }

        @Test func aClickOnASeparatorActivatesThePaneUnderIt() throws {
            let ui = UIDriver(
                layout: Fixture.sideBySide(Fixture.leaf("a"), Fixture.leaf("b"), active: "b"))
            try ui.click(at: NSPoint(x: 598, y: 400), in: try ui.window.root)
            #expect(ui.activePane == "a")
            #expect(Self.near(sizes(ui, "s"), [0.5, 0.5]), "and resizes nothing")
        }
    }

    // MARK: - Floating panes

    @MainActor
    @Suite struct FloatingPanes {
        static func one(_ rect: FloatRect = FloatRect(x: 300, y: 200, width: 400, height: 250)) -> SavedLayout {
            Fixture.saved(
                Fixture.window("w", Fixture.leaf("d", "inert"), floating: [Fixture.floating("f", Fixture.leaf("fl", "inert"), rect)]))
        }

        func rect(_ ui: UIDriver, _ id: NodeID = "f") -> FloatRect? {
            guard let layout = try? ui.layout else { return nil }
            return layout.floating.first { $0.id == id }?.rect
        }

        func moveHeader(_ ui: UIDriver, by delta: NSPoint, finish: InputSynthesizer.DragStep = .release) throws {
            let (header, start) = try ui.grip("fl")
            try ui.drag(from: start, in: header, [.move(to: NSPoint(x: start.x + delta.x, y: start.y + delta.y)), finish])
        }

        @Test func itsOwnChromeMovesItAndItStaysReachable() throws {
            let ui = UIDriver(layout: Self.one())
            try moveHeader(ui, by: NSPoint(x: 100, y: 50))
            #expect(rect(ui) == FloatRect(x: 400, y: 250, width: 400, height: 250))
            try moveHeader(ui, by: NSPoint(x: -1000, y: -500))
            #expect(
                rect(ui) == FloatRect(x: -320, y: 0, width: 400, height: 250), "80pt stays on screen; the top never goes above the window")
        }

        @Test func escapeCancelsAMove() throws {
            let ui = UIDriver(layout: Self.one())
            try moveHeader(ui, by: NSPoint(x: 100, y: 50), finish: .escape)
            #expect(rect(ui) == FloatRect(x: 300, y: 200, width: 400, height: 250))
            let view = try #require(try ui.window.root.floatingViews.first)
            #expect(view.frame == CGRect(x: 300, y: 200, width: 400, height: 250), "and puts it back where it was")
        }

        @Test func everyEdgeAndCornerResizesDownToTheMinimum() throws {
            let ui = UIDriver(layout: Self.one())
            func resize(_ edge: ResizeHandle.Edge, _ dx: CGFloat, _ dy: CGFloat) throws {
                ui.layoutAll()
                let window = try #require(try ui.window.root.floatingViews.first)
                let handle = try #require(window.subviews.compactMap { $0 as? ResizeHandle }.first { $0.edge == edge })
                let start = NSPoint(x: handle.bounds.midX, y: handle.bounds.midY)
                try ui.drag(from: start, in: handle, [.move(to: NSPoint(x: start.x + dx, y: start.y + dy)), .release])
            }
            try resize(.se, 100, 100)
            #expect(rect(ui) == FloatRect(x: 300, y: 200, width: 500, height: 350))
            try resize(.nw, -50, -50)
            #expect(rect(ui) == FloatRect(x: 250, y: 150, width: 550, height: 400))
            try resize(.n, 0, 1000)
            #expect(rect(ui) == FloatRect(x: 250, y: 430, width: 550, height: 120), "stops at 120 tall against the fixed bottom")
            try resize(.e, -1000, 0)
            #expect(rect(ui) == FloatRect(x: 250, y: 430, width: 240, height: 120), "and 240 wide against the fixed left")
            try resize(.s, 0, 100)
            #expect(rect(ui) == FloatRect(x: 250, y: 430, width: 240, height: 220))
            try resize(.w, -100, 0)
            #expect(rect(ui) == FloatRect(x: 150, y: 430, width: 340, height: 220))
            try resize(.ne, 50, -50)
            #expect(rect(ui) == FloatRect(x: 150, y: 380, width: 390, height: 270))
            try resize(.sw, -50, 50)
            #expect(rect(ui) == FloatRect(x: 100, y: 380, width: 440, height: 320))
        }

        @Test func theLastActivatedFloatingPaneIsOnTop() throws {
            let ui = UIDriver(
                layout: Fixture.saved(
                    Fixture.window(
                        "w", Fixture.leaf("d", "inert"),
                        floating: [
                            Fixture.floating("f1", Fixture.leaf("fl1", "inert"), FloatRect(x: 100, y: 100, width: 300, height: 200)),
                            Fixture.floating("f2", Fixture.leaf("fl2", "inert"), FloatRect(x: 200, y: 150, width: 300, height: 200)),
                        ])))
            let (header, point) = try ui.grip("fl1")
            try ui.click(at: point, in: header)
            #expect(try ui.layout.floating.map(\.id) == ["f2", "f1"], "raised by its chrome")
            #expect(ui.activePane == "fl1")
            // A point of F2's content that F1 doesn't cover.
            let body = try ui.body("fl2")
            try ui.click(at: body.convert(NSPoint(x: 450, y: 320), from: try ui.window.root), in: body)
            #expect(try ui.layout.floating.map(\.id) == ["f1", "f2"], "and by its content")
            #expect(ui.activePane == "fl2")
            #expect(try ui.window.root.floatingViews.map(\.floatID) == ["f1", "f2"], "drawn in that order")
        }

        @Test func unpinnedFromItsHeaderAndPinnedBackBesideItsSibling() throws {
            let ui = UIDriver(layout: DragAndDrop.pair)
            let (header, point) = try ui.grip("a")
            try ui.click(at: point, in: header, right: true)
            #expect(ui.contextMenuCount == 2, "Edit title, Unpin")
            try ui.chooseContextItem(1)
            var layout = try ui.layout
            #expect(layout.floating.first?.content.id == "a")
            #expect(layout.floating.first?.rect == FloatRect(x: 1, y: 31, width: 599, height: 768), "lifted off where it was")
            #expect(layout.shownContent?.id == "b")
            let (floatingHeader, floatingPoint) = try ui.grip("a")
            try ui.click(at: floatingPoint, in: floatingHeader, right: true)
            try ui.chooseContextItem(1)
            layout = try ui.layout
            #expect(layout.floating.isEmpty)
            #expect(layout.shownContent?.splitNode?.children.map(\.id) == ["a", "b"])
            #expect(SplitResize.near(layout.shownContent?.splitNode?.sizes, [0.5, 0.5]), "at the size it had")
        }

        @Test func aBackgroundTabsContentUnpinnedShows() throws {
            let ui = UIDriver(
                layout: Fixture.saved(Fixture.tabsWindow("w", [Fixture.leaf("x", "inert"), Fixture.leaf("y", "inert")], active: 1)))
            try ui.window.unpin("x", origin: "root-w")
            #expect(try ui.layout.floating.first?.content.id == "x")
            #expect(!(try ui.paneView("x").isHiddenOrHasHiddenAncestor), "its floating window shows it")
            #expect(try ui.body("x").content != nil)
        }

        @Test func aShrinkingWindowKeepsItsFloatingPanesInView() throws {
            let ui = UIDriver(layout: Self.one(FloatRect(x: 1000, y: 600, width: 400, height: 250)))
            let window = try #require(try ui.window.window)
            window.setContentSize(NSSize(width: 800, height: 600))
            ui.settle(0.4)
            #expect(rect(ui) == FloatRect(x: 720, y: 520, width: 400, height: 250))
        }
    }

    // MARK: - Keyboard

    @MainActor
    @Suite struct Keyboard {
        static let arrow = { (direction: KeyChord.Key.Direction) in KeyChord(.arrow(direction), [.command]) }

        /// A beside a column of B over C.
        static let lShape = Fixture.saved(
            Fixture.window(
                "w",
                Fixture.split(
                    "s", .horizontal, [Fixture.leaf("a"), Fixture.split("v", .vertical, [Fixture.leaf("b"), Fixture.leaf("c")])]),
                active: "a"))

        @Test func arrowsWalkTheSplitsAndWrapAtTheEdges() throws {
            let ui = UIDriver(layout: Self.lShape)
            #expect(try ui.press(Self.arrow(.right)))
            #expect(ui.activePane == "b", "into the column at the row it came from")
            try ui.press(Self.arrow(.down))
            #expect(ui.activePane == "c")
            try ui.press(Self.arrow(.down))
            #expect(ui.activePane == "b", "the column wraps")
            try ui.press(Self.arrow(.left))
            #expect(ui.activePane == "a")
            try ui.press(Self.arrow(.left))
            #expect(ui.activePane == "b", "the row wraps, to the pane level with A")
            try ui.press(Self.arrow(.left))
            try ui.press(Self.arrow(.up))
            #expect(ui.activePane == "c", "nothing above A: the pane at the far edge")
            #expect(ui.focusedPane == ui.activePane, "the keyboard follows")
        }

        @Test func leftAndRightCycleTabsUpAndDownNever() throws {
            let group = Fixture.tabs("g", [Fixture.tab(Fixture.leaf("x")), Fixture.tab(Fixture.leaf("y"))])
            let ui = UIDriver(layout: Fixture.saved(Fixture.window("w", group)))
            try ui.press(Self.arrow(.right))
            #expect(ui.activePane == "y")
            #expect(try ui.layout.node("g")?.group?.activeTabID == "t-y")
            try ui.press(Self.arrow(.right))
            #expect(ui.activePane == "x", "and around")
            try ui.press(Self.arrow(.down))
            #expect(ui.activePane == "x", "down never switches tabs")
            #expect(try ui.layout.node("g")?.group?.activeTabID == "t-x")
        }

        @Test func navigationStaysInsideAFloatingPane() throws {
            let split = Fixture.split("fs", .horizontal, [Fixture.leaf("f1"), Fixture.leaf("f2")])
            let floating = Fixture.floating("f", split, FloatRect(x: 300, y: 200, width: 600, height: 300))
            let ui = UIDriver(layout: Fixture.saved(Fixture.window("w", Fixture.leaf("d"), active: "f1", floating: [floating])))
            try ui.press(Self.arrow(.right))
            #expect(ui.activePane == "f2")
            try ui.press(Self.arrow(.right))
            #expect(ui.activePane == "f1", "wrapping within the floating pane, never into the docked one")
        }

        @Test func eachPressFlashesItsDirectionUnlessTurnedOff() throws {
            let ui = UIDriver(layout: Self.lShape)
            try ui.press(Self.arrow(.right))
            #expect(try ui.window.root.overlay.subviews.contains { $0 is NavFlashView })
            var off = SettingsStore.PaneSettings()
            off.showNavFlash = false
            let quiet = UIDriver(layout: Self.lShape, panes: off)
            try quiet.press(Self.arrow(.right))
            #expect(quiet.activePane == "b")
            #expect(try !quiet.window.root.overlay.subviews.contains { $0 is NavFlashView })
        }

        @Test func aTextViewWithTheKeyboardKeepsItsArrows() throws {
            let ui = UIDriver(
                layout: Fixture.sideBySide(Fixture.leaf("n", "text"), Fixture.leaf("c", "inert")))
            #expect(ui.focusedPane == "n")
            #expect(try !ui.press(Self.arrow(.right)), "the text view moves its caret")
            #expect(ui.activePane == "n")
        }

        @Test func theNewPaneShortcutsAndClose() throws {
            let ui = UIDriver(layout: Fixture.saved(Fixture.window("w", Fixture.leaf("a", "inert"))))
            #expect(try ui.press(KeyChord("t", [.command, .shift])))
            let split = try #require(try ui.layout.shownContent?.splitNode)
            #expect(split.direction == .horizontal && split.children.first?.id == "a")
            let first = try #require(ui.activePane)
            #expect(first == split.children.last?.id)
            #expect(try ui.press(KeyChord("t", [.command, .option])))
            #expect(try ui.layout.shownContent?.splitNode?.children.last?.splitNode?.direction == .vertical, "⌥⌘T splits the new pane down")
            #expect(try ui.press(KeyChord("t", [.command, .option, .shift])))
            let floating = try #require(try ui.layout.floating.first)
            #expect(ui.activePane == floating.content.id, "⌥⇧⌘T opens an unpinned pane")
            #expect(try ui.press(KeyChord("w", [.command])))
            #expect(try ui.layout.floating.isEmpty, "⌘W on a floating pane's own pane closes it")
            #expect(try ui.press(KeyChord("t", [.command])))
            #expect(try ui.layout.leaves.count == 4, "⌘T: a new tab beside the active pane")
        }
    }
}
