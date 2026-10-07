import AppKit
import SwiftUI

/// A push button that is a real `NSButton`. SwiftUI's own buttons are drawn by SwiftUI, so nothing
/// outside it can press one in a window that is never shown (the UI tests' windows); this one is a
/// control they can `performClick`, and it looks like the bordered SwiftUI button beside it.
struct SettingsButton: NSViewRepresentable {
    let title: String
    let id: String
    var isEnabled = true
    /// The title in the secondary label color (an unbound shortcut's "Not set").
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
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSButton, context: Context) -> CGSize? {
        let size = nsView.intrinsicContentSize
        return CGSize(width: max(size.width, minWidth), height: size.height)
    }

    func makeNSView(context: Context) -> NSButton {
        let button = NSButton(title: title, target: context.coordinator, action: #selector(Coordinator.pressed(_:)))
        button.bezelStyle = .push
        button.keyEquivalent = keyEquivalent
        button.setAccessibilityIdentifier(id)
        return button
    }

    func updateNSView(_ button: NSButton, context: Context) {
        context.coordinator.action = action
        button.setAccessibilityIdentifier(id)
        button.isEnabled = isEnabled
        button.bezelColor = isHighlighted ? .controlAccentColor : nil
        if isDimmed {
            button.attributedTitle = NSAttributedString(
                string: title, attributes: [.foregroundColor: NSColor.secondaryLabelColor, .font: button.font ?? .systemFont(ofSize: 13)])
        } else {
            button.title = title
        }
    }
}
