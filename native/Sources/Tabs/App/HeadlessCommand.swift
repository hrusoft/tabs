import Foundation
import TabsCore
import TabsPluginSDK

/// Command-line modes that run core and the plugins without any UI:
///
///     Tabs --plugin-report              JSON report of every plugin; exit 1 if any is broken
///     Tabs --control '<json request>'   dispatch one control request; exit 1 on error
///
/// Debug builds also accept `--plugins-dir <path>` to load plugins from
/// somewhere other than the app's own PlugIns directory.
struct HeadlessCommand {
    enum Mode {
        case pluginReport
        case control(String)
    }

    let mode: Mode
    /// Debug-only override; nil means the app's own bundled plugins.
    let pluginsDirectory: URL?

    init?(arguments: [String]) {
        if arguments.contains("--plugin-report") {
            mode = .pluginReport
        } else if let index = arguments.firstIndex(of: "--control"), arguments.indices.contains(index + 1) {
            mode = .control(arguments[index + 1])
        } else {
            return nil
        }
        #if DEBUG
        if let index = arguments.firstIndex(of: "--plugins-dir"), arguments.indices.contains(index + 1) {
            pluginsDirectory = URL(filePath: arguments[index + 1], directoryHint: .isDirectory)
            return
        }
        #endif
        pluginsDirectory = nil
    }

    @MainActor
    func run() async -> Int32 {
        let problems = BuildIntegrity.problems(appBundle: .main)
        if !problems.isEmpty {
            emit(ControlDispatcher.failure("the app bundle mixes builds: " + problems.joined(separator: "; ")))
            return 2
        }
        let paths = AppPaths.fromEnvironment()
        // Headless modes only look: they never write, move or copy user files.
        let runtime = CoreRuntime(paths: paths, readOnly: true)
        let layout = runtime.loadLayout()
        if let pluginsDirectory {
            runtime.startPlugins(from: pluginsDirectory, requiredContentTypes: layout?.contentTypes ?? [])
        } else {
            runtime.startBundledPlugins(of: .main, requiredContentTypes: layout?.contentTypes ?? [])
        }
        defer { runtime.host.stop() }

        switch mode {
        case .pluginReport:
            emit(runtime.report())
            return runtime.host.records.contains { $0.state.isProblem } ? 1 : 0
        case .control(let request):
            let response = await runtime.control.handle(json: request)
            emit(response)
            return response["ok"] == true ? 0 : 1
        }
    }

    private func emit(_ value: JSONValue) {
        guard let data = try? value.encodedData(), let text = String(data: data, encoding: .utf8) else { return }
        print(text)
    }
}
