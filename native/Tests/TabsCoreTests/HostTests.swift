import AppKit
import TabsPluginSDK
import Testing

@testable import TabsCore

/// The activation pipeline against in-process plugins: every rule and every
/// rollback, without building a bundle per case.
@MainActor
@Suite struct HostTests {
    let runtime = TestSupport.runtime()

    private func start(_ candidates: PluginCandidate..., required: Set<ContentTypeID> = []) {
        runtime.startPlugins(from: nil, inProcess: candidates, requiredContentTypes: required)
    }

    @Test func activePluginContributionsAreVisible() {
        start(
            TestSupport.candidate(TestSupport.manifest("a", contentTypes: ["a"])) { context in
                context.register(TestSupport.contentType("a"))
                context.register(CommandContribution(id: "a.go", title: "Go", menu: .view) { _ in })
                context.register(ControlVerbContribution(name: "a.ping", summary: "test") { _ in "pong" })
            })
        #expect(TestSupport.state(runtime, "a") == .active)
        #expect(runtime.registry.contributions(to: .contentTypes).map(\.value.id) == ["a"])
        #expect(runtime.registry.contribution(to: .commands, id: "a.go")?.owner == "a")
        #expect(
            runtime.host.record(for: "a")?.contributionCounts == [
                "tabs.contentTypes": 1, "tabs.commands": 1, "tabs.controlVerbs": 1,
            ])
    }

    @Test func throwingActivationRollsBackEverything() {
        var deactivated = false
        start(
            TestSupport.candidate(
                TestSupport.manifest("bad", contentTypes: ["bad"]),
                activate: { context in
                    context.register(TestSupport.contentType("bad"))
                    context.register(CommandContribution(id: "bad.go", title: "Go", menu: .view) { _ in })
                    context.events.subscribe(.paneOpened) { _ in }
                    struct Boom: Error {}
                    throw Boom()
                }, deactivate: { deactivated = true }),
            TestSupport.candidate(TestSupport.manifest("unrelated")) { _ in }
        )
        #expect(TestSupport.state(runtime, "bad") == .failed("activate() threw: Boom()"))
        #expect(runtime.registry.contributions(to: .contentTypes).isEmpty)
        #expect(runtime.registry.contributions(to: .commands).isEmpty)
        #expect(runtime.hub.subscriberCount(channelID: "tabs.paneOpened") == 0)
        #expect(!deactivated, "deactivate is for plugins whose activate returned")
        #expect(TestSupport.state(runtime, "unrelated") == .active, "plugins are isolated: one failing touches no other")
    }

    @Test func oneBadContributionFailsTheWholePlugin() {
        var deactivated = false
        start(
            TestSupport.candidate(
                TestSupport.manifest("a"),
                activate: { context in
                    context.register(CommandContribution(id: "a.fine", title: "Fine", menu: .view) { _ in })
                    context.register(CommandContribution(id: "other.stolen", title: "Stolen", menu: .view) { _ in })
                    context.events.subscribe(.paneClosed) { _ in }
                }, deactivate: { deactivated = true }))
        guard case .failed(let reason)? = TestSupport.state(runtime, "a") else {
            Issue.record("expected failure")
            return
        }
        #expect(reason.contains("\"other.stolen\": must be \"a\" or start with \"a.\""))
        #expect(runtime.registry.contributions(to: .commands).isEmpty, "the valid command is rolled back too")
        #expect(runtime.hub.subscriberCount(channelID: "tabs.paneClosed") == 0)
        #expect(deactivated, "activate returned, so the plugin gets to stop what it started")
    }

    @Test func contentTypesMustMatchTheManifestExactly() {
        start(
            TestSupport.candidate(TestSupport.manifest("undeclared")) { context in
                context.register(TestSupport.contentType("undeclared"))
            },
            TestSupport.candidate(TestSupport.manifest("unregistered", contentTypes: ["unregistered"])) { _ in }
        )
        #expect(
            TestSupport.state(runtime, "undeclared")
                == .failed("tabs.contentTypes \"undeclared\": not declared in the manifest's contentTypes"))
        #expect(
            TestSupport.state(runtime, "unregistered")
                == .failed("tabs.contentTypes \"unregistered\": declared in the manifest but never registered"))
    }

    @Test func aCommandMayApplyOnlyToItsOwnContentTypes() {
        start(
            TestSupport.candidate(TestSupport.manifest("mine", contentTypes: ["mine"])) { context in
                context.register(TestSupport.contentType("mine"))
            },
            TestSupport.candidate(TestSupport.manifest("meddler")) { context in
                context.register(CommandContribution(id: "meddler.poke", title: "Poke", menu: .view, appliesTo: "mine") { _ in })
            }
        )
        #expect(
            TestSupport.state(runtime, "meddler")
                == .failed("tabs.commands \"meddler.poke\": appliesTo \"mine\" is not one of this plugin's content types"))
    }

    @Test func shortcutClashesUnbindTheLaterCommandButNeverFailAPlugin() {
        let chord = KeyChord("k", [.command, .shift])
        start(
            TestSupport.candidate(TestSupport.manifest("first", sortOrder: 1)) { context in
                context.register(CommandContribution(id: "first.k", title: "K", menu: .view, defaultChord: chord) { _ in })
            },
            TestSupport.candidate(TestSupport.manifest("second", sortOrder: 2)) { context in
                context.register(CommandContribution(id: "second.k", title: "K", menu: .view, defaultChord: chord) { _ in })
            },
            TestSupport.candidate(TestSupport.manifest("third", sortOrder: 3)) { context in
                context.register(
                    CommandContribution(id: "third.quit", title: "Q", menu: .view, defaultChord: KeyChord("q", [.command])) { _ in })
            }
        )
        for id in ["first", "second", "third"] { #expect(TestSupport.state(runtime, id) == .active) }
        #expect(runtime.shortcuts.chord(for: "first.k") == chord)
        #expect(runtime.shortcuts.chord(for: "second.k") == nil)
        #expect(runtime.host.record(for: "second")?.notes == ["⇧⌘K is taken by first.k, so it's unbound"])
        #expect(runtime.shortcuts.chord(for: "third.quit") == nil, "core's commands come first")
        #expect(runtime.host.record(for: "third")?.notes == ["⌘Q is taken by tabs.quit, so it's unbound"])
    }

    @Test(arguments: [
        (KeyChord("a", [.shift]), nil as ContentTypeID?, "shortcut ⇧A: needs ⌘ or ⌃"),
        (
            KeyChord("r", [.control]), nil,
            "shortcut ⌃R: a shortcut that works in every pane needs ⌘ (give the command appliesTo to use ⌃ alone)"
        ),
    ])
    func unusableDefaultChordsFailTheirOwnPlugin(chord: KeyChord, scope: ContentTypeID?, problem: String) {
        start(
            TestSupport.candidate(TestSupport.manifest("p", contentTypes: ["p"])) { context in
                context.register(TestSupport.contentType("p"))
                context.register(CommandContribution(id: "p.x", title: "X", menu: .view, defaultChord: chord, appliesTo: scope) { _ in })
            })
        #expect(TestSupport.state(runtime, "p") == .failed("tabs.commands \"p.x\": \(problem)"))
    }

    @Test func aScopedCommandMayUseControlAlone() {
        start(
            TestSupport.candidate(TestSupport.manifest("term", contentTypes: ["term"])) { context in
                context.register(TestSupport.contentType("term"))
                context.register(
                    CommandContribution(
                        id: "term.search", title: "S", menu: .view, defaultChord: KeyChord("r", [.control]), appliesTo: "term"
                    ) { _ in })
            })
        #expect(TestSupport.state(runtime, "term") == .active)
        #expect(runtime.shortcuts.chord(for: "term.search") == KeyChord("r", [.control]))
    }

    @Test func duplicateIDWithinOnePluginFails() {
        start(
            TestSupport.candidate(TestSupport.manifest("a")) { context in
                context.register(ControlVerbContribution(name: "a.v", summary: "test") { _ in nil })
                context.register(ControlVerbContribution(name: "a.v", summary: "test") { _ in nil })
            })
        #expect(TestSupport.state(runtime, "a") == .failed("tabs.controlVerbs \"a.v\": registered twice"))
    }

    @Test func onlyCorePointsAcceptContributions() {
        // Plugins can't construct an ExtensionPoint (its initializer is core's);
        // the registry still refuses a point core never declared, and a type
        // that doesn't match the declaration.
        struct Stray: Contribution { let contributionID: String }
        start(
            TestSupport.candidate(TestSupport.manifest("undeclared", sortOrder: 1)) { context in
                context.contribute(Stray(contributionID: "undeclared.x"), to: ExtensionPoint<Stray>("nobody.points"))
            },
            TestSupport.candidate(TestSupport.manifest("wrongtype", sortOrder: 2)) { context in
                context.contribute(Stray(contributionID: "wrongtype.x"), to: ExtensionPoint<Stray>("tabs.commands"))
            }
        )
        #expect(
            TestSupport.state(runtime, "undeclared")?.detail
                == "nobody.points \"undeclared.x\": no extension point \"nobody.points\" is declared")
        #expect(
            TestSupport.state(runtime, "wrongtype")?.detail?.contains("the point is declared for TabsPluginSDK.CommandContribution") == true
        )
    }

    @Test func contributionsAfterActivationAreIgnoredAndReported() {
        var saved: (any PluginContext)?
        start(TestSupport.candidate(TestSupport.manifest("a")) { context in saved = context })
        saved?.register(CommandContribution(id: "a.late", title: "Late", menu: .view) { _ in })
        #expect(runtime.registry.contributions(to: .commands).isEmpty)
        #expect(runtime.host.record(for: "a")?.ignoredCalls == ["contribute tabs.commands \"a.late\" while active"])
    }

    @Test func everyPluginGetsItsOwnPlacesToWrite() throws {
        var contexts: [PluginID: any PluginContext] = [:]
        start(
            TestSupport.candidate(TestSupport.manifest("one")) { contexts["one"] = $0 },
            TestSupport.candidate(TestSupport.manifest("two")) { contexts["two"] = $0 })
        let one = try #require(contexts["one"])
        let two = try #require(contexts["two"])
        for directory in [one.dataDirectory, one.cacheDirectory, one.temporaryDirectory] {
            #expect(FileManager.default.fileExists(atPath: directory.path), "created on first access")
            #expect(directory.path.hasPrefix(runtime.paths.dataDirectory.path), "under TABS_DATA_DIR in tests")
            #expect(directory.lastPathComponent == "one")
        }
        #expect(Set([one.dataDirectory, one.cacheDirectory, one.temporaryDirectory]).count == 3)
        #expect(one.webDataStoreIdentifier != two.webDataStoreIdentifier, "web data isn't shared")

        // Stable for a data directory, and different for another (tests never share the user's web data).
        func identifier(in directory: URL) -> UUID? {
            let runtime = TestSupport.runtime(dataDirectory: directory)
            var context: (any PluginContext)?
            runtime.startPlugins(from: nil, inProcess: [TestSupport.candidate(TestSupport.manifest("one")) { context = $0 }])
            return context?.webDataStoreIdentifier
        }
        #expect(identifier(in: runtime.paths.dataDirectory) == one.webDataStoreIdentifier)
        #expect(identifier(in: TestSupport.temporaryDirectory()) != one.webDataStoreIdentifier)
        let scratch = one.temporaryDirectory
        runtime.removeTemporaryFiles()
        #expect(!FileManager.default.fileExists(atPath: scratch.path), "scratch space goes at quit")
    }

    @Test func theWebDataIdentityNeverChangesForADataDirectory() throws {
        func identifier(_ directory: URL) -> UUID? {
            let runtime = TestSupport.runtime(dataDirectory: directory)
            var context: (any PluginContext)?
            runtime.startPlugins(from: nil, inProcess: [TestSupport.candidate(TestSupport.manifest("web")) { context = $0 }])
            return context?.webDataStoreIdentifier
        }
        // An empty salt file is repaired once, not replaced on every launch.
        let empty = TestSupport.temporaryDirectory()
        FileManager.default.createFile(atPath: empty.appending(path: "web-data-salt").path, contents: Data())
        let first = identifier(empty)
        #expect(first != nil && identifier(empty) == first)
        // One that can't be read is left alone, and still gives the same identity every time.
        let locked = TestSupport.temporaryDirectory()
        let salt = locked.appending(path: "web-data-salt")
        try Data("secret".utf8).write(to: salt)
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: salt.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: salt.path) }
        let unreadable = identifier(locked)
        #expect(unreadable != nil && identifier(locked) == unreadable)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: salt.path)
        #expect(try String(contentsOf: salt, encoding: .utf8) == "secret", "never overwritten")
    }

    @Test func headlessRunsRefuseWritesRatherThanPretendToStoreThem() async {
        let directory = TestSupport.temporaryDirectory()
        let runtime = CoreRuntime(paths: AppPaths(dataDirectory: directory), readOnly: true)
        var saved: PluginSettings<TestSettings>?
        runtime.startPlugins(
            from: nil, inProcess: [TestSupport.candidate(TestSupport.manifest("p")) { saved = $0.settings(TestSettings.self) }])
        let response = await runtime.control.handle(
            ControlDispatcher.Envelope(command: "tabs.setShortcut", arguments: ["command": "tabs.quit", "chord": "none"]))
        #expect(response["ok"] == false)
        #expect(response["error"]?.stringValue?.contains("read-only") == true)
        saved?.update { $0.value = 7 }
        #expect(saved?.value == TestSettings(), "refused, not faked")
    }

    @Test func askingForASecondSettingsTypeIsRefusedNotACrash() {
        struct A: PluginSettingsValue { var a = 1 }
        struct B: PluginSettingsValue { var b = 2 }
        var second: PluginSettings<B>?
        start(
            TestSupport.candidate(TestSupport.manifest("two")) { context in
                context.settings(A.self).update { $0.a = 5 }
                second = context.settings(B.self)
            })
        #expect(TestSupport.state(runtime, "two") == .active, "the plugin keeps running")
        second?.update { $0.b = 9 }
        #expect(second?.value == B(), "defaults it can't change")
        #expect(runtime.settings.storedSettings(for: "two") == ["a": 5], "and the real settings are untouched")
        #expect(runtime.host.record(for: "two")?.ignoredCalls.first?.hasPrefix("settings(") == true)
    }

    @Test func aFailedPluginsContextIsDead() async throws {
        var saved: (any PluginContext)?
        struct Boom: Error {}
        start(
            TestSupport.candidate(TestSupport.manifest("dead", contentTypes: [])) { context in
                saved = context
                throw Boom()
            })
        let context = try #require(saved)
        // A Task the plugin left running can't reach core any more.
        let subscription = context.events.subscribe(.paneOpened) { _ in }
        #expect(subscription.isCancelled)
        #expect(runtime.hub.subscriberCount(channelID: "tabs.paneOpened") == 0)
        #expect(context.workspace.openPane(ofType: "x", config: nil) == nil)
        let settings = context.settings(TestSettings.self)
        settings.update { $0.value = 99 }
        #expect(settings.value.value == 0)
        #expect(runtime.settings.storedSettings(for: "dead") == nil)
        let task = context.spawn { try? await Task.sleep(for: .seconds(60)) }
        #expect(task.isCancelled)
        #expect(
            runtime.host.record(for: "dead")?.ignoredCalls == [
                "subscribe tabs.paneOpened while dead", "openPane x while dead", "spawn while dead",
            ])
    }

    @Test func facadesOutlivingTheRuntimeDoNotCrash() {
        var workspace: (any Workspace)?
        var events: (any EventBus)?
        do {
            let runtime = TestSupport.runtime()
            runtime.startPlugins(
                from: nil,
                inProcess: [
                    TestSupport.candidate(TestSupport.manifest("a")) { context in
                        workspace = context.workspace
                        events = context.events
                    }
                ])
            runtime.host.stop()
        }
        #expect(workspace?.activePaneID == nil)
        #expect(events?.subscribe(.paneOpened) { _ in }.isCancelled == true)
    }

    @Test func spawnedTasksAreCancelledAtStop() async throws {
        let started = AsyncStream<Void>.makeStream()
        let finished = AsyncStream<Bool>.makeStream()
        start(
            TestSupport.candidate(TestSupport.manifest("worker")) { context in
                context.spawn {
                    started.continuation.yield()
                    try? await Task.sleep(for: .seconds(60))
                    finished.continuation.yield(Task.isCancelled)
                }
            })
        var startedIterator = started.stream.makeAsyncIterator()
        _ = await startedIterator.next()
        runtime.host.stop()
        var finishedIterator = finished.stream.makeAsyncIterator()
        #expect(await finishedIterator.next() == true)
    }

    @Test func deactivateRunsOnceForEveryPluginWhoseActivateReturned() {
        var calls: [String] = []
        struct Boom: Error {}
        start(
            TestSupport.candidate(TestSupport.manifest("ok", sortOrder: 1), activate: { _ in }, deactivate: { calls.append("ok") }),
            TestSupport.candidate(
                TestSupport.manifest("rejected", sortOrder: 2),
                activate: { context in
                    context.register(CommandContribution(id: "elsewhere.x", title: "X", menu: .view) { _ in })
                }, deactivate: { calls.append("rejected") }),
            TestSupport.candidate(
                TestSupport.manifest("threw", sortOrder: 3), activate: { _ in throw Boom() },
                deactivate: { calls.append("threw") })
        )
        #expect(calls == ["rejected"], "rejected contributions: deactivated immediately")
        runtime.host.stop()
        runtime.host.stop()
        #expect(calls == ["rejected", "ok"], "active: once at stop; threw: never")
    }

    @Test func stopDeactivatesInReverseOrderAndCancelsSubscriptions() {
        var log: [String] = []
        start(
            TestSupport.candidate(
                TestSupport.manifest("second", sortOrder: 2),
                activate: { context in
                    context.events.subscribe(.paneOpened) { _ in }
                }, deactivate: { log.append("second") }),
            TestSupport.candidate(TestSupport.manifest("first", sortOrder: 1), activate: { _ in }, deactivate: { log.append("first") })
        )
        #expect(runtime.hub.subscriberCount(channelID: "tabs.paneOpened") == 1)
        runtime.host.stop()
        #expect(log == ["second", "first"])
        #expect(runtime.hub.subscriberCount(channelID: "tabs.paneOpened") == 0)
    }

    @Test func disabledPluginsNeitherLoadNorOfferCreation() {
        runtime.settings.setDisabled(true, for: "off")
        runtime.settings.setDisabled(true, for: "kept")
        var loaded: [String] = []
        start(
            TestSupport.candidate(TestSupport.manifest("off", contentTypes: ["off"])) { context in
                loaded.append("off")
                context.register(TestSupport.contentType("off"))
            },
            TestSupport.candidate(TestSupport.manifest("kept", contentTypes: ["kept"])) { context in
                loaded.append("kept")
                context.register(TestSupport.contentType("kept"))
            },
            required: ["kept"]
        )
        #expect(loaded == ["kept"])
        #expect(TestSupport.state(runtime, "off") == .disabled)
        #expect(TestSupport.state(runtime, "kept") == .active)
        #expect(runtime.host.record(for: "kept")?.notes == ["disabled, but loaded because an open pane shows its content type \"kept\""])
        #expect(runtime.panes.creatableTypes().isEmpty, "kept is running for its open pane, but offers no creation")
        runtime.host.setUserEnabled(true, for: "kept")
        #expect(runtime.panes.creatableTypes().map(\.value.id) == ["kept"])
        #expect(!runtime.settings.disabledPlugins.contains("kept"))
    }

    @Test func contentTypesOutsideThePluginsNamespaceAreRejected() {
        start(
            TestSupport.candidate(TestSupport.manifest("one", contentTypes: ["one", "one.extra"])) { context in
                context.register(TestSupport.contentType("one"))
                context.register(TestSupport.contentType("one.extra"))
            },
            TestSupport.candidate(TestSupport.manifest("two", contentTypes: ["one"])) { _ in }
        )
        #expect(TestSupport.state(runtime, "one") == .active)
        #expect(
            TestSupport.state(runtime, "two") == .rejected("invalid manifest: content type \"one\" must be \"two\" or start with \"two.\""))
    }

    @Test func twoPluginsWithOneIDAreBothRejected() {
        start(
            TestSupport.candidate(TestSupport.manifest("same")) { _ in },
            TestSupport.candidate(TestSupport.manifest("same")) { _ in }
        )
        #expect(
            runtime.host.records.filter { $0.id == "same" }.map(\.state) == [
                .rejected("another plugin has the same id"), .rejected("another plugin has the same id"),
            ])
    }
}

struct TestSettings: PluginSettingsValue, Equatable {
    var value = 0
}

@MainActor
@Suite struct LifecycleContractTests {
    let runtime = TestSupport.runtime()

    @Test func rejectedContributionsStillGetAWorkingDeactivate() async {
        final class Box {
            var context: (any PluginContext)?
        }
        let box = Box()
        let finished = AsyncStream<Bool>.makeStream()
        runtime.startPlugins(
            from: nil,
            inProcess: [
                TestSupport.candidate(
                    TestSupport.manifest("rejected"),
                    activate: { context in
                        box.context = context
                        context.spawn {
                            try? await Task.sleep(for: .seconds(60))
                            finished.continuation.yield(Task.isCancelled)
                        }
                        context.register(CommandContribution(id: "elsewhere.x", title: "X", menu: .view) { _ in })
                    },
                    deactivate: {
                        // As at quit: the context still works during deactivate.
                        box.context?.settings(TestSettings.self).update { $0.value = 1 }
                        _ = box.context?.events.subscribe(.paneClosed) { _ in }
                    })
            ])
        #expect(TestSupport.state(runtime, "rejected")?.label == "failed")
        #expect(runtime.settings.storedSettings(for: "rejected") == ["value": 1])
        #expect(runtime.host.record(for: "rejected")?.ignoredCalls.isEmpty == true)
        #expect(runtime.hub.subscriberCount(channelID: "tabs.paneClosed") == 0, "and then the kill cancels what it made")
        var iterator = finished.stream.makeAsyncIterator()
        #expect(await iterator.next() == true, "tasks are cancelled after deactivate, by the kill")
    }

    @Test func eventChannelsCarryOneType() {
        var context: (any PluginContext)?
        runtime.startPlugins(from: nil, inProcess: [TestSupport.candidate(TestSupport.manifest("a")) { context = $0 }])
        // Only core can construct channels; the hub still refuses a mismatched type.
        let refused = context?.events.subscribe(EventChannel<String>("tabs.paneOpened")) { _ in }
        #expect(refused?.isCancelled == true, "core's channel carries PaneEvent")
        #expect(
            runtime.host.record(for: "a")?.ignoredCalls == [
                "subscribe tabs.paneOpened: channel tabs.paneOpened carries TabsPluginSDK.PaneEvent, not Swift.String"
            ])
    }

    @Test func ignoredCallsAreCapped() {
        var context: (any PluginContext)?
        struct Boom: Error {}
        runtime.startPlugins(
            from: nil,
            inProcess: [
                TestSupport.candidate(TestSupport.manifest("noisy")) {
                    context = $0
                    throw Boom()
                }
            ])
        for _ in 0..<60 { _ = context?.workspace.openPane(ofType: "x") }
        let calls = runtime.host.record(for: "noisy")?.ignoredCalls ?? []
        #expect(calls.count == 50)
        #expect(calls.last == "… and 11 more")
    }
}

@Suite struct KeyChordTests {
    @Test(arguments: [
        (KeyChord("D", [.command]), "use a lowercase key with .shift instead of \"D\""),
        (KeyChord(" ", [.command]), "use .space, .return or .tab for whitespace keys"),
        (KeyChord(.arrow(.left), [.option]), "needs ⌘ or ⌃"),
        (KeyChord(.function(21), []), "function keys are F1–F20"),
    ])
    func unbindableChordsSayWhy(chord: KeyChord, problem: String) {
        #expect(chord.problem == problem)
    }

    @Test func specialKeysBind() {
        #expect(KeyChord(.function(5), []).problem == nil)
        #expect(KeyChord(.arrow(.up), [.command, .option]).description == "⌥⌘↑")
        #expect(KeyChord(.return, [.command]).menuKeyEquivalent == "\r")
    }
}
