#if DEBUG
import AppKit
import TabsCore
import TabsPluginSDK

/// A stand-in for the Electron app's bell, declared as a core kind (the
/// terminal plugin declares the real one): the visual comparison and the
/// tests check the signal mechanism's look and behaviour against Electron's
/// bell (`TerminalRenderer.tsx` → `bellStore`), with its glyph from
/// `icons.tsx`. The controlled-pane cue is core's own (`ControlledSignal`).
@MainActor
enum SignalFixtures {
    static let bellID = "bell"
    static let controlledID = ControlledSignal.id

    /// The terminal's bell: asks for attention until seen, marks the tabs
    /// holding the pane, bounces the Dock; a 3s pulse in the alert color.
    static var bell: PaneSignalContribution {
        PaneSignalContribution(
            id: bellID, label: "Bell", icon: .image(bellGlyph), color: .alert, pulse: 3, marksTabs: true, lifetime: .untilSeen,
            requestsAttention: true,
            setting: .init(
                title: "Bell indicator", detail: "Pulse a bell icon and bounce the Dock icon when a pane signals for attention."))
    }

    /// Declares the bell (once) as a core kind; `controlled` always comes after
    /// it, as its rule does in global.css, so the controlled outline wins on a
    /// pane with both.
    static func declare(in signals: PaneSignals) {
        if signals.kind(bell.id) == nil { signals.declare(bell) }
    }

    /// `BellIcon`: `M8 2.5c-2 0-3 1.6-3 4v1.3c0 .9-.3 1.7-.9 2.4l-.6.7h9l-.6-.7c-.6-.7-.9-1.5-.9-2.4V6.5c0-2.4-1-4-3-4z`
    /// and the clapper `M6.5 12.3a1.5 1.5 0 0 0 3 0`, stroked 1.2, round caps and joins.
    static let bellGlyph: NSImage = glyph { _ in
        let body = NSBezierPath()
        body.move(to: CGPoint(x: 8, y: 2.5))
        body.curve(to: CGPoint(x: 5, y: 6.5), controlPoint1: CGPoint(x: 6, y: 2.5), controlPoint2: CGPoint(x: 5, y: 4.1))
        body.line(to: CGPoint(x: 5, y: 7.8))
        body.curve(to: CGPoint(x: 4.1, y: 10.2), controlPoint1: CGPoint(x: 5, y: 8.7), controlPoint2: CGPoint(x: 4.7, y: 9.5))
        body.line(to: CGPoint(x: 3.5, y: 10.9))
        body.line(to: CGPoint(x: 12.5, y: 10.9))
        body.line(to: CGPoint(x: 11.9, y: 10.2))
        body.curve(to: CGPoint(x: 11, y: 7.8), controlPoint1: CGPoint(x: 11.3, y: 9.5), controlPoint2: CGPoint(x: 11, y: 8.7))
        body.line(to: CGPoint(x: 11, y: 6.5))
        body.curve(to: CGPoint(x: 8, y: 2.5), controlPoint1: CGPoint(x: 11, y: 4.1), controlPoint2: CGPoint(x: 10, y: 2.5))
        body.close()
        stroke(body, round: true)
        // Sweep 0 in y-down coordinates: through the bottom, the cup under the bell.
        let clapper = NSBezierPath()
        clapper.appendArc(withCenter: CGPoint(x: 8, y: 12.3), radius: 1.5, startAngle: 180, endAngle: 0, clockwise: true)
        stroke(clapper, round: true)
    }

    private static func stroke(_ path: NSBezierPath, round: Bool) {
        path.lineWidth = 1.2
        if round {
            path.lineCapStyle = .round
            path.lineJoinStyle = .round
        }
        path.stroke()
    }

    /// A 16-unit template image drawn in SVG coordinates (y down), at any scale.
    private static func glyph(_ draw: @escaping (CGRect) -> Void) -> NSImage {
        let image = NSImage(size: NSSize(width: 16, height: 16), flipped: true) { rect in
            NSColor.black.setStroke()
            NSColor.black.setFill()
            draw(rect)
            return true
        }
        image.isTemplate = true
        return image
    }
}
#endif
