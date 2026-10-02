import AppKit
import TabsPluginSDK

/// Where everything in the detail panel goes (`CommitDetailPanel.tsx`,
/// `.git-tree-detail`: padding 8 10, a 1pt border on top), in the panel's own
/// coordinates, top-left at its border box.
struct CommitDetailLayout {
    struct TextRun {
        var text: String
        var x: Double
        var baseline: Double
        var font: GitText
        var color: KeyPath<PaneTheme, NSColor>?
        var fixedColor: NSColor?
        /// The line box, for the geometry dump.
        var box: CGRect
    }

    struct Field {
        var dt: CGRect
        var dd: CGRect
    }

    struct File {
        var row: CGRect
        var stat: CGRect
        var insertions: CGRect?
        var deletions: CGRect?
        var binary: CGRect?
        var path: CGRect
    }

    var runs: [TextRun] = []
    var message: CGRect?
    var fields: [Field] = []
    var files: [File] = []
    /// The files' top border, a 1pt line across the content box.
    var filesBorder: CGRect?
    var notes: [CGRect] = []
    var height: Double = 0

    init(detail: CommitDetail?, width: Double) {
        let padding = GitTreeMetrics.detailPadding
        let x = padding.horizontal
        let contentWidth = max(width - 2 * padding.horizontal, 0)
        var y = 1 + padding.vertical
        let ui12 = GitText.ui12
        let ui11 = GitText.ui11
        let mono = GitText.mono11

        /// A `<p>` at 12px: 1em margins, collapsing with the one before.
        func paragraph(_ text: String, marginBefore: Double) {
            y += marginBefore
            for line in ui12.wrap(text, width: contentWidth) {
                let box = CGRect(x: x, y: y, width: ui12.width(line), height: ui12.lineHeight)
                runs.append(TextRun(text: line, x: x, baseline: y + ui12.ascent, font: ui12, color: \.textDim, box: box))
                notes.append(box)
                y += ui12.lineHeight
            }
        }

        guard let detail else {
            paragraph("Select a commit.", marginBefore: 12)
            height = y + 12 + padding.vertical
            return
        }

        // The message: pre-wrap, words broken where they don't fit.
        let messageTop = y
        for line in ui12.wrap(detail.message, width: contentWidth) {
            runs.append(
                TextRun(
                    text: line, x: x, baseline: y + ui12.ascent, font: ui12, color: \.text,
                    box: CGRect(x: x, y: y, width: ui12.width(line), height: ui12.lineHeight)))
            y += ui12.lineHeight
        }
        message = CGRect(x: x, y: messageTop, width: contentWidth, height: y - messageTop)
        y += 8

        // The fields: a two-column grid (max-content, 1fr), gap 2 10.
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
        let labelWidth = pairs.map { ui11.width($0.0) }.max() ?? 0
        let valueX = x + labelWidth + GitTreeMetrics.fieldsGap.column
        let valueWidth = max(contentWidth - labelWidth - GitTreeMetrics.fieldsGap.column, 0)
        for (index, (label, value)) in pairs.enumerated() {
            if index > 0 { y += GitTreeMetrics.fieldsGap.row }
            let lines = mono.wrap(value, width: valueWidth)
            let dtBox = CGRect(x: x, y: y, width: ui11.width(label), height: ui11.lineHeight)
            runs.append(TextRun(text: label, x: x, baseline: y + ui11.ascent, font: ui11, color: \.textDim, box: dtBox))
            var lineY = y
            var ddWidth = 0.0
            for line in lines {
                let lineWidth = mono.width(line)
                ddWidth = max(ddWidth, lineWidth)
                runs.append(
                    TextRun(
                        text: line, x: valueX, baseline: lineY + mono.ascent, font: mono, color: \.text,
                        box: CGRect(x: valueX, y: lineY, width: lineWidth, height: mono.lineHeight)))
                lineY += mono.lineHeight
            }
            fields.append(Field(dt: dtBox, dd: CGRect(x: valueX, y: y, width: ddWidth, height: lineY - y)))
            y += max(ui11.lineHeight, lineY - y)
        }
        // The grid's 8 below it counts even when it's empty: a grid container
        // is its own formatting context, so margins don't collapse through it.
        y += 8

        // The files: a top border, 6 below it, 17pt lines.
        filesBorder = CGRect(x: x, y: y, width: contentWidth, height: 1)
        y += 1 + 6
        let lineHeight = GitTreeMetrics.fileLineHeight
        let leading = mono.halfLeading(in: lineHeight)
        let statWidth = GitTreeMetrics.fileStatWidth
        let pathX = x + statWidth + GitTreeMetrics.fileGap
        let pathWidth = max(contentWidth - statWidth - GitTreeMetrics.fileGap, 0)
        for file in detail.files {
            let rowTop = y
            let baseline = rowTop + leading + mono.ascent
            var entry = File(
                row: .zero, stat: CGRect(x: x, y: rowTop, width: statWidth, height: lineHeight), insertions: nil, deletions: nil,
                binary: nil, path: .zero)
            let statRight = x + statWidth
            if let insertions = file.insertions, let deletions = file.deletions {
                let minus = "−\(deletions)"
                let plus = "+\(insertions)"
                let minusWidth = mono.width(minus)
                let plusWidth = mono.width(plus)
                let minusX = statRight - minusWidth
                let plusX = minusX - GitTreeMetrics.fileStatGap - plusWidth
                entry.insertions = CGRect(x: plusX, y: rowTop + leading, width: plusWidth, height: mono.lineHeight)
                entry.deletions = CGRect(x: minusX, y: rowTop + leading, width: minusWidth, height: mono.lineHeight)
                runs.append(
                    TextRun(
                        text: plus, x: plusX, baseline: baseline, font: mono, fixedColor: GitTreeColors.insertions,
                        box: entry.insertions!))
                runs.append(
                    TextRun(
                        text: minus, x: minusX, baseline: baseline, font: mono, fixedColor: GitTreeColors.deletions,
                        box: entry.deletions!))
            } else {
                let width = mono.width("binary")
                entry.binary = CGRect(x: statRight - width, y: rowTop + leading, width: width, height: mono.lineHeight)
                runs.append(
                    TextRun(text: "binary", x: statRight - width, baseline: baseline, font: mono, color: \.textDim, box: entry.binary!))
            }
            var lineTop = rowTop
            var widest = 0.0
            for line in mono.wrap(file.path, width: pathWidth) {
                let lineWidth = mono.width(line)
                widest = max(widest, lineWidth)
                runs.append(
                    TextRun(
                        text: line, x: pathX, baseline: lineTop + leading + mono.ascent, font: mono, color: \.text,
                        box: CGRect(x: pathX, y: lineTop + leading, width: lineWidth, height: mono.lineHeight)))
                lineTop += lineHeight
            }
            let rowHeight = max(lineTop - rowTop, lineHeight)
            entry.path = CGRect(x: pathX, y: rowTop + leading, width: widest, height: lineTop - rowTop - 2 * leading)
            entry.row = CGRect(x: x, y: rowTop, width: contentWidth, height: rowHeight)
            // The stat stretches to the row (a flex item, `align-items: normal`).
            entry.stat.size.height = rowHeight
            files.append(entry)
            y += rowHeight
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
}

/// The selected commit's details: its message, identity fields and changed
/// files, or for the working-tree row the same minus what a commit has.
@MainActor
final class CommitDetailView: GitFlippedView {
    unowned let pane: GitTreePane
    var theme = PaneTheme.dark { didSet { needsDisplay = true } }
    /// How far the panel's layout box sits below the whole point it's drawn
    /// at (text baselines round from there).
    var fractionalOffset = 0.0

    init(pane: GitTreePane) {
        self.pane = pane
        super.init(frame: .zero)
        setAccessibilityIdentifier("git-tree-detail")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Laid out for the panel's width; its content starts below the 1pt top
    /// border, which the pane view draws.
    func layout(width: Double) -> CommitDetailLayout {
        CommitDetailLayout(detail: pane.detail, width: width)
    }

    override func draw(_ dirtyRect: NSRect) {
        let layout = layout(width: bounds.width)
        // The view sits at a whole point; its layout box starts
        // `fractionalOffset` below that, and edges and baselines snap in the
        // window, from where the layout box really is.
        if let border = layout.filesBorder {
            theme.border.setFill()
            snapped(border.offsetBy(dx: 0, dy: fractionalOffset)).fill()
        }
        for run in layout.runs where run.box.maxY + fractionalOffset >= dirtyRect.minY && run.box.minY <= dirtyRect.maxY {
            let color = run.fixedColor ?? run.color.map { theme[keyPath: $0] } ?? theme.text
            run.font.draw(run.text, at: CGPoint(x: run.x, y: run.baseline + fractionalOffset), color: color)
        }
    }
}
