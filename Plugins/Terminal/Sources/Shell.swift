import Foundation

/// Which shell a terminal runs, where it starts, and the environment it gets,
/// as pure functions (their seams injectable).
enum Shell {
    /// Login-shell candidates tried when `$SHELL` isn't set, in preference
    /// order; the last is used even if it doesn't exist.
    static let defaultShells = ["/bin/zsh", "/bin/bash"]

    /// `$SHELL` if set (and not empty), else the first default shell that exists.
    static func resolveShell(environment: [String: String], exists: (String) -> Bool) -> String {
        if let shell = environment["SHELL"], !shell.isEmpty { return shell }
        return defaultShells.first(where: exists) ?? defaultShells[defaultShells.count - 1]
    }

    /// Expands a leading `~` the way a shell would (the spawn does no
    /// expansion); nil or `~` is home. A directory that no longer exists is
    /// home too, rather than a shell that can't start.
    static func resolveCwd(_ cwd: String?, home: String, isDirectory: (String) -> Bool) -> String {
        let path: String
        switch cwd {
        case nil, "", "~": path = home
        case let cwd? where cwd.hasPrefix("~/"): path = home + cwd.dropFirst()
        case let cwd?: path = cwd
        }
        return isDirectory(path) ? path : home
    }

    /// The whole environment for the shell: `base` (core's child environment:
    /// the app's own, plus `TABS_CONTROL_SOCKET` and `TABS_PANE_ID`), with the
    /// terminal's own identity stated over whatever was inherited:
    ///
    /// - `TERM`, `COLORTERM`: what programs read to pick a colour depth; a
    ///   program told "16 colours" quantises its own 24-bit escapes before the
    ///   emulator sees them. A Finder-launched app inherits no `COLORTERM`.
    /// - `TERM_PROGRAM`, `TERM_PROGRAM_VERSION`: the embedding terminal, as
    ///   every emulator names itself (programs key behaviour off it); stated so
    ///   a launch from another terminal doesn't leak *its* identity into panes.
    /// - `LANG`, only when no locale is set at all: a Finder-launched app has
    ///   none, and a shell in the C locale mangles non-ASCII input. Terminal.app
    ///   does the same.
    static func environment(base: [String: String], appVersion: String, locale: String) -> [String: String] {
        var environment = base
        environment["TERM"] = "xterm-256color"
        environment["COLORTERM"] = "truecolor"
        environment["TERM_PROGRAM"] = "Tabs"
        environment["TERM_PROGRAM_VERSION"] = appVersion
        let localeKeys = ["LANG", "LC_ALL", "LC_CTYPE"]
        if !localeKeys.contains(where: { !(environment[$0] ?? "").isEmpty }) {
            environment["LANG"] = locale
        }
        return environment
    }

    /// The UTF-8 locale for the user's language and region (`en_GB.UTF-8`),
    /// if the system has it, else `en_US.UTF-8`.
    static func utf8Locale(language: String?, region: String?, exists: (String) -> Bool) -> String {
        if let language, let region {
            let name = "\(language)_\(region).UTF-8"
            if exists(name) { return name }
        }
        return "en_US.UTF-8"
    }
}
