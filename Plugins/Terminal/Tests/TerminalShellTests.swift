import AppKit
import TabsPluginSDK
import Testing

@testable import TabsCore

/// `Shell` — `resolveShell`, `resolveCwd` and the environment — plus links,
/// settings and the saved config. Pure: no process, no pane.
@Suite struct ResolveShellTests {
    /// T-2
    @Test("uses $SHELL when set, without consulting the filesystem")
    func usesShellWhenSet() {
        let shell = Shell.resolveShell(environment: ["SHELL": "/usr/local/bin/fish"]) { _ in
            Issue.record("should not be called when $SHELL is set")
            return false
        }
        #expect(shell == "/usr/local/bin/fish")
    }

    /// T-2
    @Test("falls back to /bin/zsh when $SHELL is unset and zsh exists")
    func fallsBackToZsh() {
        #expect(Shell.resolveShell(environment: [:]) { $0 == "/bin/zsh" } == "/bin/zsh")
    }

    /// T-2
    @Test("falls back to /bin/bash when $SHELL is unset and only bash exists")
    func fallsBackToBash() {
        #expect(Shell.resolveShell(environment: [:]) { $0 == "/bin/bash" } == "/bin/bash")
    }

    /// T-2
    @Test("falls back to the last default even if nothing exists, rather than throwing")
    func fallsBackToTheLastDefault() {
        #expect(Shell.resolveShell(environment: [:]) { _ in false } == "/bin/bash")
    }

    /// T-2
    @Test("treats an empty string $SHELL the same as unset")
    func treatsAnEmptyShellAsUnset() {
        #expect(Shell.resolveShell(environment: ["SHELL": ""]) { $0 == "/bin/zsh" } == "/bin/zsh")
    }
}

@Suite struct ResolveCwdTests {
    let home = "/Users/someone"
    let exists: (String) -> Bool = { _ in true }

    /// T-3
    @Test("expands a bare \"~\" to the home directory")
    func expandsABareTilde() {
        #expect(Shell.resolveCwd("~", home: home, isDirectory: exists) == home)
    }

    /// T-3
    @Test("expands a \"~/\" prefix to the home directory")
    func expandsATildePrefix() {
        #expect(Shell.resolveCwd("~/projects", home: home, isDirectory: exists) == "\(home)/projects")
    }

    /// T-3
    @Test("leaves an absolute path untouched")
    func leavesAnAbsolutePathUntouched() {
        #expect(Shell.resolveCwd("/tmp", home: home, isDirectory: exists) == "/tmp")
    }

    /// T-3
    @Test("defaults to the home directory when unset or empty")
    func defaultsToHomeWhenUndefined() {
        #expect(Shell.resolveCwd(nil, home: home, isDirectory: exists) == home)
        #expect(Shell.resolveCwd("", home: home, isDirectory: exists) == home)
    }

    /// T-3: a saved directory that no longer exists starts the shell at home.
    @Test("a directory that no longer exists starts at home")
    func aMissingDirectoryStartsAtHome() {
        #expect(Shell.resolveCwd("/gone/away", home: home) { $0 != "/gone/away" } == home)
        #expect(Shell.resolveCwd("~/deleted", home: home) { $0 == "/Users/someone" } == home)
    }
}

@Suite struct EnvironmentTests {
    /// T-5, T-6: the terminal's identity overrides what the app inherited
    /// (a dev launch from another terminal), core's child environment is kept.
    @Test func statesTheTerminalsIdentityOverInheritedValues() {
        let base = [
            "TERM": "dumb", "COLORTERM": "", "TERM_PROGRAM": "iTerm.app", "TERM_PROGRAM_VERSION": "3.5",
            "TABS_CONTROL_SOCKET": "/tmp/control.sock", "TABS_PANE_ID": "pane-1", "PATH": "/usr/bin:/bin", "LANG": "de_DE.UTF-8",
        ]
        let environment = Shell.environment(base: base, appVersion: "0.1", locale: "en_US.UTF-8")
        #expect(environment["TERM"] == "xterm-256color")
        #expect(environment["COLORTERM"] == "truecolor")
        #expect(environment["TERM_PROGRAM"] == "Tabs")
        #expect(environment["TERM_PROGRAM_VERSION"] == "0.1")
        #expect(environment["TABS_CONTROL_SOCKET"] == "/tmp/control.sock")
        #expect(environment["TABS_PANE_ID"] == "pane-1")
        #expect(environment["PATH"] == "/usr/bin:/bin")
        #expect(environment["LANG"] == "de_DE.UTF-8", "a locale the app has is kept")
    }

    /// T-5: LANG is set only when the app has no locale at all
    /// (a Finder launch); any of LANG, LC_ALL, LC_CTYPE counts.
    @Test func setsLangOnlyWhenNoLocaleIsSet() {
        #expect(Shell.environment(base: [:], appVersion: "0.1", locale: "en_GB.UTF-8")["LANG"] == "en_GB.UTF-8")
        #expect(Shell.environment(base: ["LANG": ""], appVersion: "0.1", locale: "en_GB.UTF-8")["LANG"] == "en_GB.UTF-8")
        #expect(Shell.environment(base: ["LC_ALL": "C"], appVersion: "0.1", locale: "en_GB.UTF-8")["LANG"] == nil)
        #expect(Shell.environment(base: ["LC_CTYPE": "UTF-8"], appVersion: "0.1", locale: "en_GB.UTF-8")["LANG"] == nil)
    }

    /// T-5: the user's language and region when the system has that locale,
    /// else en_US.UTF-8.
    @Test func picksTheUsersUTF8LocaleOrFallsBack() {
        #expect(Shell.utf8Locale(language: "en", region: "GB") { $0 == "en_GB.UTF-8" } == "en_GB.UTF-8")
        #expect(Shell.utf8Locale(language: "en", region: "DE") { _ in false } == "en_US.UTF-8")
        #expect(Shell.utf8Locale(language: nil, region: "GB") { _ in true } == "en_US.UTF-8")
        // The real system has the fallback itself.
        #expect(FileManager.default.fileExists(atPath: "/usr/share/locale/en_US.UTF-8"))
    }
}

/// T-85–T-89: only web and mail links open.
@Suite struct TerminalLinksTests {
    @Test func opensOnlyHttpHttpsAndMailto() {
        #expect(TerminalLinks.safeURL("https://example.com/plain")?.absoluteString == "https://example.com/plain")
        #expect(TerminalLinks.safeURL("http://example.com") != nil)
        #expect(TerminalLinks.safeURL("HTTPS://EXAMPLE.COM") != nil)
        #expect(TerminalLinks.safeURL("mailto:someone@example.com") != nil)
    }

    @Test func dropsEverythingElse() {
        for link in [
            "file:///etc/passwd", "javascript:alert(1)", "ssh://host", "vscode://file/x", "x-custom:thing", "/usr/bin/ls",
            "relative/path", "", "not a url at all", "tel:123",
        ] {
            #expect(TerminalLinks.safeURL(link) == nil, "\(link)")
        }
    }
}

@MainActor
@Suite struct TerminalSettingsTests {
    /// T-110–T-119: the defaults, value for value: Terminal.app's Clear Dark
    /// profile, with GPU rendering (Metal) off.
    @Test func defaultsAreTheClearDarkProfile() {
        let settings = TerminalSettings()
        #expect(settings.inheritCwdOnNewPane)
        #expect(!settings.enableMetalRendering)
        #expect(settings.scrollback == 1000)
        let appearance = settings.appearance
        #expect(appearance.fontFamily == "JetBrains Mono NL")
        #expect(appearance.fontSize == 15)
        #expect(appearance.lineHeight == 1)
        #expect(appearance.cursorStyle == .bar)
        #expect(appearance.cursorBlink)
        #expect(appearance.background == "#06225f")
        #expect(appearance.foreground == "#e0e0e0")
        #expect(appearance.cursorColor == "#ffffff")
        #expect(appearance.selectionBackground == "#273d4c")
        #expect(
            appearance.ansi.all == [
                "#35424c", "#b45648", "#6caa71", "#c4ac62", "#6d96b4", "#bd7bcd", "#7ccbcd", "#dee5eb",
                "#465c6d", "#df6c5a", "#79be7e", "#e5c872", "#67b5ed", "#d389e5", "#84dde0", "#e5eff5",
            ])
        #expect(TerminalAnsiColors.slots.map(\.label).prefix(3) == ["Black", "Red", "Green"])
        #expect(TerminalAnsiColors.slots.map(\.label).last == "Bright White")
    }

    /// T-119: stored settings missing newer fields still decode, at every
    /// depth: appearance and its palette included.
    @Test func aPartialStoredValueDecodesOverTheDefaults() {
        let backend = MemoryBackend()
        backend.blobs["terminal"] = ["scrollback": 250, "appearance": ["fontSize": 19, "ansi": ["red": "#ff0000"]]]
        let settings = PluginSettings<TerminalSettings>(pluginID: "terminal", backend: backend, log: Log.core)
        #expect(settings.value.scrollback == 250)
        #expect(settings.value.appearance.fontSize == 19)
        #expect(settings.value.appearance.fontFamily == "JetBrains Mono NL")
        #expect(settings.value.appearance.ansi.red == "#ff0000")
        #expect(settings.value.appearance.ansi.green == "#6caa71")
        #expect(settings.value.inheritCwdOnNewPane)
    }

    @Test func colorsRoundTripAsHex() {
        #expect(NSColor(hex: "#06225f")?.hexString == "#06225f")
        #expect(NSColor(hex: "#fff")?.hexString == "#ffffff")
        #expect(NSColor(hex: "06225f") == nil)
        #expect(NSColor(hex: "#12345") == nil)
        #expect(NSColor(hex: "#gggggg") == nil)
    }
}

/// T-108, T-109: the saved config is `{cwd}`, read tolerantly (missing:
/// home) and strictly (a wrong type is refused, never replaced).
@Suite struct TerminalConfigTests {
    @Test func readsTolerantlyAndStrictly() throws {
        #expect(try JSONValue.emptyObject.decode(TerminalConfig.self) == TerminalConfig(cwd: nil))
        #expect(try (["cwd": "/tmp"] as JSONValue).decode(TerminalConfig.self) == TerminalConfig(cwd: "/tmp"))
        #expect(throws: (any Error).self) { try (["cwd": 3] as JSONValue).decode(TerminalConfig.self) }
    }
}
