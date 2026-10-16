import AppKit
import TabsPluginSDK

/// Where everything in the detail panel goes (padding 8 10, a 1pt border on
/// top), in the panel's own coordinates, top-left at its border box.
struct CommitDetailLayout {
    struct TextRun {
        /// A theme's color, or one every theme shares.
        enum Color: Equatable {
            case theme(KeyPath<PaneTheme, NSColor>)
            case fixed(NSColor)
        }

        var text: String
        var font: GitText
        var color: Color
        /// The line box: the text starts at its left, its baseline the font's
        /// ascent below its top (the geometry dump reports it).
        var box: CGRect
    }

    struct Field {
        var dt: CGRect
        var dd: CGRect
    }

    /// One changed file's row, and under it, while it's expanded, its diff.
    struct File {
        var file: ChangedFile
        var row: CGRect
        /// The chevron's column: ▸ closed, ▾ expanded.
        var disclosure: CGRect
        var expanded: Bool
        var stat: CGRect
        var insertions: CGRect?
        var deletions: CGRect?
        var binary: CGRect?
        var path: CGRect
        var diff: DiffBlock?
    }

    /// An expanded file's diff: a bordered box under its row, Show full file
    /// in a strip on top when the old file has lines to show.
    struct DiffBlock {
        /// The strip, its button, and the button's label and where it's drawn
        /// (its baseline's start).
        struct FullFile {
            var strip: CGRect
            var button: CGRect
            var label: String
            var labelOrigin: CGPoint
        }

        var box: CGRect
        var fullFile: FullFile?
        var rows: [DiffLine] = []
        var notes: [CGRect] = []
    }

    /// One row of a diff box: a line (wrapped, so maybe several tall), or a
    /// hidden run of unchanged lines.
    struct DiffLine {
        enum Kind: String { case context, added, removed, note, hidden }
        var kind: Kind
        var rect: CGRect
        var old: CGRect?
        var new: CGRect?
        /// The text's lines' bounding box (a hidden row's label).
        var text: CGRect?
        /// A hidden row: its run, whether clicking shows it, its label and
        /// the number columns it spans.
        var gap: Int?
        var revealable = false
        var label: String?
        var gutter: CGRect?
    }

    var runs: [TextRun] = []
    var message: CGRect?
    var fields: [Field] = []
    /// The Lines field's two numbers, when it's shown.
    var totals: (insertions: CGRect, deletions: CGRect)?
    var files: [File] = []
    /// The files' top border, a 1pt line across the content box.
    var filesBorder: CGRect?
    var notes: [CGRect] = []
    var height: Double = 0

    init(detail: CommitDetail?, expanded: [String: FileExpansion] = [:], width: Double) {
        let padding = GitTreeMetrics.detailPadding
        let x = padding.horizontal
        let contentWidth = max(width - 2 * padding.horizontal, 0)
        var y = 1 + padding.vertical
        let ui12 = GitText.ui12
        let ui11 = GitText.ui11
        let mono = GitText.mono11

        /// A paragraph at 12pt, 12 above and below (one 12 between two).
        func paragraph(_ text: String, marginBefore: Double) {
            y += marginBefore
            for line in ui12.wrap(text, width: contentWidth) {
                notes.append(addRun(line, at: CGPoint(x: x, y: y), font: ui12, color: .theme(\.textDim)))
                y += ui12.lineHeight
            }
        }

        guard let detail else {
            paragraph("Select a commit.", marginBefore: 12)
            height = y + 12 + padding.vertical
            return
        }

        // The message: its own line breaks kept, words broken where they don't fit.
        let messageTop = y
        for line in ui12.wrap(detail.message, width: contentWidth) {
            addRun(line, at: CGPoint(x: x, y: y), font: ui12, color: .theme(\.text))
            y += ui12.lineHeight
        }
        message = CGRect(x: x, y: messageTop, width: contentWidth, height: y - messageTop)
        y += 8

        // The fields: two columns (the widest label, then the rest), gap 2 10.
        var pairs: [(String, String)] = []
        if detail.hash != uncommittedChangesHash {
            pairs.append(("Commit", detail.hash))
            pairs.append(("Author", "\(detail.author) <\(detail.authorEmail)>"))
            pairs.append(("Date", formatDate(detail.date)))
        }
        if !detail.parents.isEmpty {
            pairs.append((detail.parents.count > 1 ? "Parents" : "Parent", detail.parents.map(shortHash).joined(separator: ", ")))
        }
        if !detail.refs.isEmpty { pairs.append(("Refs", detail.refs.joined(separator: ", "))) }
        let lineTotals = detail.lineTotals
        let labels = pairs.map(\.0) + (lineTotals == nil ? [] : ["Lines"])
        let labelWidth = labels.map { ui11.width($0) }.max() ?? 0
        let valueX = x + labelWidth + GitTreeMetrics.fieldsGap.column
        let valueWidth = max(contentWidth - labelWidth - GitTreeMetrics.fieldsGap.column, 0)
        /// A field's label, the row gap above it after the first.
        func fieldLabel(_ text: String) -> CGRect {
            if !fields.isEmpty { y += GitTreeMetrics.fieldsGap.row }
            return addRun(text, at: CGPoint(x: x, y: y), font: ui11, color: .theme(\.textDim))
        }
        for (label, value) in pairs {
            let dtBox = fieldLabel(label)
            var lineY = y
            var ddWidth = 0.0
            for line in mono.wrap(value, width: valueWidth) {
                ddWidth = max(ddWidth, addRun(line, at: CGPoint(x: valueX, y: lineY), font: mono, color: .theme(\.text)).width)
                lineY += mono.lineHeight
            }
            fields.append(Field(dt: dtBox, dd: CGRect(x: valueX, y: y, width: ddWidth, height: lineY - y)))
            y += max(ui11.lineHeight, lineY - y)
        }
        // The lines added and deleted across the files, last: `+n −m` as a
        // file's stat, `−m` on the next line when both don't fit.
        if let lineTotals {
            let dtBox = fieldLabel("Lines")
            let minus = "−\(lineTotals.deletions)"
            let minusWidth = mono.width(minus)
            let plusBox = addRun(
                "+\(lineTotals.insertions)", at: CGPoint(x: valueX, y: y), font: mono, color: .fixed(GitTreeColors.insertions))
            let minusBox = addRun(
                minus,
                at: plusBox.width + GitTreeMetrics.fileStatGap + minusWidth <= valueWidth
                    ? CGPoint(x: plusBox.maxX + GitTreeMetrics.fileStatGap, y: y) : CGPoint(x: valueX, y: plusBox.maxY),
                font: mono, color: .fixed(GitTreeColors.deletions), width: minusWidth)
            totals = (plusBox, minusBox)
            fields.append(Field(dt: dtBox, dd: plusBox.union(minusBox)))
            y += max(ui11.lineHeight, minusBox.maxY - y)
        }
        // The 8 below the fields counts even when there are none.
        y += 8

        // The files: a top border, 6 below it, 17pt lines; each row a
        // chevron, its stat and its path, and an expanded one's diff under it.
        filesBorder = CGRect(x: x, y: y, width: contentWidth, height: 1)
        y += 1 + 6
        let lineHeight = GitTreeMetrics.fileLineHeight
        let leading = mono.halfLeading(in: lineHeight)
        let statWidth = GitTreeMetrics.fileStatWidth
        let statX = x + GitTreeMetrics.fileDisclosureWidth
        let pathX = statX + statWidth + GitTreeMetrics.fileGap
        let pathWidth = max(contentWidth - GitTreeMetrics.fileDisclosureWidth - statWidth - GitTreeMetrics.fileGap, 0)
        for file in detail.files {
            let rowTop = y
            let expansion = expanded[file.path]
            var entry = File(
                file: file, row: .zero,
                disclosure: CGRect(x: x, y: rowTop, width: GitTreeMetrics.fileDisclosureWidth, height: lineHeight),
                expanded: expansion != nil, stat: CGRect(x: statX, y: rowTop, width: statWidth, height: lineHeight), insertions: nil,
                deletions: nil, binary: nil, path: .zero)
            let statRight = statX + statWidth
            if let insertions = file.insertions, let deletions = file.deletions {
                let minus = "−\(deletions)"
                let plus = "+\(insertions)"
                let minusWidth = mono.width(minus)
                let plusWidth = mono.width(plus)
                let minusX = statRight - minusWidth
                entry.insertions = addRun(
                    plus, at: CGPoint(x: minusX - GitTreeMetrics.fileStatGap - plusWidth, y: rowTop + leading), font: mono,
                    color: .fixed(GitTreeColors.insertions), width: plusWidth)
                entry.deletions = addRun(
                    minus, at: CGPoint(x: minusX, y: rowTop + leading), font: mono, color: .fixed(GitTreeColors.deletions),
                    width: minusWidth)
            } else {
                let width = mono.width("binary")
                entry.binary = addRun(
                    "binary", at: CGPoint(x: statRight - width, y: rowTop + leading), font: mono, color: .theme(\.textDim), width: width)
            }
            var lineTop = rowTop
            var widest = 0.0
            for line in mono.wrap(file.displayPath, width: pathWidth) {
                widest = max(widest, addRun(line, at: CGPoint(x: pathX, y: lineTop + leading), font: mono, color: .theme(\.text)).width)
                lineTop += lineHeight
            }
            let rowHeight = max(lineTop - rowTop, lineHeight)
            entry.path = CGRect(x: pathX, y: rowTop + leading, width: widest, height: lineTop - rowTop - 2 * leading)
            entry.row = CGRect(x: x, y: rowTop, width: contentWidth, height: rowHeight)
            // The stat and the chevron's column stretch to the row.
            entry.stat.size.height = rowHeight
            entry.disclosure.size.height = rowHeight
            y += rowHeight
            if let expansion {
                y += GitTreeMetrics.diffMargin.top
                let block = diffBlock(expansion, x: x, top: y, width: contentWidth)
                entry.diff = block
                y = block.box.maxY + GitTreeMetrics.diffMargin.bottom
            }
            files.append(entry)
        }

        var trailingMargin = 0.0
        if detail.files.isEmpty {
            paragraph(
                detail.hash == uncommittedChangesHash ? "No uncommitted changes." : "No files changed against the first parent.",
                marginBefore: 12)
            trailingMargin = 12
        }
        if detail.filesTruncated {
            paragraph("Only the first files are listed.", marginBefore: 12)
            trailingMargin = 12
        }
        height = y + trailingMargin + padding.vertical
    }

    /// An expanded file's box, its top at `top`: the Show full file strip
    /// when there's anything hidden to show, then the rows (old and new
    /// number columns, the marker, the text wrapped), or a note in their
    /// place (still reading, failed, binary, nothing changed), and the cut's
    /// note under them.
    private mutating func diffBlock(_ expansion: FileExpansion, x: Double, top: Double, width: Double) -> DiffBlock {
        let mono = GitText.mono11
        let small = GitText.ui11
        let left = x + 1
        let inner = max(width - 2, 0)
        var y = top + 1
        var block = DiffBlock(box: .zero)

        func note(_ text: String) {
            let padding = GitTreeMetrics.diffNotePadding
            y += padding.vertical
            for line in small.wrap(text, width: max(inner - 2 * padding.horizontal, 0)) {
                block.notes.append(addRun(line, at: CGPoint(x: left + padding.horizontal, y: y), font: small, color: .theme(\.textDim)))
                y += small.lineHeight
            }
            y += padding.vertical
        }
        func finish() -> DiffBlock {
            block.box = CGRect(x: x, y: top, width: width, height: y + 1 - top)
            return block
        }

        guard let diff = expansion.shown else {
            if case .failed(let message) = expansion.diff { note(message) } else { note("Reading diff…") }
            return finish()
        }

        if !diff.revealableGaps.isEmpty {
            let stripHeight = GitTreeMetrics.diffStripHeight
            let label = expansion.showsFullFile ? "Show changes only" : "Show full file"
            let labelWidth = small.width(label)
            let buttonWidth = labelWidth + 2 * GitTreeMetrics.diffButtonPadding
            block.fullFile = DiffBlock.FullFile(
                strip: CGRect(x: left, y: y, width: inner, height: stripHeight),
                button: CGRect(x: left + inner - buttonWidth, y: y, width: buttonWidth, height: stripHeight), label: label,
                labelOrigin: CGPoint(
                    x: left + inner - buttonWidth + GitTreeMetrics.diffButtonPadding,
                    y: y + (stripHeight - small.lineHeight) / 2 + small.ascent))
            // Its bottom border.
            y += stripHeight + 1
        }

        y += GitTreeMetrics.diffPadding
        let advance = GitTreeMetrics.monoAdvance
        let numberPadding = GitTreeMetrics.diffNumberPadding
        let numberWidth = Double(String(max(diff.largestLineNumber, 1)).count) * advance + 2 * numberPadding
        let newX = left + numberWidth
        let markerX = left + 2 * numberWidth
        let textX = markerX + GitTreeMetrics.diffMarkerWidth
        let textWidth = max(left + inner - GitTreeMetrics.diffTextPaddingRight - textX, advance)
        let lineHeight = GitTreeMetrics.diffLineHeight
        let leading = mono.halfLeading(in: lineHeight)

        func number(_ value: Int?, right: Double, top: Double) -> CGRect? {
            guard let value else { return nil }
            let text = String(value)
            let width = Self.codeWidth(text)
            return addRun(
                text, at: CGPoint(x: right - numberPadding - width, y: top + leading), font: mono, color: .theme(\.textDim), width: width)
        }

        for row in diff.rows(revealed: expansion.revealed) {
            switch row {
            case .hidden(let gap, let count, let revealable):
                let height = GitTreeMetrics.diffHiddenRowHeight
                let label = count == 1 ? "1 unchanged line" : "\(Self.grouped(count)) unchanged lines"
                let textTop = y + (height - small.lineHeight) / 2
                block.rows.append(
                    DiffLine(
                        kind: .hidden, rect: CGRect(x: left, y: y, width: inner, height: height),
                        text: CGRect(x: textX, y: textTop, width: small.width(label), height: small.lineHeight), gap: gap,
                        revealable: revealable, label: label, gutter: CGRect(x: left, y: y, width: 2 * numberWidth, height: height)))
                y += height
            case .line(let line):
                let kind: DiffLine.Kind =
                    switch line.kind {
                    case .context: .context
                    case .added: .added
                    case .removed: .removed
                    case .note: .note
                    }
                let pieces = Self.wrapCode(Self.expandTabs(line.text), width: textWidth)
                var entry = DiffLine(kind: kind, rect: CGRect(x: left, y: y, width: inner, height: Double(pieces.count) * lineHeight))
                entry.old = number(line.old, right: newX, top: y)
                entry.new = number(line.new, right: markerX, top: y)
                if kind == .added || kind == .removed {
                    addRun(
                        kind == .added ? "+" : "-",
                        at: CGPoint(x: markerX + (GitTreeMetrics.diffMarkerWidth - advance) / 2, y: y + leading),
                        font: mono, color: .fixed(kind == .added ? GitTreeColors.insertions : GitTreeColors.deletions), width: advance)
                }
                var textBox = CGRect.null
                for (index, piece) in pieces.enumerated() {
                    let lineTop = y + Double(index) * lineHeight
                    textBox = textBox.union(
                        addRun(
                            piece, at: CGPoint(x: textX, y: lineTop + leading), font: mono,
                            color: .theme(kind == .note ? \.textDim : \.text),
                            width: Self.codeWidth(piece)))
                }
                entry.text = textBox
                block.rows.append(entry)
                y += entry.rect.height
            }
        }
        if diff.binary {
            note("Binary file: no text to show.")
        } else if diff.hunks.isEmpty {
            note("No lines changed.")
        }
        if diff.truncated { note("Only the first \(Self.grouped(Git.diffLineCap)) lines are shown.") }
        y += GitTreeMetrics.diffPadding
        return finish()
    }

    /// Lays one line of text out with its top-left at `origin`, `width` wide
    /// (measured when not given), and returns its box.
    @discardableResult
    private mutating func addRun(_ text: String, at origin: CGPoint, font: GitText, color: TextRun.Color, width: Double? = nil) -> CGRect {
        let box = CGRect(x: origin.x, y: origin.y, width: width ?? font.width(text), height: font.lineHeight)
        runs.append(TextRun(text: text, font: font, color: color, box: box))
        return box
    }

    /// A count with its thousands grouped, as the panel's English does.
    static func grouped(_ value: Int) -> String {
        value.formatted(.number.locale(Locale(identifier: "en_US")))
    }

    /// Tabs as spaces to the next stop.
    static func expandTabs(_ text: String) -> String {
        guard text.contains("\t") else { return text }
        var out = ""
        var column = 0
        for character in text {
            if character == "\t" {
                let spaces = GitTreeMetrics.diffTabWidth - column % GitTreeMetrics.diffTabWidth
                out += String(repeating: " ", count: spaces)
                column += spaces
            } else {
                out.append(character)
                column += 1
            }
        }
        return out
    }

    /// Printable ASCII only: every character is Menlo's one advance wide.
    private static func isPlainASCII(_ text: String) -> Bool {
        text.utf8.allSatisfy { $0 >= 0x20 && $0 < 0x7f }
    }

    /// A line of code's width in Menlo 11: counted for plain ASCII (a long
    /// diff has thousands of lines), measured otherwise.
    static func codeWidth(_ text: String) -> Double {
        isPlainASCII(text) ? Double(text.utf8.count) * GitTreeMetrics.monoAdvance : GitText.mono11.width(text)
    }

    /// A line of code wrapped to `width`: after the last space that fits
    /// (but never inside the indentation), else where the line is full.
    /// Plain ASCII by character count; anything else measured, as
    /// `GitText.wrap` does, once whole when it fits (most lines do, and
    /// `wrap` measures word by word).
    static func wrapCode(_ text: String, width: Double) -> [String] {
        guard isPlainASCII(text) else {
            let trimmed = text.trimmingTrailingSpaces
            return GitText.mono11.width(trimmed) <= width + 0.01 ? [trimmed] : GitText.mono11.wrap(text, width: width)
        }
        let columns = max(Int((width + 0.01) / GitTreeMetrics.monoAdvance), 1)
        var characters = Array(text.utf8)
        guard characters.count > columns else { return [text] }
        var lines: [String] = []
        let space = UInt8(ascii: " ")
        while characters.count > columns {
            var cut = columns
            if let lastSpace = characters[..<columns].lastIndex(of: space),
                characters[..<lastSpace].contains(where: { $0 != space })
            {
                cut = lastSpace + 1
            }
            lines.append(String(decoding: characters[..<cut], as: UTF8.self))
            characters.removeFirst(cut)
        }
        lines.append(String(decoding: characters, as: UTF8.self))
        return lines
    }
}

/// The selected commit's details: its message, identity fields and changed
/// files, or for the working-tree row the same minus what a commit has. A
/// file row opens on a click to show its diff; right-click offers Show in
/// Finder and Open.
@MainActor
final class CommitDetailView: GitFlippedView {
    unowned let pane: GitTreePane
    var theme = PaneTheme.placeholder { didSet { needsDisplay = true } }
    /// How far the panel's layout box sits below the whole point it's drawn
    /// at (text baselines round from there).
    var fractionalOffset = 0.0
    private var cachedLayout: (revision: Int, width: Double, layout: CommitDetailLayout)?
    private var trackingArea: NSTrackingArea?

    /// What a click would act on: a file's row, a hidden run of a file's
    /// diff (by row), or a file's Show full file button.
    enum Target: Equatable {
        case file(Int)
        case gap(file: Int, row: Int)
        case fullFile(Int)
    }

    private(set) var hovered: Target?

    init(pane: GitTreePane) {
        self.pane = pane
        super.init(frame: .zero)
        setAccessibilityIdentifier("git-tree-detail")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Laid out for the panel's width; its content starts below the 1pt top
    /// border, which the pane view draws. Kept until the pane's detail,
    /// expansions or diffs change (a long diff is thousands of lines).
    func layout(width: Double) -> CommitDetailLayout {
        if let cachedLayout, cachedLayout.revision == pane.detailRevision, cachedLayout.width == width { return cachedLayout.layout }
        // What the pointer was over may be somewhere else now.
        if cachedLayout?.revision != pane.detailRevision { hovered = nil }
        let layout = CommitDetailLayout(detail: pane.detail, expanded: pane.expandedFiles, width: width)
        cachedLayout = (pane.detailRevision, width, layout)
        return layout
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        let layout = layout(width: bounds.width)
        // The view sits at a whole point; its layout box starts
        // `fractionalOffset` below that, and edges and baselines snap in the
        // window, from where the layout box really is.
        let offset = fractionalOffset
        func visible(_ rect: CGRect) -> Bool { rect.maxY + offset >= dirtyRect.minY && rect.minY + offset <= dirtyRect.maxY }
        if let border = layout.filesBorder {
            theme.border.setFill()
            snapped(border.offsetBy(dx: 0, dy: offset)).fill()
        }
        for (index, file) in layout.files.enumerated() {
            if hovered == .file(index), visible(file.row) {
                theme.hover(0.08).setFill()
                snapped(CGRect(x: 0, y: file.row.minY + offset, width: bounds.width, height: file.row.height)).fill()
            }
            if visible(file.disclosure) { drawChevron(in: file.disclosure.offsetBy(dx: 0, dy: offset), expanded: file.expanded) }
            if let diff = file.diff, visible(diff.box) { drawDiff(diff, file: index, visible: visible) }
        }
        for run in layout.runs where visible(run.box) {
            let color =
                switch run.color {
                case .theme(let key): theme[keyPath: key]
                case .fixed(let color): color
                }
            run.font.draw(run.text, at: CGPoint(x: run.box.minX, y: run.box.minY + run.font.ascent + offset), color: color)
        }
    }

    /// ▸ or ▾: a small bold chevron centred on the row's first line.
    private func drawChevron(in column: CGRect, expanded: Bool) {
        let center = CGPoint(x: column.minX + 5, y: column.minY + GitTreeMetrics.fileLineHeight / 2)
        let path = NSBezierPath()
        if expanded {
            path.move(to: CGPoint(x: center.x - 3, y: center.y - 1.5))
            path.line(to: CGPoint(x: center.x, y: center.y + 1.5))
            path.line(to: CGPoint(x: center.x + 3, y: center.y - 1.5))
        } else {
            path.move(to: CGPoint(x: center.x - 1.5, y: center.y - 3))
            path.line(to: CGPoint(x: center.x + 1.5, y: center.y))
            path.line(to: CGPoint(x: center.x - 1.5, y: center.y + 3))
        }
        path.lineWidth = 1.5
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        theme.textDim.setStroke()
        path.stroke()
    }

    private func drawDiff(_ diff: CommitDetailLayout.DiffBlock, file: Int, visible: (CGRect) -> Bool) {
        let offset = fractionalOffset
        let box = snapped(diff.box.offsetBy(dx: 0, dy: offset))
        let radius = GitTreeMetrics.diffRadius
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(roundedRect: box.insetBy(dx: 1, dy: 1), xRadius: radius - 1, yRadius: radius - 1).addClip()
        if let fullFile = diff.fullFile {
            let hovering = hovered == .fullFile(file)
            if hovering {
                theme.hover(0.12).setFill()
                snapped(fullFile.button.offsetBy(dx: 0, dy: offset)).fill()
            }
            let strip = fullFile.strip
            theme.border.setFill()
            snapped(CGRect(x: strip.minX, y: strip.maxY + offset, width: strip.width, height: 1)).fill()
            GitText.ui11.draw(
                fullFile.label, at: CGPoint(x: fullFile.labelOrigin.x, y: fullFile.labelOrigin.y + offset),
                color: hovering ? theme.text : theme.textDim)
        }
        for (index, row) in diff.rows.enumerated() where visible(row.rect) {
            let rect = snapped(row.rect.offsetBy(dx: 0, dy: offset))
            switch row.kind {
            case .added:
                GitTreeColors.addedLine.setFill()
                rect.fill()
            case .removed:
                GitTreeColors.removedLine.setFill()
                rect.fill()
            case .hidden:
                let hovering = hovered == .gap(file: file, row: index)
                theme.hover(hovering ? 0.12 : 0.06).setFill()
                rect.fill()
                let small = GitText.ui11
                if let gutter = row.gutter {
                    let dots = "⋯"
                    small.draw(
                        dots,
                        at: CGPoint(
                            x: gutter.midX - small.width(dots) / 2,
                            y: gutter.minY + offset + (gutter.height - small.lineHeight) / 2 + small.ascent),
                        color: theme.textDim)
                }
                if let label = row.label, let text = row.text {
                    small.draw(
                        label, at: CGPoint(x: text.minX, y: text.minY + offset + small.ascent), color: hovering ? theme.text : theme.textDim
                    )
                }
            case .context, .note: break
            }
        }
        NSGraphicsContext.restoreGraphicsState()
        theme.border.setStroke()
        let border = NSBezierPath(roundedRect: box.insetBy(dx: 0.5, dy: 0.5), xRadius: radius - 0.5, yRadius: radius - 0.5)
        border.lineWidth = 1
        border.stroke()
    }

    // MARK: Input

    /// What's at `point` (this view's coordinates): a file's row (its whole
    /// height, across the panel), or in an expanded file's diff, a hidden run
    /// that can be shown or the Show full file button.
    func target(at point: CGPoint) -> Target? {
        let layout = layout(width: bounds.width)
        let y = point.y - fractionalOffset
        let p = CGPoint(x: point.x, y: y)
        for (index, file) in layout.files.enumerated() {
            if y >= file.row.minY && y < file.row.maxY { return .file(index) }
            guard let diff = file.diff, diff.box.contains(p) else { continue }
            if diff.fullFile?.button.contains(p) == true { return .fullFile(index) }
            if let row = diff.rows.firstIndex(where: { $0.rect.contains(p) }), diff.rows[row].kind == .hidden, diff.rows[row].revealable {
                return .gap(file: index, row: row)
            }
            return nil
        }
        return nil
    }

    func fileIndex(at point: CGPoint) -> Int? {
        if case .file(let index) = target(at: point) { index } else { nil }
    }

    /// A click: opens or closes a file, shows a hidden run, or flips Show
    /// full file. It never takes the keyboard from the list.
    override func mouseDown(with event: NSEvent) {
        guard let target = target(at: convert(event.locationInWindow, from: nil)) else {
            super.mouseDown(with: event)
            return
        }
        activate(target)
    }

    func activate(_ target: Target) {
        let layout = layout(width: bounds.width)
        switch target {
        case .file(let index):
            pane.toggleFile(layout.files[index].file)
        case .gap(let file, let row):
            guard let gap = layout.files[file].diff?.rows[row].gap else { return }
            pane.revealGap(layout.files[file].file.path, gap)
        case .fullFile(let index):
            pane.toggleFullFile(layout.files[index].file.path)
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard let index = fileIndex(at: point) else { return }
        openMenu(forFile: index, at: point)
    }

    /// Right-click on a file's row: Show in Finder and Open, both on the file
    /// in the working tree as it is now, disabled when nothing is there.
    func openMenu(forFile index: Int, at point: CGPoint) {
        let files = layout(width: bounds.width).files
        guard files.indices.contains(index) else { return }
        pane.pane.showContextMenu(fileItems(for: files[index].file), at: point, in: self)
    }

    /// The file menu's items: core draws them.
    func fileItems(for file: ChangedFile) -> [PaneMenuItem] {
        let exists = pane.fileExists(file)
        return [
            PaneMenuItem("Show in Finder", isEnabled: exists) { [weak pane] in pane?.fileAction(.reveal, file) },
            PaneMenuItem("Open", isEnabled: exists) { [weak pane] in pane?.fileAction(.open, file) },
        ]
    }

    // MARK: Hover

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingArea = replaceTrackingArea(trackingArea, events: [.mouseMoved, .mouseEnteredAndExited])
    }

    override func mouseMoved(with event: NSEvent) { hover(at: convert(event.locationInWindow, from: nil)) }
    override func mouseEntered(with event: NSEvent) { hover(at: convert(event.locationInWindow, from: nil)) }
    override func mouseExited(with event: NSEvent) { hover(at: nil) }

    func hover(at point: CGPoint?) {
        let next = point.flatMap(target(at:))
        guard next != hovered else { return }
        hovered = next
        needsDisplay = true
    }
}
