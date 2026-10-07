import TabsPluginSDK

// How a git tree pane divides its body between the commit list (above) and the
// detail panel (below): the model behind `DetailDivider`, pure so the snapping
// and clamping rules are testable without views.
//
// The split lives in the pane's config (`detailFraction`, `detailCollapsed`),
// so it survives a relaunch like the directory does.

enum DetailSplitRules {
    /// The details' share of the body in a pane whose divider was never
    /// dragged: the 60/40 the pane always had.
    static let defaultFraction = 0.4
    /// The commit list never gets dragged below three rows.
    static let listMinHeight = 3 * GitTreeMetrics.rowHeight
    /// The details' smallest open height. Dragging below half of it
    /// collapses them; between half and all of it, they hold here: the snap
    /// that makes "drag it to the bottom" a gesture rather than a precise aim.
    static let detailMinHeight = 60.0
}

struct DetailSplit: Equatable, Sendable {
    /// The details' share of the body height while open, strictly between 0 and 1.
    var fraction: Double
    var collapsed: Bool
}

/// The split a pane's config asks for. Saved values are checked rather than
/// trusted: a hand-edited or stale layout file is the ordinary way to get a
/// fraction that would lay out as nothing, or as everything.
func readDetailSplit(_ config: JSONValue) -> DetailSplit {
    let fraction = config["detailFraction"]?.doubleValue
    return DetailSplit(
        fraction: fraction.flatMap { $0.isFinite && $0 > 0 && $0 < 1 ? $0 : nil } ?? DetailSplitRules.defaultFraction,
        collapsed: config["detailCollapsed"] == .bool(true))
}

/// The split for a drag that would give the details `detailHeight` points of a
/// `bodyHeight`-point body. Collapsing keeps `previous.fraction`, so the last
/// open size is never lost to a collapse.
///
/// The upper bound goes through `max` because a body shorter than both minimums
/// together would otherwise invert the range: the details keep their minimum
/// and the list gives way, rather than either going negative.
func resolveDetailDrag(detailHeight: Double, bodyHeight: Double, previous: DetailSplit) -> DetailSplit {
    // A body with no height has nothing to divide (a pane hidden mid-gesture).
    if bodyHeight <= 0 { return previous }
    if detailHeight < DetailSplitRules.detailMinHeight / 2 { return DetailSplit(fraction: previous.fraction, collapsed: true) }
    let upper = max(DetailSplitRules.detailMinHeight, bodyHeight - DetailSplitRules.listMinHeight)
    let height = min(max(detailHeight, DetailSplitRules.detailMinHeight), upper)
    // Capped just short of the whole body: `readDetailSplit` rejects 1, so a
    // value it would refuse must never be what a drag saves.
    return DetailSplit(fraction: min(height / bodyHeight, 0.99), collapsed: false)
}
