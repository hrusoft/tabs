import AppKit

/// The git tree's own icon, drawn from SVG paths (a 16-unit box, y down) as a
/// template image core colors: sharp at every scale.
@MainActor
enum GitTreeGlyphs {
    /// The git tree: two commits on a trunk (`M5 3.6v8.8`) and a branch off it
    /// (`M5 7.5h3.2a2 2 0 0 0 2-2V4.6`) to a third commit, stroked 1.2 with
    /// round caps; the three commits are 1.6 radius circles stroked 1.1.
    static let gitTree: NSImage = {
        let image = NSImage(size: NSSize(width: 16, height: 16), flipped: true) { _ in
            NSColor.black.setStroke()
            let lines = NSBezierPath()
            lines.move(to: CGPoint(x: 5, y: 3.6))
            lines.line(to: CGPoint(x: 5, y: 12.4))
            lines.move(to: CGPoint(x: 5, y: 7.5))
            lines.line(to: CGPoint(x: 8.2, y: 7.5))
            // Sweep 0 in y-down coordinates: counter-clockwise on screen, the corner turning up.
            lines.appendArc(withCenter: CGPoint(x: 8.2, y: 5.5), radius: 2, startAngle: 90, endAngle: 0, clockwise: true)
            lines.line(to: CGPoint(x: 10.2, y: 4.6))
            lines.lineWidth = 1.2
            lines.lineCapStyle = .round
            lines.stroke()
            for center in [CGPoint(x: 5, y: 2.6), CGPoint(x: 5, y: 13.4), CGPoint(x: 10.2, y: 3.6)] {
                let commit = NSBezierPath(ovalIn: CGRect(x: center.x - 1.6, y: center.y - 1.6, width: 3.2, height: 3.2))
                commit.lineWidth = 1.1
                commit.stroke()
            }
            return true
        }
        image.isTemplate = true
        return image
    }()

    /// The folder (the browse button): an open folder, two 1.1 strokes with
    /// round joins, drawn into `rect` of a flipped view from the SVG's 16-unit box.
    static func drawFolder(in rect: CGRect, color: NSColor) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.saveGState()
        context.translateBy(x: rect.minX.rounded(), y: rect.minY.rounded())
        context.scaleBy(x: rect.width / 16, y: rect.height / 16)
        color.setStroke()
        // M1.8 12.5V4a1 1 0 0 1 1-1h3.1l1.4 1.6h5.9a1 1 0 0 1 1 1v1.1 (the arcs as cubics)
        let k = 0.5523
        let back = NSBezierPath()
        back.move(to: CGPoint(x: 1.8, y: 12.5))
        back.line(to: CGPoint(x: 1.8, y: 4))
        back.curve(to: CGPoint(x: 2.8, y: 3), controlPoint1: CGPoint(x: 1.8, y: 4 - k), controlPoint2: CGPoint(x: 2.8 - k, y: 3))
        back.line(to: CGPoint(x: 5.9, y: 3))
        back.line(to: CGPoint(x: 7.3, y: 4.6))
        back.line(to: CGPoint(x: 13.2, y: 4.6))
        back.curve(to: CGPoint(x: 14.2, y: 5.6), controlPoint1: CGPoint(x: 13.2 + k, y: 4.6), controlPoint2: CGPoint(x: 14.2, y: 5.6 - k))
        back.line(to: CGPoint(x: 14.2, y: 6.7))
        // M1.8 12.5l1.8-5.2h11.1l-1.8 5.2z
        let front = NSBezierPath()
        front.move(to: CGPoint(x: 1.8, y: 12.5))
        front.line(to: CGPoint(x: 3.6, y: 7.3))
        front.line(to: CGPoint(x: 14.7, y: 7.3))
        front.line(to: CGPoint(x: 12.9, y: 12.5))
        front.close()
        for path in [back, front] {
            path.lineWidth = 1.1
            path.lineCapStyle = .round
            path.lineJoinStyle = .round
            path.stroke()
        }
        context.restoreGState()
    }
}
