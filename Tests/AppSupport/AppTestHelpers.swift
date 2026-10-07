import AppKit
import Testing

/// Renders `view` as it would draw on screen (a page must draw something) and, with
/// TABS_SNAPSHOT_DIR set, keeps the picture there as `<name>.png`. SwiftUI builds its
/// accessibility tree only for an assistive client, so a form's texts can't be read
/// back in-process; they're checked through the data the view is built from.
@MainActor
func snapshot(_ view: NSView, _ name: String) throws {
    view.layoutSubtreeIfNeeded()
    runLoopTurns()
    view.layoutSubtreeIfNeeded()
    let image = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
    if let window = view.window {
        // A hosting view's backing store starts transparent: fill it the way the window would.
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: image)
        view.effectiveAppearance.performAsCurrentDrawingAppearance {
            window.backgroundColor.setFill()
            view.bounds.fill()
        }
        NSGraphicsContext.restoreGraphicsState()
    }
    view.cacheDisplay(in: view.bounds, to: image)
    #expect(image.pixelsHigh > 100, "\(name) has a body")
    if let directory = ProcessInfo.processInfo.environment["TABS_SNAPSHOT_DIR"] {
        try image.representation(using: .png, properties: [:])?.write(to: URL(filePath: directory).appending(path: "\(name).png"))
    }
}

/// A few short turns of the main run loop. Each one reaches the point where the loop would
/// wait, where SwiftUI applies its pending updates and Core Animation commits the layers'
/// contents: what a settle needs, without waiting a fixed while.
@MainActor
func runLoopTurns(_ count: Int = 2) {
    for _ in 0..<count { RunLoop.main.run(until: Date().addingTimeInterval(0.005)) }
}

extension NSView {
    /// Every descendant, depth first.
    var allSubviews: [NSView] { subviews.flatMap { [$0] + $0.allSubviews } }
}

/// A mutable value closures can share.
@MainActor
final class Ref<Value> {
    var value: Value
    init(_ value: Value) { self.value = value }
}
