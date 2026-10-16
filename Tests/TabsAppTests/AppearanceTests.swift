import AppKit
import SwiftUI
import TabsPluginSDK
import Testing

@testable import Tabs
@testable import TabsCore

extension UITests {
    /// The Theme setting (dark, light, system) reaches every window and dialog the app puts up,
    /// not only the workspace chrome: Settings, Plugins, alerts, file panels, menus.
    @MainActor
    @Suite struct Appearance {
        /// What `view` draws with.
        private func isDark(_ view: NSView?) throws -> Bool {
            let view = try #require(view)
            return try #require(view.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua])) == .darkAqua
        }

        private func panes(_ theme: String) -> SettingsStore.PaneSettings {
            var panes = SettingsStore.PaneSettings()
            panes.colorTheme = theme
            return panes
        }

        /// The OS's own look, as far as this process can tell: nothing forced.
        private func pretendTheOSIs(_ name: NSAppearance.Name?) {
            NSApp.appearance = name.flatMap(NSAppearance.init(named:))
        }

        @Test(arguments: [("dark", NSAppearance.Name.aqua), ("light", .darkAqua)])
        func everyWindowFollowsTheSettingNotTheOS(theme: String, os: NSAppearance.Name) throws {
            pretendTheOSIs(os)
            defer { pretendTheOSIs(nil) }
            let ui = UIDriver(panes: panes(theme))
            let wantsDark = theme == "dark"
            let settings = makeSettingsWindow(for: ui.runtime)
            let plugins = makePluginsWindow(
                model: PluginsModel(host: ui.runtime.host, fingerprint: ui.runtime.sharedFingerprint), themes: ui.runtime.themes)
            defer {
                settings.close()
                plugins.close()
            }

            #expect(try isDark(ui.window.window?.contentView) == wantsDark, "the workspace")
            #expect(try isDark(settings.window?.contentView) == wantsDark, "Settings")
            #expect(try isDark(plugins.window?.contentView) == wantsDark, "Plugins")
            let alert = ui.renderer.closeConfirmation(["A terminal is running."], quitting: true)
            #expect(try isDark(alert.window.contentView) == wantsDark, "the close confirmation")
            #expect(try isDark(NSOpenPanel().contentView) == wantsDark, "a file picker")
        }

        @Test func systemFollowsTheOSAndALaterChoiceTakesOverWithoutReopeningAnything() throws {
            let ui = UIDriver(panes: panes("light"))
            let settings = makeSettingsWindow(for: ui.runtime)
            defer { settings.close() }
            #expect(try isDark(settings.window?.contentView) == false)

            ui.runtime.settings.setPanes(panes("dark"))
            #expect(try isDark(settings.window?.contentView), "an open Settings window follows the switch")
            #expect(try isDark(ui.window.window?.contentView))

            ui.runtime.settings.setPanes(panes("system"))
            #expect(NSApp.appearance == nil, "system is nothing forced: the OS decides")
            #expect(try isDark(settings.window?.contentView) == isDark(ui.window.window?.contentView))
        }

        @Test func aShellHandsTheAppearanceBackToTheOSWhenItStops() throws {
            do {
                let ui = UIDriver(panes: panes("dark"))
                #expect(ui.renderer.baseAppearance.theme.isDark)
                #expect(NSApp.appearance != nil)
            }
            #expect(NSApp.appearance == nil, "a later shell starts from the OS")
        }
    }

    /// With `TABS_SNAPSHOT_DIR` set (pass it to xcodebuild as `TEST_RUNNER_TABS_SNAPSHOT_DIR`), every
    /// surface the theme setting must reach, in every theme the app ships, under an OS appearance
    /// that disagrees with the theme: for eyes, not a gate (docs/THEMES.md).
    @MainActor
    @Suite struct AppearanceSnapshots {
        @Test func everySurfaceInEveryTheme() throws {
            guard let directory = ProcessInfo.processInfo.environment["TABS_SNAPSHOT_DIR"] else { return }
            defer { NSApp.appearance = nil }
            for entry in ThemeCatalog(directory: ThemeCatalog.bundledDirectory()).entries {
                let os: NSAppearance.Name = entry.theme.isDark ? .aqua : .darkAqua
                NSApp.appearance = NSAppearance(named: os)
                try render(entry.id, os: os, into: directory)
            }
        }

        private func render(_ theme: String, os: NSAppearance.Name, into directory: String) throws {
            var panes = SettingsStore.PaneSettings()
            panes.colorTheme = theme
            let ui = UIDriver(panes: panes)
            let osName = os == .aqua ? "light" : "dark"
            func write(_ surface: String, _ window: NSWindow) throws {
                let image = try #require(Self.render(window))
                let name = "theme-\(theme)-os-\(osName)-\(surface).png"
                try image.representation(using: .png, properties: [:])?.write(to: URL(filePath: directory).appending(path: name))
            }

            try write("workspace", #require(ui.window.window))

            let settings = makeSettingsWindow(for: ui.runtime)
            let plugins = makePluginsWindow(
                model: PluginsModel(host: ui.runtime.host, fingerprint: ui.runtime.sharedFingerprint), themes: ui.runtime.themes)
            let about = AboutWindowController(themes: ui.runtime.themes)
            let caffeinate = ui.shell.caffeinateDialog.show()
            defer {
                settings.close()
                plugins.close()
                about.close()
                caffeinate.cancel()
            }
            let tabs = try #require(settings.contentViewController as? NSTabViewController)
            let window = try #require(settings.window)
            for (index, item) in tabs.tabViewItems.enumerated() {
                tabs.selectedTabViewItemIndex = index
                if let size = item.viewController?.preferredContentSize { window.setContentSize(size) }
                try write("settings-\(item.label.lowercased().filter(\.isLetter))", window)
            }
            try write("plugins", #require(plugins.window))
            try write("about", #require(about.window))
            try write("caffeinate", #require(caffeinate.window))

            let alert = ui.renderer.closeConfirmation(["A terminal is still running."], quitting: false)
            alert.layout()
            try write("close-alert", alert.window)
        }

        /// The window with its title bar and toolbar, as the window server would composite it.
        @MainActor private static func render(_ window: NSWindow) -> NSBitmapImageRep? {
            guard let frame = window.contentView?.superview else { return nil }
            // Shown invisibly so the title bar and the controls draw as they do in a live window.
            window.alphaValue = 0
            window.orderFront(nil)
            defer { window.orderOut(nil) }
            frame.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.15))
            guard let rep = frame.bitmapImageRepForCachingDisplay(in: frame.bounds) else { return nil }
            // What the window draws on before its views do (`cacheDisplay` leaves it transparent).
            frame.effectiveAppearance.performAsCurrentDrawingAppearance {
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
                (window.backgroundColor ?? .windowBackgroundColor).setFill()
                frame.bounds.fill()
                NSGraphicsContext.restoreGraphicsState()
            }
            frame.cacheDisplay(in: frame.bounds, to: rep)
            return rep
        }
    }
}

// MARK: - Settings ▸ Panes & Tabs ▸ Appearance ▸ Theme (docs/THEMES.md)

extension UITests {
    /// The Theme menu lists System, then every theme file the app ships — Light and Dark first, the
    /// rest by name — each storing its file's id, so a saved choice stays selected. SwiftUI draws
    /// the menu itself (no AppKit pop-up button, no accessibility tree in-process): its choices are
    /// read from the list it's built from.
    @MainActor
    @Suite struct ThemeSetting {
        /// TH-3, TH-4: a broken file in the app would leave the menu without saying so; here it fails.
        @Test func everyThemeTheAppShipsLoadsAndSystemsPairIsAmongThem() {
            let catalog = ThemeCatalog(directory: ThemeCatalog.bundledDirectory())
            #expect(catalog.problems.isEmpty, "\(catalog.problems)")
            #expect(catalog.entries.prefix(2).map(\.id) == [ThemeCatalog.light, ThemeCatalog.dark])
        }

        /// TH-5, TH-6.
        @Test func thePickerListsSystemThenTheThemesAndKeepsTheStoredChoice() throws {
            let runtime = TestSupport.runtime()
            var panes = SettingsStore.PaneSettings()
            panes.colorTheme = "light"
            runtime.settings.setPanes(panes)
            let controller = makeSettingsWindow(
                pages: [], settings: runtime.settings, signals: [], shortcuts: runtime.shortcuts, themes: runtime.themes)
            defer { controller.close() }
            let tabs = try #require(controller.contentViewController as? NSTabViewController)
            #expect(tabs.tabViewItems.first?.label == "Panes & Tabs")
            let page = try #require(tabs.tabViewItems.first?.view)
            try snapshot(page, "settings-theme-light")
            let hosting = try #require(
                page.allSubviews.lazy.compactMap { $0 as? NSHostingView<ThemedRoot<PaneSettingsView>> }.first ?? page
                    as? NSHostingView<ThemedRoot<PaneSettingsView>>)
            let model = hosting.rootView.content.model
            let entries = runtime.themes.catalog.entries

            #expect(model.themes.map(\.title) == ["System"] + entries.map(\.name))
            #expect(model.themes.map(\.value) == [ThemeCatalog.system] + entries.map(\.id), "each stores its file's id")
            #expect(model.themes.prefix(3).map(\.title) == ["System", "Light", "Dark"])
            #expect(model.theme.wrappedValue == "light", "the saved choice is the one selected")

            // Choosing each stores exactly its value.
            for theme in model.themes {
                model.theme.wrappedValue = theme.value
                #expect(runtime.settings.panes.colorTheme == theme.value, "\(theme.title)")
            }

            // A stored theme no file defines: Dark is selected (what is drawn), and what is stored stays.
            panes.colorTheme = "gone"
            runtime.settings.setPanes(panes)
            #expect(model.theme.wrappedValue == ThemeCatalog.dark)
            #expect(runtime.settings.panes.colorTheme == "gone")
        }
    }
}

// MARK: - A theme reaches every surface (docs/THEMES.md)

extension UITests {
    /// A theme's tokens reach everything the app paints itself, and a change follows at once: the
    /// workspace, a pane, Settings (core's page and a plugin's), About, Plugins and Caffeinate. Two
    /// made-up themes whose backgrounds no shipped theme has; what a window shows is read from a
    /// rendering over magenta, so a part nothing painted shows as such.
    @MainActor
    @Suite struct ThemeReach {
        /// Two theme files: `first` (dark) and `second` (light).
        private static func themes() -> URL {
            let directory = TestSupport.temporaryDirectory().appending(path: "themes", directoryHint: .isDirectory)
            func write(_ id: String, _ name: String, appearance: String, bg: String, text: String) {
                TestSupport.writeJSON(
                    [
                        "name": .string(name), "appearance": .string(appearance), "bg": .string(bg), "bgElevated": "#5a3d2b",
                        "border": "#806040", "text": .string(text), "textDim": "#a08060", "accent": "#20b0c0", "onAccent": "#000000",
                        "bellAlert": "#e02020", "agent": "#9050e0",
                    ], to: directory.appending(path: "\(id).json"))
            }
            write("first", "First", appearance: "dark", bg: "#2a6e3f", text: "#f0e0a0")
            write("second", "Second", appearance: "light", bg: "#e8c8f0", text: "#301040")
            return directory
        }

        @Test func aThemesTokensReachEveryWindowAndFollowAChange() throws {  // TH-7, TH-8, TH-9, ABOUT.md A-7
            let told = Ref<[PaneTheme]>([])
            final class Watcher: PaneController {
                let view = NSView()
                let told: Ref<[PaneTheme]>
                init(told: Ref<[PaneTheme]>) { self.told = told }
                func currentConfig() -> JSONValue { .emptyObject }
                func paneAppearanceDidChange(theme: PaneTheme, depth: Int) { told.value.append(theme) }
            }
            let plugin = TestSupport.candidate(TestSupport.manifest("watch", contentTypes: ["watch"])) { context in
                context.register(
                    ContentTypeContribution(id: "watch", displayName: "Watch", icon: .symbol("eye")) { _ in Watcher(told: told) })
                // A plugin's page, made by the SDK out of core's reach.
                context.register(
                    SettingsPageContribution(id: "watch", title: "Watch", symbolName: "eye") {
                        Form { Section { Toggle("A switch", isOn: .constant(true)) } }
                    })
            }
            var panes = SettingsStore.PaneSettings()
            panes.colorTheme = "first"
            let ui = UIDriver(
                layout: Fixture.saved(Fixture.window("w", Fixture.leaf("a", "watch"))), inProcess: [plugin], panes: panes,
                themes: Self.themes())
            let catalog = ui.runtime.themes.catalog
            let workspace = try #require(ui.window.window)
            // A text field in the workspace, as a tab's title or a plugin's toolbar has.
            let field = NSTextField(string: "Some text")
            workspace.contentView?.addSubview(field)
            let settings = makeSettingsWindow(for: ui.runtime)
            let plugins = makePluginsWindow(
                model: PluginsModel(host: ui.runtime.host, fingerprint: ui.runtime.sharedFingerprint), themes: ui.runtime.themes)
            let about = AboutWindowController(themes: ui.runtime.themes)
            let caffeinate = ui.shell.caffeinateDialog.show()
            defer {
                settings.close()
                plugins.close()
                about.close()
                caffeinate.cancel()
            }
            let tabs = try #require(settings.contentViewController as? NSTabViewController)
            let settingsWindow = try #require(settings.window)

            for id in ["first", "second"] {
                let theme = try #require(catalog.entry(id)?.theme)
                panes.colorTheme = id
                ui.runtime.settings.setPanes(panes)
                runLoopTurns()
                #expect(ui.runtime.themes.current == theme)
                #expect(workspace.backgroundColor == theme.bg, "\(id): the workspace")
                #expect(told.value.last == theme, "\(id): the pane is told")
                workspace.makeFirstResponder(nil)
                #expect(workspace.makeFirstResponder(field))
                let editor = try #require(field.currentEditor() as? NSTextView)
                #expect(editor.insertionPointColor == theme.text, "\(id): the caret")
                #expect(editor.selectedTextAttributes[.backgroundColor] as? NSColor == theme.accent, "\(id): the selection")
                #expect(NSApp.appearance?.name == (theme.isDark ? .darkAqua : .aqua), "\(id): what macOS draws")
                for window in [settingsWindow, plugins.window, about.window, caffeinate.window] {
                    #expect(window?.backgroundColor == theme.bg, "\(id): \(window?.title ?? "?")'s background")
                    #expect(window?.titlebarAppearsTransparent == true, "\(id): \(window?.title ?? "?")'s title bar is its background")
                }
                let bg = try Self.reference(theme.bg)
                for (name, view) in [
                    ("Settings ▸ Panes & Tabs", try Self.page("Panes & Tabs", of: tabs, in: settingsWindow)),
                    ("a plugin's Settings page", try Self.page("Watch", of: tabs, in: settingsWindow)),
                    ("Plugins", try #require(plugins.window?.contentView)), ("Caffeinate", try #require(caffeinate.window?.contentView)),
                ] {
                    let corner = try Self.corner(of: view)
                    #expect(Self.near(corner, bg), "\(id): \(name) is painted \(corner), not the theme's background \(bg)")
                }
                let start = try #require(
                    caffeinate.window?.contentView?.allSubviews.lazy.compactMap { $0 as? NSButton }
                        .first { $0.accessibilityIdentifier() == "caffeinate-start-button" })
                #expect(start.bezelColor == theme.accent, "\(id): the default button is filled with the accent")
                #expect(
                    start.attributedTitle.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor == theme.text,
                    "\(id): in a window that isn't key, which AppKit fills grey, its title is the text color")
                #expect(about.body.theme == theme, "\(id): About")
                #expect(about.body.versionLabel.textColor == theme.textDim, "\(id): About's dim text")
            }
        }

        /// Settings' page `label`, chosen and laid out at its size.
        private static func page(_ label: String, of tabs: NSTabViewController, in window: NSWindow) throws -> NSView {
            let index = try #require(tabs.tabViewItems.map(\.label).firstIndex(of: label))
            tabs.selectedTabViewItemIndex = index
            if let size = tabs.tabViewItems[index].viewController?.preferredContentSize { window.setContentSize(size) }
            return try #require(tabs.tabViewItems[index].view)
        }

        /// The pixel 3pt in from `view`'s top left corner, drawn over magenta.
        private static func corner(of view: NSView) throws -> NSColor {
            view.layoutSubtreeIfNeeded()
            runLoopTurns()
            view.layoutSubtreeIfNeeded()
            let rep = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
            NSColor(srgbRed: 1, green: 0, blue: 1, alpha: 1).setFill()
            view.bounds.fill()
            NSGraphicsContext.restoreGraphicsState()
            view.cacheDisplay(in: view.bounds, to: rep)
            let scale = Double(rep.pixelsWide) / view.bounds.width
            return (rep.colorAt(x: Int(3 * scale), y: Int(3 * scale)) ?? .clear).usingColorSpace(.sRGB) ?? .clear
        }

        /// The color a fill of `color` reads back as through the same offscreen pipeline.
        private static func reference(_ color: NSColor) throws -> NSColor {
            let view = NSView(frame: CGRect(x: 0, y: 0, width: 8, height: 8))
            let rep = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
            color.setFill()
            view.bounds.fill()
            NSGraphicsContext.restoreGraphicsState()
            return (rep.colorAt(x: 2, y: 2) ?? .clear).usingColorSpace(.sRGB) ?? .clear
        }

        /// Within 0.1 a channel: a capture brings back what SwiftUI fills in a window a little off
        /// (#2a6e3f as #2b7e54), while an unpainted page would be the system's grey or white, or
        /// magenta.
        private static func near(_ a: NSColor, _ b: NSColor) -> Bool {
            abs(a.redComponent - b.redComponent) < 0.1 && abs(a.greenComponent - b.greenComponent) < 0.1
                && abs(a.blueComponent - b.blueComponent) < 0.1
        }
    }
}
