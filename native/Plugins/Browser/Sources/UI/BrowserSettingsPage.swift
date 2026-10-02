import SwiftUI
import TabsPluginSDK

/// Settings ▸ Browser: `BrowserSettingsPage.tsx`'s one row, in its words. The
/// setting affects only what an agent creates (`create-browser-pane`); a browser
/// a person opens by hand never reads it.
struct BrowserSettingsPage: View {
    let settings: PluginSettings<BrowserSettings>

    var body: some View {
        Form {
            Section {
                Picker(selection: settings.binding(\.controlledPanePlacement)) {
                    ForEach(NewPanePlacement.allCases, id: \.self) { Text($0.label).tag($0) }
                } label: {
                    Text("New pane placement")
                    Text(
                        "Where a browser pane created by an agent (via the tabs skill's createBrowserPane) appears relative to the pane that created it."
                    )
                }
                .accessibilityIdentifier("settings-browser-controlled-pane-placement-select")
            }
        }
    }
}
