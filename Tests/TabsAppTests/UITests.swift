import AppKit
import TabsPluginSDK
import Testing

@testable import Tabs
@testable import TabsCore

/// Core's own UI tests: the shell with stand-in panes (`StandIns`).
extension UITests {
    private func typedText(_ ui: UIDriver, _ pane: PaneID) -> String? {
        ui.config(of: pane)?["text"]?.stringValue
    }

    @Test func creatingATextPaneFromAnEmptyPaneFocusesIt() throws {
        let ui = UIDriver(standIns: true)
        let pane = try #require(ui.activePane)
        try ui.create("text")
        #expect(ui.contentType(of: pane) == "text", "filled in place")
        #expect(ui.focusedPane == pane, "and focused, so typing goes straight in")
        try ui.type("Shopping\nmilk")
        #expect(typedText(ui, pane) == "Shopping\nmilk")
        #expect(ui.engine.paneTitle(of: pane) == "Shopping", "the header is titled by the first line")
        #expect(try ui.window.window?.title == "Shopping")
        #expect(try ui.layout.tabTitles(ui.layout.root.id) == ["Tabs"], "a tab keeps the title it was made with")
    }

    @Test func pluginShortcutsRunThroughTheRealMenu() throws {
        let ui = UIDriver(standIns: true)
        let pane = try #require(ui.activePane)
        try ui.create("text")
        try ui.type("at ")
        #expect(try ui.press(KeyChord("d", [.command, .shift])), "⇧⌘D is Edit ▸ Insert Marker")
        let text = try #require(typedText(ui, pane))
        #expect(text == "at \(StandIns.marker)")
    }

    @Test func aCommandIsDisabledWhereItDoesNotApply() throws {
        let ui = UIDriver(
            layout: Fixture.saved(Fixture.tabsWindow("w", [Fixture.leaf("n", "text"), Fixture.leaf("c", "inert")], active: 1)))
        #expect(try !ui.menuItem("Edit", "Insert Marker").isEnabled, "the active pane is inert")
        try ui.press(KeyChord("d", [.command, .shift]))
        #expect(typedText(ui, "n") == "", "the shortcut did nothing")
        try ui.click(tab: "t-n")
        #expect(try ui.menuItem("Edit", "Insert Marker").isEnabled)
    }

    @Test func windowShortcutsOpenAndCloseTabs() throws {
        let ui = UIDriver()
        let first = try #require(ui.activePane)
        let root = try ui.layout.root.id
        try ui.press(KeyChord("t", [.command]))
        #expect(try ui.layout.tabIDs(root).count == 2, "⌘T: a new top-level tab")
        let second = try #require(ui.activePane)
        #expect(second != first, "the new tab is active")
        #expect(try ui.layout.tabTitles(root) == ["Tabs", "Tabs"], "an empty tab at the root is titled like the window's own")
        try ui.press(KeyChord("w", [.command]))
        // Down to one tab, the root group collapses and is wrapped again (under a new id).
        #expect(try ui.layout.root.tabs.map(\.content.id) == [first])
        #expect(ui.activePane == first)
    }

    @Test func clickingATabSwitchesAndFocusFollows() throws {
        let ui = UIDriver(
            layout: Fixture.saved(Fixture.tabsWindow("w", [Fixture.leaf("a", "text"), Fixture.leaf("b", "text")], active: 1)))
        try ui.click(tab: "t-a")
        #expect(ui.activePane == "a")
        #expect(ui.focusedPane == "a")
        try ui.type("typed into a")
        #expect(typedText(ui, "a") == "typed into a")
        #expect(typedText(ui, "b") == "")
    }

    @Test func closingABackgroundTabLeavesTheUserWhereTheyAre() throws {
        let ui = UIDriver(
            layout: Fixture.saved(
                Fixture.tabsWindow("w", [Fixture.leaf("a", "text"), Fixture.leaf("b", "inert"), Fixture.leaf("c", "inert")], active: 0)))
        try ui.click(tab: "t-a")
        try ui.close(tab: "t-c")
        #expect(try ui.layout.tabContents("root-w") == ["a", "b"])
        #expect(ui.activePane == "a")
        #expect(ui.focusedPane == "a")
    }

    @Test func onlyWhatAUserCouldReachCanBeClicked() throws {
        let ui = UIDriver(standIns: true)
        let background = try #require(ui.activePane)
        try ui.press(KeyChord("t", [.command]))
        // The first tab's empty pane — and its buttons — are behind the new tab.
        #expect(throws: InputSynthesizer.Failure.notHittable("create-text")) { try ui.create("text", in: background) }
        #expect(ui.contentType(of: background) == nil, "nothing happened")
        #expect(throws: InputSynthesizer.Failure.notFound("create-nothing")) { try ui.create("nothing") }
        let tab = try #require(try ui.layout.root.tabs.first { $0.content.id == background }?.id)
        try ui.click(tab: tab)
        try ui.create("inert", in: background)
        #expect(ui.contentType(of: background) == "inert")
    }

    @Test func menuTogglesShowTheirStateAndApplyIt() throws {
        let ui = UIDriver(standIns: true)
        let toggle = try ui.menuItem("View", "Wrap Lines")
        let before = toggle.state
        try ui.choose("View", "Wrap Lines")
        #expect(try ui.menuItem("View", "Wrap Lines").state != before)
        let stored = ui.runtime.settings.storedSettings(for: "text")?["wrapsLines"]
        #expect(stored == .bool(before == .off), "the plugin's setting changed and was persisted")
    }

    @Test func panesOfDifferentTypesShareAShortcutAndNoneFiresElsewhere() throws {
        let ran = Ref<[String]>([])
        func plugin(_ id: String, chord: KeyChord) -> PluginCandidate {
            TestSupport.candidate(TestSupport.manifest(id, contentTypes: [id])) { context in
                context.register(TestSupport.contentType(id))
                context.register(
                    CommandContribution(
                        id: CommandID("\(id).act"), title: "Act \(id)", menu: .view, defaultChord: chord, appliesTo: ContentTypeID(id)
                    ) { _ in ran.value.append(id) })
            }
        }
        let ui = UIDriver(
            layout: Fixture.saved(
                Fixture.tabsWindow("w", [Fixture.leaf("a", "alpha"), Fixture.leaf("b", "beta"), Fixture.leaf("e")], active: 0)),
            inProcess: [plugin("alpha", chord: KeyChord("k", [.command])), plugin("beta", chord: KeyChord("k", [.command]))])
        #expect(try ui.press(KeyChord("k", [.command])))
        try ui.click(tab: "t-b")
        #expect(try ui.press(KeyChord("k", [.command])))
        try ui.click(tab: "t-e")
        #expect(try !ui.press(KeyChord("k", [.command])), "in an empty pane the key goes to the pane")
        #expect(ran.value == ["alpha", "beta"])
    }

    @Test func aPaneTypesControlKeysNeverShadowAnotherPanesTyping() throws {
        let ran = Ref(0)
        let ui = UIDriver(
            layout: Fixture.saved(Fixture.tabsWindow("w", [Fixture.leaf("t", "term"), Fixture.leaf("n", "text")], active: 1)),
            inProcess: [
                TestSupport.candidate(TestSupport.manifest("term", contentTypes: ["term"])) { context in
                    context.register(TestSupport.contentType("term"))
                    context.register(
                        CommandContribution(
                            id: "term.search", title: "Search History", menu: .view, defaultChord: KeyChord("r", [.control]),
                            appliesTo: "term"
                        ) { _ in ran.value += 1 })
                },
                TestSupport.candidate(TestSupport.manifest("text", contentTypes: ["text"])) { context in
                    context.register(TestSupport.contentType("text"))
                },
            ])
        #expect(try !ui.press(KeyChord("r", [.control])), "⌃R reaches the text pane")
        try ui.click(tab: "t-t")
        #expect(try ui.press(KeyChord("r", [.control])))
        #expect(ran.value == 1)
    }

    @Test func scopedChordsAreDisarmedWhileAnotherWindowIsKey() throws {
        let ui = UIDriver(layout: Fixture.saved(Fixture.tabsWindow("w", [Fixture.leaf("n", "text")])))
        #expect(try ui.menuItem("Edit", "Insert Marker").keyEquivalent == "d")
        let settings = NSWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: true)
        ui.shell.armShortcuts(keyWindow: settings)
        #expect(try ui.menuItem("Edit", "Insert Marker").keyEquivalent == "", "typing in Settings keeps its keys")
        ui.shell.armShortcuts(keyWindow: try ui.window.window)
        #expect(try ui.menuItem("Edit", "Insert Marker").keyEquivalent == "d")
    }

    @Test func aRebindingTakesEffectAtOnce() throws {
        let ui = UIDriver(standIns: true)
        let pane = try #require(ui.activePane)
        try ui.create("text")
        try ui.runtime.shortcuts.bind("text.insertMarker", to: KeyChord("e", [.command, .shift]))
        #expect(try !ui.press(KeyChord("d", [.command, .shift])), "the old chord is gone")
        #expect(try ui.press(KeyChord("e", [.command, .shift])))
        #expect((typedText(ui, pane) ?? "").isEmpty == false)
        #expect(try ui.menuItem("Edit", "Insert Marker").keyEquivalent == "e")
    }

    @Test func aTabDraggedIntoAnotherWindowKeepsItsTextAndFocus() throws {
        let ui = UIDriver(
            layout: Fixture.saved(
                Fixture.tabsWindow(
                    "w", [Fixture.leaf("a", "text"), Fixture.leaf("b", "text")], active: 1,
                    frame: WindowFrame(x: 100, y: 100, width: 800, height: 600)),
                Fixture.window("v", Fixture.leaf("e"), frame: WindowFrame(x: 1000, y: 100, width: 800, height: 600))))
        let source = try ui.window("w")
        let destination = try ui.window("v")
        try ui.type("draft", in: source)
        #expect(typedText(ui, "b") == "draft")
        let view = try #require(ui.body("b").content)
        let tab = try ui.tabView("t-b", in: source)
        let target = try ui.body("e")
        let drop = try ui.point(NSPoint(x: target.bounds.midX, y: target.bounds.midY), of: target, from: tab)
        try ui.drag(from: NSPoint(x: tab.titleRect.minX + 4, y: tab.titleRect.midY), in: tab, [.move(to: drop, steps: 12), .release])
        let moved = try #require(ui.engine.model.window("v"))
        #expect(moved.leaves.map(\.id).contains("b"), "the tab landed in the other window")
        #expect(ui.engine.model.window("w")?.leaves.map(\.id) == ["a"])
        #expect(view.window === destination.window, "the same view, now in the other window")
        #expect(moved.activeLeafID == "b")
        #expect(ui.focusedPane(in: try #require(destination.window)) == "b", "and it has that window's keyboard")
        try ui.type(" and more", in: destination)
        #expect(typedText(ui, "b") == "draft and more", "same pane, same text view")
    }

    @Test func closeWithAnotherWindowKeyClosesThatWindowNotAPane() throws {
        final class Watcher: NSObject, NSWindowDelegate {
            var closed = false
            func windowWillClose(_ notification: Notification) { closed = true }
        }
        let ui = UIDriver(layout: Fixture.saved(Fixture.tabsWindow("w", [Fixture.leaf("c", "inert")])))
        let settings = NSWindow(contentRect: .zero, styleMask: [.titled, .closable], backing: .buffered, defer: true)
        settings.isReleasedWhenClosed = false
        let watcher = Watcher()
        settings.delegate = watcher
        ui.shell.router.close(keyWindow: settings)
        #expect(watcher.closed, "Settings (or Plugins) closes")
        #expect(try ui.layout.leaves.map(\.id) == ["c"], "and the pane behind it stays")
        ui.shell.router.close(keyWindow: try ui.window.window)
        #expect(ui.engine.model.windows.count == 1, "in a workspace window it closes the pane; the window stays")
        #expect(try ui.layout.leaves.map(\.type) == [nil], "with an empty pane in its place")
    }

    /// The palette lists what may be created now, in UI order, and a type chosen with Tab on an empty pane fills it.
    @Test func thePaletteOffersOnlyCreatableTypes() throws {
        let first = TestSupport.candidate(TestSupport.manifest("first", contentTypes: ["first"], sortOrder: 50)) { context in
            context.register(TestSupport.contentType("first"))
        }
        let ui = UIDriver(disabled: ["inert"], inProcess: [first] + StandIns.candidates())
        try ui.press(KeyChord("p", [.command]))
        #expect(ui.palette?.rows.map(\.label) == ["First", "Text"])
        try ui.key(InputSynthesizer.Key.escape)
        let empty = try #require(ui.activePane)
        try ui.createViaPalette("Text")
        let active = try #require(ui.activePane)
        #expect(ui.contentType(of: active) == "text")
        #expect(active != empty && ui.engine.model.leaf(empty) == nil, "an empty pane is filled, not tabbed beside")
        #expect(ui.focusedPane == active)
    }
}
