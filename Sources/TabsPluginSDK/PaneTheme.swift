import AppKit

/// The app's color tokens, for a pane to paint chrome-like content with (a
/// toolbar, a list's rows, hairlines). The same value core draws its own
/// chrome with: one definition. Core tells a pane which one is current with
/// `PaneController.paneAppearanceDidChange(theme:depth:)`, and it is readable
/// as `PaneContext.theme`. Content that has its own colors (a terminal's
/// palette, a graph's lanes) doesn't follow it. Every theme the user can choose
/// is a file of these tokens that core loads (docs/THEMES.md).
public struct PaneTheme: Equatable, @unchecked Sendable {  // NSColor is immutable
    public var bg: NSColor
    public var bgElevated: NSColor
    public var border: NSColor
    public var text: NSColor
    public var textDim: NSColor
    public var accent: NSColor
    /// Text on an `accent` fill.
    public var onAccent: NSColor
    public var bellAlert: NSColor
    public var agent: NSColor
    /// The hover wash's color (white on dark, black on light), used at an alpha.
    public var hover: NSColor
    public var shadow: NSColor
    /// Scales every shadow's alpha.
    public var shadowStrength: Double
    /// A dark theme (a file's `"appearance": "dark"`): what macOS draws for the app — alerts,
    /// menus, file panels, web pages' `prefers-color-scheme` — is dark Aqua.
    public var isDark: Bool

    /// Every token: core's theme files (`Contents/Resources/Themes`, docs/THEMES.md) and the
    /// tests make themes; a plugin is only ever told one.
    package init(
        bg: NSColor, bgElevated: NSColor, border: NSColor, text: NSColor, textDim: NSColor, accent: NSColor, onAccent: NSColor,
        bellAlert: NSColor, agent: NSColor, hover: NSColor, shadow: NSColor, shadowStrength: Double, isDark: Bool
    ) {
        self.bg = bg
        self.bgElevated = bgElevated
        self.border = border
        self.text = text
        self.textDim = textDim
        self.accent = accent
        self.onAccent = onAccent
        self.bellAlert = bellAlert
        self.agent = agent
        self.hover = hover
        self.shadow = shadow
        self.shadowStrength = shadowStrength
        self.isDark = isDark
    }

    /// Not a theme: no file defines it and the Theme menu never lists it. What a view holds
    /// before core tells it the theme (`paneAppearanceDidChange`, `PaneContext.theme`; core tells
    /// a pane before it is first shown), and what core draws with if no theme file loads. AppKit's
    /// own colors, so it reads in either appearance.
    public static let placeholder = PaneTheme(
        bg: .windowBackgroundColor, bgElevated: .controlBackgroundColor, border: .separatorColor, text: .labelColor,
        textDim: .secondaryLabelColor, accent: .controlAccentColor, onAccent: .alternateSelectedControlTextColor,
        bellAlert: .systemRed, agent: .systemPurple, hover: .labelColor, shadow: .shadowColor, shadowStrength: 1, isDark: true)

    /// The shade of a bar at pane `depth`: nested tab groups alternate between
    /// `bg` and `bgElevated`, so the outermost (depth 0) is `bg`. A pane's own
    /// header is at the pane's depth; the tab-bar shade after it is
    /// `surfaceNext`.
    public func surface(depth: Int) -> NSColor { depth % 2 == 0 ? bg : bgElevated }
    package func surfaceNext(depth: Int) -> NSColor { surface(depth: depth + 1) }

    public func hover(_ alpha: Double) -> NSColor { hover.withAlphaComponent(alpha) }
    public func shadow(_ alpha: Double) -> NSColor { shadow.withAlphaComponent(alpha * shadowStrength) }
}

public extension NSColor {
    /// An sRGB color from 0xRRGGBB.
    static func hex(_ value: UInt32) -> NSColor {
        NSColor(
            srgbRed: CGFloat((value >> 16) & 0xff) / 255, green: CGFloat((value >> 8) & 0xff) / 255, blue: CGFloat(value & 0xff) / 255,
            alpha: 1)
    }
}
