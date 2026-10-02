import AppKit

/// The app's color tokens — the Electron app's theme (`src/shared/theme.ts`),
/// value for value — for a pane to paint chrome-like content with (a toolbar,
/// a list's rows, hairlines). The same value core draws its own chrome with:
/// one definition. Core tells a pane which one is current with
/// `PaneController.paneAppearanceDidChange(theme:depth:)`, and it is readable
/// as `PaneContext.theme`. Content that has its own colors (a terminal's
/// palette, a graph's lanes) doesn't follow it.
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
    public var isDark: Bool

    public static let dark = PaneTheme(
        bg: .hex(0x1e1f24), bgElevated: .hex(0x2a2c33), border: .hex(0x3a3b44), text: .hex(0xe6e6eb), textDim: .hex(0x9a9ba6),
        accent: .hex(0x4f8cff), onAccent: .hex(0xffffff), bellAlert: .hex(0xff453a), agent: .hex(0xb48cff), hover: .hex(0xffffff),
        shadow: .hex(0x000000), shadowStrength: 1, isDark: true)

    public static let light = PaneTheme(
        bg: .hex(0xffffff), bgElevated: .hex(0xeff0f3), border: .hex(0xd2d3da), text: .hex(0x1c1d22), textDim: .hex(0x63646e),
        accent: .hex(0x2f6fe4), onAccent: .hex(0xffffff), bellAlert: .hex(0xd70015), agent: .hex(0x7b45d8), hover: .hex(0x000000),
        shadow: .hex(0x000000), shadowStrength: 0.45, isDark: false)

    /// The theme a setting resolves to (`system` follows the OS appearance).
    public static func resolve(_ setting: String, systemIsDark: Bool) -> PaneTheme {
        switch setting {
        case "light": .light
        case "system": systemIsDark ? .dark : .light
        default: .dark
        }
    }

    /// The shade of a bar at pane `depth` (`--surface`): nested tab groups
    /// alternate between `bg` and `bgElevated`, so the outermost (depth 0) is
    /// `bg`. A pane's own header is at the pane's depth; the tab-bar shade
    /// after it is `surfaceNext`.
    public func surface(depth: Int) -> NSColor { depth % 2 == 0 ? bg : bgElevated }
    public func surfaceNext(depth: Int) -> NSColor { surface(depth: depth + 1) }

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
