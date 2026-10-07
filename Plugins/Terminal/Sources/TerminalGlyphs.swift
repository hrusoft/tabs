import AppKit

/// The terminal's own icons, drawn from SVG paths (16-unit boxes, y down) as
/// template images core colors: sharp at every scale.
@MainActor
enum TerminalGlyphs {
    /// The bell: `M8 2.5c-2 0-3 1.6-3 4v1.3c0 .9-.3 1.7-.9 2.4l-.6.7h9l-.6-.7c-.6-.7-.9-1.5-.9-2.4V6.5c0-2.4-1-4-3-4z`
    /// and the clapper `M6.5 12.3a1.5 1.5 0 0 0 3 0`, stroked 1.2, round caps and joins.
    static let bell: NSImage = glyph {
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
        stroke(body, width: 1.2)
        // Sweep 0 in y-down coordinates: through the bottom, the cup under the bell.
        let clapper = NSBezierPath()
        clapper.appendArc(withCenter: CGPoint(x: 8, y: 12.3), radius: 1.5, startAngle: 180, endAngle: 0, clockwise: true)
        stroke(clapper, width: 1.2)
    }

    /// The terminal: the screen `<rect x="1.5" y="2.5" width="13" height="11" rx="1.5">`
    /// stroked 1 (the SVG's default), and the prompt `M4.5 6l2.5 2-2.5 2M8.5 10h3` stroked 1.2.
    static let terminal: NSImage = glyph {
        stroke(NSBezierPath(roundedRect: CGRect(x: 1.5, y: 2.5, width: 13, height: 11), xRadius: 1.5, yRadius: 1.5), width: 1)
        let prompt = NSBezierPath()
        prompt.move(to: CGPoint(x: 4.5, y: 6))
        prompt.line(to: CGPoint(x: 7, y: 8))
        prompt.line(to: CGPoint(x: 4.5, y: 10))
        prompt.move(to: CGPoint(x: 8.5, y: 10))
        prompt.line(to: CGPoint(x: 11.5, y: 10))
        stroke(prompt, width: 1.2)
    }

    /// Clear scrollback: three scrollback rows tapering off
    /// (`M2 3h9M2 6.5h6.5M2 10h4`), swept by a small wipe mark
    /// (`M10.5 11.5l3 3M13.5 11.5l-3 3`), stroked 1, round caps — not core's
    /// Clear pane eraser: this clears only the scrollback.
    static let clearScrollback: NSImage = glyph {
        let rows = NSBezierPath()
        for (y, length) in [(3.0, 9.0), (6.5, 6.5), (10.0, 4.0)] {
            rows.move(to: CGPoint(x: 2, y: y))
            rows.line(to: CGPoint(x: 2 + length, y: y))
        }
        stroke(rows, width: 1)
        let wipe = NSBezierPath()
        wipe.move(to: CGPoint(x: 10.5, y: 11.5))
        wipe.line(to: CGPoint(x: 13.5, y: 14.5))
        wipe.move(to: CGPoint(x: 13.5, y: 11.5))
        wipe.line(to: CGPoint(x: 10.5, y: 14.5))
        stroke(wipe, width: 1)
    }

    nonisolated private static func stroke(_ path: NSBezierPath, width: CGFloat) {
        path.lineWidth = width
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        path.stroke()
    }

    /// A 16-unit template image drawn in SVG coordinates (y down), at any scale.
    nonisolated private static func glyph(_ draw: @escaping @Sendable () -> Void) -> NSImage {
        let image = NSImage(size: NSSize(width: 16, height: 16), flipped: true) { _ in
            NSColor.black.setStroke()
            draw()
            return true
        }
        image.isTemplate = true
        return image
    }
}
