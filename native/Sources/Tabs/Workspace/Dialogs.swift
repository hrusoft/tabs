import AppKit
import CoreText
import TabsCore
import TabsPluginSDK

// MARK: - Dialog cards

/// The Electron app's `.modal` card (`global.css`, `core/dialogs.tsx`) for a
/// pane's question: a dimmed backdrop over the pane's window and, centered,
/// a 360-wide card of a title, a message (line breaks kept), for a choice a
/// select, and the buttons. It lives in the window's overlay, so it covers
/// that window only and the rest of the app carries on. Escape, or a click on
/// the backdrop, dismisses it; Return presses the primary button.
@MainActor
final class DialogCard: FlippedView {
    let dialog: PaneDialog
    let paneID: PaneID
    private let theme: Theme
    private weak var controller: WorkspaceWindowController?
    private let card = DialogPanel()
    private(set) var buttons: [DialogButton] = []
    private(set) var select: DialogSelect?
    /// The option a choose dialog would answer.
    private(set) var selection = 0
    private var complete: (@MainActor (PaneDialog.Answer) -> Void)?
    /// Whether it has been answered (and is gone).
    var isFinished: Bool { complete == nil }
    private weak var previousResponder: NSResponder?

    static let width: CGFloat = 360
    static let padding: CGFloat = 16
    static let gap: CGFloat = 12
    static let titleText = ChromeText(size: 14, weight: .semibold)
    static let messageText = ChromeText(size: 13)
    static let buttonText = ChromeText(size: 12)

    init(
        dialog: PaneDialog, pane: PaneID, controller: WorkspaceWindowController, complete: @escaping @MainActor (PaneDialog.Answer) -> Void
    ) {
        self.dialog = dialog
        paneID = pane
        self.controller = controller
        theme = controller.appearance.theme
        self.complete = complete
        super.init(frame: .zero)
        layer?.backgroundColor = theme.bg.withAlphaComponent(0.45).cgColor
        setAccessibilityIdentifier("dialog-backdrop")
        card.layer?.backgroundColor = theme.bgElevated.cgColor
        card.layer?.borderColor = theme.border.cgColor
        card.layer?.borderWidth = 1
        card.layer?.cornerRadius = 8
        card.layer?.masksToBounds = false
        card.setAccessibilityIdentifier("dialog")
        card.setAccessibilityRole(.group)
        card.setAccessibilityLabel(title)
        card.drawContent = { [unowned self] in self.drawCard() }
        addSubview(card)
        switch dialog {
        case .confirm(let confirm):
            addButton(confirm.cancelLabel, id: "dialog-cancel", primary: false) { [unowned self] in finish(.confirmed(false)) }
            addButton(confirm.confirmLabel, id: "dialog-confirm", primary: true) { [unowned self] in finish(.confirmed(true)) }
        case .choose(let choose):
            let field = DialogSelect(theme: theme)
            field.text = choose.options.first ?? ""
            field.onPress = { [unowned self] in openOptions() }
            select = field
            card.addSubview(field)
            addButton(choose.cancelLabel, id: "dialog-cancel", primary: false) { [unowned self] in finish(.chose(nil)) }
            addButton(choose.confirmLabel, id: "dialog-confirm", primary: true) { [unowned self] in
                finish(.chose(choose.options.isEmpty ? nil : selection))
            }
        case .alert(let alert):
            addButton(alert.buttonLabel, id: "dialog-ok", primary: true) { [unowned self] in finish(.acknowledged) }
        }
    }

    // MARK: What it says

    var title: String {
        switch dialog {
        case .confirm(let confirm): confirm.title
        case .choose(let choose): choose.title
        case .alert(let alert): alert.title
        }
    }

    var message: String {
        switch dialog {
        case .confirm(let confirm): confirm.message
        case .choose(let choose): choose.message
        case .alert(let alert): alert.message
        }
    }

    var options: [String] {
        if case .choose(let choose) = dialog { choose.options } else { [] }
    }

    private func addButton(_ label: String, id: String, primary: Bool, action: @escaping () -> Void) {
        let button = DialogButton(label: label, primary: primary, theme: theme)
        button.setAccessibilityIdentifier(id)
        button.onPress = action
        buttons.append(button)
        card.addSubview(button)
    }

    // MARK: Layout (the `.modal` box: padding 16, gap 12, border 1)

    private struct Metrics {
        var card: CGRect
        var title: CGPoint
        var messageLines: [String]
        var message: CGPoint
        var select: CGRect?
        var buttons: [CGRect]
    }

    private var metrics: Metrics {
        let inner = Self.width - 2 - 2 * Self.padding
        let titleHeight = Self.titleText.lineHeight
        let messageHeight = Self.messageText.lineHeight
        let selectHeight = Self.messageText.lineHeight + 10 + 2
        let buttonHeight = Self.buttonText.lineHeight + 12 + 2
        // `max-height: 80vh`: a message longer than the window has room for is cut.
        let maxHeight = bounds.height * 0.8
        let fixed =
            2 + 2 * Self.padding + titleHeight + Self.gap + Self.gap + (select == nil ? 0 : Self.gap + selectHeight) + 4 + buttonHeight
        var lines = message.isEmpty ? [] : Self.messageText.wrap(message, width: inner)
        let room = max(Int((maxHeight - fixed) / messageHeight), 1)
        if lines.count > room {
            lines = Array(lines.prefix(room))
            lines[room - 1] = Self.messageText.truncated(lines[room - 1] + "…", to: inner)
        }
        let messageBlock = CGFloat(lines.count) * messageHeight
        let height = fixed + messageBlock
        let cardSize = CGSize(width: Self.width, height: height)
        let origin = CGPoint(x: (bounds.width - cardSize.width) / 2, y: (bounds.height - cardSize.height) / 2)
        let cardRect = CGRect(origin: origin, size: cardSize)
        let left = 1 + Self.padding
        var y = 1 + Self.padding
        let titleOrigin = CGPoint(x: left, y: y + Self.titleText.ascent)
        y += titleHeight
        y += Self.gap
        let messageOrigin = CGPoint(x: left, y: y + Self.messageText.ascent)
        y += messageBlock
        var selectRect: CGRect?
        if select != nil {
            y += Self.gap
            selectRect = CGRect(x: left, y: y, width: inner, height: selectHeight)
            y += selectHeight
        }
        y += Self.gap + 4
        var buttonRects: [CGRect] = []
        var right = Self.width - 1 - Self.padding
        for button in buttons.reversed() {
            let width = Self.buttonText.width(button.label) + 24 + 2
            buttonRects.insert(CGRect(x: right - width, y: y, width: width, height: buttonHeight), at: 0)
            right -= width + 8
        }
        return Metrics(
            card: cardRect, title: titleOrigin, messageLines: lines, message: messageOrigin, select: selectRect,
            buttons: buttonRects)
    }

    override func layout() {
        super.layout()
        let metrics = metrics
        card.frame = metrics.card.snapped
        // Set here, not in `init`: AppKit resets a view layer's shadow before the view is shown.
        card.layer?.shadowColor = theme.shadow(0.5).cgColor
        card.layer?.shadowOpacity = 1
        card.layer?.shadowRadius = 40
        card.layer?.shadowOffset = CGSize(width: 0, height: -16)
        if let rect = metrics.select { select?.frame = rect.snapped }
        for (button, rect) in zip(buttons, metrics.buttons) { button.frame = rect.snapped }
        card.needsDisplay = true
    }

    private func drawCard() {
        let metrics = metrics
        Self.titleText.draw(title, at: metrics.title, color: theme.text)
        for (index, line) in metrics.messageLines.enumerated() {
            Self.messageText.draw(
                line, at: CGPoint(x: metrics.message.x, y: metrics.message.y + CGFloat(index) * Self.messageText.lineHeight),
                color: theme.text)
        }
    }

    // MARK: Showing and answering

    /// Puts the card over `controller`'s window and takes the keyboard.
    func present() {
        guard let controller else { return }
        let overlay = controller.root.overlay
        previousResponder = controller.window?.firstResponder
        frame = overlay.bounds
        autoresizingMask = [.width, .height]
        overlay.addSubview(self)
        layoutSubtreeIfNeeded()
        controller.window?.makeFirstResponder(self)
    }

    /// Ends the card with `answer`; only the first call counts.
    func finish(_ answer: PaneDialog.Answer) {
        guard let complete else { return }
        self.complete = nil
        let window = window
        removeFromSuperview()
        if let responder = previousResponder as? NSView, responder.window === window { window?.makeFirstResponder(responder) }
        complete(answer)
    }

    /// The user backed out, or the pane the question was about went away.
    func dismiss() { finish(dialog.dismissedAnswer) }

    /// Picks an option, as choosing it in the select does.
    func choose(option index: Int) {
        guard options.indices.contains(index) else { return }
        selection = index
        select?.text = options[index]
    }

    private func openOptions() {
        guard let controller, let select else { return }
        let origin = select.convert(CGPoint(x: 0, y: select.bounds.height), to: controller.root.overlay)
        let menu = ContextMenu.open(
            options.enumerated().map { index, title in ContextMenu.Item(title: title) { [weak self] in self?.choose(option: index) } },
            at: origin, in: controller)
        menu?.onClose = { [weak self] in
            guard let self, let window = self.window, self.complete != nil else { return }
            window.makeFirstResponder(self)
        }
    }

    // MARK: Input

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    override func mouseDown(with event: NSEvent) {
        if !card.frame.contains(convert(event.locationInWindow, from: nil)) { dismiss() }
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 || event.characters == "\u{1b}" {
            dismiss()
        } else if event.keyCode == 36 || event.keyCode == 76 || event.characters == "\r" {
            buttons.last?.onPress?()
        } else if !options.isEmpty, event.specialKey == .downArrow {
            choose(option: min(selection + 1, options.count - 1))
        } else if !options.isEmpty, event.specialKey == .upArrow {
            choose(option: max(selection - 1, 0))
        }
    }
}

/// The card's own box: its border and shadow are its layer's; the title and
/// message are drawn over them.
@MainActor
final class DialogPanel: FlippedView {
    var drawContent: (() -> Void)?

    override func draw(_ dirtyRect: NSRect) { drawContent?() }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// `.modal-button`: 12px in a bordered, 5-radius box (padding 6 12); the
/// primary one is the accent's (`.modal-button-primary`).
@MainActor
final class DialogButton: FlippedView {
    let label: String
    private let primary: Bool
    private let theme: Theme
    var onPress: (() -> Void)?
    private var hovered = false { didSet { needsDisplay = true } }
    private var tracking: NSTrackingArea?

    init(label: String, primary: Bool, theme: Theme) {
        self.label = label
        self.primary = primary
        self.theme = theme
        super.init(frame: .zero)
        setAccessibilityRole(.button)
        setAccessibilityLabel(label)
    }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 4.5, yRadius: 4.5)
        // `:hover` on the primary fades it to 0.9; on the plain one it takes the card's own shade.
        let fill = primary ? theme.accent.withAlphaComponent(hovered ? 0.9 : 1) : hovered ? theme.bgElevated : theme.bg
        fill.setFill()
        path.fill()
        (primary ? theme.accent.withAlphaComponent(hovered ? 0.9 : 1) : theme.border).setStroke()
        path.lineWidth = 1
        path.stroke()
        let text = DialogCard.buttonText
        text.draw(
            label, at: CGPoint(x: 1 + 12, y: text.baseline(centeredIn: bounds.height)), color: primary ? theme.onAccent : theme.text)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) { hovered = true }
    override func mouseExited(with event: NSEvent) { hovered = false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    override func mouseDown(with event: NSEvent) {}

    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onPress?() }
    }

    override func accessibilityPerformPress() -> Bool {
        onPress?()
        return true
    }
}

/// `.modal-select`: the choose dialog's one input, full width, 13px text in a
/// bordered box (padding 5 6, radius 5) with a menu-list chevron; pressing it
/// opens the options.
@MainActor
final class DialogSelect: FlippedView {
    private let theme: Theme
    var text = "" {
        didSet {
            needsDisplay = true
            setAccessibilityValue(text)
        }
    }
    var onPress: (() -> Void)?

    init(theme: Theme) {
        self.theme = theme
        super.init(frame: .zero)
        setAccessibilityIdentifier("dialog-select")
        setAccessibilityRole(.popUpButton)
        setAccessibilityLabel("Options")
    }

    override func draw(_ dirtyRect: NSRect) {
        theme.bg.setFill()
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 4.5, yRadius: 4.5)
        path.fill()
        theme.border.setStroke()
        path.lineWidth = 1
        path.stroke()
        let font = DialogCard.messageText
        font.draw(
            text, at: CGPoint(x: 1 + 6 + 4, y: font.baseline(centeredIn: bounds.height)), color: theme.text, maxWidth: bounds.width - 40)
        let arrow = NSBezierPath()
        let midY = bounds.height / 2
        arrow.move(to: CGPoint(x: bounds.maxX - 14.5, y: midY - 1.5))
        arrow.line(to: CGPoint(x: bounds.maxX - 11, y: midY + 2))
        arrow.line(to: CGPoint(x: bounds.maxX - 7.5, y: midY - 1.5))
        arrow.lineWidth = 2
        arrow.lineCapStyle = .round
        arrow.lineJoinStyle = .round
        theme.textDim.setStroke()
        arrow.stroke()
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    override func mouseDown(with event: NSEvent) { onPress?() }

    override func accessibilityPerformPress() -> Bool {
        onPress?()
        return true
    }
}

extension ChromeText {
    /// Lines for `white-space: pre-wrap` in `width`: explicit newlines kept,
    /// broken after spaces, a word wider than a line broken where it fills.
    func wrap(_ string: String, width: CGFloat) -> [String] {
        func trimmed(_ text: String) -> String {
            var copy = text
            while copy.hasSuffix(" ") { copy.removeLast() }
            return copy
        }
        var lines: [String] = []
        for paragraph in string.components(separatedBy: "\n") {
            var words: [String] = []
            var current = ""
            let characters = Array(paragraph)
            for (index, character) in characters.enumerated() {
                current.append(character)
                let next = index + 1 < characters.count ? characters[index + 1] : nil
                if character == " ", next != " " {
                    words.append(current)
                    current = ""
                }
            }
            if !current.isEmpty || words.isEmpty { words.append(current) }
            var line = ""
            func breakOverlong() {
                while self.width(trimmed(line)) > width + 0.01, line.count > 1 {
                    var head = ""
                    for character in line {
                        if !head.isEmpty && self.width(head + String(character)) > width + 0.01 { break }
                        head.append(character)
                    }
                    lines.append(head)
                    line = String(line.dropFirst(head.count))
                }
            }
            for word in words {
                if !line.isEmpty && self.width(line + trimmed(word)) > width + 0.01 {
                    lines.append(trimmed(line))
                    line = ""
                }
                line += word
                breakOverlong()
            }
            lines.append(trimmed(line))
        }
        return lines
    }
}

// MARK: - The renderer's side

extension WorkspaceRenderer {
    /// Asks a pane's question as a card in the window holding the pane. With
    /// no window shown (tests, headless) it answers at once, unless a test
    /// asked for the cards anyway (`showsDialogCardsUnattended`).
    func showDialog(_ dialog: PaneDialog, for pane: PaneID, completion: @escaping @MainActor (PaneDialog.Answer) -> Void) {
        guard presentsWindows || showsDialogCardsUnattended,
            let controller = engine.model.window(holding: pane).flatMap({ windowController($0.id) })
        else {
            completion(dialog.defaultAnswer)
            return
        }
        let card = DialogCard(dialog: dialog, pane: pane, controller: controller) { [weak self] answer in
            self?.dialogCards.removeAll { $0.isFinished }
            completion(answer)
        }
        dialogCards.append(card)
        card.present()
    }

    /// Asks for a file or directory in an open panel sheeted on the pane's
    /// window. With no window shown it answers what a test decided
    /// (`pickerOverride`), else cancelled.
    func showPicker(_ picker: PanePicker, for pane: PaneID, completion: @escaping @MainActor (URL?) -> Void) {
        if let pickerOverride { return completion(pickerOverride(picker)) }
        guard presentsWindows, let window = engine.model.window(holding: pane).flatMap({ windowController($0.id)?.window }) else {
            return completion(nil)
        }
        let panel = NSOpenPanel()
        panel.title = picker.title
        panel.message = picker.title
        panel.canChooseDirectories = picker.kind == .directory
        panel.canChooseFiles = picker.kind == .file
        panel.allowsMultipleSelection = false
        if let start = picker.startingAt {
            var isDirectory: ObjCBool = false
            let exists = FileManager.default.fileExists(atPath: start.path, isDirectory: &isDirectory)
            panel.directoryURL = exists && !isDirectory.boolValue ? start.deletingLastPathComponent() : start
        }
        panel.beginSheetModal(for: window) { response in
            let chosen = response == .OK ? panel.url : nil
            MainActor.assumeIsolated { completion(chosen) }
        }
    }

    /// Ends the cards of panes that have left the layout, so their askers
    /// aren't left waiting.
    func dismissDialogs(except live: Set<PaneID>) {
        for card in dialogCards where !live.contains(card.paneID) { card.dismiss() }
    }
}
