import AppKit

/// The About window's behaviour: what a press does, and which Copy buttons say "Copied".
///
/// The OS calls are injected so a test can watch them instead of opening a browser or
/// overwriting the user's pasteboard.
@MainActor
final class AboutModel {
    /// How long a Copy button says "Copied".
    static let confirmation: Duration = .milliseconds(1500)

    /// The running build's own version, never a restated literal.
    let version: String
    /// What the build links, as core and the bundled plugins credit it.
    let credits: [Attribution]
    private let opener: @MainActor (URL) -> Void
    private let pasteboard: @MainActor (String) -> Void
    private let sleep: @Sendable (Duration) async throws -> Void
    /// The addresses whose Copy button says "Copied" now. Each button keeps its own
    /// confirmation and its own timer.
    private(set) var copied: Set<String> = [] { didSet { if copied != oldValue { onChange?() } } }
    private var timers: [String: Task<Void, Never>] = [:]
    /// Told whenever `copied` changes, so the buttons redraw.
    var onChange: (() -> Void)?

    init(
        version: String = AboutModel.runningVersion, credits: [Attribution] = Attributions.all(in: .main),
        opener: @escaping @MainActor (URL) -> Void = AboutModel.openInBrowser,
        pasteboard: @escaping @MainActor (String) -> Void = AboutModel.writeToPasteboard,
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) {
        self.version = version
        self.credits = credits
        self.opener = opener
        self.pasteboard = pasteboard
        self.sleep = sleep
    }

    /// Hands `url` to the OS browser, unless it is not an http(s) or mailto URL: then nothing
    /// happens at all. A credit or a tier never navigates the window.
    func open(_ url: String) {
        guard let vetted = ExternalURL.vetted(url) else { return }
        opener(vetted)
    }

    /// Puts `entry`'s address on the pasteboard and confirms it on its button for a moment; a press
    /// during the confirmation restarts it.
    func copy(_ entry: CryptoAddress) {
        pasteboard(entry.address)
        copied.insert(entry.id)
        timers[entry.id]?.cancel()
        let sleep = sleep
        timers[entry.id] = Task { [weak self] in
            try? await sleep(Self.confirmation)
            guard !Task.isCancelled else { return }
            self?.timers[entry.id] = nil
            self?.copied.remove(entry.id)
        }
    }

    /// The window is closing: no timer outlives it.
    func stop() {
        for timer in timers.values { timer.cancel() }
        timers.removeAll()
        copied = []
    }

    // MARK: The real calls

    /// The bundle's own version: what the stock About panel shows.
    static var runningVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
    }

    /// Opens `url` in the default browser or mail client; the OS declining is logged, never fatal.
    static func openInBrowser(_ url: URL) {
        if !NSWorkspace.shared.open(url) {
            FileHandle.standardError.write(Data("[tabs] failed to open a URL externally: \(url.absoluteString)\n".utf8))
        }
    }

    /// Replaces the pasteboard's contents with `text`.
    static func writeToPasteboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }
}

/// Every measurement of the window's content, in points. The window around it is a standard
/// one (docs/ABOUT.md).
enum AboutMetrics {
    /// The content's size; the window's own title bar is outside this.
    static let bodySize = NSSize(width: 460, height: 630)
    /// The body's padding: 24 28 28.
    static let padding = NSEdgeInsets(top: 24, left: 28, bottom: 28, right: 28)
    static var contentWidth: CGFloat { bodySize.width - padding.left - padding.right }

    static let iconSize: CGFloat = 72
    /// 10 below the icon, plus the identity block's 2pt gap.
    static let gap: CGFloat = 2
    static let afterIcon: CGFloat = 10 + gap
    static let afterVersion: CGFloat = 8 + gap
    static let afterTagline: CGFloat = 10 + gap

    /// A section: 26 above it, a 1pt top border, then 20 of padding.
    static let sectionGap: CGFloat = 26
    static let sectionPadding: CGFloat = 20
    static let titleGap: CGFloat = 4
    static let descriptionGap: CGFloat = 12
    /// A section description's line height: 1.5 at 12pt.
    static let descriptionLine: CGFloat = 18

    static let tierGap: CGFloat = 8
    static let tierInset = NSEdgeInsets(top: 10, left: 12, bottom: 10, right: 12)
    static let tierColumnGap: CGFloat = 12
    static let tierAmountMinWidth: CGFloat = 86
    static let tierRadius: CGFloat = 8

    static let addressGap: CGFloat = 10
    static let addressRowGap: CGFloat = 4
    static let copyMinWidth: CGFloat = 58
    static let creditPadding: CGFloat = 3
}

// MARK: - Window

/// The About window: a standard titled window, never resizable, zoomable or full screen, holding
/// the scrolling body. Dropped by whoever holds it when it closes.
@MainActor
final class AboutWindowController: NSWindowController, NSWindowDelegate {
    let model: AboutModel
    let body: AboutBodyView
    /// Told when the window closes.
    var onClose: (() -> Void)?

    init(model: AboutModel = AboutModel()) {
        self.model = model
        body = AboutBodyView(model: model)
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: AboutMetrics.bodySize), styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered, defer: false)
        window.title = AboutCopy.windowTitle
        window.isReleasedWhenClosed = false
        // Not maximizable, not fullscreenable: its content is a fixed column of prose.
        window.standardWindowButton(.zoomButton)?.isEnabled = false
        window.collectionBehavior.insert(.fullScreenNone)
        window.contentView = body
        window.setContentSize(AboutMetrics.bodySize)
        window.center()
        super.init(window: window)
        window.delegate = self
        body.layoutSubtreeIfNeeded()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    func windowWillClose(_ notification: Notification) {
        model.stop()
        onClose?()
    }
}

/// The one About window of the app: opened on demand, brought forward if already open, dropped
/// when it closes so the next one is fresh.
@MainActor
final class AboutPresenter {
    private(set) var controller: AboutWindowController?
    private let makeController: () -> AboutWindowController
    /// False under the end-to-end hidden mode: the window is built but never shown or focused.
    private let presentsWindows: Bool

    init(presentsWindows: Bool, makeController: @escaping () -> AboutWindowController = { AboutWindowController() }) {
        self.presentsWindows = presentsWindows
        self.makeController = makeController
    }

    /// Shows and focuses the window, creating it if there isn't one yet.
    @discardableResult
    func show() -> AboutWindowController {
        let controller = controller ?? make()
        if presentsWindows {
            controller.showWindow(nil)
            controller.window?.makeKeyAndOrderFront(nil)
        }
        return controller
    }

    private func make() -> AboutWindowController {
        let controller = makeController()
        controller.onClose = { [weak self, weak controller] in
            // A newer window may already hold the slot.
            if self?.controller === controller { self?.controller = nil }
        }
        self.controller = controller
        return controller
    }

    /// Closes it without a trace (a test reset).
    func dismiss() {
        let controller = controller
        self.controller = nil
        controller?.model.stop()
        controller?.window?.close()
    }
}

// MARK: - Body

/// The window's content: a scroll view holding the identity block and the three sections, so
/// that what doesn't fit scrolls instead of growing the window.
@MainActor
final class AboutBodyView: NSView {
    let model: AboutModel
    let scrollView = NSScrollView()
    private let column = NSStackView()
    private var copyButtons: [String: CopyButton] = [:]
    private(set) var tierButtons: [String: TierButton] = [:]
    private(set) var creditButtons: [String: LinkButton] = [:]
    private(set) var addressLabels: [String: NSTextField] = [:]
    private(set) var versionLabel = NSTextField()
    private(set) var sections: [String: NSView] = [:]

    init(model: AboutModel) {
        self.model = model
        super.init(frame: NSRect(origin: .zero, size: AboutMetrics.bodySize))
        setAccessibilityIdentifier("about-window")
        build()
        model.onChange = { [weak self] in self?.refreshCopyButtons() }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    /// Every label on the page, top to bottom (for assertions and the e2e read).
    var texts: [String] {
        func collect(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(collect) }
        let all = collect(column)
        return all.compactMap { ($0 as? NSTextField)?.stringValue ?? ($0 as? NSButton).flatMap { $0.title.isEmpty ? nil : $0.title } }
    }

    // MARK: Build

    private func build() {
        let document = FlippedContainer()
        document.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = document
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        // Overlay, always: the column is exactly as wide as the window says, whatever the mouse.
        scrollView.scrollerStyle = .overlay
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scrollView)

        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 0
        column.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(column)

        let padding = AboutMetrics.padding
        let clip = scrollView.contentView
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            document.topAnchor.constraint(equalTo: clip.topAnchor),
            document.leadingAnchor.constraint(equalTo: clip.leadingAnchor),
            document.trailingAnchor.constraint(equalTo: clip.trailingAnchor),
            column.topAnchor.constraint(equalTo: document.topAnchor, constant: padding.top),
            column.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: padding.left),
            column.trailingAnchor.constraint(equalTo: document.trailingAnchor, constant: -padding.right),
            column.bottomAnchor.constraint(equalTo: document.bottomAnchor, constant: -padding.bottom),
        ])

        let identity = makeIdentity()
        column.addArrangedSubview(identity)
        identity.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true
        // Credits only when the build links something to credit.
        for section in [makeDonations(), makeCrypto()] + (model.credits.isEmpty ? [] : [makeCredits()]) {
            column.setCustomSpacing(AboutMetrics.sectionGap, after: column.arrangedSubviews.last ?? identity)
            column.addArrangedSubview(section)
            section.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true
        }
    }

    /// The identity block: the icon, the name, the version, the tagline and the copyright, centred.
    private func makeIdentity() -> NSView {
        let icon = NSImageView()
        // Decorative: the app's name is stated right below, so announcing the icon too would just repeat it.
        icon.image = NSImage(named: NSImage.applicationIconName) ?? NSApp.applicationIconImage
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.setAccessibilityElement(false)
        icon.setAccessibilityIdentifier("about-icon")
        icon.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            icon.widthAnchor.constraint(equalToConstant: AboutMetrics.iconSize),
            icon.heightAnchor.constraint(equalToConstant: AboutMetrics.iconSize),
        ])

        let name = label(AboutCopy.name, size: 22, weight: .semibold)
        name.setAccessibilityRole(.staticText)
        name.setAccessibilityIdentifier("about-name")
        // The version is the one thing here anyone ever needs to quote into a bug report, so it
        // is selectable even though the rest of the block reads as chrome.
        versionLabel = label(AboutCopy.version(model.version), size: 12, color: .secondaryLabelColor)
        versionLabel.isSelectable = true
        versionLabel.setAccessibilityIdentifier("about-version")
        let tagline = label(AboutCopy.tagline, size: 12.5, color: .secondaryLabelColor)
        tagline.setAccessibilityIdentifier("about-tagline")
        let copyright = label(AboutCopy.copyright, size: 11.5, color: .secondaryLabelColor)
        copyright.setAccessibilityIdentifier("about-copyright")

        let stack = NSStackView(views: [icon, name, versionLabel, tagline, copyright])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = AboutMetrics.gap
        stack.setCustomSpacing(AboutMetrics.afterIcon, after: icon)
        stack.setCustomSpacing(AboutMetrics.afterVersion, after: versionLabel)
        stack.setCustomSpacing(AboutMetrics.afterTagline, after: tagline)
        stack.setAccessibilityIdentifier("about-identity")
        return stack
    }

    /// A section: a hairline, its title and description, then its content.
    private func makeSection(id: String, title: String, description: String, content: NSView) -> NSView {
        let rule = NSBox()
        rule.boxType = .custom
        rule.borderWidth = 0
        rule.fillColor = .separatorColor
        rule.titlePosition = .noTitle
        rule.translatesAutoresizingMaskIntoConstraints = false
        rule.heightAnchor.constraint(equalToConstant: 1).isActive = true

        let titleLabel = label(title, size: 13, weight: .semibold)
        let descriptionLabel = label(
            description, size: 12, color: .secondaryLabelColor, wraps: true, lineHeight: AboutMetrics.descriptionLine)

        let stack = NSStackView(views: [rule, titleLabel, descriptionLabel, content])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 0
        stack.setCustomSpacing(AboutMetrics.sectionPadding, after: rule)
        stack.setCustomSpacing(AboutMetrics.titleGap, after: titleLabel)
        stack.setCustomSpacing(AboutMetrics.descriptionGap, after: descriptionLabel)
        stack.setAccessibilityIdentifier(id)
        for view in [rule, descriptionLabel, content] { view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
        sections[id] = stack
        return stack
    }

    /// The donations section.
    private func makeDonations() -> NSView {
        let tiers = NSStackView()
        tiers.orientation = .vertical
        tiers.alignment = .leading
        tiers.spacing = AboutMetrics.tierGap
        for tier in Donations.tiers {
            let button = TierButton(tier: tier) { [model] in model.open(tier.url) }
            tierButtons[tier.id] = button
            tiers.addArrangedSubview(button)
            button.widthAnchor.constraint(equalTo: tiers.widthAnchor).isActive = true
        }
        return makeSection(
            id: "about-donations", title: AboutCopy.donationsTitle, description: AboutCopy.donationsDescription, content: tiers)
    }

    /// The crypto section.
    private func makeCrypto() -> NSView {
        let rows = NSStackView()
        rows.orientation = .vertical
        rows.alignment = .leading
        rows.spacing = AboutMetrics.addressGap
        for entry in Donations.addresses {
            let row = makeAddressRow(entry)
            rows.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: rows.widthAnchor).isActive = true
        }
        return makeSection(id: "about-crypto", title: AboutCopy.cryptoTitle, description: AboutCopy.cryptoDescription, content: rows)
    }

    /// One address row: the chain's label and ticker, its address in full (wrapped, never
    /// truncated), and the Copy button beside them both.
    private func makeAddressRow(_ entry: CryptoAddress) -> NSView {
        let title = NSMutableAttributedString(
            string: entry.label + " ",
            attributes: [.font: NSFont.systemFont(ofSize: 12, weight: .medium), .foregroundColor: NSColor.labelColor])
        title.append(
            NSAttributedString(
                string: entry.symbol, attributes: [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.secondaryLabelColor]))
        let name = NSTextField(labelWithAttributedString: title)
        name.setAccessibilityIdentifier("about-address-label-\(entry.id)")

        // Wrapped rather than truncated: an address the user can read in full is what makes the copy
        // button trustworthy. No break opportunities of its own, so any character may end a line.
        let address = label(entry.address, size: 11, color: .secondaryLabelColor, wraps: true, mono: true)
        address.lineBreakMode = .byCharWrapping
        address.isSelectable = true
        address.setAccessibilityIdentifier("about-address-\(entry.id)")
        addressLabels[entry.id] = address

        let copy = CopyButton(entry: entry) { [model] in model.copy(entry) }
        copyButtons[entry.id] = copy

        let text = NSStackView(views: [name, address])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = AboutMetrics.addressRowGap
        text.translatesAutoresizingMaskIntoConstraints = false

        let row = NSView()
        row.addSubview(text)
        row.addSubview(copy)
        copy.translatesAutoresizingMaskIntoConstraints = false
        row.setAccessibilityIdentifier("about-address-row-\(entry.id)")
        // Two columns 10 apart: the button as narrow as its label allows (58 minimum), centred on
        // both lines; the text takes the rest.
        let widths = copy.widthAnchor.constraint(greaterThanOrEqualToConstant: AboutMetrics.copyMinWidth)
        let textWidth = text.trailingAnchor.constraint(equalTo: copy.leadingAnchor, constant: -10)
        NSLayoutConstraint.activate([
            text.topAnchor.constraint(equalTo: row.topAnchor),
            text.bottomAnchor.constraint(equalTo: row.bottomAnchor),
            text.leadingAnchor.constraint(equalTo: row.leadingAnchor),
            textWidth,
            copy.trailingAnchor.constraint(equalTo: row.trailingAnchor),
            copy.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            widths,
            address.widthAnchor.constraint(equalTo: text.widthAnchor),
        ])
        row.translatesAutoresizingMaskIntoConstraints = false
        return row
    }

    /// The credits section.
    private func makeCredits() -> NSView {
        let list = NSStackView()
        list.orientation = .vertical
        list.alignment = .leading
        list.spacing = 0
        for entry in model.credits {
            let name = LinkButton(title: entry.name, id: "about-credit-\(entry.name)") { [model] in model.open(entry.url) }
            creditButtons[entry.name] = name
            let license = label(entry.license, size: 11, color: .secondaryLabelColor, digits: true)
            license.setAccessibilityIdentifier("about-credit-license-\(entry.name)")
            // A row is two columns, baseline-aligned: the license lines up down the right edge.
            let row = NSView()
            for view in [name, license] {
                view.translatesAutoresizingMaskIntoConstraints = false
                row.addSubview(view)
            }
            NSLayoutConstraint.activate([
                name.leadingAnchor.constraint(equalTo: row.leadingAnchor),
                license.trailingAnchor.constraint(equalTo: row.trailingAnchor),
                name.trailingAnchor.constraint(lessThanOrEqualTo: license.leadingAnchor, constant: -8),
                name.topAnchor.constraint(equalTo: row.topAnchor, constant: AboutMetrics.creditPadding),
                name.bottomAnchor.constraint(equalTo: row.bottomAnchor, constant: -AboutMetrics.creditPadding),
                license.firstBaselineAnchor.constraint(equalTo: name.firstBaselineAnchor),
            ])
            row.translatesAutoresizingMaskIntoConstraints = false
            row.setAccessibilityIdentifier("about-credit-row-\(entry.name)")
            list.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: list.widthAnchor).isActive = true
        }
        return makeSection(
            id: "about-attributions", title: AboutCopy.creditsTitle, description: AboutCopy.creditsDescription, content: list)
    }

    private func refreshCopyButtons() {
        for (id, button) in copyButtons { button.showsCopied = model.copied.contains(id) }
    }

    // MARK: Reading the page

    func copyButton(_ id: String) -> CopyButton? { copyButtons[id] }

    /// How far the body can scroll: what is below the fold.
    var scrollableHeight: CGFloat {
        layoutSubtreeIfNeeded()
        return max((scrollView.documentView?.frame.height ?? 0) - scrollView.contentView.bounds.height, 0)
    }

    /// Scrolls so `view` is at the top of the window, as far as the content allows.
    func scrollToTop(of view: NSView) {
        layoutSubtreeIfNeeded()
        guard let document = scrollView.documentView else { return }
        let y = min(max(view.convert(view.bounds, to: document).minY - AboutMetrics.padding.top, 0), scrollableHeight)
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: y))
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    // MARK: Labels

    /// A label in the page's type: `size` pt, never selectable unless the caller says so.
    private func label(
        _ string: String, size: CGFloat, weight: NSFont.Weight = .regular, color: NSColor = .labelColor, wraps: Bool = false,
        lineHeight: CGFloat? = nil, mono: Bool = false, digits: Bool = false
    ) -> NSTextField {
        let font: NSFont =
            mono
            ? .monospacedSystemFont(ofSize: size, weight: weight)
            : digits ? .monospacedDigitSystemFont(ofSize: size, weight: weight) : .systemFont(ofSize: size, weight: weight)
        let field = wraps ? NSTextField(wrappingLabelWithString: string) : NSTextField(labelWithString: string)
        field.isSelectable = false
        field.font = font
        field.textColor = color
        if let lineHeight {
            let style = NSMutableParagraphStyle()
            style.minimumLineHeight = lineHeight
            style.maximumLineHeight = lineHeight
            field.attributedStringValue = NSAttributedString(
                string: string, attributes: [.font: font, .foregroundColor: color, .paragraphStyle: style])
        }
        if wraps { field.preferredMaxLayoutWidth = AboutMetrics.contentWidth }
        field.translatesAutoresizingMaskIntoConstraints = false
        return field
    }
}

/// The scrolled content, flipped so it grows down from the top.
private final class FlippedContainer: NSView {
    override var isFlipped: Bool { true }
}

// MARK: - Controls

/// An `NSButton` that acts when the mouse comes up inside it, rather than running AppKit's tracking
/// loop: the same thing for a real click, and the only thing a synthesized one (a window that is
/// never shown, the tests') can reach. Pressed while the button is down; keyboard and `performClick`
/// are the stock button's.
@MainActor
class PressButton: NSButton {
    override func mouseDown(with event: NSEvent) { highlight(true) }

    override func mouseUp(with event: NSEvent) {
        highlight(false)
        guard bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        sendAction(action, to: target)
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// A donation tier: a full-width bordered button holding the amount, the name and the flavor
/// text. A real `NSButton`, so it can be pressed, focused and driven like one.
@MainActor
final class TierButton: PressButton {
    let tier: DonationTier
    private(set) var isHovered = false
    private var tracking: NSTrackingArea?
    private var handler: () -> Void
    let amountLabel: NSTextField
    let nameLabel: NSTextField
    let flavorLabel: NSTextField

    init(tier: DonationTier, action: @escaping () -> Void) {
        self.tier = tier
        handler = action
        func text(_ string: String, _ size: CGFloat, _ weight: NSFont.Weight, _ color: NSColor, digits: Bool = false) -> NSTextField {
            let field = NSTextField(labelWithString: string)
            field.font = digits ? .monospacedDigitSystemFont(ofSize: size, weight: weight) : .systemFont(ofSize: size, weight: weight)
            field.textColor = color
            field.isSelectable = false
            field.translatesAutoresizingMaskIntoConstraints = false
            return field
        }
        amountLabel = text(Donations.formatAmount(tier), 15, .semibold, .controlAccentColor, digits: true)
        nameLabel = text(tier.label, 12.5, .medium, .labelColor)
        flavorLabel = text(tier.flavor, 11.5, .regular, .secondaryLabelColor)
        super.init(frame: .zero)
        title = ""
        isBordered = false
        focusRingType = .exterior
        target = self
        self.action = #selector(pressed(_:))
        setButtonType(.momentaryChange)
        translatesAutoresizingMaskIntoConstraints = false
        setAccessibilityIdentifier("about-tier-\(tier.id)")
        setAccessibilityLabel("\(Donations.formatAmount(tier)), \(tier.label). \(tier.flavor)")

        let inset = AboutMetrics.tierInset
        // Two columns, the amount spanning both rows and centred; wide enough for the largest
        // amount, so the three names start at the same x.
        let names = NSStackView(views: [nameLabel, flavorLabel])
        names.orientation = .vertical
        names.alignment = .leading
        names.spacing = 0
        names.translatesAutoresizingMaskIntoConstraints = false
        addSubview(amountLabel)
        addSubview(names)
        NSLayoutConstraint.activate([
            amountLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: inset.left),
            amountLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            amountLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: AboutMetrics.tierAmountMinWidth),
            names.leadingAnchor.constraint(equalTo: amountLabel.trailingAnchor, constant: AboutMetrics.tierColumnGap),
            names.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -inset.right),
            names.topAnchor.constraint(equalTo: topAnchor, constant: inset.top),
            names.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -inset.bottom),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    @objc private func pressed(_ sender: Any?) { handler() }

    /// What a press on any part of the tier means: children never take the hit.
    override func hitTest(_ point: NSPoint) -> NSView? {
        bounds.contains(convert(point, from: superview)) ? self : nil
    }

    /// The border: the separator color, the accent while hovered.
    var borderColor: NSColor { isHovered ? .controlAccentColor : .separatorColor }
    /// The hover wash (the label color at 6%), clear at rest.
    var washColor: NSColor { isHovered ? NSColor.labelColor.withAlphaComponent(0.06) : .clear }

    override func draw(_ dirtyRect: NSRect) {
        // A 1pt border, radius 8.
        let outline = NSBezierPath(
            roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: AboutMetrics.tierRadius, yRadius: AboutMetrics.tierRadius)
        washColor.setFill()
        outline.fill()
        borderColor.setStroke()
        outline.lineWidth = 1
        outline.stroke()
    }

    override func drawFocusRingMask() {
        NSBezierPath(roundedRect: bounds, xRadius: AboutMetrics.tierRadius, yRadius: AboutMetrics.tierRadius).fill()
    }

    override var focusRingMaskBounds: NSRect { bounds }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) { setHovered(true) }
    override func mouseExited(with event: NSEvent) { setHovered(false) }

    func setHovered(_ hovered: Bool) {
        guard hovered != isHovered else { return }
        isHovered = hovered
        needsDisplay = true
    }

    /// The pointing hand.
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
}

/// A credit's name: a button styled as a link, because that is what it does.
@MainActor
final class LinkButton: PressButton {
    private(set) var isHovered = false
    private var tracking: NSTrackingArea?
    private var handler: () -> Void
    private let text: String

    init(title: String, id: String, action: @escaping () -> Void) {
        text = title
        handler = action
        super.init(frame: .zero)
        isBordered = false
        focusRingType = .exterior
        target = self
        self.action = #selector(pressed(_:))
        setButtonType(.momentaryChange)
        alignment = .left
        setAccessibilityIdentifier(id)
        setAccessibilityLabel(title)
        render()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    @objc private func pressed(_ sender: Any?) { handler() }

    /// Accent-colored; underlined while hovered.
    private func render() {
        var attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.controlAccentColor,
        ]
        if isHovered { attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue }
        attributedTitle = NSAttributedString(string: text, attributes: attributes)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) { setHovered(true) }
    override func mouseExited(with event: NSEvent) { setHovered(false) }

    func setHovered(_ hovered: Bool) {
        guard hovered != isHovered else { return }
        isHovered = hovered
        render()
    }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
}

/// A Copy button: says "Copied" for a moment after being pressed, so the user knows the long
/// unreadable string was taken. Fixed at least 58pt wide, so the label change never shifts the
/// address column.
@MainActor
final class CopyButton: PressButton {
    private let handler: () -> Void
    /// "Copied" instead of "Copy": accent title.
    var showsCopied = false { didSet { if showsCopied != oldValue { render() } } }

    init(entry: CryptoAddress, action: @escaping () -> Void) {
        handler = action
        super.init(frame: .zero)
        bezelStyle = .rounded
        controlSize = .small
        setButtonType(.momentaryPushIn)
        target = self
        self.action = #selector(pressed(_:))
        setAccessibilityIdentifier("about-copy-\(entry.id)")
        setAccessibilityLabel(AboutCopy.copyAddressLabel(entry))
        render()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    @objc private func pressed(_ sender: Any?) { handler() }

    private func render() {
        let font = NSFont.systemFont(ofSize: 11.5)
        if showsCopied {
            attributedTitle = NSAttributedString(
                string: AboutCopy.copiedLabel, attributes: [.font: font, .foregroundColor: NSColor.controlAccentColor])
        } else {
            attributedTitle = NSAttributedString(string: AboutCopy.copyLabel, attributes: [.font: font])
        }
    }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
}
