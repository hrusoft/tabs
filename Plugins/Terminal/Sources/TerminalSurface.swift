import AppKit
import SwiftTerm

/// What the terminal pane asks of the emulator that draws it: the seam where
/// SwiftTerm sits today, and where the libghostty Swift package could sit
/// tomorrow. The pty, the settings, links, the bell and titles stay the
/// pane's; the surface only emulates and draws.
@MainActor
protocol TerminalSurface: AnyObject {
    /// The pane's content view: the padded, background-filled terminal.
    var view: NSView { get }
    /// Whether the pane is its window's visible tab. While it isn't, the grid
    /// keeps its size whatever the view does, and it takes the view's size
    /// when shown again.
    var isShown: Bool { get set }
    var delegate: (any TerminalSurfaceDelegate)? { get set }
    /// The emulator's grid size.
    var columns: Int { get }
    var rows: Int { get }
    /// Output from the shell.
    func feed(_ bytes: [UInt8])
    /// Font, colors and cursor, live (a running program keeps its screen).
    func apply(_ appearance: TerminalAppearance)
    /// Lines kept above the screen, live; 0 keeps none.
    func setScrollback(_ lines: Int)
    /// Clears the terminal: the line the cursor is on becomes the first,
    /// everything else — scrollback included — goes. Refused (false) while a
    /// full-screen program owns the alternate screen: clearing it under the
    /// program would leave it half-painted.
    @discardableResult func clear() -> Bool
    var isAlternateScreen: Bool { get }
    /// Takes the keyboard.
    func focus()
    var hasFocus: Bool { get }
    /// The visible rows, as text (tests, the Debug verbs).
    var screenText: String { get }
    /// Every line of the active buffer, scrollback included, as text.
    var bufferText: String { get }
}

@MainActor
protocol TerminalSurfaceDelegate: AnyObject {
    /// Bytes the user typed or pasted, for the shell.
    func surfaceSend(_ bytes: ArraySlice<UInt8>)
    /// The grid changed size.
    func surfaceDidResize(columns: Int, rows: Int)
    /// OSC 0/2 from the program.
    func surfaceTitleDidChange(_ title: String)
    /// BEL from the program.
    func surfaceBell()
    /// The user ⌘-clicked a link (OSC 8, or a URL in the text).
    func surfaceOpenLink(_ link: String)
}

/// The surface on SwiftTerm's `TerminalView`: Option types characters (not
/// Meta), xterm's 256 colors, no semantic-prompt clicks, no sound on BEL,
/// links only with ⌘ (and through the pane, which opens only web and mail
/// links).
@MainActor
final class SwiftTermSurface: NSObject, TerminalSurface, @MainActor TerminalViewDelegate {
    private let container: TerminalContainerView
    let terminalView: TabsTerminalView
    weak var delegate: (any TerminalSurfaceDelegate)?
    private var appearance: TerminalAppearance

    init(appearance: TerminalAppearance, scrollback: Int, metal: Bool) {
        self.appearance = appearance
        // Where SwiftTerm has a switch: no sixel in the device attributes, no
        // bidi reordering (text shows in the order it arrives), and kitty
        // images kept small.
        let options = TerminalOptions(
            cols: 80, rows: 24, cursorStyle: Self.cursorStyle(appearance), scrollback: TerminalSettings.scrollbackLines(scrollback),
            enableSixelReported: false, kittyImageCacheLimitBytes: 16 * 1024 * 1024, ansi256PaletteStrategy: .xterm,
            initialBidiState: BidiPresentationState(supportMode: .explicit))
        terminalView = TabsTerminalView(frame: .zero, font: Self.font(appearance), options: options)
        container = TerminalContainerView(terminal: terminalView)
        super.init()
        terminalView.terminalDelegate = self
        terminalView.optionAsMetaKey = false
        terminalView.bellStyle = .sound  // reaches our delegate's bell(source:), which makes no sound
        let terminal = terminalView.getTerminal()
        terminal.silentLog = true
        terminal.semanticPromptClickBehavior = .disabled
        // OSC 9 (notifications, and SwiftTerm's progress bar for 9;4): ignored.
        terminal.registerOscHandler(code: 9) { _ in }
        if metal { try? terminalView.setUseMetal(true) }
        applyColors(appearance)
        terminalView.lineSpacing = CGFloat(appearance.lineHeight)
    }

    var view: NSView { container }

    var isShown: Bool {
        get { container.isShown }
        set { container.isShown = newValue }
    }

    var columns: Int { terminalView.getTerminal().cols }
    var rows: Int { terminalView.getTerminal().rows }

    func feed(_ bytes: [UInt8]) {
        terminalView.feed(byteArray: bytes[...])
        // SwiftTerm drops the selection on every feed while it may report the
        // mouse; let it report only while a program asked for the mouse.
        terminalView.allowMouseReporting = terminalView.getTerminal().mouseMode != .off
    }

    func apply(_ appearance: TerminalAppearance) {
        let previous = self.appearance
        self.appearance = appearance
        let font = Self.font(appearance)
        if font != terminalView.font || appearance.lineHeight != previous.lineHeight {
            // A font change resizes through SwiftTerm's `resize`, which also
            // soft-resets the terminal (a running vim loses its modes); with no
            // frame it skips that, and setting the frame back resizes plainly.
            let size = terminalView.frame.size
            terminalView.setFrameSize(.zero)
            terminalView.lineSpacing = CGFloat(appearance.lineHeight)
            terminalView.font = font
            terminalView.setFrameSize(size)
        }
        applyColors(appearance)
        if Self.cursorStyle(appearance) != Self.cursorStyle(previous) {
            terminalView.getTerminal().setCursorStyle(Self.cursorStyle(appearance))
        }
    }

    private func applyColors(_ appearance: TerminalAppearance) {
        let foreground = NSColor(hex: appearance.foreground) ?? .white
        let background = NSColor(hex: appearance.background) ?? .black
        terminalView.installColors(appearance.ansi.all.map { SwiftTerm.Color(nsColor: NSColor(hex: $0) ?? foreground) })
        terminalView.nativeForegroundColor = foreground
        terminalView.nativeBackgroundColor = background
        terminalView.caretColor = NSColor(hex: appearance.cursorColor) ?? foreground
        // The glyph under a block cursor is drawn in the background color.
        terminalView.caretTextColor = background
        terminalView.selectedTextBackgroundColor = NSColor(hex: appearance.selectionBackground) ?? .selectedTextBackgroundColor
        terminalView.selectedTextForegroundColor = foreground
        container.background = background
    }

    func setScrollback(_ lines: Int) {
        // 0, not nil: nil would also stop reflowing on resize.
        terminalView.changeScrollback(TerminalSettings.scrollbackLines(lines))
    }

    @discardableResult
    func clear() -> Bool {
        let terminal = terminalView.getTerminal()
        guard !terminal.isCurrentBufferAlternate else { return false }
        let row = terminal.buffer.y
        // Scroll the cursor's line up to the top, then drop the history.
        if row > 0 { terminalView.feed(text: "\u{1b}[\(row)S\u{1b}[\(row)A") }
        terminalView.clearScrollback()
        // SwiftTerm keeps "the user scrolled up" through the clear, and output
        // would stop following the bottom; scrolling to it resets that.
        terminalView.scroll(toPosition: 1)
        return true
    }

    var isAlternateScreen: Bool { terminalView.getTerminal().isCurrentBufferAlternate }

    func focus() {
        terminalView.window?.makeFirstResponder(terminalView)
    }

    var hasFocus: Bool { terminalView.window?.firstResponder === terminalView }

    var screenText: String {
        let terminal = terminalView.getTerminal()
        return (0..<terminal.rows).compactMap { terminal.getLine(row: $0)?.translateToString(trimRight: true) }
            .joined(separator: "\n")
    }

    var bufferText: String {
        String(decoding: terminalView.getTerminal().getBufferAsData(), as: UTF8.self)
    }

    // MARK: Settings to SwiftTerm

    /// The appearance's font; the system monospaced font when the family
    /// isn't installed (the default, JetBrains Mono NL, may not be).
    static func font(_ appearance: TerminalAppearance) -> NSFont {
        let size = CGFloat(min(max(appearance.fontSize, TerminalAppearance.fontSizes.lowerBound), TerminalAppearance.fontSizes.upperBound))
        return NSFontManager.shared.font(withFamily: appearance.fontFamily, traits: [], weight: 5, size: size)
            ?? .monospacedSystemFont(ofSize: size, weight: .regular)
    }

    static func cursorStyle(_ appearance: TerminalAppearance) -> CursorStyle {
        switch (appearance.cursorStyle, appearance.cursorBlink) {
        case (.block, true): .blinkBlock
        case (.block, false): .steadyBlock
        case (.bar, true): .blinkBar
        case (.bar, false): .steadyBar
        case (.underline, true): .blinkUnderline
        case (.underline, false): .steadyUnderline
        }
    }

    // MARK: TerminalViewDelegate

    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
        // The terminal's own numbers: SwiftTerm reports the unclamped ones.
        delegate?.surfaceDidResize(columns: columns, rows: rows)
    }

    func setTerminalTitle(source: TerminalView, title: String) {
        delegate?.surfaceTitleDidChange(title)
    }

    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}

    func send(source: TerminalView, data: ArraySlice<UInt8>) {
        delegate?.surfaceSend(data)
    }

    func scrolled(source: TerminalView, position: Double) {}

    func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}

    func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
        delegate?.surfaceOpenLink(link)
    }

    func bell(source: TerminalView) {
        delegate?.surfaceBell()
    }

    func clipboardCopy(source: TerminalView, content: Data) {}
}

/// The terminal's padding (4 top, 8 left), painted in the terminal's
/// background — as is whatever is left past the last whole cell. A click
/// anywhere in it gives the terminal the keyboard.
@MainActor
final class TerminalContainerView: NSView {
    static let padding = NSEdgeInsets(top: 4, left: 8, bottom: 0, right: 0)
    let terminal: TabsTerminalView

    var background: NSColor = .black {
        didSet { layer?.backgroundColor = background.cgColor }
    }

    /// See `TerminalSurface.isShown`: the terminal is placed only while shown.
    var isShown = false {
        didSet { if isShown, !oldValue { placeTerminal() } }
    }

    init(terminal: TabsTerminalView) {
        self.terminal = terminal
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = background.cgColor
        addSubview(terminal)
        setAccessibilityIdentifier("terminal")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    // Core sizes a plugin's view by autoresizing (`resizeSubviews`) as well as
    // by layout: the terminal follows either way.
    override func layout() {
        super.layout()
        placeTerminal()
    }

    override func resizeSubviews(withOldSize oldSize: NSSize) {
        super.resizeSubviews(withOldSize: oldSize)
        placeTerminal()
    }

    private func placeTerminal() {
        guard isShown else { return }
        let padding = Self.padding
        let width = bounds.width - padding.left - padding.right
        let height = bounds.height - padding.top - padding.bottom
        // Never a degenerate frame: SwiftTerm would reflow to it.
        let frame =
            width >= 1 && height >= 1
            ? CGRect(x: padding.left, y: isFlipped ? padding.top : padding.bottom, width: width, height: height) : .zero
        if terminal.frame != frame { terminal.frame = frame }
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(terminal)
    }

    override var acceptsFirstResponder: Bool { false }
}

/// SwiftTerm's view, with its own paste and right-click.
@MainActor
final class TabsTerminalView: TerminalView {
    /// Paste: line breaks become carriage returns (what Return sends),
    /// bracketed when the program asked for it.
    override func paste(_ sender: Any) {
        guard let text = NSPasteboard.general.string(forType: .string), !text.isEmpty else { return }
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\r").replacingOccurrences(of: "\n", with: "\r")
        let bracketed = getTerminal().bracketedPasteMode
        var bytes: [UInt8] = []
        if bracketed { bytes += Array("\u{1b}[200~".utf8) }
        bytes += Array(normalized.utf8)
        if bracketed { bytes += Array("\u{1b}[201~".utf8) }
        send(data: bytes[...])
    }

    /// A right-click selects the word under it — through SwiftTerm's own
    /// double-click — unless a program has the mouse.
    override func rightMouseDown(with event: NSEvent) {
        guard getTerminal().mouseMode == .off, let window else { return super.rightMouseDown(with: event) }
        window.makeFirstResponder(self)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            if let click = NSEvent.mouseEvent(
                with: type, location: event.locationInWindow, modifierFlags: [], timestamp: event.timestamp,
                windowNumber: event.windowNumber, context: nil, eventNumber: 0, clickCount: 2, pressure: 1)
            {
                if type == .leftMouseDown { mouseDown(with: click) } else { mouseUp(with: click) }
            }
        }
    }
}
