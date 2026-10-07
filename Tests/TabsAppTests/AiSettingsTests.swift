import AppKit
import Foundation
import SwiftUI
import Testing

@testable import Tabs
@testable import TabsCore

extension UITests {
    // MARK: - Settings ▸ AI and the bundled skill (docs/BROWSER.md I-1, I-3)

    @MainActor
    @Suite struct AiSettings {
        /// A Settings window whose AI page installs a fake bundle into a temporary home.
        @MainActor private final class Fixture {
            let root = TestTemporary.location("ai")
            let controller: NSWindowController
            let installer: SkillInstaller
            var home: URL { root.appending(path: "home", directoryHint: .isDirectory) }
            var bundled: URL { root.appending(path: "skills/tabs") }

            init(bundle: Bool = true) throws {
                let skills = root.appending(path: "skills", directoryHint: .isDirectory)
                if bundle {
                    try FileManager.default.createDirectory(at: skills.appending(path: "tabs"), withIntermediateDirectories: true)
                }
                installer = SkillInstaller(
                    skillsDirectory: skills,
                    targets: SkillInstaller.targets(home: root.appending(path: "home", directoryHint: .isDirectory)))
                let runtime = TestSupport.runtime()
                controller = makeSettingsWindow(
                    pages: runtime.settingsPages(), settings: runtime.settings, signals: runtime.signals.settingKinds,
                    shortcuts: runtime.shortcuts, skills: installer)
                let tabs = try #require(controller.contentViewController as? NSTabViewController)
                tabs.selectedTabViewItemIndex = tabs.tabViewItems.count - 1
                controller.window?.layoutIfNeeded()
            }

            func settle() {
                runLoopTurns()
                controller.window?.contentView?.layoutSubtreeIfNeeded()
            }

            var page: NSView? { controller.window?.contentView }

            /// The AI page, and the model behind it.
            var hosting: NSHostingView<AiSettingsView>? { page?.allSubviews.lazy.compactMap { $0 as? NSHostingView<AiSettingsView> }.first }
            var model: AiSettingsModel? { hosting?.rootView.model }

            /// The page's buttons, top to bottom, left to right.
            var buttons: [NSButton] {
                let all = (page?.allSubviews ?? []).compactMap { $0 as? NSButton }
                return all.sorted {
                    let (a, b) = ($0.convert($0.bounds, to: nil), $1.convert($1.bounds, to: nil))
                    return a.minY == b.minY ? a.minX < b.minX : a.minY > b.minY  // window space: y up
                }
            }

            func button(_ identifier: String) -> NSButton? { buttons.first { $0.accessibilityIdentifier() == identifier } }

            /// Presses a button as its owner does: the control performs its action.
            func press(_ identifier: String) throws {
                let button = try #require(
                    button(identifier), "no button \(identifier); have \(buttons.map { $0.accessibilityIdentifier() })")
                #expect(button.isEnabled)
                button.performClick(nil)
                settle()
            }

            func remove() {
                controller.close()
                try? FileManager.default.removeItem(at: root)
            }
        }

        @Test func theAiPageIsTheLastPageAndListsBothTargetsWithTheirWords() throws {
            let box = try Fixture()
            defer { box.remove() }
            let tabs = try #require(box.controller.contentViewController as? NSTabViewController)
            #expect(tabs.tabViewItems.map(\.label) == ["Panes & Tabs", "Keyboard", "AI"])
            box.settle()
            let model = try #require(box.model)
            #expect(model.targets.map(\.label) == ["Claude Code", "Codex"])
            #expect(model.targets.map { model.installTitle(of: $0) } == ["Install", "Install"])
            #expect(model.targets.map { model.detail(of: $0) } == ["Not installed", "Not installed"])
            #expect(
                box.buttons.map { $0.accessibilityIdentifier() } == ["settings-skill-install-claude-code", "settings-skill-install-codex"],
                "an Install button per target, nothing to uninstall yet")
            #expect(box.buttons.map(\.title) == ["Install", "Install"])
            let image = try #require(
                box.page.flatMap { view -> NSBitmapImageRep? in
                    view.layoutSubtreeIfNeeded()
                    return view.bitmapImageRepForCachingDisplay(in: view.bounds)
                })
            box.page?.cacheDisplay(in: box.page?.bounds ?? .zero, to: image)
            #expect(image.pixelsHigh > 100, "the page has a body")
            if let directory = ProcessInfo.processInfo.environment["TABS_SNAPSHOT_DIR"] {
                try image.representation(using: .png, properties: [:])?.write(
                    to: URL(filePath: directory).appending(path: "settings-ai.png"))
            }
        }

        @Test func installThenUninstallThroughTheRealControlsChangeTheStatus() throws {
            let box = try Fixture()
            defer { box.remove() }
            box.settle()
            let model = try #require(box.model)
            let link = box.home.appending(path: ".claude/skills/tabs").path

            try box.press("settings-skill-install-claude-code")
            #expect(try FileManager.default.destinationOfSymbolicLink(atPath: link) == box.bundled.path)
            #expect(box.installer.status().map(\.installed) == [true, false], "only the row that was clicked")
            #expect(model.targets.map { model.installTitle(of: $0) } == ["Reinstall", "Install"])
            #expect(model.targets.map { model.detail(of: $0) } == ["Installed", "Not installed"])
            #expect(
                box.buttons.map(\.title) == ["Uninstall", "Reinstall", "Install"],
                "Uninstall and Reinstall for Claude Code (the install button keeps its column), Install for Codex")

            try box.press("settings-skill-uninstall-claude-code")
            #expect(!FileManager.default.fileExists(atPath: link))
            #expect(box.installer.status().map(\.installed) == [false, false])
            #expect(model.targets.map { model.detail(of: $0) } == ["Not installed", "Not installed"])
            #expect(box.buttons.map(\.title) == ["Install", "Install"])
        }

        @Test func aFailureReplacesTheStatusLineUntilAnActionSucceeds() throws {
            let box = try Fixture()
            defer { box.remove() }
            // Something that isn't Tabs' at Codex's destination.
            let destination = box.home.appending(path: ".agents/skills/tabs", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
            box.settle()
            let model = try #require(box.model)
            try box.press("settings-skill-install-codex")
            #expect(
                model.targets.map { model.detail(of: $0) } == [
                    "Not installed", "\(destination.path) already exists and isn't managed by Tabs",
                ])
            #expect(box.installer.status().map(\.installed) == [false, false])
            #expect(FileManager.default.fileExists(atPath: destination.path), "never clobbered")

            try FileManager.default.removeItem(at: destination)
            try box.press("settings-skill-install-codex")
            #expect(box.installer.status().map(\.installed) == [false, true])
            #expect(
                model.targets.map { model.detail(of: $0) } == ["Not installed", "Installed"], "the error is gone once an action succeeds")
        }

        @Test func aMissingBundleIsReportedAsNotFound() throws {
            let box = try Fixture(bundle: false)
            defer { box.remove() }
            box.settle()
            let model = try #require(box.model)
            try box.press("settings-skill-install-claude-code")
            #expect(model.detail(of: model.targets[0]) == "bundled skill directory not found")
        }

        // MARK: The bundled files

        /// The app bundles the skill (`Resources/skills/tabs`), whose `scripts/tabs-ctl` runs the
        /// app's `Contents/Helpers/tabs-ctl`, from the bundle and through a symlinked skill directory
        /// as Settings ▸ AI installs it. Outside a Tabs terminal pane the relay says so and exits 1,
        /// before it opens any socket (the stub's own refusal would mean it never found the relay).
        @Test func theBundledTabsCtlRefusesToRunOutsideATabsPane() throws {
            let skill = try #require(Bundle.main.resourceURL).appending(path: "skills/tabs", directoryHint: .isDirectory)
            #expect(FileManager.default.isExecutableFile(atPath: skill.appending(path: "scripts/tabs-ctl").path))
            #expect(FileManager.default.fileExists(atPath: skill.appending(path: "SKILL.md").path))
            #expect(FileManager.default.isExecutableFile(atPath: Bundle.main.bundleURL.appending(path: "Contents/Helpers/tabs-ctl").path))

            let installed = TestTemporary.location("skill")
            try FileManager.default.createDirectory(at: installed, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: installed) }
            try FileManager.default.createSymbolicLink(at: installed.appending(path: "tabs"), withDestinationURL: skill)

            for directory in [skill, installed.appending(path: "tabs")] {
                let process = Process()
                process.executableURL = directory.appending(path: "scripts/tabs-ctl")
                process.arguments = ["ping"]
                // No TABS_PANE_ID, no TABS_CONTROL_SOCKET.
                process.environment = ["PATH": "/usr/bin:/bin"]
                let output = Pipe()
                process.standardOutput = output
                process.standardError = output
                try process.run()
                process.waitUntilExit()
                let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                #expect(process.terminationStatus == 1, "\(directory.path)")
                #expect(text.contains("not running inside a Tabs terminal pane"), "\(directory.path): \(text)")
            }
        }
    }
}
