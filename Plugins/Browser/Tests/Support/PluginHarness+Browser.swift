import Foundation

extension PluginHarness {
    /// A harness running the Browser plugin (`plugin`, made here unless the test keeps its own), whose web
    /// data store (the one the harness's fresh data directory names) is deleted when the test process exits
    /// (`WebDataStores`).
    static func browser(
        _ plugin: BrowserPlugin = BrowserPlugin(), withAgent: Bool = false, testFile: String = #filePath
    ) throws -> PluginHarness {
        let harness = try PluginHarness(withAgent: withAgent, testFile: testFile) { plugin }
        if let store = plugin.services?.webDataStore { WebDataStores.discard(store) }
        return harness
    }
}
