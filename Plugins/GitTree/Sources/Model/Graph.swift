// Lane assignment: turning a flat list of commits into the columns and lines
// that make it read as a DAG rather than as a chronological list.
//
// ## The model
//
// A row is drawn as a box. Lines enter through its top edge at lane positions
// and leave through its bottom edge at lane positions; the commit's dot sits
// at `lane`, vertically centred. Three kinds of line, kept apart because they
// are drawn differently:
//
// - `incoming`: top edge → the dot. One per lane that was waiting for this
//   commit; several means several children converge here.
// - `outgoing`: the dot → bottom edge. One per parent. Two or more is a merge;
//   none is a root commit.
// - `through`: top edge → bottom edge, untouched by this commit: other
//   branches passing by.
//
// ## The algorithm
//
// One pass, with an array of open lanes. Lane `i` holds the hash it is waiting
// to see, or nil if it is free. For each commit:
//
//  1. Find every lane waiting for this hash. The dot goes in the leftmost (so a
//     merge lands on the branch that has been running longest); the rest are
//     released. A commit no lane was waiting for is a branch tip and claims
//     the leftmost free lane.
//  2. The first parent inherits the dot's lane, which keeps a linear history
//     in one straight column.
//  3. Each further parent takes a lane already waiting for it if there is one
//     (so two branches merging back together converge instead of doubling
//     up), otherwise the leftmost free lane.
//
// Reusing freed lanes rather than always appending keeps the gutter narrow;
// the cost is that a line can jump columns when a branch ends, which every
// `git log --graph`-style renderer does too.
//
// Commits are consumed in the order given (feed it `--date-order` output):
// silently reordering history would be worse than drawing what was handed.

/// One commit's row, with everything needed to draw its slice of the gutter.
struct GraphRow: Equatable, Sendable {
    var commit: Commit
    /// Column the commit's dot sits in.
    var lane: Int
    /// Top-edge lanes of the lines converging into the dot.
    var incoming: [Int]
    /// Bottom-edge lanes of the lines leaving the dot, one per parent, in
    /// git's parent order.
    var outgoing: [Int]
    /// Lanes carrying lines that cross this row without touching the dot:
    /// the same lane at the top edge and the bottom, since nothing placed
    /// during this commit ever writes to an already occupied lane.
    var through: [Int]
}

struct CommitGraph: Equatable, Sendable {
    var rows: [GraphRow]
    /// How many columns the gutter needs: the widest any row got, so the whole
    /// list shares one gutter width and the subjects line up. 1 for a linear
    /// history, 0 only for an empty graph.
    var laneCount: Int
}

/// Leftmost free slot, appending if every lane is busy.
private func claimLane(_ lanes: inout [String?]) -> Int {
    if let free = lanes.firstIndex(where: { $0 == nil }) { return free }
    lanes.append(nil)
    return lanes.count - 1
}

/// Drops trailing free lanes so the gutter shrinks back once a branch ends.
private func trim(_ lanes: inout [String?]) {
    while let last = lanes.last, last == nil { lanes.removeLast() }
}

func assignLanes(_ commits: [Commit]) -> CommitGraph {
    // Lane i is waiting for lanes[i]; nil means free.
    var lanes: [String?] = []
    var rows: [GraphRow] = []
    var laneCount = 0

    for commit in commits {
        // 1. Where this commit's dot goes, and which lanes were waiting for it.
        var waiting: [Int] = []
        for i in lanes.indices where lanes[i] == commit.hash { waiting.append(i) }
        let lane = waiting.first ?? claimLane(&lanes)

        // The lanes still open around this commit, captured before the parents
        // are placed: anything here that isn't one of `waiting` is a line
        // passing this row by. Parent placement only touches `waiting` indices
        // and freshly claimed free slots, so each of these is both the line's
        // top-edge and bottom-edge lane. Resolved by index, never by hash: two
        // lanes waiting for the same hash (two siblings sharing a parent) can't
        // be told apart by hash.
        var through: [Int] = []
        for i in lanes.indices {
            if let hash = lanes[i], hash != commit.hash { through.append(i) }
        }

        // Every waiting lane is consumed here; the dot's own lane is refilled
        // by the first parent below (or released with the rest for a root).
        for index in waiting { lanes[index] = nil }

        // 2 & 3. Place the parents.
        var outgoing: [Int] = []
        for (index, parent) in commit.parents.enumerated() {
            if index == 0 {
                lanes[lane] = parent
                outgoing.append(lane)
                continue
            }
            if let existing = lanes.firstIndex(of: parent) {
                outgoing.append(existing)
                continue
            }
            let claimed = claimLane(&lanes)
            lanes[claimed] = parent
            outgoing.append(claimed)
        }

        trim(&lanes)
        rows.append(GraphRow(commit: commit, lane: lane, incoming: waiting, outgoing: outgoing, through: through))

        // The widest point of this row: the dot, every line's ends, and
        // whatever stayed open underneath it.
        var widest = lane
        for index in waiting { widest = max(widest, index) }
        for index in outgoing { widest = max(widest, index) }
        for index in through { widest = max(widest, index) }
        widest = max(widest, lanes.count - 1)
        laneCount = max(laneCount, widest + 1)
    }

    return CommitGraph(rows: rows, laneCount: laneCount)
}
