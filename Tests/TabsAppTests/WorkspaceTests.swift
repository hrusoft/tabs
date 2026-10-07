import AppKit
import TabsPluginSDK
import Testing

@testable import Tabs
@testable import TabsCore

/// The AppKit renderer: what core's layout looks like in windows. Layout
/// behavior itself is core's and tested unhosted (LayoutEngineTests).
@MainActor
@Suite struct RendererTests {
    let runtime = TestSupport.runtime()

    /// The engine drawn by the AppKit renderer, without an app shell: the
    /// main menu is app-wide and belongs to the (serialized) UI tests.
    struct Drawn {
        let engine: LayoutEngine
        let renderer: WorkspaceRenderer
    }

    private func shell(_ plugins: PluginCandidate..., restoring saved: SavedLayout? = nil) -> Drawn {
        runtime.startPlugins(from: nil, inProcess: plugins, requiredContentTypes: saved?.contentTypes ?? [])
        let engine = LayoutEngine(runtime: runtime)
        let renderer = WorkspaceRenderer(runtime: runtime, engine: engine, presentsWindows: false)
        engine.restore(saved)
        return Drawn(engine: engine, renderer: renderer)
    }

    @MainActor
    final class LazyPane: PaneController {
        var viewRequests = 0
        lazy var view: NSView = {
            viewRequests += 1
            return NSTextView()
        }()
        func currentConfig() -> JSONValue { ["built": .bool(viewRequests > 0)] }
        var closeWarning: String? { "unsaved" }
    }

    private func lazyPlugin(_ made: Ref<[PaneID: LazyPane]>) -> PluginCandidate {
        TestSupport.candidate(TestSupport.manifest("lazy", contentTypes: ["lazy"])) { context in
            context.register(
                ContentTypeContribution(id: "lazy", displayName: "Lazy", icon: .symbol("circle")) { pane in
                    let controller = LazyPane()
                    made.value[pane.paneID] = controller
                    return controller
                })
        }
    }

    @Test func backgroundTabsBuildTheirViewOnlyOnceShown() throws {
        let made = Ref<[PaneID: LazyPane]>([:])
        let shell = shell(
            lazyPlugin(made),
            restoring: Fixture.saved(Fixture.tabsWindow("w", [Fixture.leaf("a", "lazy"), Fixture.leaf("b", "lazy")], active: 1)))
        let a = try #require(made.value["a"])
        let b = try #require(made.value["b"])
        #expect(a.viewRequests == 0, "a restored background tab isn't built")
        #expect(b.viewRequests == 1)
        #expect(shell.engine.snapshot().windows.first?.leaves.first?.config == ["built": false], "yet it saves")
        #expect(shell.renderer.body(for: "a")?.live?.controller.closeWarning == "unsaved", "and can warn")
        shell.engine.focus("a")
        #expect(a.viewRequests == 1)
        #expect(shell.renderer.body(for: "a")?.isShown == true)
        #expect(shell.renderer.body(for: "b")?.isShown == false)
    }

    @Test func aPaneMovedToAnotherWindowKeepsItsView() throws {
        let made = Ref<[PaneID: LazyPane]>([:])
        let shell = shell(
            lazyPlugin(made),
            restoring: Fixture.saved(
                Fixture.tabsWindow("w", [Fixture.leaf("a", "lazy"), Fixture.leaf("b", "lazy")], active: 1),
                Fixture.window("v", Fixture.leaf("e"))))
        let view = try #require(made.value["b"]?.view)
        #expect(shell.engine.move(.pane("b"), from: "w", to: "v", at: .emptyPane("e")))
        let window = try #require(shell.renderer.windowController("v")?.window)
        #expect(view.window === window, "the same view, now in the other window")
        #expect(made.value["b"]?.viewRequests == 1, "never rebuilt")
        #expect(shell.engine.model.window("w")?.leaves.map(\.id) == ["a"])
        #expect(shell.renderer.body(for: "a")?.isShown == true, "the old window shows what's left")
    }

    /// The empty pane's toolbar offers one button per type: a plugin's own
    /// image icon and creation label, or a symbol and "New <display name>".
    @Test func theEmptyPaneToolbarShowsEachTypesIconAndLabel() throws {
        let mark = NSImage(size: NSSize(width: 16, height: 16), flipped: true) { _ in
            NSColor.black.setFill()
            CGRect(x: 4, y: 4, width: 8, height: 8).fill()
            return true
        }
        mark.isTemplate = true
        let drawn = shell(
            TestSupport.candidate(TestSupport.manifest("drawn", contentTypes: ["drawn"])) { context in
                context.register(
                    ContentTypeContribution(id: "drawn", displayName: "Drawn", icon: .image(mark), creationLabel: "New drawn thing") {
                        _ in StubPane(config: .emptyObject)
                    })
            },
            TestSupport.candidate(TestSupport.manifest("plain", contentTypes: ["plain"])) { context in
                context.register(
                    ContentTypeContribution(id: "plain", displayName: "Plain", icon: .symbol("square")) { _ in
                        StubPane(config: .emptyObject)
                    })
            },
            restoring: Fixture.saved(Fixture.window("w", Fixture.leaf("e"))))
        let empty = try #require(drawn.renderer.body(for: "e")?.content as? EmptyPaneView)
        #expect(empty.actions.map(\.label) == ["New drawn thing", "New Plain"])
        guard case .image = empty.actions[0].icon, case .symbol("square") = empty.actions[1].icon else {
            Issue.record("the image stays an image, the symbol a symbol")
            return
        }
        empty.layoutFrame = CGRect(x: 0, y: 0, width: 240, height: 120)
        empty.frame = empty.layoutFrame
        empty.layoutSubtreeIfNeeded()
        let bitmap = try #require(NSBitmapImageRep(data: try VisualCapture.render(empty)))
        let scale = CGFloat(bitmap.pixelsWide) / 240
        let button = try #require(empty.buttonRects.first)
        let corner = try #require(bitmap.colorAt(x: Int((button.minX + 3) * scale), y: Int((button.minY + 3) * scale)))
        let center = try #require(bitmap.colorAt(x: Int(button.midX * scale), y: Int(button.midY * scale)))
        #expect(corner != center, "the template image is painted in the button's icon color")
    }

    @Test func aTitleSetWhileBuildingThePaneIsKept() throws {
        let shell = shell(
            TestSupport.candidate(TestSupport.manifest("t", contentTypes: ["t"])) { context in
                context.register(
                    ContentTypeContribution(id: "t", displayName: "Display Name", icon: .symbol("square")) { pane in
                        pane.setTitle("Chosen by the plugin")
                        return StubPane(config: pane.initialConfig)
                    })
            })
        let id = try #require(runtime.panes.openPane(ofType: "t", config: nil))
        #expect(shell.engine.paneTitle(of: id) == "Chosen by the plugin")
        #expect(shell.renderer.frontmostController?.window?.title == "Chosen by the plugin")
    }

    @Test func aTitleSetWhileBuildingTheViewShows() throws {
        let drawn = shell(
            TestSupport.candidate(TestSupport.manifest("titled", contentTypes: ["titled"])) { context in
                context.register(
                    ContentTypeContribution(id: "titled", displayName: "Display Name", icon: .symbol("square")) { pane in
                        final class Titled: PaneController {
                            let pane: any PaneContext
                            init(pane: any PaneContext) { self.pane = pane }
                            lazy var view: NSView = {
                                pane.setTitle("Set by the view")
                                return NSView()
                            }()
                            func currentConfig() -> JSONValue { [:] }
                        }
                        return Titled(pane: pane)
                    })
            })
        let id = try #require(runtime.panes.openPane(ofType: "titled", config: nil))
        #expect(drawn.engine.paneTitle(of: id) == "Set by the view")
        #expect(drawn.renderer.frontmostController?.window?.title == "Set by the view")
    }

    @Test func theLastWindowReopenedFromACloseHandlerGetsAWindowOfItsOwn() throws {
        final class Once { var armed = true }
        let once = Once()
        let drawn = shell(
            TestSupport.candidate(TestSupport.manifest("stub", contentTypes: ["stub"])) { context in
                context.register(TestSupport.contentType("stub"))
                let workspace = context.workspace
                context.events.subscribe(.paneClosed) { _ in
                    guard once.armed else { return }
                    once.armed = false
                    workspace.openPane(ofType: "stub")
                }
            }, restoring: Fixture.saved(Fixture.tabsWindow("w", [Fixture.leaf("a", "stub")])))
        let closing = try #require(drawn.renderer.windowController("w")?.window)
        closing.close()  // as the user would: the engine hears it
        #expect(drawn.engine.model.windows.map(\.id) == ["w"], "a plugin brought the window back")
        let reopened = try #require(drawn.renderer.windowController("w"))
        #expect(reopened.window !== closing, "in a window of its own, not the one that was closing")
        #expect(reopened.layout.leaves.count == 2)
    }

    @Test func whileNoWindowIsVisibleTheLastKeyOneIsFrontmost() throws {
        let drawn = shell(restoring: Fixture.saved(Fixture.window("first", Fixture.leaf("a")), Fixture.window("second", Fixture.leaf("b"))))
        #expect(drawn.engine.frontmostWindowID == "second", "nothing known: the newest")
        let first = try #require(drawn.renderer.windowController("first"))
        first.windowDidBecomeKey(Notification(name: NSWindow.didBecomeKeyNotification, object: first.window))
        #expect(drawn.engine.frontmostWindowID == "first", "the app hidden: where the user was")
    }

    @Test func windowsOpenWhereTheyWereAndReportWhereTheyGo() throws {
        let frame = WindowFrame(x: 140, y: 160, width: 720, height: 480)
        let drawn = shell(restoring: Fixture.saved(Fixture.window("w", Fixture.leaf("a"), frame: frame)))
        let window = try #require(drawn.renderer.windowController("w")?.window)
        #expect(window.frame == NSRect(x: 140, y: 160, width: 720, height: 480))
        window.setFrame(NSRect(x: 60, y: 80, width: 640, height: 400), display: false)
        #expect(drawn.engine.model.window("w")?.frame == WindowFrame(x: 60, y: 80, width: 640, height: 400))
    }

    @Test func aNewWindowCascadesOffTheLastOne() throws {
        let frame = WindowFrame(x: 200, y: 300, width: 1200, height: 800)
        let drawn = shell(restoring: Fixture.saved(Fixture.window("w", Fixture.leaf("a"), frame: frame)))
        let second = drawn.engine.openWindow()
        let cascaded = try #require(drawn.renderer.windowController(second)?.window?.frame)
        let first = try #require(drawn.renderer.windowController("w")?.window?.frame)
        let area = NSScreen.main?.visibleFrame ?? cascaded
        #expect(cascaded.size == CGSize(width: 1200, height: 800))
        #expect(cascaded.minX == first.minX + 24 || cascaded.minX == area.minX, "24pt right, or back at the edge")
        #expect(cascaded.maxY == first.maxY - 24 || cascaded.maxY == area.maxY, "24pt down, or back at the top")
    }

    @Test func windowsTheModelDropsClose() throws {
        let shell = shell(restoring: nil)
        let second = shell.engine.openWindow()
        #expect(shell.renderer.windows.count == 2)
        let closing = try #require(shell.renderer.windowController(second)?.window)
        shell.engine.tearDown()
        #expect(shell.renderer.windows.isEmpty)
        #expect(shell.renderer.windowController(second) == nil)
        #expect(!closing.isVisible)
    }

    @Test func closingThePaneInAWindowLeavesAnEmptyOneAndTheWindow() throws {
        let shell = shell(restoring: nil)
        let second = shell.engine.openWindow()
        let pane = try #require(shell.engine.model.window(second)?.leaves.first?.id)
        shell.engine.close(pane)
        #expect(shell.renderer.windows.count == 2, "a window's last pane closing leaves the window")
        #expect(shell.engine.model.window(second)?.leaves.map(\.type) == [nil])
    }

    // MARK: A pane's questions with no window shown (the cards themselves: `UITests.Dialogs`)

    /// A text pane "n" beside another, its context the one a plugin asks through.
    private func askingPane() throws -> (Drawn, PaneContextImpl) {
        let plugins = StandIns.candidates()
        let shell = shell(
            plugins[0], plugins[1], restoring: Fixture.sideBySide(Fixture.leaf("n", "text"), Fixture.leaf("b", "text"), active: "n"))
        return (shell, try #require(runtime.panes.pane("n")?.context))
    }

    /// Tests and the hidden e2e app: a question answers itself with its default button, a picker
    /// is cancelled.
    @Test func withNoWindowShownAQuestionAnswersItselfWithItsDefault() async throws {
        let (shell, pane) = try askingPane()
        #expect(await pane.confirm(PaneConfirm(title: "T", message: "M")))
        #expect(await pane.choose(PaneChoose(title: "T", message: "M", options: ["a", "b"])) == 0)
        await pane.alert(PaneAlert(title: "T", message: "M"))
        #expect(shell.renderer.dialogCards.isEmpty, "no card was ever shown")
        #expect(await pane.chooseDirectory(title: "Pick") == nil, "a picker is cancelled with no window to sheet on")
    }

    @Test func theTestsPickerAnswerReachesThePane() async throws {
        let (shell, pane) = try askingPane()
        let start = URL(filePath: "/tmp/start", directoryHint: .isDirectory)
        let asked = Ref<[PanePicker]>([])
        shell.renderer.pickerOverride = {
            asked.value.append($0)
            return URL(filePath: "/tmp/chosen")
        }
        #expect(await pane.chooseFile(title: "Pick a file", startingAt: start) == URL(filePath: "/tmp/chosen"))
        #expect(asked.value == [PanePicker(kind: .file, title: "Pick a file", startingAt: start)])
    }
}

@MainActor
@Suite struct MenuTests {
    @Test func pluginCommandsLandInTheirMenusWithShortcutsArmedByType() throws {
        let runtime = TestSupport.runtime()
        runtime.startPlugins(
            from: nil,
            inProcess: [
                TestSupport.candidate(TestSupport.manifest("m", contentTypes: ["m"])) { context in
                    context.register(TestSupport.contentType("m"))
                    context.register(
                        CommandContribution(
                            id: "m.act", title: "Act", menu: .edit, defaultChord: KeyChord("j", [.command, .option]), appliesTo: "m"
                        ) { _ in })
                }
            ])
        let router = CommandRouter(runtime: runtime)
        let menu = MainMenu.build(runtime: runtime, router: router)
        let edit = try #require(menu.item(withTitle: "Edit")?.submenu)
        let item = try #require(edit.item(withTitle: "Act"))
        #expect(item.keyEquivalent == "", "armed only while an m pane is active")
        MainMenu.arm(menu, for: "m", runtime: runtime)
        #expect(item.keyEquivalent == "j")
        #expect(item.keyEquivalentModifierMask == [.command, .option])
        #expect(!router.validateMenuItem(item), "no windows, so no active pane of type m")
        #expect(menu.item(withTitle: "View") == nil, "empty plugin menus are dropped")

        let engine = LayoutEngine(runtime: runtime)
        let withWindows = CommandRouter(runtime: runtime, engine: engine)
        engine.restore(nil)
        runtime.panes.openPane(ofType: "m", config: nil)
        #expect(withWindows.validateMenuItem(item))
    }

    /// The File menu as `MainMenu.build` makes it, each item's chord from core's table.
    private func fileMenu(_ runtime: CoreRuntime) throws -> (items: [NSMenuItem], router: CommandRouter) {
        let engine = LayoutEngine(runtime: runtime)
        let router = CommandRouter(runtime: runtime, engine: engine)
        engine.restore(nil)
        let file = try #require(MainMenu.build(runtime: runtime, router: router).item(withTitle: "File")?.submenu)
        return (file.items, router)
    }

    /// NEW-CONTENT.md F-1, F-2: File lists core's creation commands with their chords, and no New Tab With
    /// ▸ <type> however many types there are; CAFFEINATE.md M-1: it ends with Caffeinate…, enabled, with no
    /// default chord.
    @Test func theFileMenuListsItsCommandsAndHasNoNewTabWith() throws {
        let runtime = TestSupport.runtime()
        runtime.startPlugins(from: nil, inProcess: StandIns.candidates())
        let (items, router) = try fileMenu(runtime)
        let entries = items.map {
            $0.isSeparatorItem
                ? "-"
                : "\($0.title) [\($0.keyEquivalentModifierMask.contains(.command) ? "⌘" : "")\($0.keyEquivalentModifierMask.contains(.option) ? "⌥" : "")\($0.keyEquivalentModifierMask.contains(.shift) ? "⇧" : "")\($0.keyEquivalent)]"
        }
        #expect(
            entries == [
                "New Window [⌘n]", "-", "New Content… [⌘p]", "-", "New Tab [⌘t]", "New Horizontal Split [⌘⇧t]",
                "New Vertical Split [⌘⌥t]", "New Unpinned Pane [⌘⌥⇧t]", "Close Pane [⌘w]", "-", "Caffeinate… []",
            ])
        let caffeinate = try #require(items.last)
        #expect(router.validateMenuItem(caffeinate))
    }

    /// NEW-CONTENT.md P-8: New Content… takes the chord the user gives it; unbound, the item stays, enabled,
    /// with no key equivalent.
    @Test func newContentFollowsItsChordAndStaysWhenUnbound() throws {
        let runtime = TestSupport.runtime()
        runtime.startPlugins(from: nil, inProcess: [])
        func newContent() throws -> (item: NSMenuItem, router: CommandRouter) {
            let (items, router) = try fileMenu(runtime)
            return (try #require(items.first { $0.title == "New Content…" }), router)
        }
        try runtime.shortcuts.bind("tabs.commandPalette", to: KeyChord("j", [.command]))
        let rebound = try newContent().item
        #expect(rebound.keyEquivalent == "j" && rebound.keyEquivalentModifierMask == [.command])
        try runtime.shortcuts.bind("tabs.commandPalette", to: nil)
        let (bare, router) = try newContent()
        #expect(bare.keyEquivalent == "")
        #expect(router.validateMenuItem(bare), "still in the menu, and it works")
    }

    @Test func theCreationGateOffersOnlyCreatableTypes() throws {
        let runtime = TestSupport.runtime()
        runtime.settings.setDisabled(true, for: "stub")
        runtime.startPlugins(
            from: nil,
            inProcess: [
                TestSupport.candidate(TestSupport.manifest("stub", contentTypes: ["stub"])) { $0.register(TestSupport.contentType("stub")) }
            ],
            requiredContentTypes: ["stub"])
        #expect(runtime.panes.creatableTypes().isEmpty, "stub runs for an open pane but is disabled for creation")
        runtime.host.setUserEnabled(true, for: "stub")
        #expect(runtime.panes.creatableTypes().map(\.value.displayName) == ["Stub"])
    }

    @Test func disabledPluginsLoseTheirSettingsPagesButKeepRunning() {
        let runtime = TestSupport.runtime()
        runtime.settings.setDisabled(true, for: "s")
        runtime.startPlugins(
            from: nil,
            inProcess: [
                TestSupport.candidate(TestSupport.manifest("s", contentTypes: ["s"])) { context in
                    context.register(TestSupport.contentType("s"))
                    context.register(SettingsPageContribution(id: "s", title: "S", symbolName: "gear") { NSView() })
                }
            ], requiredContentTypes: ["s"])
        #expect(TestSupport.state(runtime, "s") == .active)
        #expect(runtime.settingsPages().isEmpty)
        runtime.host.setUserEnabled(true, for: "s")
        #expect(runtime.settingsPages().map(\.value.id) == ["s"])
    }
}
