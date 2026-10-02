import AppKit
import TabsCore
import TabsPluginSDK

/// The cues' look — the Electron app's `.bell-icon`, `.control-icon`,
/// `.pane-alert::after` and `.pane-controlled::after` (global.css), for any kind.
@MainActor
enum SignalStyle {
    /// The icon's box (a 16×16 SVG in the Electron app).
    static let iconSize: CGFloat = 16
    /// An SF Symbol drawn like the Electron app's line glyphs: at 10.5pt
    /// medium its ink is about 12×13 in the box with a ~1.2pt stroke, as the
    /// bell's (11×13, stroke 1.2) — one family of icons whoever declares them.
    static let symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 10.5, weight: .medium)
    /// Between icons, and before the title, in a header (the bar's flex gap).
    static let headerGap: CGFloat = Metrics.barGap
    /// In a tab: its left padding while it shows an icon (`.tab:has(> .bell-icon)`)
    /// and the gap after each icon (the tab's own flex gap).
    static let tabPaddingLeft: CGFloat = 2
    static let tabGap: CGFloat = Metrics.tabInnerGap
    /// The inner glow: `inset 0 0 14px 0 color-mix(in srgb, cue 55%, transparent)`.
    static let glowBlur: CGFloat = 14
    static let glowAlpha = 0.55

    static func color(_ kind: SignalKind, in theme: Theme) -> NSColor {
        switch kind.value.color {
        case .alert: theme.bellAlert
        case .agent: theme.agent
        case .accent: theme.accent
        case .custom(let dark, let light): theme.isDark ? dark : light
        }
    }

    /// Draws `kind`'s icon in `rect` (a flipped view), in `color`.
    static func drawIcon(_ kind: SignalKind, in rect: CGRect, color: NSColor) {
        kind.value.icon.draw(in: rect, color: color)
    }
}

extension PaneIcon {
    /// Draws the icon in `rect` (a flipped view), in `color`: fitted and
    /// centered, an SF Symbol at the weight of the chrome's line glyphs.
    @MainActor
    func draw(in rect: CGRect, color: NSColor) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        // Chromium paints an SVG at a whole CSS pixel.
        let box = CGRect(x: rect.minX.rounded(), y: rect.minY.rounded(), width: rect.width, height: rect.height)
        let image: NSImage?
        switch self {
        case .image(let template): image = template
        case .symbol(let name):
            image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
                .withSymbolConfiguration(SignalStyle.symbolConfiguration)
        }
        guard let image else { return }
        // Fit the image in the box, centered, keeping its aspect.
        let size = image.size
        let scale = size.width > 0 && size.height > 0 ? min(box.width / size.width, box.height / size.height, 1) : 1
        let drawn = CGSize(width: size.width * scale, height: size.height * scale)
        let target = CGRect(
            x: box.midX - drawn.width / 2, y: box.midY - drawn.height / 2, width: drawn.width, height: drawn.height)
        // A template: only its alpha counts, filled with the color.
        context.saveGState()
        context.beginTransparencyLayer(in: box, auxiliaryInfo: nil)
        image.draw(in: target, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        color.setFill()
        box.fill(using: .sourceIn)
        context.endTransparencyLayer()
        context.restoreGState()
    }
}

/// The pulse (`@keyframes bell-pulse` / `control-pulse`): opacity 0.3 held
/// until 30% of the cycle, eased up to 1 at 56%, eased back to 0.3 at 69%,
/// held to the end. Never below 0.3.
@MainActor
enum SignalPulse {
    static let low = 0.3
    static let keyTimes: [Double] = [0, 0.3, 0.56, 0.69, 1]
    static let values: [Double] = [low, low, 1, low, low]
    /// Captures freeze every pulse this many seconds in (the Electron capture
    /// pauses its animations the same way); nil: they run.
    static var frozenTime: TimeInterval?

    /// The opacity `time` seconds into a pulse of `period` seconds.
    static func opacity(at time: TimeInterval, period: TimeInterval) -> Double {
        guard period > 0 else { return 1 }
        let phase = (time.truncatingRemainder(dividingBy: period) + period).truncatingRemainder(dividingBy: period) / period
        for index in 1..<keyTimes.count where phase <= keyTimes[index] {
            let start = keyTimes[index - 1]
            let local = (phase - start) / (keyTimes[index] - start)
            return values[index - 1] + (values[index] - values[index - 1]) * easeInOut(local)
        }
        return low
    }

    /// CSS `ease-in-out`: cubic-bezier(0.42, 0, 0.58, 1).
    static func easeInOut(_ x: Double) -> Double {
        func bezier(_ t: Double, _ p1: Double, _ p2: Double) -> Double {
            3 * (1 - t) * (1 - t) * t * p1 + 3 * (1 - t) * t * t * p2 + t * t * t
        }
        var lower = 0.0
        var upper = 1.0
        var t = x
        for _ in 0..<60 {
            let value = bezier(t, 0.42, 0.58)
            if abs(value - x) < 1e-9 { break }
            if value < x { lower = t } else { upper = t }
            t = (lower + upper) / 2
        }
        return bezier(t, 0, 1)
    }

    /// Pulses `layer` with `kind`'s cycle, running from `since`: every layer
    /// of one signal is in phase, whenever its view was built.
    static func apply(to layer: CALayer?, period: TimeInterval?, since: TimeInterval) {
        guard let layer else { return }
        layer.removeAnimation(forKey: "pulse")
        guard let period else {
            layer.opacity = 1
            return
        }
        if let frozen = frozenTime {
            layer.opacity = Float(opacity(at: frozen, period: period))
            return
        }
        layer.opacity = 1
        let animation = CAKeyframeAnimation(keyPath: "opacity")
        animation.values = values
        animation.keyTimes = keyTimes.map { NSNumber(value: $0) }
        let ease = CAMediaTimingFunction(controlPoints: 0.42, 0, 0.58, 1)
        let linear = CAMediaTimingFunction(name: .linear)
        animation.timingFunctions = [linear, ease, ease, linear]
        animation.duration = period
        animation.repeatCount = .infinity
        animation.beginTime = since
        animation.isRemovedOnCompletion = false
        layer.add(animation, forKey: "pulse")
    }
}

/// The icons of a header's or a tab's signals, in order: one view per kind,
/// reused while the kind shows (its pulse keeps time), and their tool tips.
@MainActor
struct SignalIconRow {
    private(set) var icons: [SignalIconView] = []
    /// Tool tip owners must outlive their rects (AppKit doesn't retain them).
    private var tooltips: [NSString] = []

    /// Shows `shown` in `view`. Returns whether icons came, went or moved
    /// (what follows them must be laid out again).
    mutating func show(_ shown: [ShownSignal], in view: NSView, theme: Theme, placement: String) -> Bool {
        var next: [SignalIconView] = []
        for signal in shown {
            let icon = icons.first { $0.kindID == signal.kind.id } ?? SignalIconView()
            if icon.superview !== view { view.addSubview(icon) }
            icon.show(signal, theme: theme, placement: placement)
            next.append(icon)
        }
        for icon in icons where !next.contains(where: { $0 === icon }) { icon.removeFromSuperview() }
        let changed = next.map(ObjectIdentifier.init) != icons.map(ObjectIdentifier.init)
        icons = next
        return changed
    }

    /// A tool tip over each laid-out icon whose kind has one (`view`'s others go).
    mutating func installTooltips(in view: NSView) {
        view.removeAllToolTips()
        tooltips = []
        for icon in icons {
            guard let text = icon.shown?.kind.value.tooltip else { continue }
            let owner = text as NSString
            tooltips.append(owner)
            view.addToolTip(icon.frame, owner: owner, userData: nil)
        }
    }
}

/// One signal's icon in a header or a tab: its glyph pulses; the view itself
/// only carries it (and dims with a dragged tab). Clicks go to the chrome
/// under it.
@MainActor
final class SignalIconView: FlippedView {
    private let glyph = SignalGlyphView()
    private(set) var shown: ShownSignal?
    private var theme: Theme = .dark

    override init(frame: NSRect) {
        super.init(frame: frame)
        addSubview(glyph)
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
    }

    var kindID: String? { shown?.kind.id }

    func show(_ signal: ShownSignal, theme: Theme, placement: String) {
        let changed = shown?.kind.id != signal.kind.id || shown?.signal.since != signal.signal.since
        shown = signal
        self.theme = theme
        glyph.kind = signal.kind
        glyph.color = SignalStyle.color(signal.kind, in: theme)
        glyph.needsDisplay = true
        setAccessibilityLabel(signal.kind.value.label)
        setAccessibilityIdentifier("\(placement)-signal-\(signal.kind.id)")
        if changed { pulse() }
    }

    private func pulse() {
        guard let shown else { return }
        SignalPulse.apply(to: glyph.layer, period: shown.kind.value.pulse, since: shown.signal.since)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        pulse()
    }

    override func layout() {
        super.layout()
        glyph.frame = bounds
    }

    /// The glyph as drawn, for tests: its layer's opacity now.
    var glyphOpacity: Float { glyph.layer?.presentation()?.opacity ?? glyph.layer?.opacity ?? 1 }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

@MainActor
private final class SignalGlyphView: FlippedView {
    var kind: SignalKind?
    var color: NSColor = .red

    override func draw(_ dirtyRect: NSRect) {
        guard let kind else { return }
        // The icon view's frame is its box painted on whole points.
        SignalStyle.drawIcon(kind, in: CGRect(x: 0, y: 0, width: SignalStyle.iconSize, height: SignalStyle.iconSize), color: color)
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// A signal's outline over its pane's content — the active outline's box
/// (`.pane-alert::after`): a 1px border in the kind's color and an inner glow,
/// pulsing. Lives in its tree's overlay, above every pane and under the dock
/// preview.
@MainActor
final class SignalOutlineView: FlippedView {
    private let ink = SignalOutlineInk()
    private(set) var shown: ShownSignal?
    let pane: NodeID

    init(pane: NodeID) {
        self.pane = pane
        super.init(frame: .zero)
        addSubview(ink)
        setAccessibilityIdentifier("pane-signal-outline-\(pane)")
    }

    func show(_ signal: ShownSignal, color: NSColor, radii: (left: CGFloat, right: CGFloat)) {
        let changed = shown?.kind.id != signal.kind.id || shown?.signal.since != signal.signal.since
        shown = signal
        ink.color = color
        ink.radii = radii
        if changed { pulse() }
    }

    private func pulse() {
        guard let shown else { return }
        SignalPulse.apply(to: ink.layer, period: shown.kind.value.pulse, since: shown.signal.since)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        pulse()
    }

    override func layout() {
        super.layout()
        if ink.frame != bounds {
            ink.frame = bounds
            ink.placeBands()
        }
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// The outline's paint, in four bands along its edges: the border and the
/// glow reach only `reach` in, so the rest of the pane — most of it — keeps no
/// backing store. Its own layer draws nothing; it carries the pulse.
@MainActor
private final class SignalOutlineInk: NSView {
    /// How far in from the edge anything is painted: the border, then the
    /// glow, which fades to nothing (under 1/255) within three blur radii.
    static let reach: CGFloat = 1 + SignalStyle.glowBlur * 3

    var color: NSColor = .red {
        didSet { if color != oldValue { redraw() } }
    }
    var radii: (left: CGFloat, right: CGFloat) = (0, 0) {
        didSet { if radii != oldValue { redraw() } }
    }
    private var bands: [SignalOutlineBand] = []

    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        bands = (0..<4).map { _ in SignalOutlineBand(ink: self) }
        for band in bands { addSubview(band) }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    /// Top and bottom full width, left and right between them, each starting on
    /// a whole point of the outline so it paints the same pixels the whole
    /// outline would.
    func placeBands() {
        let size = bounds.size
        let top = min(Self.reach, size.height)
        let bottom = max((size.height - Self.reach).rounded(.down), top)
        let left = min(Self.reach, size.width)
        let right = max((size.width - Self.reach).rounded(.down), left)
        let frames = [
            CGRect(x: 0, y: 0, width: size.width, height: top),
            CGRect(x: 0, y: bottom, width: size.width, height: size.height - bottom),
            CGRect(x: 0, y: top, width: left, height: bottom - top),
            CGRect(x: right, y: top, width: size.width - right, height: bottom - top),
        ]
        for (band, frame) in zip(bands, frames) {
            band.frame = frame
            band.isHidden = frame.isEmpty
        }
        redraw()
    }

    private func redraw() {
        for band in bands { band.needsDisplay = true }
    }

    /// Paints the whole outline in its own coordinates (a band clips it).
    func paint() {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let outer = bounds
        let inner = outer.insetBy(dx: 1, dy: 1)
        let rounded = radii.left > 0 || radii.right > 0
        let innerPath =
            rounded
            ? PaneView.bottomRoundedRect(inner, left: max(radii.left - 1, 0), right: max(radii.right - 1, 0))
            : NSBezierPath(rect: inner)
        // The glow: an inset shadow, from the border's inner edge inward.
        context.saveGState()
        innerPath.addClip()
        let scale = abs(context.userSpaceToDeviceSpaceTransform.d)
        context.setShadow(
            offset: .zero, blur: SignalStyle.glowBlur * scale, color: color.mixedWithTransparent(SignalStyle.glowAlpha).cgColor)
        let surround = NSBezierPath(rect: inner.insetBy(dx: -SignalStyle.glowBlur * 3, dy: -SignalStyle.glowBlur * 3))
        surround.append(innerPath.reversed)
        NSColor.black.setFill()
        surround.fill()
        context.restoreGState()
        // The border.
        color.setFill()
        if rounded {
            let path = PaneView.bottomRoundedRect(
                outer.insetBy(dx: 0.5, dy: 0.5), left: max(radii.left - 0.5, 0), right: max(radii.right - 0.5, 0))
            color.setStroke()
            path.lineWidth = 1
            path.stroke()
        } else {
            let frame = NSBezierPath(rect: outer)
            frame.append(NSBezierPath(rect: inner).reversed)
            frame.fill()
        }
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// One band of an outline: the whole outline's paint, seen through this box.
@MainActor
private final class SignalOutlineBand: NSView {
    private unowned let ink: SignalOutlineInk

    init(ink: SignalOutlineInk) {
        self.ink = ink
        super.init(frame: .zero)
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        // Only this band: drawn straight into another context (a capture's
        // `render(in:)`), nothing else would keep the bands from overlapping.
        context.clip(to: bounds)
        context.translateBy(x: -frame.minX, y: -frame.minY)
        ink.paint()
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
