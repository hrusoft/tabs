import AppKit
import Foundation
import TabsPluginSDK
import Testing

@testable import TabsCore

/// A directory of theme files becomes the themes the Theme menu lists (docs/THEMES.md): what a
/// file says reaches the tokens, a file that doesn't decode is left out and says why, and a
/// setting resolves to a theme whatever it names. The themes the app ships are its own test
/// (`UITests.ThemeSetting`); these are made up.
@MainActor
@Suite struct ThemeCatalogTests {
    let directory = TestSupport.temporaryDirectory().appending(path: "themes", directoryHint: .isDirectory)

    /// A whole theme's keys, every color its own.
    static let full: [String: JSONValue] = [
        "name": "Full", "appearance": "light", "bg": "#010203", "bgElevated": "#040506", "border": "#070809", "text": "#0a0b0c",
        "textDim": "#0d0e0f", "accent": "#101112", "onAccent": "#131415", "bellAlert": "#161718", "agent": "#191a1b",
        "hover": "#1c1d1e", "shadow": "#1f2021", "shadowStrength": 0.5,
    ]

    /// Only the keys a theme must have.
    static func minimal(_ name: String, appearance: String = "dark") -> [String: JSONValue] {
        var fields = full
        for key in ["hover", "shadow", "shadowStrength"] { fields.removeValue(forKey: key) }
        fields["name"] = .string(name)
        fields["appearance"] = .string(appearance)
        return fields
    }

    func write(_ id: String, _ fields: [String: JSONValue]) {
        TestSupport.writeJSON(.object(fields), to: directory.appending(path: "\(id).json"))
    }

    func write(_ id: String, raw: String) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(raw.utf8).write(to: directory.appending(path: "\(id).json"))
    }

    /// TH-1, TH-2: the file's name is the id, its `name` the title, its values the tokens; what
    /// it leaves out takes the documented default.
    @Test func aFileIsAThemeAndWhatItLeavesOutTakesItsDefault() throws {
        write("full", Self.full)
        write("short", Self.minimal("Short"))
        let catalog = ThemeCatalog(directory: directory)
        #expect(catalog.problems.isEmpty)

        let full = try #require(catalog.entry("full"))
        #expect(full.name == "Full")
        #expect(full.theme.bg == .hex(0x010203) && full.theme.agent == .hex(0x191a1b))
        #expect(full.theme.hover == .hex(0x1c1d1e) && full.theme.shadow == .hex(0x1f2021))
        #expect(full.theme.shadowStrength == 0.5)
        #expect(!full.theme.isDark, "appearance: light")

        let short = try #require(catalog.entry("short")).theme
        #expect(short.isDark)
        #expect(short.hover == short.text, "hover: the text color")
        #expect(short.shadow == .hex(0x000000), "shadow: black")
        #expect(short.shadowStrength == 1)
    }

    /// TH-5: Light, Dark, then the rest by name (not by file name).
    @Test func lightAndDarkComeFirstThenTheRestByName() {
        write("zeta", Self.minimal("Alpha"))
        write("dark", Self.minimal("Dark"))
        write("alpha", Self.minimal("Omega"))
        write("light", Self.minimal("Light", appearance: "light"))
        write("mid", Self.minimal("Matrix"))
        #expect(ThemeCatalog(directory: directory).entries.map(\.id) == ["light", "dark", "zeta", "mid", "alpha"])
    }

    /// TH-3: a file that doesn't decode is left out, saying which file and what is wrong; the
    /// others load.
    @Test(arguments: [
        ("broken", "{ \"name\": ", "isn't valid JSON"),
        ("list", "[1, 2]", "isn't a JSON object"),
    ])
    func aFileThatIsntJSONIsLeftOut(id: String, raw: String, problem: String) throws {
        write("dark", Self.minimal("Dark"))
        try write(id, raw: raw)
        let catalog = ThemeCatalog(directory: directory)
        #expect(catalog.entries.map(\.id) == ["dark"])
        #expect(catalog.problems == ["\(id).json: \(problem)"])
    }

    /// One key of a whole theme changed: removed (nil), added or given a value it can't have.
    @Test(
        arguments: [
            ("missing", "accent", nil, "missing \"accent\""),
            ("typo", "acent", "#000000", "unknown key \"acent\""),
            ("color", "bg", "red", "\"bg\" isn't a color: write it #rrggbb"),
            ("short", "text", "#fff", "\"text\" isn't a color: write it #rrggbb"),
            ("appearance", "appearance", "dim", "\"appearance\" must be \"dark\" or \"light\""),
            ("strength", "shadowStrength", 2, "\"shadowStrength\" must be a number from 0 to 1"),
            ("nameless", "name", "", "\"name\" must be the text the Theme menu shows"),
            ("twin", "name", "Dark", "\"Dark\" is already the name of dark.json"),
        ] as [(String, String, JSONValue?, String)])
    func aFileWithAWrongValueIsLeftOut(id: String, key: String, value: JSONValue?, problem: String) {
        write("dark", Self.minimal("Dark"))
        var fields = Self.full
        if let value { fields[key] = value } else { fields.removeValue(forKey: key) }
        write(id, fields)
        let catalog = ThemeCatalog(directory: directory)
        #expect(catalog.entries.map(\.id) == ["dark"])
        #expect(catalog.problems == ["\(id).json: \(problem)"])
    }

    @Test(arguments: [
        ("Capital", "a theme's file name is its id: lowercase letters, digits and hyphens"),
        ("system", "\"system\" is the Theme menu's own choice"),
    ])
    func aFileWhoseNameCantBeAnIdIsLeftOut(id: String, problem: String) {
        write(id, Self.minimal("Some theme"))
        let catalog = ThemeCatalog(directory: directory)
        #expect(catalog.entries.isEmpty)
        #expect(catalog.problems == ["\(id).json: \(problem)"])
    }

    /// TH-6: `system` is Light or Dark as the OS is; a theme is itself whatever the OS; what no
    /// file defines is Dark, and with no Dark, the placeholder.
    @Test func aSettingResolvesWhateverItNames() throws {
        write("light", Self.minimal("Light", appearance: "light"))
        write("dark", Self.minimal("Dark"))
        write("other", Self.full)
        let catalog = ThemeCatalog(directory: directory)
        let light = try #require(catalog.entry("light")).theme
        let dark = try #require(catalog.entry("dark")).theme
        let other = try #require(catalog.entry("other")).theme
        for systemIsDark in [false, true] {
            #expect(catalog.resolve("system", systemIsDark: systemIsDark) == (systemIsDark ? dark : light))
            #expect(catalog.resolve("other", systemIsDark: systemIsDark) == other)
            #expect(catalog.resolve("gone", systemIsDark: systemIsDark) == dark)
        }
        #expect(catalog.choice(for: "gone") == "dark", "the menu shows what is drawn")
        #expect(catalog.choice(for: "system") == "system" && catalog.choice(for: "other") == "other")
        #expect(ThemeCatalog(directory: directory.appending(path: "none")).resolve("dark", systemIsDark: true) == .placeholder)
    }

    /// The current theme: SwiftUI reads it; an AppKit window registers, for as long as it lives.
    @Test func aChangeReachesTheObserversWhoAreStillThere() {
        let themes = Themes()
        #expect(themes.current == .placeholder, "no files: the placeholder")
        final class Owner {}
        var owner: Owner? = Owner()
        var seen: [PaneTheme] = []
        themes.observe(owner!) { _, theme in seen.append(theme) }
        themes.set(.standInLight)
        themes.set(.standInLight)
        #expect(seen == [.standInLight], "a change only")
        owner = nil
        themes.set(.standInDark)
        #expect(seen == [.standInLight], "its owner gone, nothing is told")
        #expect(themes.current == .standInDark)
    }
}
