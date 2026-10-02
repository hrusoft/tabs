import AppKit
import CoreText

/// The chrome's lengths — the Electron app's stylesheet (`global.css`), in
/// points (CSS pixels).
enum Metrics {
    /// The docked root's bar: the window's title bar (`--window-titlebar-height`).
    static let titlebarHeight: CGFloat = 30
    /// How far the root bar's content starts in, clear of the traffic lights.
    static let trafficLightGutter: CGFloat = 89
    /// Where the traffic lights sit (Electron's `trafficLightPosition`).
    static let trafficLightOrigin = CGPoint(x: 14, y: 9)
    /// A tab's strip, whatever bar holds it (`--tab-strip-height`).
    static let tabStripHeight: CGFloat = 24
    /// Every other pane's chrome bar (`--chrome-bottom`).
    static let chromeBottom: CGFloat = 24
    /// A bar's left padding at `depth` (`--depth-indent`).
    static func depthIndent(_ depth: Int) -> CGFloat { CGFloat(depth + 1) * 7 }

    static let barGap: CGFloat = 8
    static let barPaddingRight: CGFloat = 4
    static let chromeFontSize: CGFloat = 11

    static let tabGap: CGFloat = 2
    static let tabMarginTop: CGFloat = 3
    static let tabActiveMarginTop: CGFloat = 2
    static let tabMaxWidth: CGFloat = 220
    static let tabPaddingLeft: CGFloat = 10
    static let tabPaddingRight: CGFloat = 2
    static let tabInnerGap: CGFloat = 2
    static let tabCornerRadius: CGFloat = 3
    static let tabCloseFontSize: CGFloat = 12
    static let tabCloseHorizontalPadding: CGFloat = 4
    static let tabCloseVerticalPadding: CGFloat = 1

    /// `.pane-header-button`: padding 2px 5px around a 13px icon.
    static let headerButtonIcon: CGFloat = 13
    static let headerButtonSize = CGSize(width: 23, height: 17)
    static let headerControlsGap: CGFloat = 2
    /// The new-tab "+" after the last tab: a 10px icon in the same padding.
    static let newTabButtonSize = CGSize(width: 20, height: 14)
    /// The root bar's Settings button: 15px icon, 4px padding, 6px margin right.
    static let rootIconButtonSize = CGSize(width: 23, height: 23)
    static let rootIconButtonMarginRight: CGFloat = 6

    static let dropIndicatorSize = CGSize(width: 2, height: 15)
    static let emptyButtonSize: CGFloat = 32
    static let emptyButtonRadius: CGFloat = 5
    static let floatingCornerRadius: CGFloat = 6
    static let floatingResizeEdge: CGFloat = 5
    static let floatingResizeCorner: CGFloat = 8
    /// Separators take no space; this much around one grabs it.
    static let separatorHitSize: CGFloat = 10
}

/// Text drawn the way the Electron app's chrome lays it out: a line box of
/// the font's rounded ascent plus descent, the baseline `ascent` below its top.
struct ChromeText {
    let font: NSFont

    init(size: CGFloat, weight: NSFont.Weight = .regular, tabularNumbers: Bool = false) {
        font = tabularNumbers ? .monospacedDigitSystemFont(ofSize: size, weight: weight) : .systemFont(ofSize: size, weight: weight)
    }

    var ascent: CGFloat { CGFloat(CTFontGetAscent(font).rounded()) }
    var descent: CGFloat { CGFloat(CTFontGetDescent(font).rounded()) }
    var lineHeight: CGFloat { ascent + descent + CGFloat(CTFontGetLeading(font).rounded()) }

    /// The baseline for a line box centered in `height` from `top`.
    func baseline(centeredIn height: CGFloat, top: CGFloat = 0) -> CGFloat {
        top + (height - lineHeight) / 2 + ascent
    }

    func width(_ string: String) -> CGFloat {
        CGFloat(CTLineGetTypographicBounds(line(string, color: .black), nil, nil, nil))
    }

    func line(_ string: String, color: NSColor) -> CTLine {
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        return CTLineCreateWithAttributedString(NSAttributedString(string: string, attributes: attributes))
    }

    /// `string` cut to `width` as CSS `text-overflow: ellipsis` cuts it: the
    /// longest prefix that fits with "…" after it, spaces included.
    func truncated(_ string: String, to width: CGFloat) -> String {
        let room = width - self.width("…")
        var prefix = ""
        for character in string {
            let next = prefix + String(character)
            guard self.width(next) <= room + 0.01 else { break }
            prefix = next
        }
        return prefix + "…"
    }

    /// Draws `string` with its baseline at `origin` in a flipped view,
    /// truncated with an ellipsis to `maxWidth`.
    func draw(_ string: String, at origin: CGPoint, color: NSColor, maxWidth: CGFloat? = nil) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        var line = line(string, color: color)
        if let maxWidth, CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil)) > maxWidth + 0.01 {
            line = self.line(truncated(string, to: maxWidth), color: color)
        }
        context.saveGState()
        context.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        // Chromium puts a baseline on a whole CSS pixel.
        context.textPosition = CGPoint(x: origin.x, y: origin.y.rounded())
        CTLineDraw(line, context)
        context.restoreGState()
    }
}

/// The chrome's icons, drawn from the Electron app's SVGs (`icons.tsx`, a
/// 16-unit view box) at any size, in the current color.
enum ChromeIcon {
    case newTab, plus, splitHorizontal, splitVertical, newUnpinnedTab, clearPane, closePane, settings, wrapWindow, coffeeCup

    /// Draws the icon into `rect` of a flipped view.
    func draw(in rect: CGRect, color: NSColor) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.saveGState()
        // Chromium paints an SVG at a whole CSS pixel.
        context.translateBy(x: rect.minX.rounded(), y: rect.minY.rounded())
        context.scaleBy(x: rect.width / 16, y: rect.height / 16)
        color.setStroke()
        color.setFill()
        func stroke(_ path: NSBezierPath, width: CGFloat = 1, round: Bool = false) {
            path.lineWidth = width
            if round {
                path.lineCapStyle = .round
                path.lineJoinStyle = .round
            }
            path.stroke()
        }
        func box(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ r: CGFloat) -> NSBezierPath {
            NSBezierPath(roundedRect: CGRect(x: x, y: y, width: w, height: h), xRadius: r, yRadius: r)
        }
        func lines(_ segments: [(CGFloat, CGFloat, CGFloat, CGFloat)]) -> NSBezierPath {
            let path = NSBezierPath()
            for (x1, y1, x2, y2) in segments {
                path.move(to: CGPoint(x: x1, y: y1))
                path.line(to: CGPoint(x: x2, y: y2))
            }
            return path
        }
        switch self {
        case .newTab:
            stroke(box(1.5, 2.5, 13, 11, 1.5))
            stroke(lines([(8, 6, 8, 10), (6, 8, 10, 8)]), width: 1.2, round: true)
        case .plus:
            stroke(lines([(8, 3.5, 8, 12.5), (3.5, 8, 12.5, 8)]), width: 2, round: true)
        case .splitHorizontal:
            stroke(box(1.5, 2.5, 5.5, 11, 1))
            stroke(box(9, 2.5, 5.5, 11, 1))
        case .splitVertical:
            stroke(box(2.5, 1.5, 11, 5.5, 1))
            stroke(box(2.5, 9, 11, 5.5, 1))
        case .newUnpinnedTab:
            // M7 3H3.5A1.5 1.5 0 0 0 2 4.5v8A1.5 1.5 0 0 0 3.5 14h8a1.5 1.5 0 0 0 1.5-1.5V9
            let k: CGFloat = 0.5523 * 1.5
            let frame = NSBezierPath()
            frame.move(to: CGPoint(x: 7, y: 3))
            frame.line(to: CGPoint(x: 3.5, y: 3))
            frame.curve(to: CGPoint(x: 2, y: 4.5), controlPoint1: CGPoint(x: 3.5 - k, y: 3), controlPoint2: CGPoint(x: 2, y: 4.5 - k))
            frame.line(to: CGPoint(x: 2, y: 12.5))
            frame.curve(to: CGPoint(x: 3.5, y: 14), controlPoint1: CGPoint(x: 2, y: 12.5 + k), controlPoint2: CGPoint(x: 3.5 - k, y: 14))
            frame.line(to: CGPoint(x: 11.5, y: 14))
            frame.curve(to: CGPoint(x: 13, y: 12.5), controlPoint1: CGPoint(x: 11.5 + k, y: 14), controlPoint2: CGPoint(x: 13, y: 12.5 + k))
            frame.line(to: CGPoint(x: 13, y: 9))
            stroke(frame, round: true)
            let arrow = NSBezierPath()
            arrow.move(to: CGPoint(x: 9.5, y: 2))
            arrow.line(to: CGPoint(x: 14, y: 2))
            arrow.line(to: CGPoint(x: 14, y: 6.5))
            arrow.move(to: CGPoint(x: 14, y: 2))
            arrow.line(to: CGPoint(x: 8, y: 8))
            stroke(arrow, round: true)
        case .clearPane:
            let eraser = NSBezierPath()
            eraser.move(to: CGPoint(x: 11, y: 1))
            eraser.line(to: CGPoint(x: 14.5, y: 4.5))
            eraser.line(to: CGPoint(x: 6, y: 13.5))
            eraser.line(to: CGPoint(x: 2, y: 13.5))
            eraser.line(to: CGPoint(x: 2, y: 10))
            eraser.close()
            eraser.lineJoinStyle = .round
            eraser.lineWidth = 1
            eraser.stroke()
            let edge = lines([(9, 4, 12.5, 7.5)])
            edge.lineCapStyle = .round
            edge.lineWidth = 1
            edge.stroke()
        case .closePane:
            stroke(lines([(2.5, 2.5, 13.5, 13.5), (13.5, 2.5, 2.5, 13.5)]), width: 1.4, round: true)
        case .settings:
            let ring = NSBezierPath(ovalIn: CGRect(x: 8 - 3.4, y: 8 - 3.4, width: 6.8, height: 6.8))
            ring.lineWidth = 2
            ring.stroke()
            for angle in stride(from: 0.0, to: 360, by: 45) {
                context.saveGState()
                context.translateBy(x: 8, y: 8)
                context.rotate(by: CGFloat(angle) * .pi / 180)
                context.translateBy(x: -8, y: -8)
                NSBezierPath(rect: CGRect(x: 7.3, y: 1, width: 1.4, height: 3.6)).fill()
                context.restoreGState()
            }
        case .coffeeCup:
            // icons.tsx's CoffeeCupIcon: a rounded-bottom cup, an open handle,
            // and three short S-curves of steam rising off the rim.
            let cup = NSBezierPath()
            cup.move(to: CGPoint(x: 3.5, y: 7))
            cup.line(to: CGPoint(x: 10.5, y: 7))
            cup.line(to: CGPoint(x: 10.5, y: 11.5))
            cup.appendArc(withCenter: CGPoint(x: 8.5, y: 11.5), radius: 2, startAngle: 0, endAngle: 90, clockwise: false)
            cup.line(to: CGPoint(x: 5.5, y: 13.5))
            cup.appendArc(withCenter: CGPoint(x: 5.5, y: 11.5), radius: 2, startAngle: 90, endAngle: 180, clockwise: false)
            cup.close()
            cup.lineJoinStyle = .round
            cup.lineWidth = 1.2
            cup.stroke()
            let handle = NSBezierPath()
            handle.move(to: CGPoint(x: 10.5, y: 8.2))
            handle.curve(to: CGPoint(x: 13.1, y: 10.3), controlPoint1: CGPoint(x: 12.1, y: 8.2), controlPoint2: CGPoint(x: 13.1, y: 9.1))
            // `S`: the first control point reflects the last one about the join.
            handle.curve(to: CGPoint(x: 10.5, y: 12.4), controlPoint1: CGPoint(x: 13.1, y: 11.5), controlPoint2: CGPoint(x: 12.1, y: 12.4))
            stroke(handle, width: 1.2, round: true)
            for x: CGFloat in [4.5, 7.5, 10.5] {
                let steam = NSBezierPath()
                steam.move(to: CGPoint(x: x, y: 6))
                steam.curve(to: CGPoint(x: x + 0.9, y: 4), controlPoint1: CGPoint(x: x, y: 5), controlPoint2: CGPoint(x: x + 0.9, y: 5))
                steam.curve(to: CGPoint(x: x, y: 2), controlPoint1: CGPoint(x: x + 0.9, y: 3), controlPoint2: CGPoint(x: x, y: 3))
                steam.lineCapStyle = .round
                steam.lineWidth = 1
                steam.stroke()
            }
        case .wrapWindow:
            stroke(box(1.5, 2.5, 13, 11, 1.5))
            color.withAlphaComponent(color.alphaComponent * 0.4).setFill()
            box(2.5, 3.5, 5, 2.5, 0.5).fill()
            stroke(lines([(1.5, 6.5, 14.5, 6.5)]))
        }
        context.restoreGState()
    }
}

extension CGRect {
    /// The rect with each edge on a whole point: where Chromium paints a box
    /// laid out at fractional coordinates (its text keeps the fraction).
    var snapped: CGRect {
        let left = (minX + 0.0001).rounded()
        let top = (minY + 0.0001).rounded()
        return CGRect(x: left, y: top, width: (maxX + 0.0001).rounded() - left, height: (maxY + 0.0001).rounded() - top)
    }
}

/// A flipped, layer-backed view: every chrome view measures from the top
/// left, as the Electron app's CSS does.
///
/// Chrome is laid out the way Chromium lays out CSS: at fractional
/// positions, carried down unsnapped (`layoutFrame`, in the window's content
/// coordinates); only what's painted snaps — a view's frame and every box it
/// fills land on whole points, while text keeps its fractional x.
class FlippedView: NSView {
    override var isFlipped: Bool { true }

    /// Where layout put this view, unsnapped, in the window's content coordinates.
    var layoutFrame: CGRect = .zero

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    /// The layout size (unsnapped).
    var layoutSize: CGSize { layoutFrame.size }

    /// How far the unsnapped origin sits from the painted one: a layout-local
    /// point plus this is where it's drawn.
    var layoutOffset: CGPoint {
        let painted = layoutFrame.snapped.origin
        return CGPoint(x: layoutFrame.minX - painted.x, y: layoutFrame.minY - painted.y)
    }

    /// A layout-local point, in drawing coordinates (fraction kept: text).
    func drawn(_ point: CGPoint) -> CGPoint { CGPoint(x: point.x + layoutOffset.x, y: point.y + layoutOffset.y) }

    /// A layout-local rect, in drawing coordinates (fraction kept).
    func drawn(_ rect: CGRect) -> CGRect { rect.offsetBy(dx: layoutOffset.x, dy: layoutOffset.y) }

    /// A layout-local box as it's painted: its edges on whole points of the window.
    func painted(_ rect: CGRect) -> CGRect {
        let painted = layoutFrame.snapped.origin
        return rect.offsetBy(dx: layoutFrame.minX, dy: layoutFrame.minY).snapped.offsetBy(dx: -painted.x, dy: -painted.y)
    }

    /// Lays `child` out at `rect`, in this view's layout coordinates.
    func place(_ child: FlippedView, _ rect: CGRect) {
        let absolute = rect.offsetBy(dx: layoutFrame.minX, dy: layoutFrame.minY)
        let painted = layoutFrame.snapped.origin
        if child.layoutFrame != absolute {
            child.layoutFrame = absolute
            child.needsLayout = true
            child.needsDisplay = true
        }
        let frame = absolute.snapped.offsetBy(dx: -painted.x, dy: -painted.y)
        if child.frame != frame { child.frame = frame }
    }

    /// The whole of this view, in its layout coordinates.
    var layoutBounds: CGRect { CGRect(origin: .zero, size: layoutFrame.size) }
}
