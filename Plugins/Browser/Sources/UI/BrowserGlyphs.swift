import AppKit

/// The browser's icons, drawn from SVG paths (16-unit boxes, y down): the globe
/// as a template image core colors, the three nav glyphs drawn into their 13pt
/// box in the toolbar's color.
@MainActor
enum BrowserGlyphs {
    /// The globe: a `circle r 6` stroked 1 (the SVG default: butt caps),
    /// with the equator `M2 8h12` and the meridian
    /// `M8 2c1.8 1.8 2.8 4 2.8 6s-1 4.2-2.8 6c-1.8-1.8-2.8-4-2.8-6s1-4.2 2.8-6z`
    /// stroked 0.9.
    static let browser: NSImage = {
        let image = NSImage(size: NSSize(width: 16, height: 16), flipped: true) { _ in
            NSColor.black.setStroke()
            let circle = NSBezierPath(ovalIn: CGRect(x: 2, y: 2, width: 12, height: 12))
            circle.lineWidth = 1
            circle.stroke()
            let lines = NSBezierPath()
            lines.move(to: CGPoint(x: 2, y: 8))
            lines.line(to: CGPoint(x: 14, y: 8))
            lines.move(to: CGPoint(x: 8, y: 2))
            // c1.8 1.8 2.8 4 2.8 6, then the smooth s-1 4.2 -2.8 6 (its first control point
            // the reflection of the last), and the same mirrored back up.
            lines.curve(to: CGPoint(x: 10.8, y: 8), controlPoint1: CGPoint(x: 9.8, y: 3.8), controlPoint2: CGPoint(x: 10.8, y: 6))
            lines.curve(to: CGPoint(x: 8, y: 14), controlPoint1: CGPoint(x: 10.8, y: 10), controlPoint2: CGPoint(x: 9.8, y: 12.2))
            lines.curve(to: CGPoint(x: 5.2, y: 8), controlPoint1: CGPoint(x: 6.2, y: 12.2), controlPoint2: CGPoint(x: 5.2, y: 10))
            lines.curve(to: CGPoint(x: 8, y: 2), controlPoint1: CGPoint(x: 5.2, y: 6), controlPoint2: CGPoint(x: 6.2, y: 3.8))
            lines.close()
            lines.lineWidth = 0.9
            lines.stroke()
            return true
        }
        image.isTemplate = true
        return image
    }()

    enum Nav {
        case back, forward, refresh
    }

    /// Draws a nav glyph into `rect` (a flipped view's coordinates, 13 × 13) from
    /// the SVG's 16-unit box: back and forward are 1.4 strokes, refresh 1.2, round
    /// caps and joins.
    static func draw(_ glyph: Nav, in rect: CGRect, color: NSColor) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.saveGState()
        context.translateBy(x: rect.minX.rounded(), y: rect.minY.rounded())
        context.scaleBy(x: rect.width / 16, y: rect.height / 16)
        color.setStroke()
        func stroke(_ path: NSBezierPath, width: CGFloat, joins: Bool = true) {
            path.lineWidth = width
            path.lineCapStyle = .round
            if joins { path.lineJoinStyle = .round }
            path.stroke()
        }
        switch glyph {
        case .back:
            // M9.5 3.5L4.5 8l5 4.5
            let path = NSBezierPath()
            path.move(to: CGPoint(x: 9.5, y: 3.5))
            path.line(to: CGPoint(x: 4.5, y: 8))
            path.line(to: CGPoint(x: 9.5, y: 12.5))
            stroke(path, width: 1.4)
        case .forward:
            // M6.5 3.5L11.5 8l-5 4.5
            let path = NSBezierPath()
            path.move(to: CGPoint(x: 6.5, y: 3.5))
            path.line(to: CGPoint(x: 11.5, y: 8))
            path.line(to: CGPoint(x: 6.5, y: 12.5))
            stroke(path, width: 1.4)
        case .refresh:
            // M12.5 8a4.5 4.5 0 1 1-1.4-3.3: the large arc, clockwise on the
            // screen, from the right of the circle round to its upper right.
            let arc = NSBezierPath()
            let end = atan2(4.7 - 8, 11.1 - 8)
            let sweep = end < 0 ? end + 2 * .pi : end
            let steps = 64
            for step in 0...steps {
                let angle = sweep * Double(step) / Double(steps)
                let point = CGPoint(x: 8 + 4.5 * cos(angle), y: 8 + 4.5 * sin(angle))
                if step == 0 { arc.move(to: point) } else { arc.line(to: point) }
            }
            stroke(arc, width: 1.2, joins: false)
            // M11.5 2.5v2.7h-2.7
            let head = NSBezierPath()
            head.move(to: CGPoint(x: 11.5, y: 2.5))
            head.line(to: CGPoint(x: 11.5, y: 5.2))
            head.line(to: CGPoint(x: 8.8, y: 5.2))
            stroke(head, width: 1.2)
        }
        context.restoreGState()
    }
}
