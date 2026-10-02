import AppKit
import TabsPluginSDK

/// A terminal pane's saved state: where its shell starts. Tolerant of a
/// missing field (a new pane's config may be `{}`: home), strict about a
/// wrong one, so a config this build can't read is refused rather than
/// replaced.
struct TerminalConfig: Codable, Equatable {
    var cwd: String?

    init(cwd: String? = nil) { self.cwd = cwd }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        cwd = try container.decodeIfPresent(String.self, forKey: .cwd)
    }
}

/// One terminal pane — `TerminalRenderer.tsx` and its pty (`createTerminal`)
/// in one controller, since natively both live in the app's process and an
/// AppKit view keeps its state wherever core moves it: there's nothing to
/// reattach after a split, a tab promotion, floating or another window.
///
/// The shell starts when the pane is made — a restored background tab's too,
/// as the Electron app mounts hidden tabs — and ends when the pane closes.
@MainActor
final class TerminalPane: PaneController, TerminalSurfaceDelegate {
    private let pane: any PaneContext
    private let surface: any TerminalSurface
    private let settings: PluginSettings<TerminalSettings>
    private let services: TerminalServices
    private var settingsSubscription: Subscription?
    private(set) var process: ShellProcess?
    /// Where the shell was started.
    private(set) var startDirectory: String
    /// The directory last offered to other panes (and saved).
    private var offeredDirectory: String?
    private var probeScheduled = false
    /// Whether the pane is its window's visible tab: only then does the pty
    /// follow the view's size (a hidden pane never resizes it).
    private var isShown = false
    /// The size the pty was last given.
    private var ptySize: (columns: Int, rows: Int)
    private(set) var hasExited = false

    lazy var headerActions: [PaneHeaderAction] = [
        PaneHeaderAction(
            id: "pane-terminal-clear-scrollback-button", label: "Clear scrollback", icon: .image(TerminalGlyphs.clearScrollback)
        ) {
            [weak self] in self?.clear()
        }
    ]

    init(pane: any PaneContext, settings: PluginSettings<TerminalSettings>, services: TerminalServices) throws {
        let config = try pane.initialConfig.decode(TerminalConfig.self)
        self.pane = pane
        self.settings = settings
        self.services = services
        let value = settings.value
        surface = SwiftTermSurface(appearance: value.appearance, scrollback: value.scrollback, metal: value.enableMetalRendering)
        startDirectory = Shell.resolveCwd(config.cwd, home: services.home, isDirectory: services.isDirectory)
        ptySize = (surface.columns, surface.rows)
        surface.delegate = self
        settingsSubscription = settings.observe { [weak self] in self?.apply($0) }
        // Started on the next turn: by then a pane being shown has its view
        // laid out, so the shell starts at the pane's real size.
        Task { @MainActor [weak self] in self?.start() }
    }

    var view: NSView { surface.view }

    // MARK: The shell

    private func start() {
        guard process == nil, !hasExited else { return }
        ptySize = (surface.columns, surface.rows)
        do {
            process = try ShellProcess.spawn(
                executable: services.shell, arguments: ["-l"], environment: services.environment(pane.childEnvironment),
                directory: startDirectory, columns: ptySize.columns, rows: ptySize.rows,
                onOutput: { [weak self] bytes in self?.output(bytes) },
                onExit: { [weak self] in self?.exited() })
            offerDirectory()
        } catch {
            surface.feed(Array("\u{1b}[2m[could not start \(services.shell): \(error)]\u{1b}[0m\r\n".utf8))
            hasExited = true
        }
    }

    private func output(_ bytes: [UInt8]) {
        surface.feed(bytes)
        scheduleDirectoryProbe()
    }

    /// The shell ended on its own (`exit`, ⌃D): say so, and keep the pane and
    /// its last output (the Electron app's `[process exited]`).
    private func exited() {
        guard !hasExited else { return }
        hasExited = true
        surface.feed(Array("\r\n\u{1b}[2m[process exited]\u{1b}[0m\r\n".utf8))
        pane.offer(.workingDirectory, nil)
    }

    /// The shell's live directory, or nil (not running, or unknown).
    var liveDirectory: String? {
        guard let process, !hasExited else { return nil }
        return ProcessProbe.workingDirectory(of: process.pid)
    }

    /// Keeps the offered (and saved) directory current. A shell says nothing
    /// when it `cd`s, but it prints a prompt: look shortly after output.
    private func scheduleDirectoryProbe() {
        guard !probeScheduled else { return }
        probeScheduled = true
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(150))
            self?.probeScheduled = false
            self?.offerDirectory()
        }
    }

    private func offerDirectory() {
        guard let directory = liveDirectory, directory != offeredDirectory else { return }
        offeredDirectory = directory
        pane.offer(.workingDirectory, URL(filePath: directory, directoryHint: .isDirectory))
        pane.configDidChange()
    }

    // MARK: PaneController

    func currentConfig() -> JSONValue {
        // The live directory, at every save: a relaunch (or a crash) restarts
        // the shell where it was.
        (try? JSONValue(encoding: TerminalConfig(cwd: liveDirectory ?? offeredDirectory ?? startDirectory))) ?? .emptyObject
    }

    /// Something other than an idle prompt holds the terminal: a build,
    /// vim, ssh — closing ends it.
    var closeWarning: String? {
        guard let process, !hasExited,
            let group = ProcessProbe.foregroundGroup(of: process.pid)
        else { return nil }
        return ProcessProbe.commandName(of: group).map { "\($0) is still running" } ?? "A process is still running"
    }

    func focus() { surface.focus() }

    func paneDidShow() {
        isShown = true
        // The grid takes the view's size now (it kept its own while hidden),
        // and the pty follows.
        surface.isShown = true
        syncPtySize()
    }

    func paneDidHide() {
        isShown = false
        surface.isShown = false
    }

    func paneWillClose() {
        settingsSubscription?.cancel()
        end()
        services.forget(pane.paneID)
    }

    /// Ends the shell (closing the pane, or the app quitting).
    func end() {
        process?.terminate()
        hasExited = true
    }

    /// A safety net: core always closes a pane (or deactivates the plugin)
    /// before letting it go, but a shell must never outlive its pane.
    isolated deinit {
        process?.terminate()
    }

    // MARK: Actions

    /// Clears the screen and scrollback (⌘K, the header's Clear scrollback),
    /// except while a full-screen program owns the screen.
    @discardableResult
    func clear() -> Bool { surface.clear() }

    private func apply(_ settings: TerminalSettings) {
        surface.apply(settings.appearance)
        surface.setScrollback(settings.scrollback)
    }

    /// Gives the pty the view's size, while the pane is shown.
    private func syncPtySize() {
        guard isShown, let process, surface.columns > 0, surface.rows > 0,
            ptySize.columns != surface.columns || ptySize.rows != surface.rows
        else { return }
        ptySize = (surface.columns, surface.rows)
        process.resize(columns: ptySize.columns, rows: ptySize.rows)
    }

    // MARK: TerminalSurfaceDelegate

    func surfaceSend(_ bytes: ArraySlice<UInt8>) {
        guard !hasExited else { return }
        process?.write(Array(bytes))
    }

    func surfaceDidResize(columns: Int, rows: Int) { syncPtySize() }

    func surfaceTitleDidChange(_ title: String) {
        // An empty title gives the pane its type's name back.
        pane.setTitle(title.isEmpty ? "Terminal" : title)
    }

    func surfaceBell() { pane.raise(TerminalSignals.bell.signal) }

    func surfaceOpenLink(_ link: String) { services.openLink(link) }

    // MARK: Tests (the Debug verbs)

    var testState: JSONValue {
        [
            "pid": process.map { .int(Int64($0.pid)) } ?? .null,
            "columns": .int(Int64(surface.columns)), "rows": .int(Int64(surface.rows)),
            "ptyColumns": .int(Int64(ptySize.columns)), "ptyRows": .int(Int64(ptySize.rows)),
            "screen": .string(surface.screenText), "buffer": .string(surface.bufferText),
            "alternateScreen": .bool(surface.isAlternateScreen), "exited": .bool(hasExited),
            "cwd": liveDirectory.map(JSONValue.string) ?? .null, "focused": .bool(surface.hasFocus),
        ]
    }

    var surfaceForTests: any TerminalSurface { surface }
}
