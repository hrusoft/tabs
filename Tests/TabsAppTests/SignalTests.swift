import AppKit
import TabsPluginSDK
import Testing

@testable import Tabs
@testable import TabsCore

extension UITests {
    // MARK: - Pane signals (docs/PANE-SIGNALS.md)

    @MainActor
    @Suite struct Signals {
        /// Panes a | b side by side, a active.
        static let pair = Fixture.sideBySide(Fixture.leaf("a"), Fixture.leaf("b"), active: "a")

        @Test func aSignalsIconSitsBeforeTheHeaderTitle() throws {
            let ui = UIDriver(layout: Self.pair)
            let plain = try #require(try ui.paneView("a").header).titleRect.minX
            ui.raise("bell", on: "b")
            let header = try #require(try ui.paneView("b").header)
            #expect(try ui.headerSignals("b") == ["bell"])
            let icon = try #require(InputSynthesizer.find("pane-signal-bell", in: try ui.window.window!, within: header))
            #expect(icon.frame.size == CGSize(width: 16, height: 16))
            #expect(icon.frame.minX == header.grip.frame.maxX + 8, "right after the grip, the bar's gap between")
            #expect(icon.frame.minY == 4, "centered in the 24pt bar")
            #expect(header.titleRect.minX - plain == 24, "the title moves over by the icon and a gap")

            ui.raise("controlled", on: "b")
            #expect(try ui.headerSignals("b") == ["bell", "controlled"], "the bell first")
            #expect(header.titleRect.minX - plain == 48)
        }

        @Test func anIconIsAnImageLabelledForAccessibility() throws {
            let ui = UIDriver(layout: Self.pair)
            ui.raise("bell", "controlled", on: "b")
            let window = try #require(try ui.window.window)
            let bell = try #require(InputSynthesizer.find("pane-signal-bell", in: window))
            let robot = try #require(InputSynthesizer.find("pane-signal-controlled", in: window))
            #expect(bell.accessibilityRole() == .image && bell.accessibilityLabel() == "Bell")
            #expect(robot.accessibilityLabel() == "Controlled by another pane")
            #expect(bell.hitTest(NSPoint(x: bell.frame.midX, y: bell.frame.midY)) == nil, "clicks go to the header under it")
        }

        @Test func aTabHoldingASignalledPaneShowsItsIconAndGrows() throws {
            let ui = UIDriver(layout: Fixture.saved(Fixture.tabsWindow("w", [Fixture.leaf("x"), Fixture.leaf("y")], active: 1)))
            let tab = try ui.tabView("t-x")
            let (width, title) = (tab.naturalWidth, tab.titleRect.minX)
            ui.raise("bell", on: "x")
            ui.raise("controlled", on: "y")
            #expect(tab.signalIcons.compactMap(\.kindID) == ["bell"])
            #expect(InputSynthesizer.find("tab-signal-bell", in: try ui.window.window!, within: tab) != nil)
            #expect(tab.naturalWidth - width == 10, "2pt padding, the 16pt icon and a 2pt gap instead of 10pt padding")
            #expect(tab.titleRect.minX - title == 10)
            let icon = try #require(tab.signalIcons.first)
            #expect(icon.layoutFrame.minX - tab.layoutFrame.minX == 3, "the tab's border, then 2pt")
            #expect(try ui.tabView("t-y").signalIcons.isEmpty, "a controlled pane never marks its tab")
            #expect(try ui.headerSignals("y") == ["controlled"])
        }

        @Test func theOutlineCoversThePanesContentInItsKindsColor() throws {
            let ui = UIDriver(layout: Self.pair)
            ui.raise("bell", on: "b")
            let tree = try ui.window.root.docked
            let outline = try #require(try ui.outline("b"))
            #expect(outline.frame == tree.overlay.outlineRect(of: try ui.paneView("b")), "the active outline's box")
            #expect(outline.shown?.kind.id == "bell")
            #expect(try ui.outline("a") == nil)
            // The left edge, on b's own border: the bell's red.
            let rep = try ui.rendering()
            let color = try #require(rep.colorAt(x: Int(outline.frame.minX * 2), y: Int(outline.frame.midY * 2))?.usingColorSpace(.sRGB))
            // Not the exact color, but the bell's red.
            #expect(color.redComponent > 0.9 && color.greenComponent < 0.45 && color.blueComponent < 0.45, "\(color)")
        }

        @Test func aCueOnTheActivePaneReplacesItsAccentOutline() throws {
            SignalPulse.frozenTime = 0
            defer { SignalPulse.frozenTime = nil }
            let ui = UIDriver(layout: Fixture.sideBySide(Fixture.leaf("a"), Fixture.leaf("b"), active: "b"))
            ui.raise("bell", on: "b")
            let outline = try #require(try ui.outline("b"))
            // At the pulse's trough the cue is 30% opaque: what's beneath shows
            // through — b's neutral border, not the accent.
            let rep = try ui.rendering()
            let color = try #require(rep.colorAt(x: Int(outline.frame.minX * 2), y: Int(outline.frame.midY * 2))?.usingColorSpace(.sRGB))
            #expect(color.blueComponent < 0.35, "no accent under the cue: \(color)")
            #expect(color.redComponent > color.blueComponent)
        }

        @Test func clickingASignalledPaneClearsItsBellButNotItsStatus() throws {
            let ui = UIDriver(layout: Self.pair)
            ui.raise("bell", "controlled", on: "b")
            let header = try #require(try ui.paneView("b").header)
            try ui.click(at: NSPoint(x: header.titleRect.minX + 10, y: header.titleRect.midY), in: header)
            #expect(ui.activeNode == "b")
            #expect(try ui.headerSignals("b") == ["controlled"])
            #expect(try ui.outline("b")?.shown?.kind.id == "controlled")
        }

        @Test func clickingItsTabClearsABackgroundPanesBell() throws {
            let ui = UIDriver(layout: Fixture.saved(Fixture.tabsWindow("w", [Fixture.leaf("x"), Fixture.leaf("y")], active: 1)))
            ui.raise("bell", on: "x")
            #expect(try ui.tabView("t-x").signalIcons.count == 1)
            try ui.click(tab: "t-x")
            #expect(ui.activePane == "x")
            #expect(try ui.tabView("t-x").signalIcons.isEmpty)
            #expect(try ui.headerSignals("x").isEmpty)
        }

        @Test func windowFocusDecidesWhetherABellIsLookedAt() throws {
            let ui = UIDriver(layout: Self.pair)
            var focused = true
            ui.renderer.focusOverride = { _ in focused }
            ui.raise("bell", on: "a")
            #expect(try ui.headerSignals("a").isEmpty, "the active pane of a focused window: dropped")
            #expect(ui.renderer.attentionRequests == 0)
            focused = false
            ui.raise("bell", on: "a")
            #expect(try ui.headerSignals("a") == ["bell"], "the user is away")
            #expect(ui.renderer.attentionRequests == 1, "and the Dock bounces")
            ui.raise("bell", on: "b")
            #expect(ui.renderer.attentionRequests == 2)
            focused = true
            try ui.window.windowDidBecomeKey(Notification(name: NSWindow.didBecomeKeyNotification))
            ui.layoutAll()
            #expect(try ui.headerSignals("a").isEmpty, "coming back to the window is looking at its active pane")
            #expect(try ui.headerSignals("b") == ["bell"], "not at the others")
        }

        @Test func attentionFollowsWindowFocusAndTheActivePane() throws {
            let told = Ref<[String]>([])
            final class Watcher: PaneController {
                let view = NSView()
                let id: String
                let told: Ref<[String]>
                init(id: String, told: Ref<[String]>) {
                    self.id = id
                    self.told = told
                }
                func currentConfig() -> JSONValue { .emptyObject }
                func paneDidBecomeAttended() { told.value.append("+\(id)") }
                func paneDidLoseAttention() { told.value.append("-\(id)") }
            }
            let plugin = TestSupport.candidate(TestSupport.manifest("watch", contentTypes: ["watch"])) { context in
                context.register(
                    ContentTypeContribution(id: "watch", displayName: "Watch", icon: .symbol("eye")) {
                        Watcher(id: $0.paneID.rawValue, told: told)
                    })
            }
            let ui = UIDriver(
                layout: Fixture.saved(
                    Fixture.window("w", Fixture.leaf("a", "watch")), Fixture.window("v", Fixture.leaf("b", "watch"))),
                inProcess: [plugin])
            var focused: WindowID?
            ui.renderer.focusOverride = { $0 == focused }
            #expect(told.value.isEmpty, "no focused window: nobody is looked at")
            focused = "w"
            try ui.window("w").windowDidBecomeKey(Notification(name: NSWindow.didBecomeKeyNotification))
            #expect(told.value == ["+a"])
            focused = "v"
            try ui.window("w").windowDidResignKey(Notification(name: NSWindow.didResignKeyNotification))
            try ui.window("v").windowDidBecomeKey(Notification(name: NSWindow.didBecomeKeyNotification))
            #expect(told.value == ["+a", "-a", "+b"], "the second window took the attention")
            focused = nil
            try ui.window("v").windowDidResignKey(Notification(name: NSWindow.didResignKeyNotification))
            #expect(told.value == ["+a", "-a", "+b", "-b"])
        }

        @Test func aPaneIsToldTheThemeAndItsDepthWhenEitherChanges() throws {
            let told = Ref<[String]>([])
            final class Watcher: PaneController {
                let view = NSView()
                let id: String
                let told: Ref<[String]>
                init(id: String, told: Ref<[String]>) {
                    self.id = id
                    self.told = told
                }
                func currentConfig() -> JSONValue { .emptyObject }
                func paneAppearanceDidChange(theme: PaneTheme, depth: Int) {
                    told.value.append("\(id) \(theme.isDark ? "dark" : "light") \(depth)")
                }
            }
            let plugin = TestSupport.candidate(TestSupport.manifest("watch", contentTypes: ["watch"])) { context in
                context.register(
                    ContentTypeContribution(id: "watch", displayName: "Watch", icon: .symbol("eye")) {
                        Watcher(id: $0.paneID.rawValue, told: told)
                    })
            }
            let ui = UIDriver(
                layout: Fixture.saved(
                    Fixture.window("w", Fixture.leaf("a", "watch")), Fixture.window("v", Fixture.leaf("b", "watch"))),
                inProcess: [plugin])
            let depth = try ui.paneView("a", in: ui.window("w")).depth
            #expect(told.value.contains("a dark \(depth)"), "told what it starts with: \(told.value)")
            told.value = []
            var appearance = ui.renderer.baseAppearance
            appearance.theme = .light
            ui.renderer.baseAppearance = appearance
            #expect(Set(told.value) == ["a light \(depth)", "b light \(depth)"], "a theme change reaches every pane once")
            told.value = []
            ui.renderer.baseAppearance = appearance
            #expect(told.value.isEmpty, "nothing changed")
            // Moved into a's tab group: one level deeper.
            #expect(ui.engine.move(.pane("b"), from: "v", to: "w", at: .dock(targetID: "a", zone: .center)))
            ui.layoutAll()
            #expect(try ui.paneView("b", in: ui.window("w")).depth == depth + 1)
            #expect(told.value.contains("b light \(depth + 1)"), "\(told.value)")
        }

        @Test func thePulseFollowsItsKeyframes() {
            #expect(SignalPulse.opacity(at: 0, period: 3) == 0.3)
            #expect(SignalPulse.opacity(at: 0.9, period: 3) == 0.3, "held until 30%")
            #expect(abs(SignalPulse.opacity(at: 1.3, period: 3) - 0.665) < 0.005, "ease-in-out on the way up")
            #expect(abs(SignalPulse.opacity(at: 1.68, period: 3) - 1) < 1e-9, "the peak at 56%")
            #expect(abs(SignalPulse.opacity(at: 2.07, period: 3) - 0.3) < 1e-9, "back down by 69%")
            #expect(abs(SignalPulse.opacity(at: 4.68, period: 3) - 1) < 1e-9, "and again every cycle")
            #expect(abs(SignalPulse.opacity(at: 2.52, period: 4.5) - 1) < 1e-9, "the controlled cue's slower cycle")
            #expect(SignalPulse.easeInOut(0) == 0 && abs(SignalPulse.easeInOut(1) - 1) < 1e-9)
            #expect(abs(SignalPulse.easeInOut(0.5) - 0.5) < 1e-6, "symmetric")
        }

        @Test func aPulsingIconAnimatesFromItsRaiseAndASteadyOneDoesnt() throws {
            let ui = UIDriver(layout: Self.pair, standIns: true)
            ui.raise("bell", on: "b")
            let icon = try #require(try ui.paneView("b").header?.signalIcons.first)
            let pulse = try #require(icon.subviews.first?.layer?.animation(forKey: "pulse") as? CAKeyframeAnimation)
            #expect(pulse.duration == 3 && pulse.repeatCount == .infinity)
            #expect(pulse.beginTime == ui.runtime.signals.raised(on: "b").first?.since, "in phase with the outline and the tab")
            let outline = try #require(try ui.outline("b"))
            #expect(outline.subviews.first?.layer?.animation(forKey: "pulse")?.beginTime == pulse.beginTime)

            // A status indicator has no pulse.
            let steady = try #require(ui.runtime.signals.kind("inert.status"))
            #expect(steady.value.pulse == nil)
            ui.runtime.signals.raise(steady.value.signal, on: "a", by: nil)
            ui.layoutAll()
            let still = try #require(try ui.paneView("a").header?.signalIcons.first)
            #expect(still.subviews.first?.layer?.animation(forKey: "pulse") == nil)
            #expect(still.subviews.first?.layer?.opacity == 1)
        }

        @Test func aDraggedPanesOutlineDimsWithIt() throws {
            let ui = UIDriver(layout: Self.pair)
            ui.raise("controlled", on: "b")
            let controller = try ui.window
            let header = try #require(try ui.paneView("b").header)
            let from = header.convert(NSPoint(x: header.titleRect.minX + 10, y: header.titleRect.midY), to: controller.root)
            ui.renderer.drag.simulate(from: from, to: NSPoint(x: 300, y: 400), in: controller)
            defer { ui.renderer.drag.endSimulation() }
            controller.refreshOverlays()
            #expect(try ui.outline("b")?.alphaValue == 0.4)
        }

        @Test func theDockPreviewCoversASignalledPanesOutline() throws {
            SignalPulse.frozenTime = 2.52  // the controlled cue at its peak
            defer { SignalPulse.frozenTime = nil }
            let ui = UIDriver(layout: Self.pair)
            ui.raise("controlled", on: "b")
            let controller = try ui.window
            let overlay = try ui.window.root.docked.overlay
            let (header, start) = try ui.grip("a")
            // b's left half (the middle of an empty pane fills it instead).
            let (target, point) = try ui.spot("b", 0.1, 0.55)
            ui.renderer.drag.simulate(
                from: try ui.contentPoint(start, in: header), to: try ui.contentPoint(point, in: target), in: controller)
            defer { ui.renderer.drag.endSimulation() }
            #expect(controller.dragVisuals.target == .dock(targetID: "b", zone: .left))
            #expect(try ui.outline("b") != nil)
            let rep = try ui.rendering()
            let layers = try #require(overlay.layer?.sublayers)
            let previewIndex = try #require(layers.firstIndex { $0 === overlay.previewHost.layer })
            let outlinesIndex = try #require(layers.firstIndex { $0 === overlay.outlineHost.layer })
            #expect(previewIndex > outlinesIndex, "the preview over the outlines, as its z-index puts it")
            // The preview's left border lies over the cue's brightest glow, and
            // paints the same with the cue gone.
            let edge = try #require(overlay.previewFrame)
            let (x, y) = (Int(edge.minX.rounded() * 2) + 1, Int(edge.midY * 2))
            let covered = try #require(rep.colorAt(x: x, y: y))
            ui.runtime.signals.withdraw(PaneSignal("controlled"), from: "b", by: nil)
            #expect(try ui.outline("b") == nil)
            let bare = try #require(try ui.rendering().colorAt(x: x, y: y))
            #expect(covered == bare, "\(covered) with the cue under it, \(bare) without")
        }

        @Test func theSettingsPageHasASwitchPerKindThatHidesIt() throws {
            let ui = UIDriver(layout: Self.pair, inProcess: StandIns.candidates())
            ui.raise("bell", on: "b")
            let model = PaneSettingsModel(store: ui.runtime.settings, signals: ui.runtime.signals.settingKinds)
            // Plugins' kinds first, then core's (and its stand-ins).
            #expect(model.signalSwitches.map(\.id) == ["inert.status", "bell", "controlled"])
            #expect(model.signalSwitches.map(\.title) == ["Status indicator", "Bell indicator", "Control indicator"])
            model.signalBinding("bell").wrappedValue = false
            #expect(ui.runtime.settings.panes.disabledSignals == ["bell"])
            ui.layoutAll()
            #expect(try ui.headerSignals("b").isEmpty, "hidden at once")
            #expect(try ui.outline("b") == nil)
            model.signalBinding("bell").wrappedValue = true
            ui.layoutAll()
            #expect(try ui.headerSignals("b") == ["bell"], "kept while hidden")
        }

        @Test func aDisabledPluginsKindsLeaveTheSettingsPage() throws {
            let ui = UIDriver(layout: Self.pair, disabled: ["inert"], standIns: true)
            #expect(!ui.runtime.signals.settingKinds.map(\.id).contains("inert.status"))
        }
    }
}
