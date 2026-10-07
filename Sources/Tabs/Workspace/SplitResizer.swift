import AppKit
import TabsCore
import TabsPluginSDK

/// Resizing splits by their separators:
///
/// - Separators take no space; a 10pt band around each grabs it. Every split
///   whose band holds the pointer moves at once, so a press where separators
///   cross drags both ways.
/// - A drag moves the boundary by the pointer's travel since the press;
///   neither neighbour goes below 5% — pushing further moves the next ones.
/// - With the setting on, a boundary within 8pt of another split's separator
///   (same orientation, anywhere on screen) snaps onto it.
/// - When a drag moves several splits directly (a crossing), other splits'
///   separators aligned (within 5pt) with a moving one are carried along.
/// - Sizes are live while dragging and committed to the model on release.
@MainActor
final class SplitResizer {
    unowned let window: WorkspaceWindowController

    init(window: WorkspaceWindowController) {
        self.window = window
    }

    struct HitRegion {
        let split: SplitNodeView
        /// The child after the separator.
        let index: Int
        let rect: CGRect
    }

    private var root: WindowRootView { window.root }

    /// The tree on top at `point` (root coordinates): a floating pane over it, else the docked one.
    private func topTree(at point: CGPoint) -> TreeHostView {
        for floating in root.floatingViews.reversed() where floating.frame.contains(point) { return floating.tree }
        return root.docked
    }

    /// A split's separator bands (root coordinates), by the child after each.
    private func bands(of split: SplitNodeView) -> [(index: Int, rect: CGRect)] {
        let horizontal = split.direction == .horizontal
        let frames = split.childContentRects
        let splitRect = split.layoutFrame
        let half = Metrics.separatorHitSize / 2
        return frames.indices.dropFirst().map { index in
            let position = horizontal ? frames[index].minX : frames[index].minY
            let rect =
                horizontal
                ? CGRect(x: position - half, y: splitRect.minY, width: Metrics.separatorHitSize, height: splitRect.height)
                : CGRect(x: splitRect.minX, y: position - half, width: splitRect.width, height: Metrics.separatorHitSize)
            return (index, rect)
        }
    }

    /// Each split's separator band under `point`, at most one per split.
    func hitRegions(at point: CGPoint) -> [HitRegion] {
        let tree = topTree(at: point)
        var result: [HitRegion] = []
        for split in window.splitViews where split.isDescendant(of: tree) {
            let horizontal = split.direction == .horizontal
            var best: (region: HitRegion, distance: CGPoint)?
            for (index, rect) in bands(of: split) {
                let distance = CGPoint(
                    x: point.x >= rect.minX && point.x <= rect.maxX ? 0 : min(abs(point.x - rect.minX), abs(point.x - rect.maxX)),
                    y: point.y >= rect.minY && point.y <= rect.maxY ? 0 : min(abs(point.y - rect.minY), abs(point.y - rect.maxY)))
                let axis = horizontal ? distance.x : distance.y
                if best == nil || axis <= (horizontal ? best!.distance.x : best!.distance.y) {
                    best = (HitRegion(split: split, index: index, rect: rect), distance)
                }
            }
            if let best, best.distance.x <= 0, best.distance.y <= 0 { result.append(best.region) }
        }
        return result
    }

    // MARK: Cursor

    /// The separators' cursors, as rects AppKit applies (root coordinates):
    /// the window is cut into a grid along every separator band, floating
    /// pane and frame handle edge, and each cell whose press a separator
    /// takes gets that separator's cursor — the 4-way arrow where bands of
    /// both orientations cross.
    func cursorRects() -> [(rect: CGRect, cursor: NSCursor)] {
        let bands = window.splitViews.flatMap { bands(of: $0).map(\.rect) }
        guard !bands.isEmpty else { return [] }
        var edges = bands
        for floating in root.floatingViews {
            edges.append(floating.frame)
            edges.append(contentsOf: floating.subviews.compactMap { $0 as? ResizeHandle }.map { floating.convert($0.frame, to: root) })
        }
        let bounds = root.bounds
        func cuts(_ values: [CGFloat], _ low: CGFloat, _ high: CGFloat) -> [CGFloat] {
            Set(values.map { min(max($0, low), high) } + [low, high]).sorted()
        }
        let xs = cuts(edges.flatMap { [$0.minX, $0.maxX] }, bounds.minX, bounds.maxX)
        let ys = cuts(edges.flatMap { [$0.minY, $0.maxY] }, bounds.minY, bounds.maxY)
        var result: [(rect: CGRect, cursor: NSCursor)] = []
        for (top, bottom) in zip(ys, ys.dropFirst()) where bottom > top {
            for (left, right) in zip(xs, xs.dropFirst()) where right > left {
                let cell = CGRect(x: left, y: top, width: right - left, height: bottom - top)
                let center = CGPoint(x: cell.midX, y: cell.midY)
                guard bands.contains(where: { $0.contains(center) }), let cursor = cursor(at: center) else { continue }
                // Runs of cells with the same cursor become one rect.
                if let last = result.last, last.cursor == cursor, last.rect.maxX == left, last.rect.minY == top, last.rect.maxY == bottom {
                    result[result.count - 1].rect = last.rect.union(cell)
                } else {
                    result.append((cell, cursor))
                }
            }
        }
        return result
    }

    /// The cursor of the separators at `point` (root coordinates), when a press there would take them.
    func cursor(at point: CGPoint) -> NSCursor? {
        guard root.hitTest(root.convert(point, to: root.superview)) === root else { return nil }
        let regions = hitRegions(at: point)
        return regions.isEmpty ? nil : cursor(for: regions, flags: [])
    }

    private struct Limits: OptionSet {
        let rawValue: Int
        static let horizontalMin = Limits(rawValue: 1)
        static let horizontalMax = Limits(rawValue: 2)
        static let verticalMin = Limits(rawValue: 4)
        static let verticalMax = Limits(rawValue: 8)
    }

    private func cursor(for regions: [HitRegion], flags: Limits) -> NSCursor {
        let horizontal = regions.contains { $0.split.direction == .horizontal }
        let vertical = regions.contains { $0.split.direction == .vertical }
        if flags.contains(.horizontalMin) && !vertical { return .resizeRight }
        if flags.contains(.horizontalMax) && !vertical { return .resizeLeft }
        if flags.contains(.verticalMin) && !horizontal { return .resizeDown }
        if flags.contains(.verticalMax) && !horizontal { return .resizeUp }
        if horizontal && vertical { return .move }
        return horizontal ? .resizeLeftRight : .resizeUpDown
    }

    // MARK: The gesture

    private struct Gesture {
        let region: HitRegion
        let initialSizes: [Double]
        let length: CGFloat
        /// The model's sizes: what tells which boundary a tick moved.
        let modelSizes: [Double]
        var cluster: [Member]?
    }

    /// Another split's separator carried along with a moving one.
    private struct Member {
        let split: SplitNodeView
        let index: Int
        let initialPosition: CGFloat
    }

    func mouseDown(_ event: NSEvent) {
        guard let nsWindow = window.window else { return }
        let start = root.convert(event.locationInWindow, from: nil)
        let regions = hitRegions(at: start)
        guard !regions.isEmpty else { return }
        var gestures = regions.map { region in
            Gesture(
                region: region, initialSizes: region.split.sizes,
                length: region.split.direction == .horizontal ? region.split.layoutSize.width : region.split.layoutSize.height,
                modelSizes: region.split.split?.sizes ?? region.split.sizes)
        }
        // The drag's cursor holds wherever the pointer goes, past a pinned separator too.
        nsWindow.disableCursorRects()
        defer {
            nsWindow.enableCursorRects()
            nsWindow.invalidateCursorRects(for: root)
        }
        var moved = false
        var lastTickParticipants = 0
        var tick = 0
        tracking: while let next = nsWindow.nextEvent(
            matching: [.leftMouseDragged, .leftMouseUp, .keyDown], until: .distantFuture, inMode: .eventTracking, dequeue: true)
        {
            switch next.type {
            case .leftMouseDragged:
                let point = root.convert(next.locationInWindow, from: nil)
                if point != start { moved = true }
                tick += 1
                var participants = 0
                var flags: Limits = []
                for index in gestures.indices {
                    let gesture = gestures[index]
                    let split = gesture.region.split
                    let horizontal = split.direction == .horizontal
                    let travel = horizontal ? point.x - start.x : point.y - start.y
                    guard gesture.length > 0 else { continue }
                    let delta = Double(travel / gesture.length) * 100
                    let previous = split.sizes.map { $0 * 100 }
                    let nextSizes = Self.adjustLayoutByDelta(
                        delta: delta, initial: gesture.initialSizes.map { $0 * 100 }, prev: previous,
                        pivots: (gesture.region.index - 1, gesture.region.index), minSize: Tree.minPaneSize * 100)
                    if nextSizes == previous {
                        if delta != 0 {
                            flags.insert(
                                horizontal ? (delta < 0 ? .horizontalMin : .horizontalMax) : (delta < 0 ? .verticalMin : .verticalMax))
                        }
                        continue
                    }
                    participants += 1
                    split.liveSizes = nextSizes.map { $0 / 100 }
                    split.layoutSubtreeIfNeeded()
                    split.needsLayout = true
                    let context = self.context(of: split, sizes: split.sizes, modelSizes: gesture.modelSizes)
                    if window.appearance.snapResizeSeparators, let context {
                        snap(split, context: context)
                    }
                    if let context {
                        mirror(&gestures[index], context: context, canDiscover: tick > 1 && lastTickParticipants >= 2)
                    }
                }
                lastTickParticipants = participants
                cursor(for: regions, flags: flags).set()
                root.layoutSubtreeIfNeeded()
                window.refreshOverlays()
            case .keyDown:
                continue
            default:
                break tracking
            }
        }
        if !moved {
            for gesture in gestures { gesture.region.split.liveSizes = nil }
            // A plain click on a separator still activates the pane it lands on.
            clickThrough(at: start)
            return
        }
        commit(gestures)
    }

    /// The boundary a tick moved and its geometry, when exactly one adjacent
    /// pair changed from the model's sizes.
    private func context(of split: SplitNodeView, sizes: [Double], modelSizes: [Double]) -> (index: Int, start: CGFloat, length: CGFloat)? {
        let changed = sizes.indices.filter { abs(sizes[$0] - (modelSizes.indices.contains($0) ? modelSizes[$0] : 0)) > 1e-4 }
        guard changed.count == 2, changed[1] == changed[0] + 1 else { return nil }
        let rect = split.layoutFrame
        let horizontal = split.direction == .horizontal
        return (changed[1], horizontal ? rect.minX : rect.minY, horizontal ? rect.width : rect.height)
    }

    /// Other splits' separators of the same orientation, on screen.
    private func otherSeparators(of split: SplitNodeView) -> [(split: SplitNodeView, index: Int, position: CGFloat)] {
        var result: [(SplitNodeView, Int, CGFloat)] = []
        for other in window.splitViews where other !== split && other.direction == split.direction {
            let frames = other.childContentRects
            let horizontal = other.direction == .horizontal
            let cross = horizontal ? other.layoutSize.height : other.layoutSize.width
            guard cross > 0 else { continue }
            for index in frames.indices.dropFirst() { result.append((other, index, horizontal ? frames[index].minX : frames[index].minY)) }
        }
        return result
    }

    private func snap(_ split: SplitNodeView, context: (index: Int, start: CGFloat, length: CGFloat)) {
        guard
            let snapped = SeparatorSnap.snappedSizes(
                sizes: split.sizes, index: context.index, containerStart: Double(context.start), containerLength: Double(context.length),
                candidates: otherSeparators(of: split).map { Double($0.position) })
        else { return }
        split.liveSizes = snapped
        split.needsLayout = true
    }

    /// Carries this drag's travel to the separators aligned with it when it
    /// started — discovered on the second tick, and only for a drag that moved
    /// several splits directly (a crossing), never a lone one.
    private func mirror(_ gesture: inout Gesture, context: (index: Int, start: CGFloat, length: CGFloat), canDiscover: Bool) {
        let split = gesture.region.split
        let initial = CGFloat(
            SeparatorSnap.boundaryPosition(
                sizes: gesture.modelSizes, index: context.index, containerStart: Double(context.start),
                containerLength: Double(context.length)))
        if gesture.cluster == nil {
            guard canDiscover else { return }
            gesture.cluster = otherSeparators(of: split)
                .filter { abs($0.position - initial) <= CGFloat(SeparatorSnap.alignmentThreshold) }
                .map { Member(split: $0.split, index: $0.index, initialPosition: $0.position) }
        }
        guard let members = gesture.cluster, !members.isEmpty else { return }
        let current = CGFloat(
            SeparatorSnap.boundaryPosition(
                sizes: split.sizes, index: context.index, containerStart: Double(context.start), containerLength: Double(context.length)))
        let delta = current - initial
        for member in members {
            let rect = member.split.layoutFrame
            let horizontal = member.split.direction == .horizontal
            guard
                let applied = SeparatorSnap.applyBoundary(
                    sizes: member.split.sizes, index: member.index, containerStart: Double(horizontal ? rect.minX : rect.minY),
                    containerLength: Double(horizontal ? rect.width : rect.height), target: Double(member.initialPosition + delta))
            else { continue }
            member.split.liveSizes = applied
            member.split.needsLayout = true
        }
    }

    /// Every split the gesture moved, its live sizes committed at once.
    private func commit(_ gestures: [Gesture]) {
        var splits: [SplitNodeView] = []
        for gesture in gestures {
            splits.append(gesture.region.split)
            splits.append(contentsOf: (gesture.cluster ?? []).map(\.split))
        }
        var seen: Set<NodeID> = []
        let changes: [(NodeID, [Double])] = splits.compactMap { split in
            guard seen.insert(split.nodeID).inserted, let sizes = split.liveSizes else { return nil }
            return (split.nodeID, sizes)
        }
        for split in splits { split.liveSizes = nil }
        window.renderer.engine.perform(in: window.windowID) { layout, titles in
            var changed = false
            for (id, sizes) in changes { changed = layout.resizeSplit(id, sizes, titles: titles) || changed }
            return changed
        }
        root.needsLayout = true
    }

    private func clickThrough(at point: CGPoint) {
        let tree = topTree(at: point)
        guard let hit = tree.hitTest(root.convert(point, to: tree.superview)) else { return }
        var view: NSView? = hit
        while let current = view {
            if let pane = current as? PaneView {
                window.activate(pane.nodeID)
                return
            }
            view = current.superview
        }
    }

    // MARK: Layout arithmetic

    private static func format(_ number: Double) -> Double { (number * 1000).rounded() / 1000 }
    private static func equal(_ a: Double, _ b: Double, tolerance: Double = 0) -> Bool { abs(format(a) - format(b)) <= tolerance }
    private static func compare(_ a: Double, _ b: Double) -> Int { equal(a, b) ? 0 : (a > b ? 1 : -1) }

    private static func validate(_ size: Double, minSize: Double) -> Double {
        format(min(100, compare(size, minSize) < 0 ? minSize : size))
    }

    /// Moves a boundary by `delta` (percentages): the panels on the shrinking side
    /// give up the delta in order from the separator, each down to its
    /// minimum; the pivot on the other side takes what they gave.
    static func adjustLayoutByDelta(
        delta requested: Double, initial: [Double], prev: [Double], pivots: (Int, Int), minSize: Double
    ) -> [Double] {
        if equal(requested, 0) { return initial }
        var delta = requested
        var next = initial
        var applied = 0.0
        let (first, second) = pivots
        guard initial.indices.contains(first), initial.indices.contains(second) else { return prev }
        // How far the growing side can go.
        do {
            let increment = delta < 0 ? 1 : -1
            var index = delta < 0 ? second : first
            var available = 0.0
            while initial.indices.contains(index) {
                available += validate(100, minSize: minSize) - initial[index]
                index += increment
            }
            let magnitude = min(abs(delta), abs(available))
            delta = delta < 0 ? -magnitude : magnitude
        }
        // The shrinking side, from the separator outward.
        do {
            var index = delta < 0 ? first : second
            while initial.indices.contains(index) {
                let remaining = abs(delta) - abs(applied)
                let previous = initial[index]
                let safe = validate(previous - remaining, minSize: minSize)
                if !equal(previous, safe) {
                    applied += previous - safe
                    next[index] = safe
                    if format(applied) >= format(abs(delta)) { break }
                }
                index += delta < 0 ? -1 : 1
            }
        }
        if next == prev { return prev }
        // The growing pivot takes what the other side gave.
        let pivot = delta < 0 ? second : first
        next[pivot] = validate(initial[pivot] + applied, minSize: minSize)
        let total = next.reduce(0, +)
        if !equal(total, 100, tolerance: 0.1) { return prev }
        return next
    }
}

extension NSCursor {
    /// The 4-way arrow: AppKit has no public one, so it's the system's own art
    /// from HIServices, with the shadow its info.plist asks for — the open hand
    /// if that's ever missing.
    @MainActor static let move: NSCursor = {
        let folder = URL(
            fileURLWithPath:
                "/System/Library/Frameworks/ApplicationServices.framework/Versions/A/Frameworks/HIServices.framework/Versions/A/Resources/cursors/move"
        )
        guard let art = NSImage(contentsOf: folder.appendingPathComponent("cursor.pdf")),
            let info = NSDictionary(contentsOf: folder.appendingPathComponent("info.plist")),
            let hotX = info["hotx"] as? Double, let hotY = info["hoty"] as? Double
        else { return .openHand }
        // Room for the shadow (blur 2, 1pt down) on every side.
        let margin: CGFloat = 3
        let size = NSSize(width: art.size.width + margin * 2, height: art.size.height + margin * 2)
        let image = NSImage(size: size, flipped: false) { _ in
            let shadow = NSShadow()
            shadow.shadowBlurRadius = 2
            shadow.shadowOffset = NSSize(width: 0, height: -1)
            shadow.shadowColor = NSColor.black.withAlphaComponent(0.45)
            shadow.set()
            art.draw(in: NSRect(origin: NSPoint(x: margin, y: margin), size: art.size))
            return true
        }
        return NSCursor(image: image, hotSpot: NSPoint(x: hotX + margin, y: hotY + margin))
    }()
}
