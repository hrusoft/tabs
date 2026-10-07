import AppKit
import TabsPluginSDK
import Testing

@testable import TabsCore

@MainActor
@Suite struct SettingsTests {
    struct Prefs: PluginSettingsValue {
        var size = 12.0
        var name = "default"
    }

    @Test func storedValuesMergeOverDefaults() {
        let backend = MemoryBackend()
        backend.blobs["p"] = ["size": 20, "retired": true]
        let settings = PluginSettings<Prefs>(pluginID: "p", backend: backend, log: Log.core)
        #expect(settings.value == Prefs(size: 20, name: "default"))
    }

    @Test func undecodableValuesFallBackWithoutDestroyingData() {
        let backend = MemoryBackend()
        backend.blobs["p"] = ["size": "huge"]
        let settings = PluginSettings<Prefs>(pluginID: "p", backend: backend, log: Log.core)
        #expect(settings.value == Prefs())
        #expect(backend.blobs["p"] == ["size": "huge"], "untouched until the user changes something")
        #expect(backend.writes == 0)
    }

    @Test func anUpdateThatCannotBeStoredIsRefusedWhole() {
        let backend = MemoryBackend()
        let settings = PluginSettings<Prefs>(pluginID: "p", backend: backend, log: Log.core)
        settings.update { $0.size = .nan }
        #expect(settings.value == Prefs())
        #expect(backend.writes == 0)
    }

    @Test func updatesPersistAndNotifyUntilCancelled() {
        let backend = MemoryBackend()
        let settings = PluginSettings<Prefs>(pluginID: "p", backend: backend, log: Log.core)
        var seen: [Double] = []
        let subscription = settings.observe { seen.append($0.size) }
        settings.update { $0.size = 14 }
        settings.update { $0.size = 14 }
        subscription.cancel()
        settings.update { $0.size = 16 }
        #expect(seen == [14])
        #expect(backend.writes == 2, "a no-op update writes nothing")
        #expect(backend.blobs["p"] == ["size": 16, "name": "default"])
    }

    @Test func fieldsFromANewerBuildSurviveAnUpdate() {
        let backend = MemoryBackend()
        backend.blobs["p"] = ["size": 20, "addedLater": ["deep": true]]
        let settings = PluginSettings<Prefs>(pluginID: "p", backend: backend, log: Log.core)
        settings.update { $0.size = 22 }
        #expect(backend.blobs["p"] == ["size": 22, "name": "default", "addedLater": ["deep": true]])
    }

    struct Optional: PluginSettingsValue {
        var path: String?
    }

    @Test func aClearedOptionalStaysCleared() {
        let backend = MemoryBackend()
        backend.blobs["p"] = ["path": "/tmp"]
        let settings = PluginSettings<Optional>(pluginID: "p", backend: backend, log: Log.core)
        settings.update { $0.path = nil }
        #expect(settings.value.path == nil)
        #expect(backend.blobs["p"] == [:], "a known field isn't carried back in")
    }

    @Test func restoreLayoutIsOnByDefault() {  // RESTORE-LAYOUT.md R-1
        let file = TestSupport.temporaryDirectory().appending(path: "settings.json")
        #expect(SettingsStore(file: file).panes.persistLayoutOnExit)
        TestSupport.writeJSON(["core": ["panes": ["colorTheme": "light"]]], to: file)
        #expect(SettingsStore(file: file).panes.persistLayoutOnExit, "absent from an older file: the default")
        TestSupport.writeJSON(["core": ["panes": ["persistLayoutOnExit": "nope"]]], to: file)
        #expect(SettingsStore(file: file).panes.persistLayoutOnExit, "undecodable: the default, the other fields kept")
    }

    @Test func coreFieldsFromANewerBuildSurviveASave() {
        let file = TestSupport.temporaryDirectory().appending(path: "settings.json")
        TestSupport.writeJSON(["version": 1, "core": ["disabledPlugins": [], "addedLater": [1, 2]], "alsoLater": true], to: file)
        let store = SettingsStore(file: file)
        store.setDisabled(true, for: "x")
        let reread = TestSupport.readJSON(file)
        #expect(reread?["core"]?["addedLater"] == [1, 2])
        #expect(reread?["alsoLater"] == true)
        #expect(reread?["core"]?["disabledPlugins"] == ["x"])
    }

    @Test func settingsFileKeepsBlobsOfPluginsThatArentLoaded() {
        let file = TestSupport.temporaryDirectory().appending(path: "settings.json")
        TestSupport.writeJSON(["core": ["disabledPlugins": ["x"]], "plugins": ["gone": ["a": 1]]], to: file)
        let store = SettingsStore(file: file)
        #expect(store.disabledPlugins == ["x"])
        store.store(["b": 2], for: "here")
        store.setDisabled(false, for: "x")
        let reread = TestSupport.readJSON(file)
        #expect(reread?["plugins"] == ["gone": ["a": 1], "here": ["b": 2]])
        #expect(reread?["core"]?["disabledPlugins"] == [])
    }
}
