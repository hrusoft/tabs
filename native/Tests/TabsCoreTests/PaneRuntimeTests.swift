import AppKit
import TabsPluginSDK
import Testing

@testable import TabsCore

/// A layout that records what the runtime asked of it.
@MainActor
final class FakeShell: WorkspaceShell {
    let runtime: PaneRuntime
    var window: WindowID = "w1"
    var placed: [(PaneID, PanePlacement)] = []
    var closeRequests: [PaneID] = []
    var titleChanges: [PaneID] = []
    var stateChanges: [PaneID] = []
    var refusesPlacement = false
    private(set) var active: PaneID?

    init(runtime: PaneRuntime) {
        self.runtime = runtime
        runtime.shell = self
    }

    var frontmostWindowID: WindowID? { window }
    var activePaneID: PaneID? { active }

    func place(_ pane: LivePane, placement: PanePlacement) -> Bool {
        guard !refusesPlacement else { return false }
        placed.append((pane.id, placement))
        runtime.attach(pane, in: window)
        activate(pane.id)
        return true
    }

    func activate(_ pane: PaneID?) {
        active = pane
        runtime.activePaneDidChange(to: pane, in: window)
    }

    func focus(_ pane: PaneID) { activate(pane) }
    func requestClose(_ pane: PaneID) { closeRequests.append(pane) }
    func paneTitleDidChange(_ pane: PaneID) { titleChanges.append(pane) }
    func paneStateDidChange(_ pane: PaneID) { stateChanges.append(pane) }
    var menus: [(pane: PaneID, titles: [String], point: NSPoint)] = []
    func paneShowContextMenu(_ items: [PaneMenuItem], at point: NSPoint, in view: NSView, for pane: PaneID) {
        menus.append((pane, items.map(\.title), point))
    }
    /// Answers every question with `answer` (the dialog's default when nil), and keeps them.
    var dialogs: [PaneDialog] = []
    var dialogAnswer: PaneDialog.Answer?
    func paneShowDialog(_ dialog: PaneDialog, for pane: PaneID, completion: @escaping @MainActor (PaneDialog.Answer) -> Void) {
        dialogs.append(dialog)
        completion(dialogAnswer ?? dialog.defaultAnswer)
    }
    var pickers: [PanePicker] = []
    var pickerAnswer: URL?
    func paneShowPicker(_ picker: PanePicker, for pane: PaneID, completion: @escaping @MainActor (URL?) -> Void) {
        pickers.append(picker)
        completion(pickerAnswer)
    }
}

/// A pane whose config a test controls, and that records what core told it.
@MainActor
final class ProbePane: PaneController {
    let view = NSView()
    var config: JSONValue
    var closed = false
    var visibility: [String] = []
    init(config: JSONValue) { self.config = config }
    func currentConfig() -> JSONValue { config }
    func paneWillClose() { closed = true }
    func paneDidShow() { visibility.append("show") }
    func paneDidHide() { visibility.append("hide") }
}

/// A pane that puts its own view in its header's title slot.
@MainActor
final class TitledProbePane: PaneController {
    let view = NSView()
    let title = NSView()
    var headerTitle: NSView? { title }
    func currentConfig() -> JSONValue { .emptyObject }
}

/// The pane contract as plugins see it, against a fake layout: no windows.
@MainActor
@Suite struct PaneRuntimeTests {
    let runtime = TestSupport.runtime()

    private var probe: PluginCandidate {
        TestSupport.candidate(TestSupport.manifest("probe", contentTypes: ["probe"])) { context in
            context.register(
                ContentTypeContribution(
                    id: "probe", displayName: "Probe", icon: .symbol("circle"),
                    initialConfig: { creation in
                        let directory = creation.origin.flatMap { context.workspace.capability(.workingDirectory, of: $0) }
                        return ["origin": directory.map { .string($0.path) } ?? nil]
                    }
                ) { pane in
                    ProbePane(config: pane.initialConfig)
                })
        }
    }

    /// Keeps the (weakly held) shell alive for the test and collects events.
    final class Fixture {
        var shell: FakeShell?
        var lines: [String] = []
    }
    let fixture = Fixture()

    private func startWithEventLog() -> (FakeShell, () -> [String]) {
        let fixture = fixture
        runtime.startPlugins(
            from: nil,
            inProcess: [
                probe,
                TestSupport.candidate(TestSupport.manifest("watcher")) { context in
                    for (channel, name) in [
                        (EventChannel<PaneEvent>.paneOpened, "open"), (.paneClosed, "close"), (.activePaneChanged, "active"),
                    ] {
                        context.events.subscribe(channel) {
                            fixture.lines.append("\(name) \($0.paneID) \($0.contentType?.rawValue ?? "-")")
                        }
                    }
                },
            ])
        let shell = FakeShell(runtime: runtime.panes)
        fixture.shell = shell
        return (shell, { fixture.lines })
    }

    @Test func aPaneOffersATitleViewOrNone() throws {
        runtime.startPlugins(
            from: nil,
            inProcess: [
                TestSupport.candidate(TestSupport.manifest("headers", contentTypes: ["headers.plain", "headers.titled"])) { context in
                    context.register(
                        ContentTypeContribution(id: "headers.plain", displayName: "Plain", icon: .symbol("circle")) { _ in
                            ProbePane(config: .null)
                        })
                    context.register(
                        ContentTypeContribution(id: "headers.titled", displayName: "Titled", icon: .symbol("circle")) { _ in
                            TitledProbePane()
                        })
                }
            ])
        let shell = FakeShell(runtime: runtime.panes)
        let restoredPlain = runtime.panes.restore(LayoutLeaf(id: "p", type: "headers.plain"), in: shell.window)
        let restoredTitled = runtime.panes.restore(LayoutLeaf(id: "t", type: "headers.titled"), in: shell.window)
        guard case .live(let plain) = restoredPlain, case .live(let titled) = restoredTitled else {
            Issue.record("expected live panes: \(restoredPlain) \(restoredTitled)")
            return
        }
        #expect(plain.controller.headerTitle == nil, "the default is core's own title")
        let controller = try #require(titled.controller as? TitledProbePane)
        #expect(titled.controller.headerTitle === controller.title)
    }

    @Test func openedAfterItIsInAWindowThenActive() throws {
        let (_, log) = startWithEventLog()
        let id = try #require(runtime.panes.openPane(PaneRequest(type: "probe")))
        #expect(log() == ["open \(id) probe", "active \(id) probe"])
        #expect(runtime.panes.contentType(of: id) == "probe")
        #expect(runtime.panes.panes(ofType: "probe") == [id])
    }

    @Test func closedOnlyForPanesThatOpened() throws {
        let (shell, log) = startWithEventLog()
        let restored = runtime.panes.restore(LayoutLeaf(id: "r", type: "probe"), in: shell.window)
        guard case .live(let pane) = restored else { Issue.record("expected live"); return }
        runtime.panes.detach(pane.id)
        #expect(log().isEmpty, "never attached: no open, no close")
        runtime.panes.detach("an-empty-pane")
        #expect(log().isEmpty)
        let id = try #require(runtime.panes.openPane(PaneRequest(type: "probe")))
        runtime.panes.detach(id)
        #expect(log().last == "close \(id) probe")
    }

    @Test func activeChangesAreDeduplicatedAndFollowFillsInPlace() throws {
        let (shell, log) = startWithEventLog()
        shell.activate("empty")
        shell.activate("empty")
        #expect(log() == ["active empty -"])
        // The active empty pane is filled in place: same id, new type.
        let pane = try #require(runtime.panes.create(PaneRequest(type: "probe"), id: "empty", in: shell.window))
        runtime.panes.attach(pane, in: shell.window)
        #expect(log() == ["active empty -", "open empty probe", "active empty probe"])
    }

    @Test func creationIsGatedButRestorationIsNot() {
        runtime.settings.setDisabled(true, for: "probe")
        runtime.startPlugins(from: nil, inProcess: [probe], requiredContentTypes: ["probe"])
        let shell = FakeShell(runtime: runtime.panes)
        fixture.shell = shell
        #expect(!runtime.panes.canCreate("probe"))
        #expect(runtime.panes.openPane(PaneRequest(type: "probe")) == nil)
        #expect(runtime.panes.create(PaneRequest(type: "probe"), in: shell.window) == nil)
        guard case .live = runtime.panes.restore(LayoutLeaf(id: "kept", type: "probe"), in: shell.window) else {
            Issue.record("a pane the user has keeps working")
            return
        }
    }

    @Test func unavailableTypesSayWhy() {
        runtime.startPlugins(
            from: nil,
            inProcess: [
                TestSupport.candidate(TestSupport.manifest("broken", contentTypes: ["broken"])) { _ in
                    struct Boom: Error {}
                    throw Boom()
                }
            ])
        guard case .unavailable(let reason) = runtime.panes.restore(LayoutLeaf(id: "x", type: "broken"), in: "w") else {
            Issue.record("expected unavailable")
            return
        }
        #expect(reason == "Its plugin, Broken, is failed: activate() threw: Boom().")
        guard case .unavailable(let other) = runtime.panes.restore(LayoutLeaf(id: "y", type: "nobody"), in: "w") else { return }
        #expect(other == "No installed plugin provides it.")
    }

    @Test func aPaneThatCannotBePlacedIsReleasedSilently() {
        let (shell, log) = startWithEventLog()
        shell.refusesPlacement = true
        #expect(runtime.panes.openPane(PaneRequest(type: "probe")) == nil)
        #expect(runtime.panes.panes(ofType: "probe").isEmpty)
        #expect(log().isEmpty)
    }

    @Test func aBadConfigCostsOnlyThatPaneItsLatestChange() throws {
        _ = startWithEventLog()
        let id = try #require(runtime.panes.openPane(PaneRequest(type: "probe", config: ["n": 1])))
        let pane = try #require(runtime.panes.pane(id))
        let probe = try #require(pane.controller as? ProbePane)
        probe.config = ["n": 2]
        #expect(runtime.panes.snapshot(pane).config == ["n": 2])
        probe.config = ["n": .double(.nan)]
        #expect(runtime.panes.snapshot(pane).config == ["n": 2], "the last good config")
    }

    @Test func originAndCapabilitiesConnectPlugins() throws {
        _ = startWithEventLog()
        let origin = try #require(runtime.panes.openPane(PaneRequest(type: "probe")))
        runtime.panes.pane(origin)?.context.offer(.workingDirectory, URL(filePath: "/tmp/project"))
        #expect(runtime.workspace.capability(.workingDirectory, of: origin) == URL(filePath: "/tmp/project"))
        let child = try #require(runtime.panes.openPane(PaneRequest(type: "probe", origin: origin)))
        #expect(runtime.panes.pane(child)?.context.initialConfig == ["origin": "/tmp/project"])
    }

    @Test func contextCallbacksReachTheShellOnlyOnceAttached() async throws {
        let (shell, _) = startWithEventLog()
        let id = try #require(runtime.panes.openPane(PaneRequest(type: "probe")))
        let context = try #require(runtime.panes.pane(id)?.context)
        context.setTitle("Renamed")
        context.configDidChange()
        context.requestClose()
        #expect(shell.titleChanges == [id])
        #expect(shell.stateChanges == [id])
        #expect(shell.closeRequests.isEmpty, "requestClose is deferred: never inside the plugin's own call")
        await Task.yield()
        #expect(shell.closeRequests == [id])
        #expect(runtime.panes.pane(id)?.title == "Renamed")
        runtime.panes.detach(id)
        context.setTitle("After")
        #expect(shell.titleChanges == [id], "a detached pane's context is cut off")
    }

    @Test func aPanesQuestionsAreAnsweredByTheShell() async throws {
        let (shell, _) = startWithEventLog()
        let id = try #require(runtime.panes.openPane(PaneRequest(type: "probe")))
        let context = try #require(runtime.panes.pane(id)?.context)
        // No user: each dialog's default button.
        #expect(await context.confirm(PaneConfirm(title: "T", message: "M")))
        #expect(await context.choose(PaneChoose(title: "T", message: "M", options: ["a", "b"])) == 0)
        await context.alert(PaneAlert(title: "T", message: "M"))
        #expect(shell.dialogs.count == 3)
        #expect(shell.dialogs[0] == .confirm(PaneConfirm(title: "T", message: "M", confirmLabel: "OK", cancelLabel: "Cancel")))
        // The user's answers come back as they are.
        shell.dialogAnswer = .confirmed(false)
        #expect(await context.confirm(PaneConfirm(title: "T", message: "M")) == false)
        shell.dialogAnswer = .chose(1)
        #expect(await context.choose(PaneChoose(title: "T", message: "M", options: ["a", "b"])) == 1)
        shell.dialogAnswer = .chose(nil)
        #expect(await context.choose(PaneChoose(title: "T", message: "M", options: ["a", "b"])) == nil)
        // An answer outside the options is no answer.
        shell.dialogAnswer = .chose(5)
        #expect(await context.choose(PaneChoose(title: "T", message: "M", options: ["a", "b"])) == nil)
        // Nothing to choose from is never asked.
        let asked = shell.dialogs.count
        #expect(await context.choose(PaneChoose(title: "T", message: "M", options: [])) == nil)
        #expect(shell.dialogs.count == asked)
    }

    @Test func aPanesPickerIsCancelledUnlessTheShellSaysOtherwise() async throws {
        let (shell, _) = startWithEventLog()
        let id = try #require(runtime.panes.openPane(PaneRequest(type: "probe")))
        let context = try #require(runtime.panes.pane(id)?.context)
        let start = URL(filePath: "/tmp/start", directoryHint: .isDirectory)
        #expect(await context.chooseDirectory(title: "Pick", startingAt: start) == nil)
        shell.pickerAnswer = URL(filePath: "/tmp/chosen")
        #expect(await context.chooseFile(title: "Pick a file") == URL(filePath: "/tmp/chosen"))
        #expect(
            shell.pickers == [
                PanePicker(kind: .directory, title: "Pick", startingAt: start), PanePicker(kind: .file, title: "Pick a file"),
            ])
    }

    @Test func aClosedPanesQuestionsAreDismissedNotAsked() async throws {
        let (shell, _) = startWithEventLog()
        let id = try #require(runtime.panes.openPane(PaneRequest(type: "probe")))
        let context = try #require(runtime.panes.pane(id)?.context)
        runtime.panes.detach(id)
        #expect(await context.confirm(PaneConfirm(title: "T", message: "M")) == false)
        #expect(await context.choose(PaneChoose(title: "T", message: "M", options: ["a"])) == nil)
        await context.alert(PaneAlert(title: "T", message: "M"))
        #expect(await context.chooseDirectory(title: "Pick") == nil)
        #expect(shell.dialogs.isEmpty && shell.pickers.isEmpty)
    }

    @Test func aConfigThatIsNotJSONIsRefusedAtCreation() {
        let (_, log) = startWithEventLog()
        #expect(runtime.panes.openPane(PaneRequest(type: "probe", config: ["x": .double(.infinity)])) == nil)
        #expect(log().isEmpty)
    }

    @Test func aPaneThePluginCannotBuildStaysUnavailableAndVerbatim() {
        struct Unreadable: Error, CustomStringConvertible { var description: String { "config is from the future" } }
        runtime.startPlugins(
            from: nil,
            inProcess: [
                TestSupport.candidate(TestSupport.manifest("picky", contentTypes: ["picky"])) { context in
                    context.register(
                        ContentTypeContribution(id: "picky", displayName: "Picky", icon: .symbol("circle")) { _ in throw Unreadable() })
                }
            ])
        fixture.shell = FakeShell(runtime: runtime.panes)
        guard case .unavailable(let reason) = runtime.panes.restore(LayoutLeaf(id: "p", type: "picky", config: ["v": 2]), in: "w1") else {
            Issue.record("expected unavailable")
            return
        }
        #expect(reason == "Picky could not open this pane's saved state: config is from the future")
        #expect(runtime.panes.openPane(PaneRequest(type: "picky")) == nil)
    }

    @Test func aDuplicatePaneIDGetsAFreshOne() throws {
        _ = startWithEventLog()
        guard case .live(let first) = runtime.panes.restore(LayoutLeaf(id: "same", type: "probe"), in: "w1"),
            case .live(let second) = runtime.panes.restore(LayoutLeaf(id: "same", type: "probe"), in: "w1")
        else {
            Issue.record("expected two live panes")
            return
        }
        #expect(first.id == "same")
        #expect(second.id != "same")
        runtime.panes.detach(second.id)
        #expect(runtime.panes.pane("same") === first, "closing one never tears down the other")
    }

    @Test func pluginsCannotOpenPanesWhileActivating() {
        var opened: PaneID?
        runtime.startPlugins(
            from: nil,
            inProcess: [
                TestSupport.candidate(TestSupport.manifest("eager", contentTypes: ["eager"])) { context in
                    context.register(TestSupport.contentType("eager"))
                    opened = context.workspace.openPane(ofType: "eager")
                }
            ])
        fixture.shell = FakeShell(runtime: runtime.panes)
        #expect(opened == nil)
        #expect(runtime.host.record(for: "eager")?.ignoredCalls == ["openPane eager while activating"])
    }

    @Test func aPluginManagesOnlyItsOwnPanes() throws {
        final class Box { var context: (any PluginContext)? }
        let box = Box()
        runtime.startPlugins(
            from: nil,
            inProcess: [
                probe,
                TestSupport.candidate(TestSupport.manifest("other", contentTypes: ["other"])) { context in
                    context.register(TestSupport.contentType("other"))
                    box.context = context
                },
            ])
        fixture.shell = FakeShell(runtime: runtime.panes)
        let context = try #require(box.context)
        let probePane = try #require(runtime.panes.openPane(PaneRequest(type: "probe")))
        let ownPane = try #require(context.workspace.openPane(ofType: "other"))

        #expect(context.workspace.openPane(ofType: "probe") == nil)
        #expect(context.workspace.panes(ofType: "probe").isEmpty)
        context.workspace.focusPane(probePane)
        #expect(fixture.shell?.activePaneID == ownPane, "focusing another plugin's pane was refused")
        #expect(context.workspace.panes(ofType: "other") == [ownPane])
        // Core facts about other panes stay visible.
        #expect(context.workspace.contentType(of: probePane) == "probe")
        #expect(
            runtime.host.record(for: "other")?.ignoredCalls == [
                "openPane probe: not one of this plugin's content types",
                "panes(ofType: probe): not one of this plugin's content types",
                "focusPane \(probePane): not one of this plugin's content types",
            ])
    }

    @Test func capabilitiesAreTheOnlyWindowIntoAnotherPluginsPane() throws {
        final class Box { var context: (any PluginContext)? }
        let box = Box()
        runtime.startPlugins(
            from: nil,
            inProcess: [
                probe,
                TestSupport.candidate(TestSupport.manifest("asker")) { box.context = $0 },
            ])
        fixture.shell = FakeShell(runtime: runtime.panes)
        let pane = try #require(runtime.panes.openPane(PaneRequest(type: "probe")))
        runtime.panes.pane(pane)?.context.offer(.workingDirectory, URL(filePath: "/tmp/repo"))
        #expect(box.context?.workspace.capability(.workingDirectory, of: pane) == URL(filePath: "/tmp/repo"))
    }

    @Test func capabilitiesArePushedStoredAndAnnouncedOnChange() async throws {
        final class Box { var context: (any PluginContext)? }
        let box = Box()
        var changes: [String] = []
        runtime.startPlugins(
            from: nil,
            inProcess: [
                TestSupport.candidate(TestSupport.manifest("probe", contentTypes: ["probe"])) { context in
                    context.register(
                        ContentTypeContribution(id: "probe", displayName: "Probe", icon: .symbol("circle")) { pane in
                            // Offered while being built: kept, announced by paneOpened rather than a change.
                            pane.offer(.workingDirectory, URL(filePath: "/start"))
                            return ProbePane(config: pane.initialConfig)
                        })
                },
                TestSupport.candidate(TestSupport.manifest("follower")) { context in
                    box.context = context
                    context.events.subscribe(.capabilityChanged(.workingDirectory)) { event in
                        changes.append(context.workspace.capability(.workingDirectory, of: event.paneID)?.path ?? "none")
                    }
                },
            ])
        fixture.shell = FakeShell(runtime: runtime.panes)
        let id = try #require(runtime.panes.openPane(PaneRequest(type: "probe")))
        let reader = try #require(box.context).workspace
        #expect(reader.capability(.workingDirectory, of: id) == URL(filePath: "/start"))
        let context = try #require(runtime.panes.pane(id)?.context)
        context.offer(.workingDirectory, URL(filePath: "/next"))
        #expect(reader.capability(.workingDirectory, of: id) == URL(filePath: "/next"), "readers see it at once")
        #expect(changes.isEmpty, "announced after the offering call returns, never inside it")
        await Task.yield()
        #expect(changes == ["/next"])
        context.offer(.workingDirectory, URL(filePath: "/next"))
        await Task.yield()
        #expect(changes == ["/next"], "no change, no event")
        context.offer(.workingDirectory, URL(filePath: "/a"))
        context.offer(.workingDirectory, nil)
        await Task.yield()
        #expect(changes == ["/next", "none"], "a burst is one event, with the latest value")
        runtime.panes.detach(id)
        context.offer(.workingDirectory, URL(filePath: "/after"))
        await Task.yield()
        #expect(changes.count == 2, "a closed pane offers nothing")
        #expect(reader.capability(.workingDirectory, of: id) == nil)
    }

    @Test func onlyCapabilitiesCoreDeclaresExist() throws {
        final class Box { var context: (any PluginContext)? }
        let box = Box()
        runtime.startPlugins(from: nil, inProcess: [probe, TestSupport.candidate(TestSupport.manifest("asker")) { box.context = $0 }])
        fixture.shell = FakeShell(runtime: runtime.panes)
        let pane = try #require(runtime.panes.openPane(PaneRequest(type: "probe")))
        // What a plugin built with core's package name could construct: a private channel.
        let secret = PaneCapability<String>("probe.secret")
        runtime.panes.pane(pane)?.context.offer(secret, "psst")
        let context = try #require(box.context)
        #expect(context.workspace.capability(secret, of: pane) == nil)
        let subscription = context.events.subscribe(.capabilityChanged(secret)) { _ in }
        #expect(subscription.isCancelled)
        #expect(
            runtime.host.record(for: "asker")?.ignoredCalls == [
                "capability probe.secret: core declares no such capability",
                "subscribe tabs.capabilityChanged.probe.secret: no channel tabs.capabilityChanged.probe.secret is declared",
            ])
    }

    @Test func visibilityReachesThePaneOnChangeOnly() throws {
        _ = startWithEventLog()
        let id = try #require(runtime.panes.openPane(PaneRequest(type: "probe")))
        let probe = try #require(runtime.panes.pane(id)?.controller as? ProbePane)
        runtime.panes.visibilityDidChange(id, visible: true)
        runtime.panes.visibilityDidChange(id, visible: true)
        runtime.panes.visibilityDidChange(id, visible: false)
        #expect(probe.visibility == ["show", "hide"])
    }

    @Test func aPaneMovingWindowsIsAnnouncedAndItsContextFollows() throws {
        var moves: [String] = []
        runtime.startPlugins(
            from: nil,
            inProcess: [
                probe,
                TestSupport.candidate(TestSupport.manifest("watcher")) { context in
                    context.events.subscribe(.paneMoved) { moves.append("\($0.paneID) → \($0.windowID)") }
                },
            ])
        fixture.shell = FakeShell(runtime: runtime.panes)
        let id = try #require(runtime.panes.openPane(PaneRequest(type: "probe")))
        runtime.panes.paneDidMove(id, to: "w1")
        runtime.panes.paneDidMove(id, to: "w2")
        #expect(moves == ["\(id) → w2"], "only a real change")
        #expect(runtime.panes.pane(id)?.context.windowID == "w2")
    }

    @Test func childProcessesLearnTheSocketAndTheirPane() throws {
        _ = startWithEventLog()
        runtime.controlSocketPath = "/tmp/tabs.sock"
        runtime.panes.baseEnvironment = [
            "PATH": "/usr/bin", "TABS_DATA_DIR": "/tmp/test-data", "TABS_LISTEN_SOCKET": "/tmp/own.sock", "TABS_E2E_HIDDEN": "1",
            "TABS_PANE_ID": "the-parent-app's",
        ]
        let id = try #require(runtime.panes.openPane(PaneRequest(type: "probe")))
        #expect(
            runtime.panes.pane(id)?.context.childEnvironment
                == ["PATH": "/usr/bin", "TABS_CONTROL_SOCKET": "/tmp/tabs.sock", "TABS_PANE_ID": id.rawValue],
            "the app's own launch settings never reach a child")
    }
}

/// Every subscriber sees events in the order they were published, even when a
/// handler causes another one.
@MainActor
@Suite struct EventOrderTests {
    @Test func aNestedPublishWaitsForTheCurrentDelivery() {
        let hub = EventHub()
        let channel = EventChannel<Int>("tabs.test")
        hub.declare(channel)
        var seen: [String] = []
        _ = hub.subscribe(channel, owner: "first") { value in
            seen.append("first \(value)")
            if value == 1 { hub.publish(channel, 2) }
        }
        _ = hub.subscribe(channel, owner: "second") { seen.append("second \($0)") }
        hub.publish(channel, 1)
        #expect(seen == ["first 1", "second 1", "first 2", "second 2"])
    }

    @Test func anUpdateFromInsideASettingsObserverReachesEveryoneInOrder() {
        struct Count: PluginSettingsValue { var n = 0 }
        let settings = PluginSettings<Count>(pluginID: "p", backend: MemoryBackend(), log: Log.core)
        var seen: [String] = []
        let first = settings.observe { value in
            seen.append("first \(value.n)")
            if value.n == 1 { settings.update { $0.n = 2 } }
        }
        let second = settings.observe { seen.append("second \($0.n)") }
        settings.update { $0.n = 1 }
        #expect(seen == ["first 1", "second 1", "first 2", "second 2"])
        withExtendedLifetime((first, second)) {}
    }
}
