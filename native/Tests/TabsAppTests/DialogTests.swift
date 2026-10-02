import AppKit
import TabsPluginSDK
import Testing

@testable import Tabs
@testable import TabsCore

extension UITests {
    // MARK: - Pane dialogs and pickers (PaneContext.confirm/choose/alert/pick)

    @MainActor
    @Suite struct Dialogs {
        /// A text pane "n" beside a plain one "b": a pane that can ask.
        static let pair = Fixture.sideBySide(Fixture.leaf("n", "text"), Fixture.leaf("b", "text"), active: "n")

        private func context(_ ui: UIDriver, _ pane: PaneID = "n") throws -> PaneContextImpl {
            try #require(ui.runtime.panes.pane(pane)?.context)
        }

        /// Runs `ask` as a pane's task and waits for its card.
        private func asking<Result: Sendable>(
            _ ui: UIDriver, _ ask: @escaping @MainActor () async -> Result
        ) async throws -> (card: DialogCard, answer: Task<Result, Never>) {
            let task = Task { @MainActor in await ask() }
            return (try await ui.waitForDialog(), task)
        }

        @Test func withNoWindowShownAQuestionAnswersItselfWithItsDefault() async throws {
            let ui = UIDriver(layout: Self.pair)
            let pane = try context(ui)
            #expect(await pane.confirm(PaneConfirm(title: "T", message: "M")))
            #expect(await pane.choose(PaneChoose(title: "T", message: "M", options: ["a", "b"])) == 0)
            await pane.alert(PaneAlert(title: "T", message: "M"))
            #expect(ui.dialog == nil, "no card was ever shown")
            #expect(await pane.chooseDirectory(title: "Pick") == nil, "a picker is cancelled with no window to sheet on")
        }

        @Test func theTestsPickerAnswerReachesThePane() async throws {
            let ui = UIDriver(layout: Self.pair)
            let start = URL(filePath: "/tmp/start", directoryHint: .isDirectory)
            var asked: [PanePicker] = []
            ui.renderer.pickerOverride = {
                asked.append($0)
                return URL(filePath: "/tmp/chosen")
            }
            #expect(await (try context(ui)).chooseFile(title: "Pick a file", startingAt: start) == URL(filePath: "/tmp/chosen"))
            #expect(asked == [PanePicker(kind: .file, title: "Pick a file", startingAt: start)])
        }

        @Test func aConfirmIsTheElectronCardOverTheWindow() async throws {
            let ui = UIDriver(layout: Self.pair)
            ui.renderer.showsDialogCardsUnattended = true
            let pane = try context(ui)
            let (card, answer) = try await asking(ui) {
                await pane.confirm(PaneConfirm(title: "Checkout", message: "Sure?\nReally.", confirmLabel: "Go"))
            }
            let overlay = try ui.window.root.overlay
            #expect(card.superview === overlay, "an in-window overlay: the rest of the app is not blocked")
            #expect(card.frame == overlay.bounds)
            let panel = try #require(InputSynthesizer.find("dialog", in: try ui.window.window!, within: card))
            #expect(panel.frame.width == 360)
            #expect(abs(panel.frame.midX - overlay.bounds.midX) <= 0.5 && abs(panel.frame.midY - overlay.bounds.midY) <= 0.5, "centered")
            #expect(panel.accessibilityLabel() == "Checkout")
            #expect(card.message == "Sure?\nReally.")
            #expect(card.buttons.map { $0.accessibilityLabel() } == ["Cancel", "Go"])
            let cancel = card.buttons[0]
            let confirm = card.buttons[1]
            // Right-aligned inside the 16pt padding and the 1pt border, 8pt apart.
            #expect(confirm.frame.maxX == panel.frame.width - 17)
            #expect(cancel.frame.maxX == confirm.frame.minX - 8)
            #expect(confirm.frame.height == cancel.frame.height)
            try ui.pressDialogButton("dialog-confirm")
            #expect(await answer.value == true)
            #expect(ui.dialog == nil && card.superview == nil)
        }

        @Test func cancelEscapeAndAClickOutsideAllAnswerNo() async throws {
            let ui = UIDriver(layout: Self.pair)
            ui.renderer.showsDialogCardsUnattended = true
            let pane = try context(ui)
            for dismiss in [
                { try ui.pressDialogButton("dialog-cancel") },
                { try ui.clickDialogBackdrop() },
                { try ui.type("\u{1b}") },
            ] as [() throws -> Void] {
                let (_, answer) = try await asking(ui) { await pane.confirm(PaneConfirm(title: "T", message: "M")) }
                try dismiss()
                #expect(await answer.value == false)
                #expect(ui.dialog == nil)
            }
        }

        @Test func aChooseAnswersTheIndexPickedInItsSelect() async throws {
            let ui = UIDriver(layout: Self.pair)
            ui.renderer.showsDialogCardsUnattended = true
            let pane = try context(ui)
            let (card, answer) = try await asking(ui) {
                await pane.choose(
                    PaneChoose(title: "Checkout", message: "Which?", options: ["main", "stable", "old"], confirmLabel: "Checkout"))
            }
            #expect(card.options == ["main", "stable", "old"] && card.selection == 0)
            let select = try #require(card.select)
            #expect(select.accessibilityIdentifier() == "dialog-select")
            try ui.chooseDialogOption(2)
            #expect(card.selection == 2)
            #expect(ui.contextMenu == nil, "choosing closes the select's menu")
            try ui.pressDialogButton("dialog-confirm")
            #expect(await answer.value == 2)
        }

        @Test func aChooseCancelledAnswersNil() async throws {
            let ui = UIDriver(layout: Self.pair)
            ui.renderer.showsDialogCardsUnattended = true
            let pane = try context(ui)
            let (_, answer) = try await asking(ui) { await pane.choose(PaneChoose(title: "T", message: "M", options: ["a", "b"])) }
            try ui.pressDialogButton("dialog-cancel")
            #expect(await answer.value == nil)
        }

        @Test func anAlertHasOneButtonAndKeepsItsMessagesLineBreaks() async throws {
            let ui = UIDriver(layout: Self.pair)
            ui.renderer.showsDialogCardsUnattended = true
            let pane = try context(ui)
            let text = "error: Your local changes would be overwritten:\n\tconflict.txt\nPlease commit or stash."
            let (card, answer) = try await asking(ui) { await pane.alert(PaneAlert(title: "Checkout failed", message: text)) }
            #expect(card.buttons.map { $0.accessibilityIdentifier() } == ["dialog-ok"])
            #expect(card.message == text)
            try ui.pressDialogButton("dialog-ok")
            await answer.value
            #expect(ui.dialog == nil)
        }

        @Test func returnPressesThePrimaryButton() async throws {
            let ui = UIDriver(layout: Self.pair)
            ui.renderer.showsDialogCardsUnattended = true
            let pane = try context(ui)
            let (_, answer) = try await asking(ui) { await pane.confirm(PaneConfirm(title: "T", message: "M")) }
            try ui.type("\r")
            #expect(await answer.value == true)
        }

        @Test func aCardCoversItsOwnWindowOnly() async throws {
            let ui = UIDriver(
                layout: Fixture.saved(Fixture.window("w1", Fixture.leaf("n", "text")), Fixture.window("w2", Fixture.leaf("b", "text"))))
            ui.renderer.showsDialogCardsUnattended = true
            let pane = try context(ui, "n")
            let (card, answer) = try await asking(ui) { await pane.confirm(PaneConfirm(title: "T", message: "M")) }
            let mine = try ui.window("w1")
            let other = try ui.window("w2")
            #expect(card.superview === mine.root.overlay)
            #expect(other.root.overlay.subviews.isEmpty, "the other window is untouched")
            card.dismiss()
            #expect(await answer.value == false)
        }

        @Test func aPaneThatClosesWhileAskingIsAnsweredNo() async throws {
            let ui = UIDriver(layout: Self.pair)
            ui.renderer.showsDialogCardsUnattended = true
            let pane = try context(ui)
            let (_, answer) = try await asking(ui) { await pane.confirm(PaneConfirm(title: "T", message: "M")) }
            ui.engine.close("n")
            #expect(await answer.value == false)
            #expect(ui.dialog == nil)
        }

        @Test func aLongMessageStaysInsideTheWindow() async throws {
            let ui = UIDriver(layout: Self.pair)
            ui.renderer.showsDialogCardsUnattended = true
            let pane = try context(ui)
            let text = (1...200).map { "line \($0)" }.joined(separator: "\n")
            let (card, answer) = try await asking(ui) { await pane.alert(PaneAlert(title: "T", message: text)) }
            let panel = try #require(InputSynthesizer.find("dialog", in: try ui.window.window!, within: card))
            #expect(panel.frame.height <= card.bounds.height * 0.8 + 1, "max-height: 80vh")
            card.dismiss()
            await answer.value
        }
    }
}
