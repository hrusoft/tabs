import AppKit
import TabsPluginSDK
import Testing

@testable import Tabs
@testable import TabsCore

/// A control in a header title: takes a press, counts it.
@MainActor
final class TitleButton: NSView {
    private(set) var presses = 0
    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { presses += 1 }
    override func mouseUp(with event: NSEvent) {}
}

/// A header title: one button at its left, empty space after it.
@MainActor
final class TitleProbe: NSView, PaneHeaderTitleView {
    let button = TitleButton()
    private(set) var slots: [PaneHeaderSlot] = []
    override var isFlipped: Bool { true }
    init() {
        super.init(frame: .zero)
        addSubview(button)
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
    override func layout() {
        super.layout()
        button.frame = CGRect(x: 0, y: 2, width: min(20, bounds.width), height: 20)
    }
    func paneHeaderSlotDidChange(_ slot: PaneHeaderSlot) { slots.append(slot) }
}

@MainActor
final class TitledPane: PaneController {
    let view = NSView()
    let probe = TitleProbe()
    var headerTitle: NSView? { probe }
    func currentConfig() -> JSONValue { .emptyObject }
}

extension UITests {
    /// `PaneController.headerTitle`: a plugin's view in the header's title slot.
    @MainActor
    @Suite struct HeaderTitle {
        /// Titled pane A beside plain pane B; B is the active one.
        static let pair = Fixture.saved(
            Fixture.window("w", Fixture.split("s", .horizontal, [Fixture.leaf("a", "titled"), Fixture.leaf("b")]), active: "b"))

        private func titled() -> PluginCandidate {
            TestSupport.candidate(TestSupport.manifest("titled", contentTypes: ["titled"])) { context in
                context.register(
                    ContentTypeContribution(id: "titled", displayName: "Titled", icon: .symbol("square")) { _ in TitledPane() })
            }
        }

        private func driver() -> (UIDriver, TitleProbe) {
            let ui = UIDriver(layout: Self.pair, inProcess: [titled()])
            return (ui, (ui.renderer.body(for: "a")?.live?.controller as! TitledPane).probe)
        }

        @Test func theViewSitsInTheTitleSlotInPlaceOfTheTitle() throws {
            let (ui, probe) = driver()
            let header = try #require(try ui.paneView("a").header)
            #expect(header.titleView === probe)
            #expect(probe.superview === header)
            let slot = header.titleRect
            #expect(abs(probe.frame.minX - slot.minX) <= 0.5 && abs(probe.frame.width - slot.width) <= 1, "it fills the slot")
            #expect(probe.frame.height == 24, "as tall as the bar's content")
            #expect(probe.frame.minX > header.grip.frame.maxX, "after the grip")
            #expect(probe.frame.maxX < header.controls.frame.minX, "before the controls")
            #expect(try ui.paneView("b").header?.titleView == nil, "a pane without one keeps the title")
            #expect(header.grip.superview === header && header.controls.superview === header, "the rest of the bar is still drawn")
            let depth = try ui.paneView("a").depth
            let bar = header.layoutSize.width - Metrics.depthIndent(depth) - Metrics.barPaddingRight
            let told = try #require(probe.slots.last)
            #expect(abs(told.barContentWidth - bar) < 0.01, "told the bar's content width: \(told.barContentWidth) vs \(bar)")
        }

        @Test func theSlotFlexesWithTheWindowDownToNothing() throws {
            let (ui, probe) = driver()
            let window = try #require(try ui.window.window)
            let wide = probe.frame.width
            window.setContentSize(NSSize(width: 500, height: 400))
            ui.settle(0.3)
            let narrow = probe.frame.width
            #expect(narrow < wide, "it shrinks with the bar")
            #expect(narrow > 0)
            window.setContentSize(NSSize(width: 200, height: 400))
            ui.settle(0.3)
            let header = try #require(try ui.paneView("a").header)
            #expect(probe.frame.width >= 0 && probe.frame.maxX <= header.controls.frame.minX, "never over the controls, and never negative")
            window.setContentSize(NSSize(width: 1200, height: 400))
            ui.settle(0.3)
            #expect(probe.frame.width > narrow, "and it grows back")
        }

        @Test func aTitleViewMeansNoEditTitle() throws {
            let (ui, probe) = driver()
            let header = try #require(try ui.paneView("a").header)
            let empty = NSPoint(x: probe.bounds.maxX - 12, y: probe.bounds.midY)
            // Double-clicking the empty space after its controls renames nothing.
            try ui.click(at: empty, in: probe, count: 2)
            #expect(header.editor == nil)
            // A plain pane's menu offers Edit title and Unpin; this one's only Unpin.
            let (plain, point) = try ui.grip("b")
            try ui.click(at: point, in: plain, right: true)
            #expect(ui.contextMenuCount == 2, "Edit title, Unpin")
            try ui.press(KeyChord(.escape, []))
            #expect(ui.contextMenu == nil)
            try ui.click(at: empty, in: probe, right: true)
            #expect(ui.contextMenuCount == 1, "Unpin")
        }

        /// The Electron test "a git tree pane's header controls do not start a pane drag".
        @Test func aPressOnItsControlActivatesThePaneWithoutStartingADrag() throws {
            let (ui, probe) = driver()
            #expect(ui.activePane == "b")
            let before = try ui.layout.rootNode
            let (pane, target) = try ui.spot("b", 0.9, 0.55)
            try ui.drag(
                probe.button, from: NSPoint(x: probe.button.bounds.midX, y: probe.button.bounds.midY), to: target, in: pane)
            #expect(probe.button.presses == 1, "the control took the press")
            #expect(!ui.renderer.drag.isDragging)
            #expect(try ui.layout.rootNode == before, "nothing moved")
            #expect(ui.activePane == "a", "and the pane is active")
        }

        @Test func aPressOnItsEmptySpaceDragsThePaneLikeTheRestOfTheBar() throws {
            let (ui, probe) = driver()
            let start = NSPoint(x: probe.bounds.maxX - 8, y: probe.bounds.midY)
            let (pane, edge) = try ui.spot("b", 0.9, 0.55)
            try ui.drag(probe, from: start, to: edge, in: pane)
            #expect(probe.button.presses == 0)
            #expect(try ui.layout.shownContent?.splitNode?.children.map(\.id) == ["b", "a"], "docked beside B")
        }
    }
}
