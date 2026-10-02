import AppKit
import Darwin
import SwiftUI
import TabsPluginSDK
import Testing

@testable import Tabs
@testable import TabsCore

/// Renders `view` as it would draw on screen (a page must draw something) and, with
/// TABS_SNAPSHOT_DIR set, keeps the picture there as `<name>.png`. SwiftUI builds its
/// accessibility tree only for an assistive client, so a form's texts can't be read
/// back in-process; they're checked through the data the view is built from.
@MainActor
func snapshot(_ view: NSView, _ name: String) throws {
    view.layoutSubtreeIfNeeded()
    RunLoop.main.run(until: Date().addingTimeInterval(0.3))
    view.layoutSubtreeIfNeeded()
    let image = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
    if let window = view.window {
        // A hosting view's backing store starts transparent: fill it the way the window would.
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: image)
        view.effectiveAppearance.performAsCurrentDrawingAppearance {
            window.backgroundColor.setFill()
            view.bounds.fill()
        }
        NSGraphicsContext.restoreGraphicsState()
    }
    view.cacheDisplay(in: view.bounds, to: image)
    #expect(image.pixelsHigh > 100, "\(name) has a body")
    if let directory = ProcessInfo.processInfo.environment["TABS_SNAPSHOT_DIR"] {
        try image.representation(using: .png, properties: [:])?.write(to: URL(filePath: directory).appending(path: "\(name).png"))
    }
}

extension UITests {
    // MARK: - Caffeinate: the menu item and the title-bar cup (docs/CAFFEINATE.md M-*, B-*)

    @MainActor
    @Suite struct Caffeinate {
        /// Waits for the process's exit to be announced. Async: the exit reaches the main actor as a
        /// task, which runs only while the test is suspended (a nested run loop inside the test's own
        /// main-queue job can't run it).
        private func eventually(_ ui: UIDriver, _ seconds: Double = 5, _ condition: () -> Bool) async -> Bool {
            let deadline = Date().addingTimeInterval(seconds)
            while true {
                ui.layoutAll()
                if condition() { return true }
                if Date() > deadline { return false }
                try? await Task.sleep(for: .milliseconds(20))
            }
        }

        private func fileMenu() throws -> NSMenu {
            let file = try #require(NSApp.mainMenu?.item(withTitle: "File")?.submenu)
            file.update()
            return file
        }

        private func bar(_ ui: UIDriver, _ controller: WorkspaceWindowController? = nil) throws -> TabBarView {
            let controller = try controller ?? ui.window
            let root = try #require(controller.layout.root.id as NodeID?)
            return try #require(ui.paneView(root, in: controller).tabBar)
        }

        @Test func theFileMenuEndsWithCaffeinate() throws {  // M-1
            let ui = UIDriver()
            let items = try fileMenu().items
            #expect(items.last?.title == "Caffeinate…")
            #expect(items.dropLast().last?.isSeparatorItem == true)
            #expect(items.dropLast(2).last?.title == "Close Pane")
            #expect(items.last?.isEnabled == true)
            #expect(items.last?.keyEquivalent == "", "no default chord")
            _ = ui
        }

        @Test func theItemReadsDecafWhileRunning() async throws {  // M-2, M-4
            let ui = UIDriver()
            defer { ui.runtime.caffeinate.killNow() }
            ui.runtime.caffeinate.start(CaffeinateFlags())
            #expect(try fileMenu().items.last?.title == "Decaf")
            #expect(try fileMenu().items.contains { $0.title == "Caffeinate…" } == false)
            let pid = try #require(ui.runtime.caffeinate.pid)
            try ui.choose("File", "Decaf")
            #expect(ui.shell.caffeinateDialog.controller == nil, "Decaf opens no dialog")
            #expect(await eventually(ui) { !ui.runtime.caffeinate.isRunning })
            #expect(kill(pid, 0) != 0)
            #expect(try fileMenu().items.last?.title == "Caffeinate…", "relabeled once the exit is noticed")
        }

        @Test func theMenuOpensTheDialogAndStartsNothing() throws {  // M-3
            let ui = UIDriver()
            try ui.choose("File", "Caffeinate…")
            let dialog = try #require(ui.shell.caffeinateDialog.controller)
            defer { dialog.cancel() }
            #expect(!ui.runtime.caffeinate.isRunning)
        }

        @Test func itIsARebindableCommandWithNoDefaultChord() async throws {  // M-5
            let ui = UIDriver()
            defer { ui.runtime.caffeinate.killNow() }
            #expect(ui.runtime.shortcuts.binding(for: "tabs.caffeinate")?.chord == nil)
            try ui.runtime.shortcuts.bind("tabs.caffeinate", to: KeyChord("j", [.command, .shift]))
            #expect(try ui.press(KeyChord("j", [.command, .shift])), "the chord the user gave it")
            let dialog = try #require(ui.shell.caffeinateDialog.controller, "not running: it opens the dialog")
            dialog.start()
            #expect(ui.runtime.caffeinate.isRunning)
            #expect(try ui.press(KeyChord("j", [.command, .shift])), "the same chord on Decaf")
            #expect(await eventually(ui) { !ui.runtime.caffeinate.isRunning }, "running: it stops the process")
        }

        @Test func theMenuWorksWithNoWorkspaceWindow() throws {  // M-6 (deviation: no window is reopened)
            let ui = UIDriver()
            let window = try ui.window.windowID
            ui.engine.windowDidClose(window)
            #expect(ui.renderer.windows.isEmpty)
            try ui.choose("File", "Caffeinate…")
            let dialog = try #require(ui.shell.caffeinateDialog.controller)
            defer { dialog.cancel() }
            #expect(ui.renderer.windows.isEmpty, "the dialog is a window of its own: none is reopened to host it")
        }

        @Test func theCupAppearsBeforeSettingsOnlyWhileRunning() async throws {  // B-1
            let ui = UIDriver()
            defer { ui.runtime.caffeinate.killNow() }
            #expect(try bar(ui).caffeinateButton.isHidden)
            ui.runtime.caffeinate.start(CaffeinateFlags())
            ui.layoutAll()
            let bar = try bar(ui)
            #expect(!bar.caffeinateButton.isHidden)
            let cup = bar.caffeinateButton.layoutFrame
            let settings = bar.settingsButton.layoutFrame
            #expect(cup.size == CGSize(width: 23, height: 23))
            #expect(cup.maxX + 14 == settings.minX, "its 6pt margin and the bar's 8pt gap, immediately before Settings")
            #expect(cup.midY == settings.midY)
            #expect(bar.controls.layoutFrame.maxX + Metrics.barGap <= cup.minX, "the group's controls move over for it")
            ui.runtime.caffeinate.stop()
            #expect(await eventually(ui) { bar.caffeinateButton.isHidden })
        }

        @Test func clickingTheCupStops() async throws {  // B-2
            let ui = UIDriver()
            defer { ui.runtime.caffeinate.killNow() }
            ui.runtime.caffeinate.start(CaffeinateFlags())
            ui.layoutAll()
            let active = ui.activePane
            try ui.click("caffeinate-decaf-button")
            #expect(await eventually(ui) { !ui.runtime.caffeinate.isRunning })
            #expect(try bar(ui).caffeinateButton.isHidden)
            #expect(ui.activePane == active, "a press on it activates nothing")  // B-6
            #expect(ui.shell.caffeinateDialog.controller == nil)
        }

        @Test func theCupIsNamedDecaf() throws {  // B-3
            let ui = UIDriver()
            let cup = try bar(ui).caffeinateButton
            #expect(cup.accessibilityIdentifier() == "caffeinate-decaf-button")
            #expect(cup.accessibilityLabel() == "Decaf")
            #expect(cup.label == "Decaf", "its tooltip")
            #expect(cup.accessibilityRole() == .button)
        }

        @Test func theCupIsOnlyOnTheDockedRootsBar() throws {  // B-4
            let group = TabGroup(
                id: "g",
                tabs: [
                    Tab(id: "t-x", title: "X", content: .leaf(LayoutLeaf(id: "x", type: nil))),
                    Tab(id: "t-y", title: "Y", content: .leaf(LayoutLeaf(id: "y", type: nil))),
                ])
            let split = LayoutNode.split(
                Split(id: "s", direction: .horizontal, children: [.leaf(LayoutLeaf(id: "a", type: nil)), .tabs(group)]))
            let root = TabGroup(id: "root", tabs: [Tab(id: "t-main", title: "Tabs", content: split)])
            let ui = UIDriver(layout: SavedLayout(windows: [WindowLayout(id: "w", root: .tabs(root), active: "a")]))
            defer { ui.runtime.caffeinate.killNow() }
            ui.runtime.caffeinate.start(CaffeinateFlags())
            ui.layoutAll()
            #expect(try !bar(ui).caffeinateButton.isHidden)
            let nested = try #require(ui.paneView("g").tabBar)
            #expect(nested.caffeinateButton.isHidden)
            #expect(nested.settingsButton.isHidden)
        }

        @Test func theCupShowsOnEveryWindowsRootBar() throws {  // P-17, B-5
            let ui = UIDriver()
            defer { ui.runtime.caffeinate.killNow() }
            ui.runtime.caffeinate.start(CaffeinateFlags())
            let second = ui.engine.openWindow()
            ui.layoutAll()
            #expect(ui.renderer.windows.count == 2)
            for controller in ui.renderer.windows { #expect(try !bar(ui, controller).caffeinateButton.isHidden, "\(controller.windowID)") }
            #expect(try !bar(ui, ui.window(second)).caffeinateButton.isHidden, "a window opened while it runs shows it at once")
        }

        @Test func pressingTheCupDoesNotDragTheWindow() throws {  // B-6
            let ui = UIDriver()
            let cup = try bar(ui).caffeinateButton
            #expect(!cup.mouseDownCanMoveWindow)
            #expect(cup.acceptsFirstMouse(for: nil))
        }
    }

    // MARK: - The Caffeinate dialog (docs/CAFFEINATE.md D-*)

    @MainActor
    @Suite struct CaffeinateDialog {
        private func button(_ identifier: String, in controller: CaffeinateWindowController) throws -> NSButton {
            let buttons = (controller.window?.contentView?.allSubviews ?? []).compactMap { $0 as? NSButton }
            return try #require(buttons.first { $0.accessibilityIdentifier() == identifier }, "no button \(identifier)")
        }

        /// A presenter over a real `Caffeinate`, which the test stops.
        private func presenter() -> (CaffeinateDialogPresenter, TabsCore.Caffeinate) {
            let caffeinate = TabsCore.Caffeinate()
            return (CaffeinateDialogPresenter(caffeinate: caffeinate, presentsWindows: false), caffeinate)
        }

        @Test func itIsTitledCaffeinate() throws {  // D-1, D-15
            let (presenter, _) = presenter()
            let controller = presenter.show()
            defer { controller.cancel() }
            let window = try #require(controller.window)
            #expect(window.title == "Caffeinate")
            #expect(!window.styleMask.contains(.resizable))
            #expect(window.styleMask.contains(.closable))
            #expect(window.parent == nil)
            #expect(window.contentLayoutRect.width == CaffeinateDialogView.width)
            #expect(window.contentLayoutRect.height > 200, "sized to its form")
        }

        @Test func itListsTheFiveAssertionsInOrderWithTheirHints() throws {  // D-2, D-4
            #expect(
                CaffeinateCopy.assertions.map(\.title) == [
                    "Prevent display sleep", "Prevent idle system sleep", "Prevent disk idle sleep", "Prevent system sleep",
                    "Declare the user active",
                ])
            #expect(
                CaffeinateCopy.assertions.map(\.hint) == [
                    nil, nil, nil, "Only applies on AC power.", "Wakes the display; lasts 5 seconds unless a timer is also set below.",
                ])
            #expect(
                CaffeinateCopy.assertions.map(\.flag) == [
                    \.preventDisplaySleep, \.preventIdleSleep, \.preventDiskSleep, \.preventSystemSleep, \.declareUserActive,
                ])
            #expect(CaffeinateCopy.timerTitle == "Stop after")
            #expect(CaffeinateCopy.timerHint == "Leave empty to run until Decaf.")
            #expect(CaffeinateCopy.timerUnit == "minutes")

            // …and the window draws them (TABS_SNAPSHOT_DIR keeps the picture, to look at).
            let (presenter, _) = presenter()
            let controller = presenter.show()
            defer { controller.cancel() }
            let view = try #require(controller.window?.contentView)
            try snapshot(view, "caffeinate-dialog")
        }

        @Test func theDefaultsKeepTheMacRunningButLetTheDisplaySleep() throws {  // D-3
            let model = CaffeinateDialogModel()
            #expect(model.flags == CaffeinateFlags(preventIdleSleep: true, preventSystemSleep: true))
            #expect(model.timerText == "")
        }

        @Test func startSendsTheToggledFlagsAndCloses() throws {  // D-5
            let (presenter, caffeinate) = presenter()
            defer { caffeinate.killNow() }
            let controller = presenter.show()
            controller.model.flags.preventDisplaySleep = true
            controller.model.flags.preventIdleSleep = false
            controller.model.timerText = "5"
            try button("caffeinate-start-button", in: controller).performClick(nil)
            #expect(presenter.controller == nil)
            #expect(controller.window?.isVisible != true)
            let pid = try #require(caffeinate.pid)
            let ps = Process()
            ps.executableURL = URL(fileURLWithPath: "/bin/ps")
            ps.arguments = ["-o", "args=", "-p", String(pid)]
            let pipe = Pipe()
            ps.standardOutput = pipe
            try ps.run()
            ps.waitUntilExit()
            let argv = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            #expect(argv.contains("-d -s -t 300 -w"), "display and system (idle unticked), 5 minutes: \(argv)")
        }

        @Test func anEmptyTimerRunsUntilDecaf() {  // D-6
            let model = CaffeinateDialogModel()
            #expect(model.flagsToStart.timerSeconds == nil)
            #expect(model.flagsToStart == CaffeinateFlags.dialogDefaults)
        }

        @Test func timerTextParsesAsElectronParsesIt() {  // D-7
            #expect(CaffeinateDialogModel.parseTimerMinutes("5") == 300)
            #expect(CaffeinateDialogModel.parseTimerMinutes("  12 ") == 720)
            #expect(CaffeinateDialogModel.parseTimerMinutes("1e1") == 600, "a JavaScript Number reads exponents")
            for none in ["", "   ", "0", "-3", "1.5", "abc", "5 min", "Infinity", "nan"] {
                #expect(CaffeinateDialogModel.parseTimerMinutes(none) == nil, "\(none)")
            }
        }

        @Test func cancelEscapeAndCloseStartNothing() throws {  // D-8
            let (presenter, caffeinate) = presenter()
            defer { caffeinate.killNow() }

            var controller = presenter.show()
            try button("caffeinate-cancel-button", in: controller).performClick(nil)
            #expect(presenter.controller == nil)

            controller = presenter.show()
            let window = try #require(controller.window)
            #expect(InputSynthesizer.press(KeyChord(.escape, []), in: window), "Escape is Cancel's key equivalent")
            #expect(presenter.controller == nil)

            controller = presenter.show()
            try #require(controller.window).performClose(nil)
            #expect(presenter.controller == nil)

            #expect(!caffeinate.isRunning)
        }

        @Test func askingAgainKeepsTheOpenDialogAndWhatWasTyped() throws {  // D-9
            let (presenter, _) = presenter()
            let first = presenter.show()
            defer { first.cancel() }
            first.model.timerText = "7"
            first.model.flags.preventDiskSleep = true
            let again = presenter.show()
            #expect(again === first)
            #expect(again.model.timerText == "7")
            #expect(again.model.flags.preventDiskSleep)
            #expect(NSApp.windows.filter { $0.title == "Caffeinate" && $0.delegate === first }.count == 1)
        }

        @Test func eachNewDialogStartsFromTheDefaults() throws {  // D-10
            let (presenter, _) = presenter()
            let first = presenter.show()
            first.model.timerText = "7"
            first.model.flags.declareUserActive = true
            first.cancel()
            let second = presenter.show()
            defer { second.cancel() }
            #expect(second !== first)
            #expect(second.model.flags == CaffeinateFlags.dialogDefaults)
            #expect(second.model.timerText == "")
        }

        @Test func returnPressesStart() throws {  // D-12
            let (presenter, caffeinate) = presenter()
            defer { caffeinate.killNow() }
            let controller = presenter.show()
            let window = try #require(controller.window)
            #expect(try button("caffeinate-start-button", in: controller).keyEquivalent == "\r", "the default button")
            #expect(InputSynthesizer.press(KeyChord(.return, []), in: window))
            #expect(caffeinate.isRunning)
            #expect(presenter.controller == nil)
        }
    }

    // MARK: - Settings ▸ Panes & Tabs ▸ Startup (docs/RESTORE-LAYOUT.md R-2)

    @MainActor
    @Suite struct RestoreLayoutSetting {
        @Test func theSwitchIsOnPanesAndTabsUnderStartup() throws {
            let runtime = TestSupport.runtime()
            let controller = makeSettingsWindow(
                pages: [], settings: runtime.settings, signals: [], shortcuts: runtime.shortcuts)
            defer { controller.close() }
            let tabs = try #require(controller.contentViewController as? NSTabViewController)
            #expect(tabs.tabViewItems.first?.label == "Panes & Tabs")
            let page = try #require(tabs.tabViewItems.first?.view)
            try snapshot(page, "settings-panes-and-tabs")

            // The switch writes the setting, both ways.
            let hosting = try #require(
                page.allSubviews.lazy.compactMap { $0 as? NSHostingView<PaneSettingsView> }.first ?? page
                    as? NSHostingView<PaneSettingsView>)
            let model = hosting.rootView.model
            #expect(model.binding(\.persistLayoutOnExit).wrappedValue)
            model.binding(\.persistLayoutOnExit).wrappedValue = false
            #expect(runtime.settings.panes.persistLayoutOnExit == false)
            model.binding(\.persistLayoutOnExit).wrappedValue = true
            #expect(runtime.settings.panes.persistLayoutOnExit)
        }
    }
}
