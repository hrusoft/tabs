import AppKit
import CoreText

/// The browser chrome's lengths, in points.
enum BrowserMetrics {
    /// The header's content height (24, its border below): the slot's height.
    static let barHeight = 24.0
    /// The gap between the header's children.
    static let gap = 8.0
    /// A nav button: a 13pt icon padded 2 above and below, 5 either side.
    static let iconSize = 13.0
    static let buttonSize = CGSize(width: 23, height: 17)
    /// The address bar: 20 tall with a 1pt border, radius 3.
    static let barFieldHeight = 20.0
    static let borderWidth = 1.0
    static let radius = 3.0
    /// The title segment: at most 30% of the bar, padded 2 by 6, a 1pt border at its right.
    static let segmentMaxFraction = 0.3
    static let segmentPaddingX = 6.0
    static let segmentPaddingY = 2.0
    /// The segment's line height.
    static let segmentLineHeight = 16.0
    /// The input's padding, 2 by 6.
    static let inputPaddingX = 6.0
    static let inputPaddingY = 2.0
    /// A disabled button is drawn at this opacity.
    static let disabledOpacity = 0.35
}

/// Text laid out on a line box of the font's rounded ascent plus rounded
/// descent, the baseline `ascent` below its top, drawn at a fractional x on a
/// whole-point baseline.
struct BrowserText: @unchecked Sendable {  // NSFont is immutable
    let font: NSFont

    static let ui12 = BrowserText(font: .systemFont(ofSize: 12))

    var ascent: Double { Double(CTFontGetAscent(font)).rounded() }
    var descent: Double { Double(CTFontGetDescent(font)).rounded() }
    var lineHeight: Double { ascent + descent }

    /// For an explicit line height: the half-leading above the font's line box,
    /// floored (a 15pt line in 16 sits at the top, not 0.5 down).
    func halfLeading(in lineHeight: Double) -> Double { ((lineHeight - self.lineHeight) / 2).rounded(.down) }

    func width(_ string: String) -> Double {
        guard !string.isEmpty else { return 0 }
        return Double(CTLineGetTypographicBounds(line(string, color: .black), nil, nil, nil))
    }

    func line(_ string: String, color: NSColor) -> CTLine {
        CTLineCreateWithAttributedString(NSAttributedString(string: string, attributes: [.font: font, .foregroundColor: color]))
    }

    /// `string` cut to `width` with an ellipsis: the longest prefix that fits
    /// with "…" after it, spaces kept.
    func truncated(_ string: String, to width: Double) -> String {
        let room = width - self.width("…")
        var prefix = ""
        for character in string {
            let next = prefix + String(character)
            guard self.width(next) <= room + 0.01 else { break }
            prefix = next
        }
        return prefix + "…"
    }

    /// Draws `string` with its baseline at `origin` (a flipped context). The
    /// baseline lands on a whole point. With `maxWidth`, truncated with an
    /// ellipsis.
    func draw(_ string: String, at origin: CGPoint, color: NSColor, maxWidth: Double? = nil) {
        guard !string.isEmpty, let context = NSGraphicsContext.current?.cgContext else { return }
        var text = string
        if let maxWidth, width(string) > maxWidth + 0.01 { text = truncated(string, to: maxWidth) }
        context.saveGState()
        context.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        context.textPosition = CGPoint(x: origin.x, y: origin.y.rounded())
        CTLineDraw(line(text, color: color), context)
        context.restoreGState()
    }
}

/// A view whose origin is top-left, like the page.
class BrowserFlippedView: NSView {
    override var isFlipped: Bool { true }
}

/// `x` snapped as a painted box edge is: to a whole point, round half up.
func snap(_ x: Double) -> Double { (x + 0.5).rounded(.down) }

func snapped(_ rect: CGRect) -> CGRect {
    let x0 = snap(rect.minX)
    let y0 = snap(rect.minY)
    return CGRect(x: x0, y: y0, width: snap(rect.maxX) - x0, height: snap(rect.maxY) - y0)
}
