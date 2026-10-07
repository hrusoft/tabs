import AppKit
import SwiftUI

/// A page in the Settings window. Id is namespaced; one plugin may add several.
///
/// Core makes the page (`makeView`) when its tab is first chosen, not as Settings opens, and
/// sizes the window to it: `width` wide, as tall as the page's fitting size up to what the
/// screen allows, the page scrolling past that. A SwiftUI page gets the standard layout from
/// the SwiftUI init (`settingsPageLayout()`: a grouped form, `width` wide), so it declares
/// neither a width nor a form style; an AppKit page lays itself out in `width`.
public struct SettingsPageContribution: Contribution {
    public let id: String
    public var title: String
    public var symbolName: String
    public var makeView: @MainActor () -> NSView

    public var contributionID: String { id }

    /// Every page's width, in points: the Settings window's, the same for every page.
    public static let width: CGFloat = 600

    public init(id: String, title: String, symbolName: String, makeView: @escaping @MainActor () -> NSView) {
        self.id = id
        self.title = title
        self.symbolName = symbolName
        self.makeView = makeView
    }

    public init<Content: View>(
        id: String, title: String, symbolName: String,
        @ViewBuilder content: @escaping @MainActor () -> Content
    ) {
        self.init(id: id, title: title, symbolName: symbolName) { NSHostingView(rootView: content().settingsPageLayout()) }
    }
}

extension View {
    /// A Settings page's layout: its forms grouped (System Settings' labelled rows in cards),
    /// at the page width, as tall as the window core gives it (a longer form scrolls). The
    /// SwiftUI page init applies it; a page that hosts itself applies it at its root.
    public func settingsPageLayout() -> some View {
        formStyle(.grouped).frame(width: SettingsPageContribution.width)
    }
}
