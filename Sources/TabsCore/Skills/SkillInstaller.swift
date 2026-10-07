import Foundation

/// Installs the bundled "control Tabs" skill (`Sources/Tabs/Resources/skills/tabs`: `SKILL.md`
/// and `scripts/tabs-ctl`) into the personal skill directory of each agent that can use it, by
/// symlink.
///
/// Every agent this can install into is one row of `targets`: install, uninstall and status
/// stay generic over the list, and so does Settings ▸ AI, which draws one row per entry.
/// Nothing here reads the real home directory or the app bundle except `standard`, so tests
/// point it at a temporary directory.
package struct SkillInstaller: Sendable {
    /// One agent the skill can be installed into.
    package struct Target: Equatable, Sendable {
        package let id: String
        package let label: String
        /// Where this agent looks for a personal skill (see `Sources/Tabs/Resources/skills/tabs/SKILL.md`).
        package let directory: URL

        package init(id: String, label: String, directory: URL) {
            self.id = id
            self.label = label
            self.directory = directory
        }
    }

    /// A target and whether the skill is installed into it.
    package struct Status: Equatable, Sendable {
        package let id: String
        package let label: String
        package let installed: Bool

        package init(id: String, label: String, installed: Bool) {
            self.id = id
            self.label = label
            self.installed = installed
        }
    }

    /// What an install or an uninstall did; the failure is the sentence Settings shows.
    package enum Result: Equatable, Sendable {
        case ok
        case failed(String)
    }

    /// The directory that holds the bundled `tabs` skill directory.
    package let skillsDirectory: URL
    package let targets: [Target]

    package init(skillsDirectory: URL, targets: [Target]) {
        self.skillsDirectory = skillsDirectory
        self.targets = targets
    }

    /// Claude Code and Codex, under `home`.
    package static func targets(home: URL) -> [Target] {
        [
            Target(
                id: "claude-code", label: "Claude Code",
                directory: home.appending(path: ".claude/skills/tabs", directoryHint: .isDirectory)),
            Target(
                id: "codex", label: "Codex",
                directory: home.appending(path: ".agents/skills/tabs", directoryHint: .isDirectory)),
        ]
    }

    /// The running app's own skills (`Contents/Resources/skills`, next to the executable — an
    /// agent's shell is a plain OS process, so the skill must be real files, not inside an
    /// archive) and the real home. The link points into the app bundle, so it breaks if the app
    /// moves; installing again fixes it.
    package static func standard(bundle: Bundle = .main, home: URL? = nil) -> SkillInstaller {
        let home = home ?? URL(filePath: ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory(), directoryHint: .isDirectory)
        let skills = (bundle.resourceURL ?? bundle.bundleURL).appending(path: "skills", directoryHint: .isDirectory)
        return SkillInstaller(skillsDirectory: skills, targets: targets(home: home))
    }

    private var source: URL { skillsDirectory.appending(path: "tabs", directoryHint: .isDirectory) }

    /// Symlinks the bundled skill into `targetID`'s personal skill directory, creating parent
    /// directories as needed. Refuses to touch a destination that already exists and isn't a
    /// symlink we previously created ourselves — never clobbers something the user put there.
    package func install(_ targetID: String) -> Result {
        guard let target = targets.first(where: { $0.id == targetID }) else {
            return .failed("unknown install target: \(targetID)")
        }
        guard Self.exists(source.path), let resolvedSource = Self.realPath(source.path) else {
            return .failed("bundled skill directory not found")
        }

        let destination = target.directory.path
        let existingTarget = Self.symlinkRealTarget(destination)
        let destinationExists = Self.exists(destination) || existingTarget != nil
        if destinationExists && existingTarget != resolvedSource {
            return .failed("\(destination) already exists and isn't managed by Tabs")
        }

        do {
            let files = FileManager.default
            if destinationExists { try? files.removeItem(atPath: destination) }
            try files.createDirectory(at: target.directory.deletingLastPathComponent(), withIntermediateDirectories: true)
            try files.createSymbolicLink(atPath: destination, withDestinationPath: source.path)
            return .ok
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    /// Removes the symlink `install` created for `targetID`, if any. Same ownership check as
    /// `install`, in reverse: refuses to remove a destination that exists but isn't a symlink
    /// (so not something `install` created) — never deletes something the user put there
    /// themselves. Nothing installed is a no-op, not an error.
    package func uninstall(_ targetID: String) -> Result {
        guard let target = targets.first(where: { $0.id == targetID }) else {
            return .failed("unknown install target: \(targetID)")
        }

        let destination = target.directory.path
        if Self.symlinkRealTarget(destination) == nil {
            if !Self.exists(destination) { return .ok }
            return .failed("\(destination) already exists and isn't managed by Tabs")
        }

        do {
            try FileManager.default.removeItem(atPath: destination)
            return .ok
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    /// Per-target install status, for Settings ▸ AI. Installed means a link whose real target is
    /// *this* bundle's skill directory.
    package func status() -> [Status] {
        let resolvedSource = Self.exists(source.path) ? Self.realPath(source.path) : nil
        return targets.map { target in
            Status(
                id: target.id, label: target.label,
                installed: resolvedSource != nil && Self.symlinkRealTarget(target.directory.path) == resolvedSource)
        }
    }

    // MARK: File system

    /// `existsSync`: follows symlinks, so a dangling link doesn't exist.
    private static func exists(_ path: String) -> Bool {
        var info = stat()
        return stat(path, &info) == 0
    }

    /// `realpathSync`, symlinks fully resolved. `URL.resolvingSymlinksInPath` isn't it: it also
    /// strips `/private`, which would make a temporary directory never equal its own real path.
    private static func realPath(_ path: String) -> String? {
        guard let resolved = realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    /// The real path a symlink at `path` resolves to, or nil if it isn't a symlink (or doesn't exist).
    private static func symlinkRealTarget(_ path: String) -> String? {
        var info = stat()
        guard lstat(path, &info) == 0, info.st_mode & S_IFMT == S_IFLNK else { return nil }
        return realPath(path)
    }
}
