import Foundation
import TabsPluginSDK
import Testing

@testable import TabsCore

/// The persistence promise: never overwrite a file we couldn't fully read.
@MainActor
@Suite struct PersistenceTests {
    let directory = TestSupport.temporaryDirectory()
    var layoutFile: URL { directory.appending(path: "layout.json") }

    private func siblings(_ prefix: String) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []).filter { $0.hasPrefix(prefix) }.sorted()
    }

    private let sample = SavedLayout(windows: [
        WindowLayout(
            id: "w",
            root: .tabs(
                TabGroup(
                    id: "g",
                    tabs: [
                        Tab(
                            id: "t", title: "A",
                            content: .leaf(
                                LayoutLeaf(id: "a", type: "alpha", config: ["text": "keep me", "n": 1_727_200_000_123_456_789], title: "A"))
                        )
                    ])), active: "a")
    ])

    @Test func roundTripsWithAVersion() throws {
        let store = LayoutStore(file: layoutFile)
        #expect(store.save(sample))
        #expect(TestSupport.readJSON(layoutFile)?["version"] == 1)
        #expect(
            TestSupport.readJSON(layoutFile)?["windows"]?[0]
                == [
                    "id": "w", "activePaneId": "a", "floating": [],
                    "root": [
                        "id": "g", "type": "tabs", "activeTabId": "t",
                        "tabs": [
                            [
                                "id": "t", "title": "A",
                                "content": [
                                    "id": "a", "type": "alpha", "title": "A",
                                    "config": ["text": "keep me", "n": 1_727_200_000_123_456_789],
                                ],
                            ]
                        ],
                    ],
                ])
        #expect(LayoutStore(file: layoutFile).load().document == sample)
    }

    @Test func unparseableFilesAreMovedAsideNotOverwritten() throws {
        try Data("{not json".utf8).write(to: layoutFile)
        let store = LayoutStore(file: layoutFile)
        guard case .unreadable(let reason) = store.load() else { Issue.record("expected unreadable"); return }
        #expect(reason.contains("does not parse"))
        #expect(siblings("layout.unreadable-").count == 1)
        #expect(!FileManager.default.fileExists(atPath: layoutFile.path))
    }

    @Test func fileThatParsesButDoesNotDecodeIsAlsoMovedAside() throws {
        TestSupport.writeJSON(["version": 1, "windows": "not an array"], to: layoutFile)
        guard case .unreadable(let reason) = LayoutStore(file: layoutFile).load() else { Issue.record("expected unreadable"); return }
        #expect(reason.contains("does not decode"))
        #expect(siblings("layout.unreadable-").count == 1)
    }

    @Test func missingOptionalFieldsTakeDefaults() {
        TestSupport.writeJSON(
            [
                "version": 1,
                "windows": [
                    ["id": "w", "root": ["id": "g", "type": "tabs", "tabs": [["id": "t", "content": ["id": "a", "type": "alpha"]]]]]
                ],
            ],
            to: layoutFile)
        let layout = LayoutStore(file: layoutFile).load().document
        let expected = WindowLayout(
            id: "w", root: .tabs(TabGroup(id: "g", tabs: [Tab(id: "t", title: "", content: .leaf(LayoutLeaf(id: "a", type: "alpha")))])))
        #expect(layout == SavedLayout(windows: [expected]))
        #expect(layout?.windows.first?.activePaneID == "g", "no saved active pane: the tree's first")
    }

    @Test func aMalformedPaneCostsOnlyItselfAndTheOriginalIsKept() throws {
        TestSupport.writeJSON(
            [
                "version": 1,
                "windows": [
                    [
                        "id": "w",
                        "root": [
                            "id": "s", "type": "split", "direction": "horizontal",
                            "children": [
                                ["id": "good", "type": "alpha", "config": ["text": "survives"]],
                                ["type": "alpha"],
                                ["type": "split", "from": "a newer build"],
                            ],
                        ],
                    ]
                ],
            ], to: layoutFile)
        let store = LayoutStore(file: layoutFile)
        guard case .recovered(let layout, let notes) = store.load() else { Issue.record("expected recovered"); return }
        #expect(layout.windows.first?.leaves.map(\.id) == ["good"])
        #expect(notes == ["dropped malformed pane #1 of children", "dropped malformed pane #2 of children"])
        #expect(siblings("layout.partial-").isEmpty, "nothing copied until a save would replace it")
        #expect(store.save(layout))
        #expect(siblings("layout.partial-").count == 1)
        #expect(store.save(layout))
        #expect(siblings("layout.partial-").count == 1, "only before the first save")
    }

    @Test func aPartlyReadFileThatVanishedDoesNotBlockSaving() throws {
        TestSupport.writeJSON(
            [
                "version": 1,
                "windows": [["id": "w", "root": ["id": "g", "type": "tabs", "tabs": [["id": "t", "content": ["type": "alpha"]]]]]],
            ],
            to: layoutFile)
        let store = LayoutStore(file: layoutFile)
        guard case .recovered(let layout, _) = store.load() else { Issue.record("expected recovered"); return }
        try FileManager.default.removeItem(at: layoutFile)  // the user reset it
        #expect(store.save(layout), "nothing left to preserve, so the save goes ahead")
        #expect(store.save(layout))
        #expect(siblings("layout.partial-").isEmpty)
    }

    @Test func aFileFromANewerBuildIsPreservedBeforeSaving() {
        TestSupport.writeJSON(["version": 9, "windows": [], "futureField": true], to: layoutFile)
        let store = LayoutStore(file: layoutFile)
        guard case .recovered(_, let notes) = store.load() else { Issue.record("expected recovered"); return }
        #expect(notes.first?.contains("newer build (version 9") == true)
        store.save(sample)
        #expect(siblings("layout.newer-").count == 1)
    }

    @Test func readOnlyStoresTouchNothing() throws {
        try Data("{not json".utf8).write(to: layoutFile)
        let store = LayoutStore(file: layoutFile, readOnly: true)
        _ = store.load()
        #expect(!store.save(sample))
        #expect(FileManager.default.fileExists(atPath: layoutFile.path))
        #expect(siblings("layout.unreadable-").isEmpty)
    }

    @Test func anUnencodableDocumentLeavesThePreviousFile() throws {
        let store = LayoutStore(file: layoutFile)
        store.save(sample)
        let before = try Data(contentsOf: layoutFile)
        var broken = sample
        broken.windows[0] = WindowLayout(id: "w", root: .leaf(LayoutLeaf(id: "a", type: "alpha", config: ["x": .double(.nan)])))
        #expect(!store.save(broken))
        #expect(try Data(contentsOf: layoutFile) == before)
    }

    @Test func coreSettingsThatDoNotDecodeAreResetButTheFileIsKept() {
        let file = directory.appending(path: "settings.json")
        TestSupport.writeJSON(
            ["version": 1, "core": ["disabledPlugins": "beta", "shortcuts": ["tabs.quit": nil]], "plugins": ["beta": ["a": 1]]], to: file)
        let settings = SettingsStore(file: file)
        #expect(settings.disabledPlugins.isEmpty)
        #expect(settings.loadNotes == ["disabledPlugins did not decode and was reset"])
        #expect(settings.shortcutOverrides == ["tabs.quit": nil], "one bad field costs only itself")
        #expect(settings.storedSettings(for: "beta") == ["a": 1], "plugin blobs survive")
        settings.setDisabled(true, for: "alpha")
        #expect(siblings("settings.partial-").count == 1)
    }

    @Test func aPaneSettingThatDoesNotDecodeIsResetReportedAndTheFileKept() {
        let file = directory.appending(path: "settings.json")
        TestSupport.writeJSON(
            ["version": 1, "core": ["panes": ["dimInactivePanesIntensity": "x", "dimInactivePanes": false]]], to: file)
        let settings = SettingsStore(file: file)
        #expect(settings.panes.dimInactivePanesIntensity == SettingsStore.PaneSettings().dimInactivePanesIntensity)
        #expect(settings.panes.dimInactivePanes == false, "one bad field costs only itself")
        #expect(settings.loadNotes == ["panes.dimInactivePanesIntensity did not decode and was reset"])
        settings.setDisabled(true, for: "alpha")
        #expect(siblings("settings.partial-").count == 1)
    }

    @Test func paneSettingsThatAreNotAnObjectAreResetAndReported() {
        let file = directory.appending(path: "settings.json")
        TestSupport.writeJSON(["version": 1, "core": ["panes": 5]], to: file)
        let settings = SettingsStore(file: file)
        #expect(settings.panes == SettingsStore.PaneSettings())
        #expect(settings.loadNotes == ["panes did not decode and were reset"])
    }

    @Test func anUnreadableSettingsFileIsNamedOnceInTheNotes() throws {
        try Data("{not json".utf8).write(to: directory.appending(path: "settings.json"))
        let runtime = TestSupport.runtime(dataDirectory: directory)
        #expect(runtime.persistenceNotes.count == 1)
        #expect(runtime.persistenceNotes.first?.hasPrefix("settings.json: does not parse: ") == true, "\(runtime.persistenceNotes)")
    }
}

@MainActor
@Suite struct PersistenceFailureTests {
    let directory = TestSupport.temporaryDirectory()
    struct Refused: Error {}

    @Test func ifTheOriginalCannotBeCopiedAsideItIsNotOverwritten() throws {
        let file = directory.appending(path: "layout.json")
        TestSupport.writeJSON(
            [
                "version": 1,
                "windows": [["id": "w", "root": ["id": "g", "type": "tabs", "tabs": [["id": "t", "content": ["type": "alpha"]]]]]],
            ],
            to: file)
        let before = try Data(contentsOf: file)
        let store = LayoutStore(file: file)
        store.fileOperations.copy = { _, _ in throw Refused() }
        guard case .recovered(let layout, _) = store.load() else {
            Issue.record("expected recovered")
            return
        }
        #expect(!store.save(layout))
        #expect(try Data(contentsOf: file) == before)
        store.fileOperations = .init()
        #expect(store.save(layout), "the next save retries the copy")
    }

    @Test func ifAnUnreadableFileCannotBeMovedAsideItIsNeverOverwritten() throws {
        let file = directory.appending(path: "layout.json")
        try Data("{broken".utf8).write(to: file)
        let store = LayoutStore(file: file)
        store.fileOperations.move = { _, _ in throw Refused() }
        guard case .unreadable(let reason) = store.load() else {
            Issue.record("expected unreadable")
            return
        }
        #expect(reason.contains("will not be overwritten"))
        #expect(!store.save(SavedLayout(windows: [])))
        #expect(try Data(contentsOf: file) == Data("{broken".utf8))
    }

    @Test func pluginSettingsThatDoNotDecodeAreReportedAndKept() {
        let file = directory.appending(path: "settings.json")
        TestSupport.writeJSON(["version": 1, "core": [:], "plugins": ["not", "an", "object"]], to: file)
        let settings = SettingsStore(file: file)
        #expect(settings.loadNotes == ["plugin settings did not decode and were reset"])
        settings.store(["a": 1], for: "p")
        let asides = (try? FileManager.default.contentsOfDirectory(atPath: directory.path))?.filter { $0.hasPrefix("settings.partial-") }
        #expect(asides?.count == 1)
    }
}
