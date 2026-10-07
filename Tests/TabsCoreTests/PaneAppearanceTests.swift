import AppKit
import Foundation
import TabsPluginSDK
import Testing

@testable import TabsCore

/// `paneAppearanceDidChange(theme:depth:)` and the context's `theme` and
/// `depth`: told once to begin with, then on a change of either only.
@MainActor
@Suite struct PaneAppearanceTests {
    let runtime = TestSupport.runtime()
    let renderer = FakeRenderer()
    private final class Held { var engine: LayoutEngine? }
    private let held = Held()
    private final class Log {
        var told: [(theme: PaneTheme, depth: Int)] = []
        var contexts: [any PaneContext] = []
    }
    private let log = Log()

    private final class Watcher: PaneController {
        let view = NSView()
        let log: Log
        let pane: any PaneContext
        init(pane: any PaneContext, log: Log) {
            self.pane = pane
            self.log = log
        }
        func currentConfig() -> JSONValue { .emptyObject }
        func paneAppearanceDidChange(theme: PaneTheme, depth: Int) {
            // Already current when told.
            #expect(pane.theme == theme && pane.depth == depth)
            log.told.append((theme, depth))
        }
    }

    private func start() -> PaneID {
        let log = log
        let plugin = TestSupport.candidate(TestSupport.manifest("watch", contentTypes: ["watch"])) { context in
            context.register(
                ContentTypeContribution(id: "watch", displayName: "Watch", icon: .symbol("eye")) { pane in
                    log.contexts.append(pane)
                    return Watcher(pane: pane, log: log)
                })
        }
        runtime.startPlugins(from: nil, inProcess: [plugin])
        let engine = LayoutEngine(runtime: runtime)
        engine.renderer = renderer
        engine.restore(
            SavedLayout(windows: [WindowLayout(id: "w", root: .leaf(LayoutLeaf(id: "a", type: "watch")), active: "a")]))
        held.engine = engine
        return "a"
    }

    @Test func aPaneStartsWithTheDarkThemeAtDepthZeroBeforeItIsTold() {
        _ = start()
        #expect(log.contexts.first?.theme == .dark)
        #expect(log.contexts.first?.depth == 0)
        #expect(log.told.isEmpty)
    }

    @Test func theFirstWordIsToldEvenWhenItIsTheDefault() {
        let pane = start()
        runtime.panes.appearanceDidChange(pane, theme: .dark, depth: 0)
        #expect(log.told.count == 1)
        runtime.panes.appearanceDidChange(pane, theme: .dark, depth: 0)
        #expect(log.told.count == 1, "the same again: not told")
    }

    @Test func aThemeChangeIsToldAndReadableAtOnce() {
        let pane = start()
        runtime.panes.appearanceDidChange(pane, theme: .dark, depth: 1)
        runtime.panes.appearanceDidChange(pane, theme: .light, depth: 1)
        #expect(log.told.map(\.theme) == [.dark, .light])
        #expect(log.told.map(\.depth) == [1, 1])
        #expect(log.contexts.first?.theme == .light)
    }

    @Test func aDepthChangeIsToldWithTheSameTheme() {
        let pane = start()
        runtime.panes.appearanceDidChange(pane, theme: .dark, depth: 1)
        runtime.panes.appearanceDidChange(pane, theme: .dark, depth: 2)
        #expect(log.told.map(\.depth) == [1, 2])
        #expect(log.contexts.first?.depth == 2)
    }

    @Test func aPaneThatIsGoneIsNotTold() {
        _ = start()
        runtime.panes.appearanceDidChange("nobody", theme: .light, depth: 3)
        #expect(log.told.isEmpty)
    }

    @Test func surfacesAlternateWithDepth() {
        #expect(PaneTheme.dark.surface(depth: 0) == PaneTheme.dark.bg)
        #expect(PaneTheme.dark.surface(depth: 1) == PaneTheme.dark.bgElevated)
        #expect(PaneTheme.light.surface(depth: 2) == PaneTheme.light.bg)
        #expect(PaneTheme.light.surfaceNext(depth: 0) == PaneTheme.light.bgElevated)
    }
}
