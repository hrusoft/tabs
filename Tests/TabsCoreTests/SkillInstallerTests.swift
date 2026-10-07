import Foundation
import Testing

@testable import TabsCore

/// The skill installer. Everything lives under a throwaway temporary directory — never the real
/// home, since the installer's whole job is symlinking into an agent's personal skill directory.
@Suite struct SkillInstallerTests {
    /// One sandbox with a bundled `tabs` skill directory and one fake agent home per requested agent.
    struct Sandbox {
        let root: URL
        let skillsDirectory: URL
        /// One per requested agent, in order — the directory each target symlinks into.
        let targetDirectories: [URL]
        let targets: [SkillInstaller.Target]

        init(_ agents: [(id: String, label: String)]) throws {
            let root = TestTemporary.location("skills")
            let skillsDirectory = root.appending(path: "bundled-skills", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(
                at: skillsDirectory.appending(path: "tabs", directoryHint: .isDirectory), withIntermediateDirectories: true)
            let directories = agents.map { root.appending(path: "\($0.id)-home/skills/tabs", directoryHint: .isDirectory) }
            self.root = root
            self.skillsDirectory = skillsDirectory
            targetDirectories = directories
            targets = zip(agents, directories).map { SkillInstaller.Target(id: $0.id, label: $0.label, directory: $1) }
        }

        func installer(skills: URL? = nil) -> SkillInstaller {
            SkillInstaller(skillsDirectory: skills ?? skillsDirectory, targets: targets)
        }

        var bundled: String { skillsDirectory.appending(path: "tabs").path }

        func destination(of link: URL) -> String? { try? FileManager.default.destinationOfSymbolicLink(atPath: link.path) }
        func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

        func remove() { try? FileManager.default.removeItem(at: root) }
    }

    static let fakeAgent = (id: "fake-agent", label: "Fake Agent")

    @Suite struct InstallAndStatus {
        @Test func reportsNotInstalledBeforeInstalling() throws {
            let box = try Sandbox([SkillInstallerTests.fakeAgent])
            defer { box.remove() }
            #expect(box.installer().status() == [SkillInstaller.Status(id: "fake-agent", label: "Fake Agent", installed: false)])
        }

        @Test func symlinksTheBundledSkillIntoTheTargetDirectory() throws {
            let box = try Sandbox([SkillInstallerTests.fakeAgent])
            defer { box.remove() }
            #expect(box.installer().install("fake-agent") == .ok)
            #expect(box.destination(of: box.targetDirectories[0]) == box.bundled)
        }

        @Test func reportsInstalledAfterInstalling() throws {
            let box = try Sandbox([SkillInstallerTests.fakeAgent])
            defer { box.remove() }
            _ = box.installer().install("fake-agent")
            #expect(box.installer().status() == [SkillInstaller.Status(id: "fake-agent", label: "Fake Agent", installed: true)])
        }

        @Test func isIdempotentInstallingTwiceSucceedsAndReLinksCleanly() throws {
            let box = try Sandbox([SkillInstallerTests.fakeAgent])
            defer { box.remove() }
            #expect(box.installer().install("fake-agent") == .ok)
            #expect(box.installer().install("fake-agent") == .ok)
            #expect(box.destination(of: box.targetDirectories[0]) == box.bundled)
        }

        @Test func refusesToClobberADestinationThatAlreadyExistsAndIsNotOurs() throws {
            let box = try Sandbox([SkillInstallerTests.fakeAgent])
            defer { box.remove() }
            let directory = box.targetDirectories[0]
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data("not ours".utf8).write(to: directory.appending(path: "SKILL.md"))
            let result = box.installer().install("fake-agent")
            #expect(result == .failed("\(directory.path) already exists and isn't managed by Tabs"))
            #expect(box.exists(directory.appending(path: "SKILL.md")))
        }

        @Test func errorsOnAnUnknownTargetId() throws {
            let box = try Sandbox([SkillInstallerTests.fakeAgent])
            defer { box.remove() }
            #expect(box.installer().install("nonexistent") == .failed("unknown install target: nonexistent"))
        }

        @Test func errorsWhenTheBundledSkillDirectoryIsMissing() throws {
            let box = try Sandbox([SkillInstallerTests.fakeAgent])
            defer { box.remove() }
            let missing = box.root.appending(path: "missing", directoryHint: .isDirectory)
            #expect(box.installer(skills: missing).install("fake-agent") == .failed("bundled skill directory not found"))
        }
    }

    @Suite struct Uninstall {
        @Test func removesASymlinkInstallSkillCreated() throws {
            let box = try Sandbox([SkillInstallerTests.fakeAgent])
            defer { box.remove() }
            _ = box.installer().install("fake-agent")
            #expect(box.installer().uninstall("fake-agent") == .ok)
            #expect(!box.exists(box.targetDirectories[0]))
            #expect(box.exists(box.skillsDirectory.appending(path: "tabs")), "the bundle itself is untouched")
        }

        @Test func reportsNotInstalledAfterUninstalling() throws {
            let box = try Sandbox([SkillInstallerTests.fakeAgent])
            defer { box.remove() }
            _ = box.installer().install("fake-agent")
            _ = box.installer().uninstall("fake-agent")
            #expect(box.installer().status() == [SkillInstaller.Status(id: "fake-agent", label: "Fake Agent", installed: false)])
        }

        @Test func isANoOpWhenNothingIsInstalled() throws {
            let box = try Sandbox([SkillInstallerTests.fakeAgent])
            defer { box.remove() }
            #expect(box.installer().uninstall("fake-agent") == .ok)
        }

        @Test func refusesToRemoveADestinationThatExistsButIsNotASymlinkWeCreated() throws {
            let box = try Sandbox([SkillInstallerTests.fakeAgent])
            defer { box.remove() }
            let directory = box.targetDirectories[0]
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data("not ours".utf8).write(to: directory.appending(path: "SKILL.md"))
            guard case .failed = box.installer().uninstall("fake-agent") else {
                Issue.record("a directory Tabs didn't create was removed")
                return
            }
            #expect(box.exists(directory))
        }

        @Test func errorsOnAnUnknownTargetId() throws {
            let box = try Sandbox([SkillInstallerTests.fakeAgent])
            defer { box.remove() }
            #expect(box.installer().uninstall("nonexistent") == .failed("unknown install target: nonexistent"))
        }
    }

    /// Coverage for the shape the target list actually has: more than one agent. Nothing above
    /// exercises a list with two entries, so nothing above would catch one target's install or
    /// uninstall leaking into another's.
    @Suite struct MultipleInstallTargets {
        static let agents = [(id: "agent-a", label: "Agent A"), (id: "agent-b", label: "Agent B")]

        @Test func reportsIndependentNotInstalledStatusForEachTarget() throws {
            let box = try Sandbox(Self.agents)
            defer { box.remove() }
            #expect(
                box.installer().status() == [
                    SkillInstaller.Status(id: "agent-a", label: "Agent A", installed: false),
                    SkillInstaller.Status(id: "agent-b", label: "Agent B", installed: false),
                ])
        }

        @Test func installingOneTargetDoesNotInstallTheOther() throws {
            let box = try Sandbox(Self.agents)
            defer { box.remove() }
            #expect(box.installer().install("agent-a") == .ok)
            #expect(
                box.installer().status() == [
                    SkillInstaller.Status(id: "agent-a", label: "Agent A", installed: true),
                    SkillInstaller.Status(id: "agent-b", label: "Agent B", installed: false),
                ])
            #expect(!box.exists(box.targetDirectories[1]))
        }

        @Test func installingBothTargetsSymlinksEachIntoItsOwnDirectorySharingOneBundledSource() throws {
            let box = try Sandbox(Self.agents)
            defer { box.remove() }
            #expect(box.installer().install("agent-a") == .ok)
            #expect(box.installer().install("agent-b") == .ok)
            #expect(box.destination(of: box.targetDirectories[0]) == box.bundled)
            #expect(box.destination(of: box.targetDirectories[1]) == box.bundled)
            #expect(
                box.installer().status() == [
                    SkillInstaller.Status(id: "agent-a", label: "Agent A", installed: true),
                    SkillInstaller.Status(id: "agent-b", label: "Agent B", installed: true),
                ])
        }

        @Test func uninstallingOneTargetLeavesTheOtherInstalled() throws {
            let box = try Sandbox(Self.agents)
            defer { box.remove() }
            _ = box.installer().install("agent-a")
            _ = box.installer().install("agent-b")
            #expect(box.installer().uninstall("agent-a") == .ok)
            #expect(!box.exists(box.targetDirectories[0]))
            #expect(
                box.installer().status() == [
                    SkillInstaller.Status(id: "agent-a", label: "Agent A", installed: false),
                    SkillInstaller.Status(id: "agent-b", label: "Agent B", installed: true),
                ])
        }
    }

    @Suite struct RealTargets {
        @Test func theStandardTargetsAreClaudeCodeAndCodexUnderTheGivenHome() {
            let targets = SkillInstaller.targets(home: URL(filePath: "/somewhere/home", directoryHint: .isDirectory))
            #expect(targets.map(\.id) == ["claude-code", "codex"])
            #expect(targets.map(\.label) == ["Claude Code", "Codex"])
            #expect(targets.map(\.directory.path) == ["/somewhere/home/.claude/skills/tabs", "/somewhere/home/.agents/skills/tabs"])
        }

        @Test func installingCreatesTheParentDirectoriesOfTheRealTargets() throws {
            let box = try Sandbox([])
            defer { box.remove() }
            let home = box.root.appending(path: "home", directoryHint: .isDirectory)
            let installer = SkillInstaller(skillsDirectory: box.skillsDirectory, targets: SkillInstaller.targets(home: home))
            #expect(installer.install("claude-code") == .ok)
            #expect(installer.install("codex") == .ok)
            #expect(box.destination(of: home.appending(path: ".claude/skills/tabs")) == box.bundled)
            #expect(box.destination(of: home.appending(path: ".agents/skills/tabs")) == box.bundled)
            #expect(installer.status().map(\.installed) == [true, true])
        }

        @Test func aLinkToAnotherDirectoryIsNotInstalledAndIsNotOverwritten() throws {
            let box = try Sandbox([SkillInstallerTests.fakeAgent])
            defer { box.remove() }
            let elsewhere = box.root.appending(path: "elsewhere", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
            let directory = box.targetDirectories[0]
            try FileManager.default.createDirectory(at: directory.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.createSymbolicLink(atPath: directory.path, withDestinationPath: elsewhere.path)
            #expect(box.installer().status().map(\.installed) == [false], "installed only for a link to this bundle")
            #expect(box.installer().install("fake-agent") == .failed("\(directory.path) already exists and isn't managed by Tabs"))
            #expect(box.destination(of: directory) == elsewhere.path)
        }
    }
}
