import AppKit
import TabsCore
import TabsPluginSDK

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var runtime: CoreRuntime?
    private var shell: AppShell?
    private var pluginsWindow: NSWindowController?
    private var settingsWindow: NSWindowController?
    /// The About window, one at a time.
    private lazy var about = AboutPresenter(presentsWindows: !Self.isHidden)
    private var controlServer: ControlServer?

    /// `TABS_E2E_HIDDEN=1` (end-to-end tests): windows are built but never
    /// shown, the app never activates (so it never takes focus from the
    /// user) and stays out of the Dock (`runInBackground()`), dialogs are
    /// auto-answered, and problems go to stderr.
    static var isHidden: Bool { ProcessInfo.processInfo.environment["TABS_E2E_HIDDEN"] == "1" }

    /// `TABS_E2E_PLUGINS=<dir>` (end-to-end tests, hidden Debug builds only):
    /// test plugin bundles started beside the bundled ones, so a test can have
    /// a pane that no shipped plugin owns.
    static var fixturePlugins: URL? {
        #if DEBUG
        guard isHidden, let path = ProcessInfo.processInfo.environment["TABS_E2E_PLUGINS"], !path.isEmpty else { return nil }
        return URL(filePath: path, directoryHint: .isDirectory)
        #else
        nil
        #endif
    }

    /// Under `xcodebuild test` the app is only a host: the tests build their
    /// own runtimes, so the app itself starts nothing.
    static var isHostingTests: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
            || ProcessInfo.processInfo.environment["XCTestBundlePath"] != nil
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard !Self.isHostingTests else { return }

        let problems = BuildIntegrity.problems(appBundle: .main)
        if !problems.isEmpty, Self.isHidden {
            FileHandle.standardError.write(Data(("Tabs is damaged: " + problems.joined(separator: "; ") + "\n").utf8))
            exit(2)
        }
        if !problems.isEmpty {
            let alert = NSAlert()
            alert.messageText = "Tabs is damaged"
            alert.informativeText =
                "Parts of the app come from different builds. Reinstall or rebuild it.\n\n"
                + problems.joined(separator: "\n")
            alert.runModal()
            NSApp.terminate(nil)
            return
        }

        let paths = AppPaths.fromEnvironment()
        // The socket first: panes built while restoring already hand its path
        // to the processes they spawn.
        let socket = startControlServer(in: paths.dataDirectory)
        let runtime = start(paths, controlSocket: socket)
        if Self.isHidden {
            for note in runtime.persistenceNotes { FileHandle.standardError.write(Data("recovered: \(note)\n".utf8)) }
        } else {
            NSApp.activate()
            reportRecoveredState(runtime.persistenceNotes)
        }
    }

    /// Core and the shell on `paths`: the saved layout, the bundled plugins,
    /// the windows. What launching does, and what a test reset does again.
    @discardableResult
    private func start(_ paths: AppPaths, controlSocket: String?) -> CoreRuntime {
        let runtime = CoreRuntime(paths: paths, controlSocketPath: controlSocket)
        let layout = runtime.loadLayout()
        runtime.startBundledPlugins(of: .main, alongside: Self.fixturePlugins, requiredContentTypes: layout?.contentTypes ?? [])

        let shell = AppShell(runtime: runtime, presentsWindows: !Self.isHidden)
        shell.pluginsDidChange = { [weak self] in self?.refreshSettingsWindow() }
        shell.engine.restore(layout)

        self.runtime = runtime
        self.shell = shell
        #if DEBUG
        // Only in test mode: `tabs.test.reset` empties the data directory.
        if Self.isHidden {
            TestControlVerbs.register(on: runtime, shell: shell, about: about) { [weak self] in self?.resetForTests() }
        }
        #endif
        return runtime
    }

    /// The per-boot control socket: `TABS_LISTEN_SOCKET` if set (tests), else
    /// `<data dir>/control-<pid>.sock`. Not `TABS_CONTROL_SOCKET`: that's what
    /// the app gives processes in its panes, so a Tabs launched from a shell
    /// inside Tabs would otherwise take over its parent's socket. Requests go to
    /// whichever runtime is current (a test reset replaces it).
    /// Returns the path it listens on, or nil if it couldn't start.
    private func startControlServer(in dataDirectory: URL) -> String? {
        ControlServer.removeStaleSockets(in: dataDirectory)
        let path = ProcessInfo.processInfo.environment["TABS_LISTEN_SOCKET"] ?? ControlServer.defaultPath(in: dataDirectory)
        let server = ControlServer(path: path) { [weak self] line in
            guard let self else { return #"{"ok":false,"error":"the app is quitting"}"# }
            return await self.handleControl(line)
        }
        do {
            try server.start()
            controlServer = server
            return path
        } catch {
            FileHandle.standardError.write(Data("control socket unavailable: \(error)\n".utf8))
            return nil
        }
    }

    private func handleControl(_ line: String) async -> String {
        guard let runtime else { return #"{"ok":false,"error":"not started"}"# }
        let response = await runtime.control.handle(json: line)
        guard let data = try? response.encodedData(pretty: false) else { return #"{"ok":false,"error":"unencodable response"}"# }
        return String(decoding: data, as: UTF8.self)
    }

    #if DEBUG
    /// `tabs.test.reset`: the state of a fresh launch without relaunching —
    /// plugins deactivated, windows gone, the data directory emptied (but for
    /// the control socket), then core, plugins and windows started again.
    /// Loaded plugin images stay loaded; each plugin gets a new instance, as
    /// the plugin contract allows.
    private func resetForTests() {
        guard let old = runtime, let shell else { return }
        shell.stop()
        // Nothing left running from the last test.
        old.caffeinate.killNow()
        // Panes end as if closed (plugins release what they hold — a
        // terminal's shell), and the old layout never saves again.
        shell.engine.tearDown()
        for window in shell.renderer.windows {
            window.isClosingForModel = true
            window.window?.close()
            window.dismantle()
        }
        for window in [pluginsWindow, settingsWindow] { window?.close() }
        about.dismiss()
        pluginsWindow = nil
        settingsWindow = nil
        old.host.stop()
        old.removeTemporaryFiles()
        let data = old.paths.dataDirectory
        for name in (try? FileManager.default.contentsOfDirectory(atPath: data.path)) ?? []
        where !(name.hasPrefix("control-") && name.hasSuffix(".sock")) {
            try? FileManager.default.removeItem(at: data.appending(path: name))
        }
        start(old.paths, controlSocket: old.controlSocketPath)
    }
    #endif

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let shell else { return .terminateNow }
        return shell.engine.shouldQuit() ? .terminateNow : .terminateCancel
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Save first: nothing after it may cost the user their layout.
        shell?.engine.saveNow()
        // A signal to a running process, not a new launch; `-w` is the
        // backstop for a quit that never gets here (a crash, a SIGKILL).
        runtime?.caffeinate.killNow()
        controlServer?.stop()
        runtime?.host.stop()
        runtime?.removeTemporaryFiles()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if shell?.engine.model.windows.isEmpty == true { shell?.engine.openWindow() }
        return true
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }

    private func refreshSettingsWindow() {
        guard let runtime else { return }
        if let settingsWindow {
            let wasVisible = settingsWindow.window?.isVisible == true
            settingsWindow.close()
            self.settingsWindow = makeSettingsWindow(for: runtime)
            if wasVisible { self.settingsWindow?.showWindow(nil) }
        }
    }

    /// Saved state that had to be recovered is worth one alert: the originals
    /// were kept, and the user should know where.
    private func reportRecoveredState(_ notes: [String]) {
        guard !notes.isEmpty else { return }
        let alert = NSAlert()
        alert.messageText = "Some saved state could not be fully restored"
        alert.informativeText = notes.joined(separator: "\n\n")
        alert.alertStyle = .warning
        alert.runModal()
    }

    // MARK: Menu actions

    /// Tabs ▸ About Tabs: the About window, created if needed, else brought forward.
    @objc func showAbout(_ sender: Any?) {
        about.show()
    }

    @objc func showPlugins(_ sender: Any?) {
        guard let runtime else { return }
        if pluginsWindow == nil {
            let model = PluginsModel(host: runtime.host, fingerprint: runtime.sharedFingerprint) {}
            pluginsWindow = makePluginsWindow(model: model)
        }
        present(pluginsWindow)
    }

    @objc func showSettings(_ sender: Any?) {
        guard let runtime else { return }
        if settingsWindow == nil { settingsWindow = makeSettingsWindow(for: runtime) }
        present(settingsWindow)
    }

    /// Brings `controller`'s window forward; hidden (`isHidden`), it is built but never shown or focused.
    private func present(_ controller: NSWindowController?) {
        guard !Self.isHidden else { return }
        controller?.showWindow(nil)
        controller?.window?.makeKeyAndOrderFront(nil)
    }
}
