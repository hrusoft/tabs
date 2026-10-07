import Foundation
import TabsPluginSDK
import Testing

@testable import TabsCore

/// The "you would lose work" confirmation's words (`CloseConfirmation`,
/// docs/TERMINAL.md T-72), and which question the engine asks — closing or
/// quitting.
@MainActor
@Suite struct CloseConfirmationTests {
    /// T-72: one warning — one bullet, "it", Close Anyway; Cancel is the other button.
    @Test func oneWarningIsOneBulletAndClosingEndsIt() {
        let copy = CloseConfirmation(warnings: ["vim is still running"], quitting: false)
        #expect(copy.message == "A pane is still busy")
        #expect(copy.detail == "• vim is still running\n\nClosing will end it immediately.")
        #expect(copy.proceed == "Close Anyway")
        #expect(CloseConfirmation.cancel == "Cancel")
    }

    /// T-72: several warnings — counted in the title, one bullet each, in order, "them".
    @Test func severalWarningsAreCountedAndListedInOrder() {
        let copy = CloseConfirmation(warnings: ["vim is still running", "npm is still running"], quitting: false)
        #expect(copy.message == "2 panes are still busy")
        #expect(copy.detail == "• vim is still running\n• npm is still running\n\nClosing will end them immediately.")
    }

    /// T-71, T-72: quitting asks the same question with Quit Anyway.
    @Test func quittingGoesAheadWithQuitAnyway() {
        let copy = CloseConfirmation(warnings: ["ssh is still running"], quitting: true)
        #expect(copy.proceed == "Quit Anyway")
        #expect(copy.message == "A pane is still busy")
        #expect(copy.detail.hasSuffix("Closing will end it immediately."), "the same wording, for quit too")
    }

    /// T-70, T-71: closing a pane or a window asks as a close; only quitting asks as a quit.
    @Test func onlyQuittingAsksAsAQuit() throws {
        let runtime = TestSupport.runtime()
        let renderer = FakeRenderer()
        runtime.startPlugins(
            from: nil,
            inProcess: [
                TestSupport.candidate(TestSupport.manifest("stub", contentTypes: ["stub"])) { context in
                    context.register(
                        ContentTypeContribution(id: "stub", displayName: "Stub", icon: .symbol("circle")) {
                            WarningPane(config: $0.initialConfig)
                        })
                }
            ], requiredContentTypes: ["stub"])
        let engine = LayoutEngine(runtime: runtime)
        engine.renderer = renderer
        let tabs = ["a", "b"].map { Tab(title: "Tab", content: .leaf(LayoutLeaf(id: PaneID($0), type: "stub"))) }
        engine.restore(
            SavedLayout(windows: [WindowLayout(id: "w", root: .tabs(TabGroup(tabs: tabs, activeTabID: tabs[0].id)), active: "a")]))
        for id in ["a", "b"] { (engine.live(PaneID(id))?.controller as? WarningPane)?.warning = "\(id) is still running" }

        renderer.answers = [false, false, false]
        engine.close("a")
        #expect(engine.shouldClose("w") == false)
        #expect(engine.shouldQuit() == false)
        #expect(
            renderer.asked == [
                ["a is still running"], ["a is still running", "b is still running"], ["a is still running", "b is still running"],
            ])
        #expect(renderer.askedToQuit == [false, false, true])
    }
}
