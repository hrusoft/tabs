import Foundation

/// One row of an expanded file's diff: a line, or a run of unchanged lines
/// the hunks leave out, shown as one row until it's revealed.
enum DiffRow: Equatable, Sendable {
    case line(FileDiff.Line)
    /// `count` unchanged lines hidden; `gap` names the run (`FileDiff.Gap`).
    /// `revealable` when the old file's lines are there to show them.
    case hidden(gap: Int, count: Int, revealable: Bool)
}

extension FileDiff {
    /// A run of unchanged lines no hunk shows: before hunk `index`, or after
    /// the last one (`index == hunks.count`). Unchanged, so the same on both
    /// sides: `oldFirst` in the old file is `oldFirst + newOffset` in the new.
    struct Gap: Equatable, Sendable {
        var index: Int
        var oldFirst: Int
        var count: Int
        var newOffset: Int

        /// Whether the old file's lines (`base`) hold the run's: it can be
        /// shorter than the headers say (it changed under a filter, or the
        /// read was cut), and only what it has shows.
        func isRevealable(in base: [String]?) -> Bool {
            base.map { oldFirst - 1 + count <= $0.count } ?? false
        }
    }

    /// Every unchanged run the hunks leave out. Those before a hunk are known
    /// from the headers; the one after the last needs the old file's length,
    /// and isn't known when the diff was cut.
    var gaps: [Gap] {
        guard !hunks.isEmpty else { return [] }
        var gaps: [Gap] = []
        var next = 1
        for (index, hunk) in hunks.enumerated() {
            let count = hunk.oldFirst - next
            if count > 0 { gaps.append(Gap(index: index, oldFirst: next, count: count, newOffset: hunk.newFirst - hunk.oldFirst)) }
            next = hunk.oldLast + 1
        }
        if let base, !truncated, let last = hunks.last, base.count >= next {
            gaps.append(Gap(index: hunks.count, oldFirst: next, count: base.count - next + 1, newOffset: last.newLast - last.oldLast))
        }
        return gaps
    }

    /// The rows shown with the runs in `revealed` (gap indices) open: the
    /// hunks' lines in order, each run either its lines or one hidden row.
    func rows(revealed: Set<Int>) -> [DiffRow] {
        let gaps = Dictionary(uniqueKeysWithValues: self.gaps.map { ($0.index, $0) })
        var rows: [DiffRow] = []
        func run(_ index: Int) {
            guard let gap = gaps[index] else { return }
            let revealable = gap.isRevealable(in: base)
            if revealed.contains(index), revealable, let base {
                for old in gap.oldFirst..<(gap.oldFirst + gap.count) {
                    rows.append(.line(Line(kind: .context, text: base[old - 1], old: old, new: old + gap.newOffset)))
                }
            } else {
                rows.append(.hidden(gap: index, count: gap.count, revealable: revealable))
            }
        }
        for (index, hunk) in hunks.enumerated() {
            run(index)
            rows += hunk.lines.map(DiffRow.line)
        }
        run(hunks.count)
        return rows
    }

    /// The runs that could be revealed (the old file has their lines).
    var revealableGaps: Set<Int> {
        Set(gaps.filter { $0.isRevealable(in: base) }.map(\.index))
    }

    /// The widest line number any row can show, revealed or not: the number
    /// columns keep their width as runs open.
    var largestLineNumber: Int {
        var largest = 0
        for hunk in hunks {
            for line in hunk.lines { largest = max(largest, line.old ?? 0, line.new ?? 0) }
        }
        for gap in gaps {
            let last = gap.oldFirst + gap.count - 1
            largest = max(largest, last, last + gap.newOffset)
        }
        return largest
    }
}
