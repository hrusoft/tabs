import SwiftUI
import TabsPluginSDK

/// Settings ▸ Git tree: `GitTreeSettingsPage.tsx`'s three toggles, in its
/// words. Every change applies to open panes at once.
struct GitTreeSettingsPage: View {
    let settings: PluginSettings<GitTreeSettings>

    var body: some View {
        Form {
            Section {
                Toggle(isOn: settings.binding(\.autoRefreshOnFocus)) {
                    Text("Auto-refresh on focus")
                    Text("Re-read a git tree pane's history whenever it becomes active while the window is focused.")
                }
                .accessibilityIdentifier("settings-auto-refresh-checkbox")
                Toggle(isOn: settings.binding(\.showAuthorColumn)) {
                    Text("Show author column")
                    Text("Show who authored each commit in the commit list, alongside its hash and message.")
                }
                .accessibilityIdentifier("settings-show-author-column-checkbox")
                Toggle(isOn: settings.binding(\.showDateColumn)) {
                    Text("Show date column")
                    Text("Show each commit's date in the commit list, alongside its hash and message.")
                }
                .accessibilityIdentifier("settings-show-date-column-checkbox")
            }
        }
    }
}
