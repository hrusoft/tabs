import Foundation
import TabsPluginSDK

/// Core's internal verbs about the running app: `tabs.info`, `tabs.plugins`,
/// `tabs.shortcuts` and `tabs.setShortcut`. `tabs.verbs` is the dispatcher's
/// own, and the control plane's are `installControlPlane`'s; these read the
/// whole runtime, so the composition root adds them once it is built.
extension CoreRuntime {
    func addRuntimeVerbs() {
        control.addCoreVerb(
            ControlVerbContribution(name: "tabs.info", summary: "This process: pid, data directory, control socket, build") {
                [unowned self] _ in
                let stamp = BuildStamp(of: .main)
                return [
                    "pid": .int(Int64(getpid())),
                    "dataDirectory": .string(self.paths.dataDirectory.path),
                    "controlSocket": self.controlSocketPath.map(JSONValue.string) ?? .null,
                    "configuration": stamp.map { .string($0.configuration) } ?? .null,
                    "sharedFingerprint": self.sharedFingerprint.map(JSONValue.string) ?? .null,
                ]
            })
        control.addCoreVerb(
            ControlVerbContribution(name: "tabs.plugins", summary: "Every discovered plugin and its state") { [unowned self] _ in
                self.report()
            })
        addShortcutVerbs()
    }

    private func addShortcutVerbs() {
        control.addCoreVerb(
            ControlVerbContribution(
                name: "tabs.shortcuts", summary: "Every command's shortcut: default, effective, where it came from, and why if unbound"
            ) { [unowned self] _ in
                .array(
                    self.shortcuts.bindings.map { binding in
                        [
                            "command": .string(binding.command.rawValue), "owner": .string(binding.owner.rawValue),
                            "title": .string(binding.title), "appliesTo": binding.scope.map { .string($0.rawValue) } ?? .null,
                            "default": binding.defaultChord.map { .string($0.stringValue) } ?? .null,
                            "chord": binding.chord.map { .string($0.stringValue) } ?? .null,
                            "source": binding.source.map { .string($0.rawValue) } ?? .null,
                            "fixed": .bool(binding.isFixed),
                            "note": binding.note.map(JSONValue.string) ?? .null,
                        ]
                    })
            })
        control.addCoreVerb(
            ControlVerbContribution(
                name: "tabs.setShortcut", summary: "Rebind a command for the user: a chord (cmd+shift+k), none to unbind, default to reset",
                arguments: [
                    ControlArgument("command", .string, required: true),
                    ControlArgument("chord", .string, required: true, summary: "e.g. cmd+shift+k, ctrl+f5; none; default"),
                ]
            ) { [unowned self] invocation in
                let command = CommandID(invocation["command"]?.stringValue ?? "")
                let chord = invocation["chord"]?.stringValue ?? ""
                do {
                    switch chord {
                    case "default": try self.shortcuts.reset(command)
                    case "none": try self.shortcuts.bind(command, to: nil)
                    default:
                        guard let parsed = KeyChord(string: chord) else { throw Shortcuts.Refusal("\"\(chord)\" is not a shortcut") }
                        try self.shortcuts.bind(command, to: parsed)
                    }
                } catch {
                    throw ControlVerbError(String(describing: error))
                }
                let binding = self.shortcuts.binding(for: command)
                return [
                    "chord": binding?.chord.map { .string($0.stringValue) } ?? .null,
                    "note": binding?.note.map(JSONValue.string) ?? .null,
                ]
            })
    }
}
