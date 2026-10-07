import Foundation
import TabsPluginSDK

/// Where `create-browser-pane` (the tabs-ctl verb) places a newly created
/// browser pane relative to the caller's own pane. Has no effect on panes a
/// person opens by hand (New Tab, the split shortcuts, the empty-pane toolbar
/// never read this setting).
enum NewPanePlacement: String, CaseIterable, Codable, Sendable {
    case tab
    case splitHorizontal = "split-horizontal"
    case splitVertical = "split-vertical"
    case unpinned

    static let `default`: NewPanePlacement = .tab

    /// The label Settings ▸ Browser shows.
    var label: String {
        switch self {
        case .tab: "New tab"
        case .splitHorizontal: "Horizontal split"
        case .splitVertical: "Vertical split"
        case .unpinned: "Unpinned window"
        }
    }
}

/// `value` as a known placement, or the default for anything else (unset,
/// hand-edited garbage, another build's since-renamed value): this value drives
/// a branch in `create-browser-pane`, not just a label, so a caller must never
/// see anything outside the known set.
func resolveNewPanePlacement(_ value: JSONValue?) -> NewPanePlacement {
    value?.stringValue.flatMap(NewPanePlacement.init(rawValue:)) ?? .default
}

/// The browser's settings (Settings ▸ Browser). Core merges what's stored over
/// these defaults field by field, and the decoder is total: everything
/// downstream trusts the placement to be one of the four, so garbage is
/// normalized here rather than at every read site, and nothing a hand-edited
/// file holds can throw.
struct BrowserSettings: PluginSettingsValue {
    var controlledPanePlacement: NewPanePlacement = .default

    init() {}

    init(from decoder: any Decoder) throws {
        guard let container = try? decoder.container(keyedBy: CodingKeys.self) else { return }
        let stored = try? container.decodeIfPresent(JSONValue.self, forKey: .controlledPanePlacement)
        controlledPanePlacement = resolveNewPanePlacement(stored ?? nil)
    }
}
