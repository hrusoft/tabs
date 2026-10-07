import AppKit
import TabsPluginSDK
import Testing

@testable import Tabs
@testable import TabsCore

extension UITests {
    // MARK: - The ⌘P command palette (docs/NEW-CONTENT.md; ids P-, T-, S-, K-, M-, C-, F-, E-)

    /// The palette in a window: opened by its chord, keyed and clicked through the window, making
    /// panes. Its rows and what each key does to them are `PaletteStateTests`', without a window.
    @MainActor
    @Suite struct PaletteTests {
        /// What the test plugins' panes were created from.
        final class Origins {
            var made: [(type: String, origin: PaneID?)] = []
            var onMake: (() -> Void)?
        }

        private static func plugin(
            _ id: String, types: [String], origins: Origins = Origins(), symbol: String = "square"
        ) -> PluginCandidate {
            TestSupport.candidate(TestSupport.manifest(id, contentTypes: types.map { "\(id).\($0)" })) { context in
                for type in types {
                    context.register(
                        ContentTypeContribution(
                            id: ContentTypeID("\(id).\(type)"), displayName: type.capitalized, icon: .symbol(symbol),
                            initialConfig: { creation in
                                origins.made.append((type, creation.origin))
                                origins.onMake?()
                                return .emptyObject
                            },
                            makePane: { pane in StubPane(config: pane.initialConfig) }))
                }
            }
        }

        private let cmdP = KeyChord("p", [.command])

        /// The palette, opened by its chord as a user does.
        @discardableResult
        private func open(_ ui: UIDriver) throws -> PaletteView {
            try ui.press(cmdP)
            return try #require(ui.palette, "⌘P opened no palette")
        }

        private func labels(_ palette: PaletteView) -> [String] { palette.rows.map(\.label) }

        /// A point on row `index`, in the palette's (window content) coordinates.
        private func center(of row: Int, in palette: PaletteView) -> NSPoint {
            let box = palette.rowRect(row)
            return NSPoint(x: palette.panelLayout.minX + box.midX, y: palette.panelLayout.minY + box.midY)
        }

        private func two(_ origins: Origins = Origins()) -> [PluginCandidate] {
            [Self.plugin("pal", types: ["alpha", "beta"], origins: origins)]
        }

        // MARK: Opening

        /// P-1, T-1, T-2, T-4, P-6
        @Test func theChordOpensTheTypeStepAimedAtTheActivePaneAndTakesTheKeyboard() throws {
            let ui = UIDriver(inProcess: two(), requiring: ["pal.alpha", "pal.beta"])
            let active = try ui.layout.activePaneID
            let palette = try open(ui)
            #expect(palette.step == .type)
            #expect(palette.target == active)
            #expect(labels(palette) == ["Alpha", "Beta"], "the types' plain names, in UI order")
            #expect(palette.highlighted == 0)
            #expect(try ui.window.window?.firstResponder === palette, "the keyboard is the palette's")
            #expect(palette.superview === (try ui.window.root.overlay), "in the window's overlay")
            for row in palette.rows {
                guard case .type(.symbol("square")) = row.icon else {
                    Issue.record("a row without its type's icon")
                    return
                }
            }
        }

        /// P-6: it takes the keyboard from whatever held it (a text editor here).
        @Test func itTakesTheKeyboardFromAPaneThatHadIt() throws {
            let ui = UIDriver(standIns: true)
            try ui.create("text")
            #expect(ui.focusedPane != nil)
            let palette = try open(ui)
            #expect(ui.focusedPane == nil)
            #expect(try ui.window.window?.firstResponder === palette)
        }

        /// P-3
        @Test func itOpensOnlyInTheWindowTheChordWasUsedIn() throws {
            let ui = UIDriver(layout: Fixture.saved(Fixture.window("w1", Fixture.leaf("a")), Fixture.window("w2", Fixture.leaf("b"))))
            let front = try ui.window
            let other = try #require(ui.renderer.windows.first { $0 !== front })
            try open(ui)
            #expect(Palette.current(in: front) != nil)
            #expect(Palette.current(in: other) == nil)
        }

        /// P-4
        @Test func itIsAboveAFloatingPane() throws {
            let float = Fixture.floating("float", Fixture.leaf("f"), FloatRect(x: 300, y: 200, width: 400, height: 300))
            let ui = UIDriver(layout: Fixture.saved(Fixture.window("w", Fixture.leaf("a"), floating: [float])))
            let palette = try open(ui)
            let root = try ui.window.root
            let order = root.subviews
            let floatingIndex = try #require(order.firstIndex(of: root.floatingLayer))
            let overlayIndex = try #require(order.firstIndex(of: root.overlay))
            #expect(overlayIndex > floatingIndex)
            #expect(palette.superview === root.overlay)
        }

        /// P-7, Q-1: the highlight resets only when the step's kind changes.
        @Test func openingAgainResetsTheHighlightOnlyOnAChangeOfStep() throws {
            let ui = UIDriver(inProcess: two(), requiring: ["pal.alpha", "pal.beta"])
            let palette = try open(ui)
            try ui.key(InputSynthesizer.Key.down)
            #expect(palette.highlighted == 1)
            try open(ui)
            #expect(palette.highlighted == 1, "same step: kept")
            try ui.key(InputSynthesizer.Key.return)
            #expect(palette.step == .placement("pal.beta"))
            #expect(palette.highlighted == 0, "a new step starts on its first row")
            try ui.key(InputSynthesizer.Key.down)
            try ui.key(InputSynthesizer.Key.down)
            #expect(palette.highlighted == 2)
            try open(ui)
            #expect(palette.step == .type, "the chord again returns to the first step")
            #expect(palette.highlighted == 0, "the kind changed")
            let overlay = try ui.window.root.overlay
            #expect(overlay.subviews.compactMap { $0 as? PaletteView }.count == 1, "still one palette")
        }

        // MARK: Step 1

        /// T-5, C-11, Q-2: a type turned off while open leaves the list; the highlight isn't clamped.
        @Test func aTypeTurnedOffWhileOpenLeavesTheList() throws {
            let ui = UIDriver(
                inProcess: [Self.plugin("one", types: ["alpha"]), Self.plugin("two", types: ["beta"])],
                requiring: ["one.alpha", "two.beta"])
            let palette = try open(ui)
            #expect(labels(palette) == ["Alpha", "Beta"])
            try ui.key(InputSynthesizer.Key.down)
            ui.runtime.host.setUserEnabled(false, for: "two")
            ui.settle(until: { labels(palette) == ["Alpha"] })
            #expect(labels(palette) == ["Alpha"])
            #expect(palette.highlighted == 1, "not clamped")
            try ui.key(InputSynthesizer.Key.return)
            #expect(ui.palette === palette && palette.step == .type, "Return with nothing under the highlight does nothing")
            ui.runtime.host.setUserEnabled(true, for: "two")
            ui.settle(until: { labels(palette) == ["Alpha", "Beta"] })
            #expect(labels(palette) == ["Alpha", "Beta"], "and back")
        }

        // MARK: Keyboard

        /// K-5: Escape closes and returns the keyboard to the pane that was active.
        @Test func escapeReturnsTheKeyboardToThePane() throws {
            let ui = UIDriver(standIns: true)
            try ui.create("text")
            let pane = try #require(ui.focusedPane)
            try open(ui)
            #expect(ui.focusedPane == nil)
            try ui.key(InputSynthesizer.Key.escape)
            #expect(ui.palette == nil)
            #expect(ui.focusedPane == pane)
        }

        // MARK: Mouse

        /// M-1
        @Test func enteringARowHighlightsIt() throws {
            let ui = UIDriver(inProcess: two(), requiring: ["pal.alpha", "pal.beta"])
            let palette = try open(ui)
            let window = try #require(try ui.window.window)
            let point = center(of: 1, in: palette)
            let event = try #require(InputSynthesizer.mouseEvent(.mouseMoved, at: palette.convert(point, to: nil), in: window))
            palette.mouseMoved(with: event)
            #expect(palette.highlighted == 1)
            // Keys move it on; the pointer resting in the same row doesn't take it back (mouseenter fires on entry only).
            try ui.key(InputSynthesizer.Key.up)
            #expect(palette.highlighted == 0)
            palette.mouseMoved(with: event)
            #expect(palette.highlighted == 0)
        }

        /// M-2
        @Test func clickingARowChoosesIt() throws {
            let ui = UIDriver(inProcess: two(), requiring: ["pal.alpha", "pal.beta"])
            let palette = try open(ui)
            try ui.click(at: center(of: 1, in: palette), in: palette)
            #expect(palette.step == .placement("pal.beta"))
            try ui.click(at: center(of: 3, in: palette), in: palette)
            #expect(ui.palette == nil)
            #expect(try ui.layout.floating.count == 1, "Unpinned Pane")
        }

        /// M-3
        @Test func clickingTheBackdropDismissesAndReturnsTheKeyboard() throws {
            let ui = UIDriver(standIns: true)
            try ui.create("text")
            let pane = try #require(ui.focusedPane)
            let palette = try open(ui)
            try ui.click(at: NSPoint(x: 4, y: 4), in: palette)
            #expect(ui.palette == nil)
            #expect(ui.focusedPane == pane)
        }

        /// M-4: the panel's own padding, border and the empty text are inert.
        @Test func clickingThePanelOutsideItsRowsDoesNothing() throws {
            let ui = UIDriver(inProcess: two(), requiring: ["pal.alpha", "pal.beta"])
            let palette = try open(ui)
            try ui.click(at: NSPoint(x: palette.panelLayout.minX + 2, y: palette.panelLayout.midY), in: palette)
            #expect(ui.palette === palette && palette.step == .type)
        }

        /// M-5: nothing under the backdrop reacts.
        @Test func thePanesBeneathTheBackdropDontReact() throws {
            let ui = UIDriver(inProcess: two(), requiring: ["pal.alpha", "pal.beta"])
            let before = try ui.layout.leaves.count
            let root = try ui.layout.root.id
            let tabs = try ui.layout.tabIDs(root).count
            let palette = try open(ui)
            let plus = try ui.paneView(root).tabBar!.strip.newTabButton
            let point = try ui.contentPoint(NSPoint(x: plus.bounds.midX, y: plus.bounds.midY), in: plus)
            try ui.click(at: point, in: palette)
            #expect(ui.palette == nil, "a click on the backdrop closes it")
            #expect(try ui.layout.leaves.count == before && ui.layout.tabIDs(root).count == tabs, "and the button under it wasn't pressed")
        }

        /// M-6, Q-6
        @Test func aRightClickOnTheBackdropDoesNothing() throws {
            let ui = UIDriver(inProcess: two(), requiring: ["pal.alpha", "pal.beta"])
            let palette = try open(ui)
            try ui.click(at: NSPoint(x: 4, y: 4), in: palette, right: true)
            #expect(ui.palette === palette)
        }

        // MARK: Creating and placing

        /// C-3: Horizontal Split, then Vertical Split of the pane it made; K-4: a digit chooses with
        /// any modifier held (the test is on the physical key alone).
        @Test func aTypeThenASplitSplitsTheTarget() throws {
            let ui = UIDriver(
                layout: Fixture.saved(Fixture.window("w", Fixture.leaf("a", "pal.alpha"))), inProcess: two(),
                requiring: ["pal.alpha", "pal.beta"])
            try open(ui)
            try ui.key(InputSynthesizer.Key.digit(1))
            try ui.key(InputSynthesizer.Key.digit(2))
            let split = try #require(try ui.layout.shownContent?.splitNode)
            #expect(split.direction == .horizontal)
            #expect(split.children.first?.id == "a" && split.children.count == 2)
            let made = try #require(ui.activePane)
            #expect(split.children.last?.id == made)

            try open(ui)
            try ui.key(InputSynthesizer.Key.digit(2), modifiers: [.shift, .option])
            try ui.key(InputSynthesizer.Key.digit(3), modifiers: [.control])
            let nested = try #require(try ui.layout.shownContent?.splitNode?.children.last?.splitNode, "the new pane was split")
            #expect(nested.direction == .vertical)
            #expect(nested.children.first?.id == made && nested.children.count == 2)
            #expect(ui.contentType(of: try #require(ui.activePane)) == "pal.beta")
            #expect(try ui.layout.leaves.count == 3)
        }

        /// C-5: it closes first, then makes the pane (so a pane that takes time leaves no palette).
        @Test func theOverlayIsGoneByTheTimeThePaneExists() throws {
            let origins = Origins()
            let ui = UIDriver(inProcess: two(origins), requiring: ["pal.alpha", "pal.beta"])
            let palette = try open(ui)
            var overlayWhenMade = true
            origins.onMake = { overlayWhenMade = palette.superview != nil }
            try ui.key(InputSynthesizer.Key.return)
            try ui.key(InputSynthesizer.Key.return)
            #expect(!overlayWhenMade)
        }

        /// C-6: the target is the pane active when the palette opened; C-1: Tab puts the new pane in a
        /// tab beside it.
        @Test func itAimsAtThePaneThatWasActiveWhenItOpened() throws {
            let ui = UIDriver(
                layout: Fixture.sideBySide(Fixture.leaf("a", "pal.alpha"), Fixture.leaf("b", "pal.alpha"), active: "a"), inProcess: two(),
                requiring: ["pal.alpha", "pal.beta"])
            let palette = try open(ui)
            #expect(palette.target == "a")
            ui.engine.perform(in: try ui.window.windowID) { layout, _ in layout.setActivePane("b") }
            // Focus follows the active pane out of the palette: choose directly.
            palette.choose(0)
            palette.choose(0)
            let made = try #require(ui.activePane)
            let root = LayoutNode.tabs(try ui.layout.root)
            guard case .tab(let group, _)? = Tree.findParent(root, "a") else {
                Issue.record("the new tab isn't beside a")
                return
            }
            #expect(group.tabs.contains { $0.content.leaves.contains { $0.id == made } })
        }

        /// D-4: the open palette is not part of the layout.
        @Test func theLayoutIsUntouchedByAPaletteThatCreatesNothing() throws {
            let ui = UIDriver(inProcess: two(), requiring: ["pal.alpha", "pal.beta"])
            let before = ui.engine.model
            try open(ui)
            try ui.key(InputSynthesizer.Key.escape)
            #expect(ui.engine.model == before)
        }

        // MARK: Sizes

        /// L-2, E-2, E-5: centered in the window, however it is sized.
        @Test func thePanelStaysCenteredWhenTheWindowIsResized() throws {
            let ui = UIDriver(inProcess: two(), requiring: ["pal.alpha", "pal.beta"])
            let palette = try open(ui)
            for size in [NSSize(width: 1200, height: 800), NSSize(width: 700, height: 500)] {
                try ui.window.window?.setContentSize(size)
                ui.layoutAll()
                let panel = palette.panelLayout
                #expect(panel.width == 320)
                #expect(abs(panel.midX - size.width / 2) < 0.01 && abs(panel.midY - size.height / 2) < 0.01)
            }
        }
    }
}
