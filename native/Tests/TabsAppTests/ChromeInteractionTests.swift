import AppKit
import TabsPluginSDK
import Testing

@testable import Tabs
@testable import TabsCore

extension UIDriver {
    /// Drags `view` from `start` (its coordinates) to `end` in `target` — in
    /// the same window or another — then releases, or finishes with `finish`.
    func drag(
        _ view: NSView, from start: NSPoint, to end: NSPoint, in target: NSView, wait: TimeInterval? = nil,
        finish: InputSynthesizer.DragStep = .release
    ) throws {
        let destination = try point(end, of: target, from: view)
        var steps: [InputSynthesizer.DragStep] = [.move(to: destination, steps: 10)]
        if let wait { steps.append(.wait(wait)) }
        steps.append(finish)
        try drag(from: start, in: view, steps)
    }

    /// Where a press picks up a pane: on its header's title (or, for a group, its bar clear of the tabs).
    func grip(_ pane: NodeID, in window: WorkspaceWindowController? = nil) throws -> (view: NSView, point: NSPoint) {
        let view = try paneView(pane, in: window)
        if let header = view.header { return (header, NSPoint(x: header.titleRect.minX + 6, y: header.titleRect.midY)) }
        let bar = try #require(view.tabBar)
        return (bar, NSPoint(x: bar.strip.frame.maxX - 4, y: bar.bounds.height / 2))
    }

    /// Where a press picks up a tab.
    func grip(tab: NodeID, in window: WorkspaceWindowController? = nil) throws -> (view: NSView, point: NSPoint) {
        let view = try tabView(tab, in: window)
        return (view, NSPoint(x: view.titleRect.minX + 4, y: view.titleRect.midY))
    }

    /// A point of a pane, as fractions of its box (0.5, 0.55 is its middle, below the header).
    func spot(
        _ pane: NodeID, _ x: CGFloat, _ y: CGFloat, in window: WorkspaceWindowController? = nil
    ) throws -> (view: NSView, point: NSPoint) {
        let view = try paneView(pane, in: window)
        return (view, NSPoint(x: view.bounds.width * x, y: view.bounds.height * y))
    }
}

extension UITests {
    // MARK: - Tabs

    @MainActor
    @Suite struct TabStrip {
        /// A split: empty pane A beside group G of two empty tabs, X and Y (Y shown).
        static let splitWithGroup = Fixture.saved(
            Fixture.window(
                "w",
                Fixture.split(
                    "s", .horizontal,
                    [
                        Fixture.leaf("a"),
                        Fixture.tabs("g", [Fixture.tab(Fixture.leaf("x")), Fixture.tab(Fixture.leaf("y"))], active: "t-y"),
                    ]), active: "y"))

        @Test func thePlusButtonAddsATabToItsOwnGroupOnly() throws {
            let ui = UIDriver(layout: Self.splitWithGroup)
            let button = try #require(try ui.paneView("g").tabBar?.strip.newTabButton)
            try ui.click(button)
            let layout = try ui.layout
            #expect(layout.tabIDs("g").count == 3, "a tab in G")
            #expect(layout.root.tabs.count == 1, "none at the root")
            let added = try #require(layout.tabContents("g").last)
            #expect(ui.activePane == added, "the new tab is active")
            #expect(layout.tabTitles("g").last == "New Tab")
        }

        @Test func aDoubleClickedTitleRenamesOnReturn() throws {
            let ui = UIDriver(layout: Self.splitWithGroup)
            try ui.click(tab: "t-x", count: 2)
            #expect(try ui.tabView("t-x").editor != nil, "an editor over the title")
            try ui.type("Renamed\n")
            #expect(try ui.layout.tabTitles("g") == ["Renamed", "New Tab"])
            #expect(try ui.tabView("t-x").editor == nil)
        }

        @Test func escapeAbandonsARenameAndAnEmptyTitleIsRefused() throws {
            let ui = UIDriver(layout: Self.splitWithGroup)
            try ui.click(tab: "t-x", count: 2)
            try ui.type("Nope")
            try ui.press(KeyChord(.escape, []))
            #expect(try ui.layout.tabTitles("g") == ["New Tab", "New Tab"])
            try ui.click(tab: "t-x", count: 2)
            try ui.type("   \n")
            #expect(try ui.layout.tabTitles("g") == ["New Tab", "New Tab"], "a tab always has a title")
        }

        @Test func editTitleFromTheTabsMenu() throws {
            let ui = UIDriver(layout: Self.splitWithGroup)
            try ui.click(tab: "t-y", right: true)
            #expect(ui.contextMenuCount == 2, "Edit title, Unpin")
            try ui.chooseContextItem(0)
            try ui.type("From the menu\n")
            #expect(try ui.layout.tabTitles("g") == ["New Tab", "From the menu"])
        }

        @Test func aOneTabGroupUngroupsFromItsBarsMenuButTheRootNever() throws {
            let ui = UIDriver(layout: Fixture.sideBySide(Fixture.leaf("a"), Fixture.tabs("g", [Fixture.tab(Fixture.leaf("x"))])))
            let (bar, point) = try ui.grip("g")
            try ui.click(at: point, in: bar, right: true)
            #expect(ui.contextMenuCount == 2, "Unpin, Ungroup")
            try ui.chooseContextItem(1)
            #expect(try ui.layout.node("g") == nil, "the group is gone")
            #expect(try ui.layout.node("s")?.splitNode?.children.map(\.id) == ["a", "x"], "its tab's content took its place")

            let root = try #require(try ui.paneView(ui.layout.root.id).tabBar)
            try ui.click(at: NSPoint(x: root.strip.frame.maxX - 4, y: 12), in: root, right: true)
            #expect(ui.contextMenu == nil, "the window's own bar offers neither Unpin nor Ungroup")
        }

        @Test func aGroupUnpinsFromItsBarAndPinsBack() throws {
            let ui = UIDriver(layout: Self.splitWithGroup)
            let (bar, point) = try ui.grip("g")
            try ui.click(at: point, in: bar, right: true)
            try ui.chooseContextItem(0)
            var layout = try ui.layout
            #expect(layout.floating.map(\.content.id) == ["g"], "the whole group floats, tabs and all")
            #expect(layout.tabContents("g") == ["x", "y"])
            #expect(layout.node("s") == nil, "the split it left collapsed")
            let (floatingBar, floatingPoint) = try ui.grip("g")
            try ui.click(at: floatingPoint, in: floatingBar, right: true)
            #expect(ui.contextMenuCount == 1, "Pin")
            try ui.chooseContextItem(0)
            layout = try ui.layout
            #expect(layout.floating.isEmpty)
            #expect(layout.shownContent?.splitNode?.children.map(\.id) == ["a", "g"], "back beside the pane it came from")
        }
    }

    // MARK: - Header controls

    @MainActor
    @Suite struct HeaderControls {
        static let one = Fixture.saved(Fixture.window("w", Fixture.leaf("a")))

        @Test func splitHorizontallyIsTheRootButton() throws {
            let ui = UIDriver(layout: Self.one)
            try ui.click(try ui.control("pane-split-horizontal-button", of: "a"))
            let split = try #require(try ui.layout.shownContent?.splitNode)
            #expect(split.direction == .horizontal)
            #expect(split.children.first?.id == "a")
            #expect(ui.activePane == split.children.last?.id, "the new pane is active")
            #expect(ui.focusedPane == ui.activePane)
        }

        @Test func theMenuSplitsVerticallyOpensTabsAndWraps() throws {
            // Inert panes: a new tab at an empty pane would replace it rather than join it.
            let ui = UIDriver(layout: Fixture.saved(Fixture.window("w", Fixture.leaf("a", "inert"))))
            try ui.choose(.splitVertical, of: "a")
            #expect(try ui.layout.shownContent?.splitNode?.direction == .vertical)
            #expect(HeaderMenu.openDropdown == nil, "choosing closes the menu")

            try ui.choose(.newTab, of: "a")
            let group = try #require(try ui.layout.shownContent?.splitNode?.children.first)
            #expect(group.group?.tabs.map(\.content.id).first == "a", "A was promoted into a group with the new tab")
            #expect(group.group?.tabs.count == 2)

            let other = try #require(try ui.layout.shownContent?.splitNode?.children.last?.id)
            try ui.choose(.wrapInTabGroup, of: other)
            let wrapped = try #require(try ui.layout.shownContent?.splitNode?.children.last)
            #expect(wrapped.group?.tabs.map(\.content.id) == [other])
            #expect(wrapped.group?.tabs.first?.title == "Inert", "titled after its content")
            #expect(ui.activeNode == wrapped.id, "the new group is active")
        }

        @Test func aNewTabAtAnEmptyPaneReplacesIt() throws {
            let ui = UIDriver(layout: Fixture.sideBySide(Fixture.leaf("a"), Fixture.leaf("b", "inert")))
            try ui.choose(.newTab, of: "a")
            let group = try #require(try ui.layout.shownContent?.splitNode?.children.first?.group)
            #expect(group.tabs.count == 1 && group.tabs.first?.content.id != "a", "the empty pane gave way to the new tab")
            #expect(try ui.layout.node("a") == nil)
        }

        @Test func aNewUnpinnedTabFloatsOverTheTopRightOfItsPane() throws {
            let ui = UIDriver(layout: Self.one)
            try ui.choose(.newUnpinnedTab, of: "a")
            let floating = try #require(try ui.layout.floating.first)
            // A's box is [1, 31, 1198, 768]: 640×400 inset 16pt from its top-right corner.
            #expect(floating.rect == FloatRect(x: 543, y: 47, width: 640, height: 400))
            #expect(try ui.layout.leaves.map(\.id).first == "a", "A stays docked")
            #expect(ui.activePane == floating.content.id)
        }

        @Test func closeAndClear() throws {
            let ui = UIDriver(
                layout: Fixture.sideBySide(Fixture.leaf("a", "inert"), Fixture.leaf("b")))
            try ui.choose(.clear, of: "b")
            #expect(try ui.layout.node("b") != nil, "clearing an empty pane is disabled")
            try ui.choose(.clear, of: "a")
            #expect(try ui.layout.node("a") == nil)
            let cleared = try #require(try ui.layout.shownContent?.splitNode?.children.first)
            #expect(cleared.isEmpty, "an empty pane in its place")
            #expect(ui.activePane == cleared.id, "which keeps the focus")
            try ui.click(try ui.control("pane-close-button", of: "b"))
            #expect(try ui.layout.shownContent?.id == cleared.id, "closing B collapsed the split")
        }

        @Test func theRootBarsControlsActOnTheShownTab() throws {
            let ui = UIDriver(
                layout: Fixture.saved(Fixture.tabsWindow("w", [Fixture.leaf("a", "inert"), Fixture.leaf("b", "inert")], active: 1)))
            let root = try ui.layout.root.id
            let bar = try ui.chrome(root)
            let window = try #require(bar.window)
            #expect(InputSynthesizer.find("pane-split-horizontal-button", in: window, within: bar) == nil, "no split on the root bar")
            try ui.click(try ui.control("pane-new-tab-button", of: root))
            #expect(try ui.layout.root.tabs.count == 3, "New tab is the root bar's own first control")
            try ui.click(tab: "t-b")
            try ui.click(try ui.control("pane-close-button", of: root))
            #expect(try ui.layout.leaves.map(\.id).contains("b") == false, "closing the root closes the tab it shows")
            #expect(try ui.layout.leaves.map(\.id).contains("a"))
        }
    }

    // MARK: - Chrome

    @MainActor
    @Suite struct Chrome {
        @Test func theTrafficLightsSitInTheRootBar() throws {
            let ui = UIDriver()
            let window = try #require(try ui.window.window as? WorkspaceWindow)
            window.placeTrafficLights()
            let close = try #require(window.standardWindowButton(.closeButton))
            let frame = close.convert(close.bounds, to: nil)
            #expect(frame.minX == 14, "Electron's trafficLightPosition x")
            #expect(window.frame.height - frame.maxY == 9, "and y, centered in the 30pt bar")
            let zoomButton = try #require(window.standardWindowButton(.zoomButton))
            let zoom = zoomButton.convert(zoomButton.bounds, to: nil)
            #expect(zoom.maxX < Metrics.trafficLightGutter, "clear of the gutter the bar leaves them")
        }

        @Test func fullscreenCollapsesTheRootBar() throws {
            let ui = UIDriver()
            let controller = try ui.window
            let bar = try #require(try ui.paneView(ui.layout.root.id).tabBar)
            #expect(bar.layoutFrame.height == 31, "30pt, plus the row the active tab overhangs")
            #expect(bar.strip.layoutFrame.minX == 90, "the gutter clears the traffic lights")
            controller.windowWillEnterFullScreen(Notification(name: NSWindow.willEnterFullScreenNotification))
            ui.layoutAll()
            #expect(bar.layoutFrame.height == 25, "an ordinary bar in fullscreen")
            #expect(bar.strip.layoutFrame.minX == 8, "no gutter")
            #expect(controller.appearance.cornerRadius == 0)
            controller.windowDidExitFullScreen(Notification(name: NSWindow.didExitFullScreenNotification))
            ui.layoutAll()
            #expect(bar.layoutFrame.height == 31)
        }

        @Test func onlyInactivePanesBodiesDim() throws {
            let layout = Fixture.sideBySide(Fixture.leaf("a"), Fixture.leaf("b"), active: "a")
            let ui = UIDriver(layout: layout)
            #expect(try (ui.body("a").content as? EmptyPaneView)?.dim == nil)
            #expect(try (ui.body("b").content as? EmptyPaneView)?.dim != nil, "grayscale and darker")
            try ui.click(body: "b")
            #expect(try (ui.body("a").content as? EmptyPaneView)?.dim != nil, "follows activation")
            #expect(try (ui.body("b").content as? EmptyPaneView)?.dim == nil)

            var off = SettingsStore.PaneSettings()
            off.dimInactivePanes = false
            let undimmed = UIDriver(layout: layout, panes: off)
            #expect(try (undimmed.body("b").content as? EmptyPaneView)?.dim == nil)
        }

        @Test func theActiveOutlineFollowsActivation() throws {
            let ui = UIDriver(
                layout: Fixture.sideBySide(Fixture.leaf("a"), Fixture.leaf("b"), active: "a"))
            func pixel(_ x: Int, _ y: Int) throws -> NSColor {
                let root = try ui.window.root
                RunLoop.main.run(until: Date().addingTimeInterval(0.1))
                let image = try #require(NSBitmapImageRep(data: VisualCapture.render(root)))
                return try #require(image.colorAt(x: x * 2, y: y * 2)?.usingColorSpace(.sRGB))
            }
            // The capture's color space shifts it a little; nothing else in the chrome is this blue.
            func isAccent(_ color: NSColor) -> Bool { color.blueComponent - color.redComponent > 0.4 }
            func accented() throws -> [Int] { try [0, 1, 598, 599, 600, 601, 1198, 1199].filter { isAccent(try pixel($0, 400)) } }
            // Each outline covers its pane's left and right border columns (A: 0 and 599, B: 600 and 1199).
            #expect(try accented() == [0, 599])
            try ui.click(body: "b")
            #expect(try accented() == [600, 1199])
        }
    }
}
