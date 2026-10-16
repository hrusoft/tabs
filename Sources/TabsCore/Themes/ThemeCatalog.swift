import AppKit
import Foundation
import Observation
import TabsPluginSDK

/// One theme the app ships: a file of `Contents/Resources/Themes` (docs/THEMES.md).
package struct ThemeEntry: Equatable, Sendable {
    /// The file's name without `.json`: what the Theme setting stores.
    package let id: String
    /// What the Theme menu shows.
    package let name: String
    package let theme: PaneTheme
}

/// The themes the app ships, one JSON file each in `Sources/Tabs/Resources/Themes`, bundled as
/// `Contents/Resources/Themes` (docs/THEMES.md). A file that doesn't decode is left out and
/// says why (`problems`, logged); the rest load.
package struct ThemeCatalog: Sendable {
    /// The Theme menu's own choice: Light or Dark, as the OS is.
    package static let system = "system"
    /// System's pair, and what a setting naming no loaded theme draws with.
    package static let light = "light"
    package static let dark = "dark"

    /// Light, Dark, then every other theme by name: the Theme menu's order after System.
    package let entries: [ThemeEntry]
    /// One line per file left out: "<file>: <what is wrong>".
    package let problems: [String]

    package static let empty = ThemeCatalog(entries: [], problems: [])

    private init(entries: [ThemeEntry], problems: [String]) {
        self.entries = entries
        self.problems = problems
    }

    /// The app's own themes: `Contents/Resources/Themes` of `bundle`.
    package static func bundledDirectory(of bundle: Bundle = .main) -> URL {
        (bundle.resourceURL ?? bundle.bundleURL).appending(path: "Themes", directoryHint: .isDirectory)
    }

    /// Every `.json` file in `directory`; none when there is no such directory.
    package init(directory: URL) {
        let files =
            ((try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        var loaded: [ThemeEntry] = []
        var problems: [String] = []
        for file in files {
            let id = file.deletingPathExtension().lastPathComponent
            do throws(ThemeFileError) {
                try Self.check(id: id)
                guard let data = try? Data(contentsOf: file) else { throw ThemeFileError("can't be read") }
                let (name, theme) = try Self.decode(data)
                if let taken = loaded.first(where: { $0.name == name }) {
                    throw ThemeFileError("\"\(name)\" is already the name of \(taken.id).json")
                }
                loaded.append(ThemeEntry(id: id, name: name, theme: theme))
            } catch {
                problems.append("\(file.lastPathComponent): \(error.message)")
            }
        }
        for problem in problems { Log.core.error("theme left out: \(problem, privacy: .public)") }
        func rank(_ entry: ThemeEntry) -> Int { [Self.light, Self.dark].firstIndex(of: entry.id) ?? 2 }
        entries = loaded.sorted { a, b in
            if rank(a) != rank(b) { return rank(a) < rank(b) }
            let order = a.name.localizedStandardCompare(b.name)
            return order == .orderedSame ? a.id < b.id : order == .orderedAscending
        }
        self.problems = problems
    }

    package func entry(_ id: String) -> ThemeEntry? { entries.first { $0.id == id } }

    /// The theme `setting` names: `system` is Light or Dark as the OS is; an id no file loaded
    /// is Dark (the setting itself is kept); with no Dark either, the placeholder.
    package func resolve(_ setting: String, systemIsDark: Bool) -> PaneTheme {
        let id = setting == Self.system ? (systemIsDark ? Self.dark : Self.light) : setting
        return entry(id)?.theme ?? entry(Self.dark)?.theme ?? .placeholder
    }

    /// The Theme menu's choice for `setting`: itself when the menu lists it, else Dark, what is
    /// drawn instead.
    package func choice(for setting: String) -> String {
        setting == Self.system || entry(setting) != nil ? setting : Self.dark
    }

    // MARK: The file

    /// Every key a theme file may hold (docs/THEMES.md): its name, its appearance, its colors.
    private static let keys: Set = [
        "name", "appearance", "bg", "bgElevated", "border", "text", "textDim", "accent", "onAccent", "bellAlert", "agent", "hover",
        "shadow", "shadowStrength",
    ]

    /// A file's id is its name: lowercase letters, digits and hyphens, and never `system`.
    private static func check(id: String) throws(ThemeFileError) {
        guard id.first.map({ $0.isLowercase || $0.isNumber }) == true,
            id.allSatisfy({ ($0.isASCII && ($0.isLowercase || $0.isNumber)) || $0 == "-" })
        else { throw ThemeFileError("a theme's file name is its id: lowercase letters, digits and hyphens") }
        guard id != system else { throw ThemeFileError("\"system\" is the Theme menu's own choice") }
    }

    /// One file's theme, or what is wrong with it: not an object, a key missing or unknown, a
    /// value of the wrong kind.
    package static func decode(_ data: Data) throws(ThemeFileError) -> (name: String, theme: PaneTheme) {
        guard let value = try? JSONDecoder().decode(JSONValue.self, from: data) else { throw ThemeFileError("isn't valid JSON") }
        guard case .object(let fields) = value else { throw ThemeFileError("isn't a JSON object") }
        if let unknown = fields.keys.filter({ !keys.contains($0) }).sorted().first {
            throw ThemeFileError("unknown key \"\(unknown)\"")
        }
        guard let rawName = fields["name"] else { throw ThemeFileError("missing \"name\"") }
        guard let name = rawName.stringValue?.trimmingCharacters(in: .whitespaces), !name.isEmpty else {
            throw ThemeFileError("\"name\" must be the text the Theme menu shows")
        }
        guard let rawAppearance = fields["appearance"] else { throw ThemeFileError("missing \"appearance\"") }
        guard let appearance = rawAppearance.stringValue, ["dark", "light"].contains(appearance) else {
            throw ThemeFileError("\"appearance\" must be \"dark\" or \"light\"")
        }
        func color(_ key: String) throws(ThemeFileError) -> NSColor? {
            guard let raw = fields[key] else { return nil }
            guard let text = raw.stringValue, let value = hexColor(text) else {
                throw ThemeFileError("\"\(key)\" isn't a color: write it #rrggbb")
            }
            return value
        }
        func required(_ key: String) throws(ThemeFileError) -> NSColor {
            guard let value = try color(key) else { throw ThemeFileError("missing \"\(key)\"") }
            return value
        }
        var shadowStrength = 1.0
        if let raw = fields["shadowStrength"] {
            guard let number = raw.doubleValue, (0...1).contains(number) else {
                throw ThemeFileError("\"shadowStrength\" must be a number from 0 to 1")
            }
            shadowStrength = number
        }
        let text = try required("text")
        let theme = PaneTheme(
            bg: try required("bg"), bgElevated: try required("bgElevated"), border: try required("border"), text: text,
            textDim: try required("textDim"), accent: try required("accent"), onAccent: try required("onAccent"),
            bellAlert: try required("bellAlert"), agent: try required("agent"), hover: try color("hover") ?? text,
            shadow: try color("shadow") ?? .hex(0x000000), shadowStrength: shadowStrength, isDark: appearance == "dark")
        return (name, theme)
    }

    /// `#rrggbb` (either case), or nil.
    private static func hexColor(_ text: String) -> NSColor? {
        guard text.count == 7, text.first == "#", let value = UInt32(text.dropFirst(), radix: 16),
            text.dropFirst().allSatisfy(\.isHexDigit)
        else { return nil }
        return .hex(value)
    }
}

/// What is wrong with a theme file, in a few words.
package struct ThemeFileError: Error, Equatable {
    package let message: String
    package init(_ message: String) { self.message = message }
}

/// The app's themes, and the one everything is drawn with now: what the shell resolved from the
/// Theme setting (`AppShell.applyPaneSettings`). SwiftUI content observes `current`; an AppKit
/// window registers with `observe`.
@MainActor
@Observable
package final class Themes {
    package let catalog: ThemeCatalog
    package private(set) var current: PaneTheme
    @ObservationIgnored private let observers = ObserverList<PaneTheme>()

    /// Starts on Dark (the setting's default), or the placeholder when no file loaded.
    package init(catalog: ThemeCatalog = .empty) {
        self.catalog = catalog
        current = catalog.resolve(ThemeCatalog.dark, systemIsDark: true)
    }

    /// Makes `theme` current and tells every observer, on a change only.
    package func set(_ theme: PaneTheme) {
        guard theme != current else { return }
        current = theme
        observers.notify(theme)
    }

    /// Calls `handler` with each new theme for as long as `owner` lives.
    package func observe<Owner: AnyObject>(_ owner: Owner, _ handler: @escaping @MainActor (Owner, PaneTheme) -> Void) {
        observers.add(while: owner, handler)
    }
}
