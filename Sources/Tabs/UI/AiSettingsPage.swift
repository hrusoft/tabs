import AppKit
import SwiftUI
import TabsCore

/// Settings ▸ AI: what an agent running inside a Tabs pane needs from the app itself. Two things,
/// together because they are the same question asked from both ends: what Tabs hands the agent (the
/// bundled "control Tabs" skill, installed into an agent's personal skill directory, see
/// `SkillInstaller`) and what the agent has to be told about Tabs (the bell note, which is a hint
/// rather than a control: nothing here can write another program's config for it).
///
/// The install rows are explicit and user-triggered, one per install target. Nothing here is a
/// stored setting.
@MainActor
@Observable
final class AiSettingsModel {
    private(set) var targets: [SkillInstaller.Status]
    /// The last failure per target, shown in place of its status until an action succeeds.
    private(set) var errors: [String: String] = [:]
    @ObservationIgnored private let installer: SkillInstaller

    init(installer: SkillInstaller) {
        self.installer = installer
        targets = installer.status()
    }

    func install(_ id: String) { run(id, installer.install) }
    func uninstall(_ id: String) { run(id, installer.uninstall) }

    /// The install button's title: installing again is a re-link.
    func installTitle(of target: SkillInstaller.Status) -> String { target.installed ? "Reinstall" : "Install" }

    /// What a row's second line says: the failure if there is one, else the status.
    func detail(of target: SkillInstaller.Status) -> String {
        if let error = errors[target.id], !error.isEmpty { return error }
        return target.installed ? "Installed" : "Not installed"
    }

    private func run(_ id: String, _ action: (String) -> SkillInstaller.Result) {
        switch action(id) {
        case .ok:
            errors[id] = ""
            targets = installer.status()
        case .failed(let message):
            errors[id] = message
        }
    }
}

struct AiSettingsView: View {
    @Bindable var model: AiSettingsModel

    var body: some View {
        Form {
            Section {
                ForEach(model.targets, id: \.id) { target in
                    LabeledContent {
                        HStack(spacing: 6) {
                            if target.installed {
                                SettingsButton("Uninstall", id: "settings-skill-uninstall-\(target.id)") { model.uninstall(target.id) }
                            }
                            SettingsButton(model.installTitle(of: target), id: "settings-skill-install-\(target.id)") {
                                model.install(target.id)
                            }
                        }
                    } label: {
                        Text(target.label)
                        Text(model.detail(of: target))
                            .accessibilityIdentifier("settings-skill-status-\(target.id)")
                    }
                }
            } header: {
                Text("Skills")
            } footer: {
                Text(
                    "Installs a skill that lets an agent running in a Tabs terminal pane open and control browser panes it creates. It only works from inside Tabs — installing it doesn't affect anything outside the app."
                )
            }
            Section("Bell notifications") {
                VStack(alignment: .leading, spacing: 10) {
                    let code = { (text: String) in Text(text).font(.subheadline.monospaced()) }
                    Text(
                        "Claude Code stays silent in terminals it doesn't recognise, so it never rings the bell (\(code("\\a"))) Tabs watches for. Run \(code("/config")) → notification channel → “Terminal bell”, or add to \(code("~/.claude/settings.json")):"
                    )
                    .font(.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Text(#""preferredNotifChannel": "terminal_bell""#)
                        .font(.callout.monospaced()).textSelection(.enabled)
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
                        .accessibilityIdentifier("settings-ai-bell-snippet")
                }
            }
        }
        .settingsPageLayout()
        .accessibilityIdentifier("settings-page-ai")
    }
}
