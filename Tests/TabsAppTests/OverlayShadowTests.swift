import AppKit
import Testing

@testable import Tabs
@testable import TabsCore

extension UITests {
    /// Overlays' drop shadows are their layers', and AppKit resets a view layer's shadow before the
    /// view is shown: one set in `init` is gone by the time it draws (the header menu and the tab
    /// ghost both lost theirs that way). Set in `layout()`, it survives.
    @MainActor
    @Suite struct OverlayShadow {
        @Test func theMenuAndGhostKeepTheirShadowsOnceShown() throws {
            let ui = UIDriver(layout: Fixture.saved(Fixture.window("w", Fixture.leaf("a"))))
            let controller = try #require(ui.renderer.windows.first)
            let ghost = DragGhostView()
            ghost.update(title: "New Tab", theme: .light)
            controller.root.overlay.addSubview(ghost)
            ghost.frame = CGRect(x: 20, y: 20, width: 100, height: 22)
            let menu = try ui.control(HeaderAction.splitHorizontal.accessibilityID, of: "a")
            try ui.hover(at: NSPoint(x: menu.bounds.midX, y: menu.bounds.midY), in: menu)
            let dropdown = try #require(HeaderMenu.openDropdown, "the menu didn't open")
            ui.layoutAll()
            controller.window?.displayIfNeeded()

            for (name, view, radius) in [("tab ghost", ghost, 12.0), ("header menu", dropdown, 24)] as [(String, NSView, Double)] {
                let layer = try #require(view.layer)
                #expect(layer.shadowOpacity == 1, "\(name): no shadow")
                #expect(Double(layer.shadowRadius) == radius, "\(name): shadow radius \(layer.shadowRadius)")
                #expect(layer.shadowColor != nil, "\(name): no shadow color")
            }
            ui.unhover(controller)
        }
    }
}
