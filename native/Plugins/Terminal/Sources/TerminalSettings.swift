import AppKit
import TabsPluginSDK

/// Shape of the text cursor — Terminal.app's CursorType profile key.
enum TerminalCursorStyle: String, Codable, CaseIterable, Sendable {
    case block, bar, underline

    var label: String {
        switch self {
        case .block: "Block"
        case .bar: "Bar"
        case .underline: "Underline"
        }
    }
}

/// The 16-color ANSI palette (8 normal + 8 bright), as `#rrggbb` strings.
struct TerminalAnsiColors: Codable, Equatable, Sendable {
    var black = "#35424c"
    var red = "#b45648"
    var green = "#6caa71"
    var yellow = "#c4ac62"
    var blue = "#6d96b4"
    var magenta = "#bd7bcd"
    var cyan = "#7ccbcd"
    var white = "#dee5eb"
    var brightBlack = "#465c6d"
    var brightRed = "#df6c5a"
    var brightGreen = "#79be7e"
    var brightYellow = "#e5c872"
    var brightBlue = "#67b5ed"
    var brightMagenta = "#d389e5"
    var brightCyan = "#84dde0"
    var brightWhite = "#e5eff5"

    /// Every color in palette order (0–15), with its label: the settings
    /// page's two rows and the emulator's palette both come from this one list.
    static var slots: [(key: WritableKeyPath<TerminalAnsiColors, String>, label: String)] {
        [
            (\.black, "Black"), (\.red, "Red"), (\.green, "Green"), (\.yellow, "Yellow"),
            (\.blue, "Blue"), (\.magenta, "Magenta"), (\.cyan, "Cyan"), (\.white, "White"),
            (\.brightBlack, "Bright Black"), (\.brightRed, "Bright Red"), (\.brightGreen, "Bright Green"),
            (\.brightYellow, "Bright Yellow"), (\.brightBlue, "Bright Blue"), (\.brightMagenta, "Bright Magenta"),
            (\.brightCyan, "Bright Cyan"), (\.brightWhite, "Bright White"),
        ]
    }

    var all: [String] { Self.slots.map { self[keyPath: $0.key] } }
}

/// Font and colors for every terminal pane. The defaults are a real macOS
/// Terminal.app "Clear Dark" profile, as the Electron app's are. The palette
/// is user data: it doesn't follow the app's theme.
struct TerminalAppearance: Codable, Equatable, Sendable {
    var fontFamily = "JetBrains Mono NL"
    var fontSize: Double = 15
    var lineHeight: Double = 1
    var cursorStyle = TerminalCursorStyle.bar
    var cursorBlink = true
    var background = "#06225f"
    var foreground = "#e0e0e0"
    var cursorColor = "#ffffff"
    var selectionBackground = "#273d4c"
    var ansi = TerminalAnsiColors()

    static let fontSizes: ClosedRange<Double> = 8...32
    static let lineHeights: ClosedRange<Double> = 0.8...2
}

/// The terminal's settings (Settings ▸ Terminal). Stored values merge over
/// these defaults at every depth, so a field added later decodes.
struct TerminalSettings: PluginSettingsValue {
    /// A new tab or split made from a pane starts in that pane's live directory.
    var inheritCwdOnNewPane = true
    /// New panes draw with Metal (the Electron app's WebGL rendering). Off by
    /// default: CoreGraphics is SwiftTerm's mature path.
    var enableMetalRendering = false
    /// Lines of history above the screen, per pane; 0 keeps none. Applies to
    /// open panes at once. Used through `scrollbackLines`.
    var scrollback = 1000
    var appearance = TerminalAppearance()

    /// The most scrollback a pane keeps. SwiftTerm allocates the whole ring up
    /// front (xterm.js's grows as it fills), so a typo can't be allowed to
    /// reserve gigabytes in every pane, at every launch.
    static let maxScrollback = 100_000

    /// The scrollback a pane actually keeps for a stored value: 0 to `maxScrollback`.
    static func scrollbackLines(_ stored: Int) -> Int { min(max(stored, 0), maxScrollback) }
}

extension NSColor {
    /// `#rrggbb` (or `#rgb`), in sRGB; nil for anything else.
    convenience init?(hex: String) {
        var digits = hex.trimmingCharacters(in: .whitespaces)
        guard digits.hasPrefix("#") else { return nil }
        digits.removeFirst()
        if digits.count == 3 { digits = digits.map { "\($0)\($0)" }.joined() }
        guard digits.count == 6, let value = UInt32(digits, radix: 16) else { return nil }
        self.init(
            srgbRed: CGFloat((value >> 16) & 0xff) / 255, green: CGFloat((value >> 8) & 0xff) / 255,
            blue: CGFloat(value & 0xff) / 255, alpha: 1)
    }

    /// `#rrggbb` in sRGB.
    var hexString: String {
        let color = usingColorSpace(.sRGB) ?? self
        func byte(_ component: CGFloat) -> Int { Int((min(max(component, 0), 1) * 255).rounded()) }
        return String(format: "#%02x%02x%02x", byte(color.redComponent), byte(color.greenComponent), byte(color.blueComponent))
    }
}
