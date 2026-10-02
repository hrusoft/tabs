import AppKit
import TabsPluginSDK
import Testing

@testable import Tabs
@testable import TabsCore

/// Renders every kind of pane offscreen from the shipped plugins and checks the
/// result isn't blank. With TABS_SNAPSHOT_DIR set (pass it to xcodebuild as
/// TEST_RUNNER_TABS_SNAPSHOT_DIR) the PNGs are written there — a way to look at
/// the UI on a machine where screenshots aren't permitted.
@MainActor
@Suite(.serialized) struct SnapshotTests {
    @Test func everyPaneKindRenders() throws {
        let runtime = TestSupport.runtime()
        let layout = Fixture.saved(
            Fixture.tabsWindow(
                "w",
                [
                    Fixture.leaf("browser", "browser"),
                    Fixture.leaf("tree", "git-tree", config: ["cwd": "/"]),
                    Fixture.leaf("gone", "terminal", config: ["cwd": "~"], title: "zsh"),
                    Fixture.leaf("empty"),
                ], active: 0))
        runtime.startBundledPlugins(of: .main, requiredContentTypes: layout.contentTypes)
        let engine = LayoutEngine(runtime: runtime)
        let renderer = WorkspaceRenderer(runtime: runtime, engine: engine, presentsWindows: false)
        engine.restore(layout)
        let window = try #require(renderer.windows.first)

        for (index, leaf) in window.layout.leaves.enumerated() {
            engine.focus(leaf.id)
            window.root.layoutSubtreeIfNeeded()
            // Layers get their content in a display pass, which a run-loop turn brings.
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
            let image = try #require(render(window.root))
            #expect(distinctColors(in: image) > 8, "\(leaf.id) rendered blank")
            try write(image, "pane-\(index)-\(leaf.id)")
        }
    }

    @Test func pluginsAndSettingsWindowsRender() throws {
        let runtime = TestSupport.runtime()
        runtime.startPlugins(
            from: Bundle.main.builtInPlugInsURL, bundled: BuildStamp(of: .main)?.bundledPlugins,
            inProcess: [
                TestSupport.candidate(TestSupport.manifest("broken", sortOrder: 50)) { _ in
                    struct NotConfigured: Error {}
                    throw NotConfigured()
                }
            ])
        let plugins = makePluginsWindow(model: PluginsModel(host: runtime.host, fingerprint: runtime.sharedFingerprint) {})
        let settings = makeSettingsWindow(
            pages: runtime.settingsPages(), settings: runtime.settings, signals: runtime.signals.settingKinds, shortcuts: runtime.shortcuts)
        for (name, controller) in [("plugins", plugins), ("settings", settings)] {
            let image = try #require(controller.window?.contentView.flatMap(renderCached))
            #expect(distinctColors(in: image, from: 0) > 8, "\(name) rendered blank")
            try write(image, "window-\(name)")
        }
        // Every Settings page, at the size the window takes for it.
        let tabs = try #require(settings.contentViewController as? NSTabViewController)
        for (index, item) in tabs.tabViewItems.enumerated() {
            tabs.selectedTabViewItemIndex = index
            if let size = item.viewController?.preferredContentSize { settings.window?.setContentSize(size) }
            let image = try #require(settings.window?.contentView.flatMap(renderCached))
            #expect(distinctColors(in: image, from: 0) > 8, "Settings ▸ \(item.label) rendered blank")
            let slug = item.label.lowercased().split { !$0.isLetter && !$0.isNumber }.joined(separator: "-")
            try write(image, "window-settings-\(index)-\(slug)")
        }
    }

    private func write(_ image: NSBitmapImageRep, _ name: String) throws {
        guard let directory = ProcessInfo.processInfo.environment["TABS_SNAPSHOT_DIR"] else { return }
        try image.representation(using: .png, properties: [:])?.write(to: URL(filePath: directory).appending(path: "\(name).png"))
    }

    /// The workspace's own layer tree (its chrome paints with layers too), as the visual capture renders it.
    private func render(_ view: NSView) -> NSBitmapImageRep? {
        (try? VisualCapture.render(view)).flatMap(NSBitmapImageRep.init(data:))
    }

    /// A SwiftUI window, drawn by AppKit.
    private func renderCached(_ view: NSView) -> NSBitmapImageRep? {
        view.layoutSubtreeIfNeeded()
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor.windowBackgroundColor.setFill()
        view.bounds.fill()
        NSGraphicsContext.restoreGraphicsState()
        view.cacheDisplay(in: view.bounds, to: rep)
        return rep
    }

    /// Distinct colors below row `top` (by default: the pane body, under the
    /// root bar and header).
    private func distinctColors(in image: NSBitmapImageRep, from top: Int = 120) -> Int {
        var seen = Set<UInt32>()
        for y in stride(from: top, to: image.pixelsHigh, by: 4) {
            for x in stride(from: 0, to: image.pixelsWide, by: 4) {
                guard let color = image.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                let r = UInt32(color.redComponent * 255), g = UInt32(color.greenComponent * 255), b = UInt32(color.blueComponent * 255)
                seen.insert(r << 16 | g << 8 | b)
            }
        }
        return seen.count
    }
}
