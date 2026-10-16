import AppKit
import SwiftUI
import TabsPluginSDK

/// A push button that is a real `NSButton`. SwiftUI's own buttons are drawn by SwiftUI, so nothing
/// outside it can press one in a window that is never shown (the UI tests' windows); this one is a
/// control they can `performClick`, and it looks like the bordered SwiftUI button beside it. Its
/// title is in the app's theme (`appTheme`); the default button and a highlighted one are filled
/// with the theme's accent.
struct SettingsButton: NSViewRepresentable {
    let title: String
    let id: String
    var isEnabled = true
    /// The title in the theme's `textDim` (an unbound shortcut's "Not set").
    var isDimmed = false
    /// The accent bezel (a shortcut chip that is recording).
    var isHighlighted = false
    var minWidth: CGFloat = 0
    /// "\r" makes it the window's default button, "\u{1b}" its cancel button.
    var keyEquivalent = ""
    let action: () -> Void

    init(
        _ title: String, id: String, isEnabled: Bool = true, isDimmed: Bool = false, isHighlighted: Bool = false, minWidth: CGFloat = 0,
        keyEquivalent: String = "", action: @escaping () -> Void
    ) {
        self.title = title
        self.id = id
        self.isEnabled = isEnabled
        self.isDimmed = isDimmed
        self.isHighlighted = isHighlighted
        self.minWidth = minWidth
        self.keyEquivalent = keyEquivalent
        self.action = action
    }

    final class Coordinator: NSObject {
        var action: () -> Void = {}
        @objc func pressed(_ sender: Any?) { action() }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    /// The button's own size, not the row's.
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: SettingsPushButton, context: Context) -> CGSize? {
        let size = nsView.intrinsicContentSize
        return CGSize(width: max(size.width, minWidth), height: size.height)
    }

    func makeNSView(context: Context) -> SettingsPushButton {
        let button = SettingsPushButton(title: title, target: context.coordinator, action: #selector(Coordinator.pressed(_:)))
        button.bezelStyle = .push
        button.keyEquivalent = keyEquivalent
        button.setAccessibilityIdentifier(id)
        return button
    }

    func updateNSView(_ button: SettingsPushButton, context: Context) {
        context.coordinator.action = action
        button.setAccessibilityIdentifier(id)
        button.isEnabled = isEnabled
        button.look = .init(
            label: title, theme: context.environment.appTheme, isFilled: isHighlighted || keyEquivalent == "\r", isDimmed: isDimmed)
    }
}

/// `SettingsButton`'s `NSButton`. A filled one has the theme's accent for its bezel, which AppKit
/// fills only while the window is key (grey otherwise): its title is `onAccent` then, and the
/// theme's text when not, so it reads on either.
final class SettingsPushButton: NSButton {
    struct Look: Equatable {
        var label = ""
        var theme = PaneTheme.placeholder
        var isFilled = false
        /// The title in the theme's `textDim` (an unbound shortcut's "Not set").
        var isDimmed = false
    }

    var look = Look() { didSet { if look != oldValue { render() } } }
    override var isEnabled: Bool { didSet { if isEnabled != oldValue { render() } } }
    private var keyObservers: [any NSObjectProtocol] = []

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        for observer in keyObservers { NotificationCenter.default.removeObserver(observer) }
        keyObservers = []
        if let window {
            for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification] {
                keyObservers.append(
                    NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                        MainActor.assumeIsolated { self?.render() }
                    })
            }
        }
        render()
    }

    isolated deinit {
        for observer in keyObservers { NotificationCenter.default.removeObserver(observer) }
    }

    private func render() {
        let theme = look.theme
        bezelColor = look.isFilled ? theme.accent : nil
        let color =
            look.isFilled && window?.isKeyWindow == true ? theme.onAccent : look.isDimmed || !isEnabled ? theme.textDim : theme.text
        let centered = NSMutableParagraphStyle()
        centered.alignment = .center
        attributedTitle = NSAttributedString(
            string: look.label, attributes: [.foregroundColor: color, .font: font ?? .systemFont(ofSize: 13), .paragraphStyle: centered])
    }
}
