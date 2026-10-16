import Foundation

/// How the app itself was launched: the environment variables it reads at launch. The one list
/// both their readers and `PaneRuntime`'s child environment use, so a setting added here is
/// never passed on — or a Tabs started from a pane would share this one's data, socket, hidden
/// mode, test plugins or (Debug) test windows' switch.
package enum LaunchSetting: String, CaseIterable, Sendable {
    /// The data directory (`AppPaths.fromEnvironment`).
    case dataDirectory = "TABS_DATA_DIR"
    /// The control socket's path (tests).
    case listenSocket = "TABS_LISTEN_SOCKET"
    /// `1`: hidden mode, for end-to-end tests.
    case hidden = "TABS_E2E_HIDDEN"
    /// Test plugin bundles started beside the bundled ones (hidden Debug builds only; a Release
    /// build ignores it, and still never passes it on).
    case fixturePlugins = "TABS_E2E_PLUGINS"
    #if DEBUG
    /// `1`: workspace windows count as seen by WebKit (UI tests). Release builds neither honour
    /// nor know it.
    case windowsCountAsSeen = "TABS_TEST_WINDOWS_SEEN"
    #endif

    /// Its value in `environment` (the process's own by default).
    package func value(in environment: [String: String] = ProcessInfo.processInfo.environment) -> String? {
        environment[rawValue]
    }
}
