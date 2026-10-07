import AppKit
import CoreText
import TabsPluginSDK

/// The git tree's lengths, in points.
enum GitTreeMetrics {
    /// Row height.
    static let rowHeight = 24.0
    /// Horizontal distance between lane centres.
    static let laneWidth = 12.0
    static let dotRadius = 3.5
    static let headRingRadius = 5.0
    static let lineWidth = 1.5

    static let rowGap = 8.0
    static let rowPaddingLeft = 6.0
    static let rowPaddingRight = 8.0

    /// The toolbar's height: the header bar's content (24, its border below).
    static let toolbarHeight = 24.0
    static let toolbarGap = 8.0
    static let fieldHeight = 20.0

    static let pillPadding = 5.0
    static let pillMarginRight = 6.0
    static let pillLineHeight = 14.0
    static let pillRadius = 8.0

    static let loadMoreMargin = (vertical: 6.0, horizontal: 8.0)
    static let loadMorePadding = 4.0

    static let detailPadding = (vertical: 8.0, horizontal: 10.0)
    static let fieldsGap = (row: 2.0, column: 10.0)
    static let fileLineHeight = 17.0
    static let fileStatWidth = 84.0
    static let fileGap = 8.0
    static let fileStatGap = 5.0

    static let noticePadding = 16.0
    static let noticeParagraphGap = 6.0

    static let collapsedDividerHeight = 8.0
    static let gripSize = CGSize(width: 24, height: 2)
}

extension PaneTheme {
    /// The selected row's fill: the accent at 18%.
    var selection: NSColor { accent.withAlphaComponent(0.18) }
}

/// The git tree's own colors — content, not chrome: the same in both themes.
enum GitTreeColors {
    /// The lane palette, cycling by lane index.
    static let lanes: [NSColor] = [0x4f8cff, 0xe0a44a, 0x59b871, 0xc76fd0, 0x46bcc4, 0xe0705a].map { NSColor.hex($0) }
    static func lane(_ index: Int) -> NSColor { lanes[index % lanes.count] }
    /// Diff stats' own colors, not borrowed lanes.
    static let insertions = NSColor.hex(0x59b871)
    static let deletions = NSColor.hex(0xe0705a)
}

/// Text in a line box of the font's rounded ascent plus rounded descent, the
/// baseline `ascent` below its top, drawn at a fractional x on a whole-point
/// baseline.
struct GitText: @unchecked Sendable {  // NSFont is immutable
    let font: NSFont

    static let ui12 = GitText(font: .systemFont(ofSize: 12))
    static let ui11 = GitText(font: .systemFont(ofSize: 11))
    static let ui10 = GitText(font: .systemFont(ofSize: 10))
    /// Monospaced text, in Menlo.
    static let mono11 = GitText(font: NSFont(name: "Menlo-Regular", size: 11) ?? .monospacedSystemFont(ofSize: 11, weight: .regular))
    static let italic12 = GitText(
        font: NSFont(descriptor: NSFont.systemFont(ofSize: 12).fontDescriptor.withSymbolicTraits(.italic), size: 12)
            ?? .systemFont(ofSize: 12))

    var ascent: Double { Double(CTFontGetAscent(font)).rounded() }
    var descent: Double { Double(CTFontGetDescent(font)).rounded() }
    var lineHeight: Double { ascent + descent }

    /// For an explicit line height: the half-leading above the font's line box.
    func halfLeading(in lineHeight: Double) -> Double { (lineHeight - self.lineHeight) / 2 }

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

    /// `string` wrapped to `width`: explicit newlines kept, lines broken after
    /// spaces (and after a hyphen), and a word that doesn't fit on a line of
    /// its own broken wherever the line is full. Never after `/`, so a long
    /// path fills each line.
    func wrap(_ string: String, width: Double) -> [String] {
        var lines: [String] = []
        for paragraph in string.components(separatedBy: "\n") {
            // Break opportunities: after a run of spaces, after a hyphen
            // followed by a letter.
            var words: [String] = []
            var current = ""
            let characters = Array(paragraph)
            for (index, character) in characters.enumerated() {
                current.append(character)
                let next = index + 1 < characters.count ? characters[index + 1] : nil
                if character == " ", next != " " {
                    words.append(current)
                    current = ""
                } else if character == "-", let next, next.isLetter, current.count > 1 {
                    words.append(current)
                    current = ""
                }
            }
            if !current.isEmpty || words.isEmpty { words.append(current) }
            var line = ""
            /// Emits full lines while `line` is wider than a line: a word
            /// longer than a whole line breaks where the line is full.
            func breakOverlong() {
                while self.width(line.trimmingTrailingSpaces) > width + 0.01, line.count > 1 {
                    var head = ""
                    for character in line {
                        if !head.isEmpty && self.width(head + String(character)) > width + 0.01 { break }
                        head.append(character)
                    }
                    lines.append(head)
                    line = String(line.dropFirst(head.count))
                }
            }
            for word in words {
                if !line.isEmpty && self.width(line + word.trimmingTrailingSpaces) > width + 0.01 {
                    lines.append(line.trimmingTrailingSpaces)
                    line = ""
                }
                line += word
                breakOverlong()
            }
            lines.append(line.trimmingTrailingSpaces)
        }
        return lines
    }
}

extension String {
    /// Without its trailing spaces, which hang past a wrapped line's end.
    var trimmingTrailingSpaces: String {
        var copy = self
        while copy.hasSuffix(" ") { copy.removeLast() }
        return copy
    }
}

/// A view whose origin is top-left.
class GitFlippedView: NSView {
    override var isFlipped: Bool { true }
}

/// `x` snapped as a painted box edge is: to a whole point, round half up.
func snap(_ x: Double) -> Double { (x + 0.5).rounded(.down) }

func snapped(_ rect: CGRect) -> CGRect {
    let x0 = snap(rect.minX)
    let y0 = snap(rect.minY)
    return CGRect(x: x0, y: y0, width: snap(rect.maxX) - x0, height: snap(rect.maxY) - y0)
}
