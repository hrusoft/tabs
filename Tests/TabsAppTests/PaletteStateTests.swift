import AppKit
import TabsPluginSDK
import Testing

@testable import Tabs
@testable import TabsCore

/// The ⌘P palette without a window (docs/NEW-CONTENT.md): each step's rows and what every key does
/// to them (`PaletteState`), and the panel's size (`PaletteView.panelLayout`). The palette in a
/// window, opened by its chord, clicked and keyed through the window, is `UITests.PaletteTests`;
/// how its rows are drawn, `GeometryGoldenTests` (`Visual/scenarios/palette-*`).
@MainActor
@Suite struct PaletteStateTests {
    typealias Key = InputSynthesizer.Key

    /// Two types in UI order, Alpha and Beta, as the renderer lists the creatable ones.
    private let two = PaletteState(
        types: ["Alpha", "Beta"].map {
            EmptyPaneView.Action(
                type: ContentTypeID("pal.\($0.lowercased())"), label: "New \($0.lowercased())", displayName: $0, icon: .symbol("square"))
        })

    // MARK: Step 1

    /// T-6, T-7: nothing enabled → the sentence, and only Escape does anything.
    @Test func withNothingToCreateItSaysSoAndIgnoresEveryKeyButEscape() {
        var state = PaletteState(types: [])
        #expect(state.rows.isEmpty)
        #expect(PaletteView.emptyLines.joined(separator: " ") == NoContentTypes.message)
        #expect(PaletteView.emptyLines.count == 2, "it wraps in the 320-wide panel")
        #expect(
            abs(PaletteView.panelLayout(in: CGSize(width: 1200, height: 800), rows: 0).height - 60) < 0.01,
            "border, padding, two 12pt lines, the sentence's padding (60)")
        for key in [Key.down, Key.up, Key.return, Key.digit(1)] {
            let effect = state.key(key)
            #expect(effect == nil, "\(key)")
        }
        #expect(state.step == .type && state.highlighted == 0)
        let escape = state.key(Key.escape)
        #expect(escape == .dismiss)
    }

    // MARK: Step 2

    /// S-1, S-2, S-3, S-5: the four placements, the header buttons' icons, the first highlighted.
    @Test func theSecondStepListsTheFourPlacements() {
        var state = two
        state.highlighted = 1
        let effect = state.choose(1)
        #expect(effect == .stepped(reset: true))
        #expect(state.step == .placement("pal.beta"))
        #expect(
            state.rows.map(\.label) == ["Tab", "Horizontal Split", "Vertical Split", "Unpinned Pane"], "the menu's labels without \"New \"")
        #expect(state.highlighted == 0, "a new step starts on its first row")
        let icons = state.rows.compactMap { row -> ChromeIcon? in
            if case .chrome(let icon) = row.icon { icon } else { nil }
        }
        #expect(icons == [.newTab, .splitHorizontal, .splitVertical, .newUnpinnedTab], "the header buttons' own icons")
        #expect(state.rows.map(\.key) == ["new-tab", "split-horizontal", "split-vertical", "new-unpinned-pane"])
    }

    /// S-4, Q-5: no way back; Escape closes it all.
    @Test func escapeFromTheSecondStepClosesEverything() {
        var state = two
        _ = state.choose(0)
        for key: UInt16 in [51, 123, 48] {
            let effect = state.key(key)
            #expect(effect == nil, "\(key): delete, ←, Tab don't go back")
        }
        #expect(state.step == .placement("pal.alpha"))
        let escape = state.key(Key.escape)
        #expect(escape == .dismiss)
    }

    // MARK: Keyboard

    /// K-1
    @Test func arrowsMoveTheHighlightAndWrap() {
        var state = two
        let effect = state.key(Key.down)
        #expect(effect == .redraw)
        #expect(state.highlighted == 1)
        _ = state.key(Key.down)
        #expect(state.highlighted == 0, "wrapped past the last")
        _ = state.key(Key.up)
        #expect(state.highlighted == 1, "and back past the first")
    }

    /// K-2, K-3, K-4: Return (and Enter) choose the highlighted row; a digit its row, by the main
    /// row's key, not the keypad's.
    @Test func returnAndTheDigitsChoose() {
        var state = two
        _ = state.key(Key.down)
        _ = state.key(Key.return)
        #expect(state.step == .placement("pal.beta"), "Return chooses the highlighted row")
        let four = state.key(Key.digit(4))
        #expect(four == .create(.unpinned, "pal.beta"), "and on step 2 a row creates")

        state = two
        _ = state.key(76)
        #expect(state.step == .placement("pal.alpha"), "Enter, as Return")

        state = two
        _ = state.key(Key.digit(2))
        #expect(state.step == .placement("pal.beta"), "2 chooses the second row directly, without moving the highlight first")
        let tab = state.key(Key.return)
        #expect(tab == .create(.tab, "pal.beta"))

        state = two
        let past = [state.key(Key.digit(3)), state.key(Key.digit(9))]
        #expect(past == [nil, nil])
        let keypad = state.key(83)
        #expect(keypad == nil, "the keypad's 1 isn't a digit here")
        #expect(state.step == .type, "a digit past the last row does nothing")
    }

    /// K-6: there's no search field: every other key is left alone.
    @Test func otherKeysDoNothing() {
        var state = two
        // a, b, Tab, Space, ←, →
        for key: UInt16 in [0, 11, 48, 49, 123, 124] {
            let effect = state.key(key)
            #expect(effect == nil, "\(key)")
        }
        #expect(state.step == .type && state.highlighted == 0)
    }

    // MARK: Sizes

    /// E-4, L-8: a list taller than 70% of the window is capped (and scrolls); a short one is as
    /// tall as its rows; centered either way.
    @Test func aTallListIsCappedAtSeventyPercentOfTheWindow() {
        let size = CGSize(width: 900, height: 500)
        let tall = PaletteView.panelLayout(in: size, rows: 30)
        #expect(tall.height == 350)
        #expect(PaletteView.rowHeight == 30, "rows keep their height")
        let short = PaletteView.panelLayout(in: size, rows: 2)
        #expect(short.height == 70, "border 1 and padding 4 around two 30pt rows")
        for panel in [tall, short] {
            #expect(panel.width == 320 && panel.midX == size.width / 2 && panel.midY == size.height / 2)
        }
    }
}
