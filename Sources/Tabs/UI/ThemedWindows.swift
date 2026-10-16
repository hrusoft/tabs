import AppKit
import SwiftUI
import TabsCore
import TabsPluginSDK

// The app's own windows in the theme (docs/THEMES.md): Settings, Plugins, About, Caffeinate. Their
// SwiftUI content sits in `ThemedRoot`; the window paints its background and title bar with
// `NSWindow.paint(with:)`. Both follow the Theme setting live.

extension EnvironmentValues {
    /// The app's theme, for what a style doesn't reach: an AppKit control in a page, a fill in the
    /// accent. Set by `ThemedRoot`.
    @Entry var appTheme: PaneTheme = .placeholder
}

/// A window's SwiftUI content in the app's theme, live: the theme's background under it, its
/// `text` and `textDim` as the primary and secondary styles, `border` as the third (a grouped
/// form draws its separators in it), and its `accent` as the tint of every control. A grouped
/// form's own row descriptions take the primary style: mark them `.foregroundStyle(.secondary)`.
struct ThemedRoot<Content: View>: View {
    let themes: Themes
    let content: Content

    init(_ themes: Themes, @ViewBuilder content: () -> Content) {
        self.themes = themes
        self.content = content()
    }

    var body: some View {
        let theme = themes.current
        content
            .tint(Color(nsColor: theme.accent))
            .foregroundStyle(Color(nsColor: theme.text), Color(nsColor: theme.textDim), Color(nsColor: theme.border))
            .scrollContentBackground(.hidden)
            .background(Color(nsColor: theme.bg))
            .environment(\.appTheme, theme)
    }
}

/// A plugin's Settings page in the app's theme: the page's own view (the SDK's hosting view for a
/// SwiftUI page) inside core's `ThemedRoot`, whose environment — the styles, the tint, the hidden
/// form background — reaches the page's own SwiftUI. Verified on macOS 27 only (docs/THEMES.md).
struct EmbeddedSettingsPage: NSViewRepresentable {
    let page: NSView

    func makeNSView(context: Context) -> NSView { page }

    func updateNSView(_ page: NSView, context: Context) {}

    /// All it's offered: the window gives the page its size (`SettingsPageSizing`).
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSView, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? SettingsPageContribution.width, height: proposal.height ?? nsView.fittingSize.height)
    }
}

extension NSWindow {
    /// Paints the window's background, title bar included, in the app's theme from now on.
    func paint(with themes: Themes) {
        titlebarAppearsTransparent = true
        backgroundColor = themes.current.bg
        themes.observe(self) { window, theme in window.backgroundColor = theme.bg }
    }
}
