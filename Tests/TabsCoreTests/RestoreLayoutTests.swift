import AppKit
import Foundation
import TabsPluginSDK
import Testing

@testable import TabsCore

/// Restore layout on relaunch (docs/RESTORE-LAYOUT.md): `persistLayoutOnExit`,
/// gating what launch reads and what save points write.
@MainActor
@Suite struct RestoreLayoutTests {
    /// A pane that counts how often core asks it for its state.
    @MainActor final class CountingPane: PaneController {
        let view = NSView()
        var asked = 0
        func currentConfig() -> JSONValue {
            asked += 1
            return ["n": 1]
        }
    }

    @MainActor final class Panes { var all: [CountingPane] = [] }

    let directory = TestSupport.temporaryDirectory()
    var layoutFile: URL { directory.appending(path: "layout.json") }

    private func runtime(persist: Bool) -> CoreRuntime {
        let runtime = TestSupport.runtime(dataDirectory: directory)
        var panes = runtime.settings.panes
        panes.persistLayoutOnExit = persist
        runtime.settings.setPanes(panes)
        return runtime
    }

    private func engine(_ runtime: CoreRuntime, _ panes: Panes, restoring saved: SavedLayout?) -> LayoutEngine {
        runtime.startPlugins(
            from: nil,
            inProcess: [
                TestSupport.candidate(TestSupport.manifest("count", contentTypes: ["count"])) { context in
                    context.register(
                        ContentTypeContribution(id: "count", displayName: "Count", icon: .symbol("circle")) { _ in
                            let pane = CountingPane()
                            panes.all.append(pane)
                            return pane
                        })
                }
            ], requiredContentTypes: saved?.contentTypes ?? [])
        let engine = LayoutEngine(runtime: runtime)
        engine.restore(saved)
        return engine
    }

    private func window(_ id: WindowID = "w", pane: PaneID = "a") -> WindowLayout {
        let tab = Tab(title: "Tab", content: .leaf(LayoutLeaf(id: pane, type: "count")))
        return WindowLayout(id: id, root: .tabs(TabGroup(tabs: [tab], activeTabID: tab.id)), active: pane)
    }

    private var fileText: String? { try? String(contentsOf: layoutFile, encoding: .utf8) }

    @Test func offAtLaunchNeitherReadsNorTouchesTheFile() throws {  // R-4, R-11
        LayoutStore(file: layoutFile).save(SavedLayout(windows: [window("saved")]))
        let before = try #require(fileText)
        let runtime = runtime(persist: false)
        #expect(runtime.loadLayout() == nil, "a fresh launch")
        #expect(runtime.persistenceNotes.isEmpty)
        #expect(fileText == before, "left exactly as it was")

        try Data("{not json".utf8).write(to: layoutFile)
        #expect(runtime.loadLayout() == nil)
        #expect(fileText == "{not json", "even an unreadable file isn't moved aside")
        #expect(
            try FileManager.default.contentsOfDirectory(atPath: directory.path).filter { $0.hasPrefix("layout.") } == ["layout.json"])
    }

    @Test func onAtLaunchReadsTheFile() throws {  // R-3
        LayoutStore(file: layoutFile).save(SavedLayout(windows: [window("saved")]))
        #expect(runtime(persist: true).loadLayout()?.windows.map(\.id) == ["saved"])
    }

    @Test func offNothingIsWritten() throws {  // R-5
        let runtime = runtime(persist: false)
        let engine = engine(runtime, Panes(), restoring: SavedLayout(windows: [window()]))
        engine.windowFrameDidChange("w", to: WindowFrame(x: 1, y: 2, width: 800, height: 600))
        engine.saveNow()
        #expect(!FileManager.default.fileExists(atPath: layoutFile.path))
    }

    @Test func offNoPaneIsAskedForItsState() throws {  // R-6
        let panes = Panes()
        let engine = engine(runtime(persist: false), panes, restoring: SavedLayout(windows: [window()]))
        let pane = try #require(panes.all.first)
        let asked = pane.asked
        engine.saveNow()
        #expect(pane.asked == asked)
    }

    @Test func turningItOnResumesSavingTheLiveLayout() throws {  // R-7
        let runtime = runtime(persist: false)
        let engine = engine(runtime, Panes(), restoring: SavedLayout(windows: [window("w1", pane: "a")]))
        engine.openWindow()
        engine.saveNow()
        #expect(!FileManager.default.fileExists(atPath: layoutFile.path))
        var settings = runtime.settings.panes
        settings.persistLayoutOnExit = true
        runtime.settings.setPanes(settings)
        engine.saveNow()
        let saved = try #require(LayoutStore(file: layoutFile).load().document)
        #expect(saved.windows.count == 2, "every window as it is now, the one opened while off included")
        #expect(saved.windows.first?.leaves.first?.config == ["n": 1], "live panes asked for their state")
    }

    @Test func turningItOffStopsWriting() throws {  // R-8
        let runtime = runtime(persist: true)
        let engine = engine(runtime, Panes(), restoring: SavedLayout(windows: [window("w1")]))
        engine.saveNow()
        let written = try #require(fileText)
        var settings = runtime.settings.panes
        settings.persistLayoutOnExit = false
        runtime.settings.setPanes(settings)
        engine.openWindow()
        engine.saveNow()
        #expect(fileText == written, "the file keeps what it last held")
        #expect(runtime.loadLayout() == nil, "and the next launch starts fresh")
    }

    @Test func theLastClosedWindowComesBackEvenWhenOff() throws {  // R-10
        let engine = engine(runtime(persist: false), Panes(), restoring: SavedLayout(windows: [window("w1", pane: "a")]))
        engine.windowDidClose("w1")
        #expect(engine.model.windows.isEmpty)
        let reopened = engine.openWindow()
        #expect(engine.model.window(reopened)?.leaves.map(\.type) == ["count"], "kept in memory, not read from disk")
    }

    @Test func theSettingPersists() throws {  // R-9
        _ = runtime(persist: false)
        let reread = SettingsStore(file: directory.appending(path: "settings.json"))
        #expect(reread.panes.persistLayoutOnExit == false)
        #expect(TestSupport.readJSON(directory.appending(path: "settings.json"))?["core"]?["panes"]?["persistLayoutOnExit"] == false)
    }
}
