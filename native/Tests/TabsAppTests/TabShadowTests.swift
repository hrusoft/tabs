import AppKit
import Testing

@testable import Tabs
@testable import TabsCore

extension UITests {
    /// The active tab's drop shadow (`.tab-active`'s `0 7px 10px`): it falls down the bar beside the tab,
    /// and never over the tab's top edge (a negative offset there spilled the blur into the bar above it).
    @MainActor
    @Suite struct TabShadow {
        /// A window's way of drawing: the view's own `draw` into a bitmap, its flip in the context's
        /// transform. (The visual capture renders layers instead, where a flipped context has the other
        /// sign, which is why a shadow that pointed up in a real window still matched Electron there.)
        private func render(_ view: NSView) throws -> NSBitmapImageRep {
            view.layoutSubtreeIfNeeded()
            let rep = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: rep)
            return rep
        }

        private func luminance(_ rep: NSBitmapImageRep, _ point: NSPoint, _ view: NSView) throws -> Double {
            let scale = Double(rep.pixelsWide) / view.bounds.width
            let color = try #require(rep.colorAt(x: Int(point.x * scale), y: Int(point.y * scale))).usingColorSpace(.sRGB)!
            return 0.2126 * color.redComponent + 0.7152 * color.greenComponent + 0.0722 * color.blueComponent
        }

        @Test func theShadowFallsBesideTheTabAndNotOverItsTop() throws {
            let ui = UIDriver(layout: Fixture.saved(Fixture.tabsWindow("w", [Fixture.leaf("a"), Fixture.leaf("b")], active: 1)))
            let tab = try ui.tabView("t-b")
            #expect(tab.isActive)
            // The bar paints the background the shadow falls on; the strip over it is transparent.
            let strip = try #require(tab.strip.superview)
            let rep = try render(strip)
            let frame = tab.convert(tab.bounds, to: strip)
            // The bar as the shadow doesn't reach it: the empty strip to the tab's right, at the same height.
            let bar = try luminance(rep, NSPoint(x: strip.bounds.maxX - 4, y: frame.minY + 1), strip)
            #expect(bar > 0.05, "sampling the bar, not a void")

            // Over the tab's top edge: the margin above its box. An upward shadow darkens it by a third;
            // a downward one only lets a little of its blur (σ 5pt, Electron's too) reach past the edge.
            let above = try luminance(rep, NSPoint(x: frame.midX, y: frame.minY + 0.5), strip)
            #expect(above >= bar * 0.85, "no shadow over the tab's top: \(above) against the bar's \(bar)")

            // Beside the tab, near its foot: where a shadow cast down pools.
            let beside = try luminance(rep, NSPoint(x: frame.minX - 3, y: frame.maxY - 6), strip)
            #expect(beside <= bar * 0.9, "the shadow falls down the bar beside the tab: \(beside) against the bar's \(bar)")
            #expect(beside < above, "it is stronger beside the tab's foot than over its head")
        }
    }
}
