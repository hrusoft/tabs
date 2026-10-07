import AppKit
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
            let plugins = makePluginsWindow(model: PluginsModel(host: ui.runtime.host, fingerprint: ui.runtime.sharedFingerprint) {})
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
    /// surface the theme setting must reach, rendered under a setting that disagrees with the OS.
    @MainActor
    @Suite struct AppearanceSnapshots {
        @Test(arguments: [("dark", NSAppearance.Name.aqua), ("light", .darkAqua)])
        func surfacesUnderADisagreeingOS(theme: String, os: NSAppearance.Name) throws {
            guard let directory = ProcessInfo.processInfo.environment["TABS_SNAPSHOT_DIR"] else { return }
            NSApp.appearance = NSAppearance(named: os)
            defer { NSApp.appearance = nil }
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
            let plugins = makePluginsWindow(model: PluginsModel(host: ui.runtime.host, fingerprint: ui.runtime.sharedFingerprint) {})
            defer {
                settings.close()
                plugins.close()
            }
            let tabs = try #require(settings.contentViewController as? NSTabViewController)
            let window = try #require(settings.window)
            for (index, item) in tabs.tabViewItems.enumerated() {
                tabs.selectedTabViewItemIndex = index
                if let size = item.viewController?.preferredContentSize { window.setContentSize(size) }
                try write("settings-\(item.label.lowercased().filter(\.isLetter))", window)
            }
            try write("plugins", #require(plugins.window))

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
