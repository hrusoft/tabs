import AppKit
import TabsCore
import TabsPluginSDK

/// The chrome's colors: the SDK's `PaneTheme`, the one definition core and
/// plugins paint with. The themes themselves are files (`runtime.themes`, docs/THEMES.md).
typealias Theme = PaneTheme

extension NSColor {
    /// `color-mix(in srgb, self p%, other)`.
    func mixed(_ fraction: Double, with other: NSColor) -> NSColor {
        let a = usingColorSpace(.sRGB) ?? self
        let b = other.usingColorSpace(.sRGB) ?? other
        let alpha = a.alphaComponent * fraction + b.alphaComponent * (1 - fraction)
        guard alpha > 0 else { return .clear }
        // Premultiplied, as color-mix interpolates.
        func channel(_ x: CGFloat, _ y: CGFloat) -> CGFloat {
            (x * a.alphaComponent * fraction + y * b.alphaComponent * (1 - fraction)) / alpha
        }
        return NSColor(
            srgbRed: channel(a.redComponent, b.redComponent), green: channel(a.greenComponent, b.greenComponent),
            blue: channel(a.blueComponent, b.blueComponent), alpha: alpha)
    }

    /// `color-mix(in srgb, self p%, transparent)`.
    func mixedWithTransparent(_ fraction: Double) -> NSColor {
        (usingColorSpace(.sRGB) ?? self).withAlphaComponent(alphaComponent * fraction)
    }

    /// CSS `filter: grayscale(g) brightness(b)`, applied in sRGB: how an
    /// inactive pane's content is dimmed.
    func dimmed(grayscale g: Double, brightness b: Double) -> NSColor {
        guard let c = usingColorSpace(.sRGB) else { return self }
        let (r, gr, bl) = (Double(c.redComponent), Double(c.greenComponent), Double(c.blueComponent))
        let next = Dimming.grayscale(g).map { row in row.r * r + row.g * gr + row.b * bl }
        func clamp(_ x: Double) -> CGFloat { CGFloat(min(max(x * b, 0), 1)) }
        return NSColor(srgbRed: clamp(next[0]), green: clamp(next[1]), blue: clamp(next[2]), alpha: c.alphaComponent)
    }
}

/// How an inactive pane's content is dimmed: CSS `grayscale(g)`, then
/// `brightness(b)` scaling the result. One source for the colors the chrome
/// dims itself (`NSColor.dimmed`) and the filter over a plugin's view
/// (`PaneBodyHost`).
enum Dimming {
    /// `grayscale(g)`'s matrix over sRGB: one row per channel of the result,
    /// its weights for red, green and blue.
    static func grayscale(_ g: Double) -> [(r: Double, g: Double, b: Double)] {
        let k = 1 - g
        return [
            (0.2126 + 0.7874 * k, 0.7152 - 0.7152 * k, 0.0722 - 0.0722 * k),
            (0.2126 - 0.2126 * k, 0.7152 + 0.2848 * k, 0.0722 - 0.0722 * k),
            (0.2126 - 0.2126 * k, 0.7152 - 0.7152 * k, 0.0722 + 0.9278 * k),
        ]
    }
}

extension NSAppearance {
    /// What the Theme setting pins the whole app to: dark or light Aqua as the theme it resolved
    /// to is (`isDark`); nil for `system`, which leaves it to the OS. Set on `NSApp`, it reaches
    /// every window, alert, file panel, menu and web page the app puts up.
    static func pinned(by setting: String, theme: Theme) -> NSAppearance? {
        setting == ThemeCatalog.system ? nil : NSAppearance(named: theme.isDark ? .darkAqua : .aqua)
    }
}

/// What the chrome is drawn with: the pane settings, and the state it follows.
struct PaneAppearance: Equatable {
    var theme: Theme = .placeholder
    var dimInactivePanes = true
    var dimIntensity = 0.34
    var showNavFlash = true
    var snapResizeSeparators = true
    /// Tabs the user didn't name show their pane's title (`LayoutEngine.tabTitle`).
    var tabTitlesFollowPanes = true
    /// The OS window's corner radius, which the bottom corners of the
    /// outermost panes follow (0 in fullscreen).
    var cornerRadius: CGFloat = 16
    /// The managed caffeinate process runs: the docked root's bar shows the cup.
    var caffeinateRunning = false

    /// What dims an inactive pane's content, or nil.
    var dim: (grayscale: Double, brightness: Double)? {
        guard dimInactivePanes else { return nil }
        let intensity = min(1, max(0, dimIntensity))
        return (intensity, 1 - 0.7 * intensity)
    }
}
