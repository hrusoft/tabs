import TabsPluginSDK

/// The git tree's settings (Settings ▸ Git tree). Core merges what's stored
/// over these defaults, field by field, like the Electron app's
/// `mergeGitTreeSettings`. The page size stays a constant and the branch
/// filter is per pane (`config.branchScope`), as in the Electron app.
struct GitTreeSettings: PluginSettingsValue {
    /// Whether an active git tree pane re-reads its log when it (or its
    /// window) regains focus.
    var autoRefreshOnFocus = false
    /// Whether the commit list shows an author column. Off by default: the
    /// graph, hash and message are the only columns always shown.
    var showAuthorColumn = false
    /// Whether the commit list shows a date column. Off by default, likewise.
    var showDateColumn = false

    init() {}

    // Tolerant field by field, so one bad value doesn't cost the others (the
    // Electron merge keeps every well-typed field; core's merge over defaults
    // fills absent ones).
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        autoRefreshOnFocus = (try? container.decode(Bool.self, forKey: .autoRefreshOnFocus)) ?? false
        showAuthorColumn = (try? container.decode(Bool.self, forKey: .showAuthorColumn)) ?? false
        showDateColumn = (try? container.decode(Bool.self, forKey: .showDateColumn)) ?? false
    }
}
