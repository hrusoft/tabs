import AppKit
import TabsPluginSDK

/// The rules core attaches to its own extension points.
///
/// Rules here are about a plugin's own contribution; nothing here depends on
/// another plugin. Shortcut clashes in particular aren't a rule: `Shortcuts`
/// resolves them by leaving the later command unbound.
package enum CoreExtensionPoints {
    /// What's wrong with a control verb's declaration, core's or a plugin's.
    package static func problem(with verb: ControlVerbContribution) -> String? {
        if verb.summary.trimmingCharacters(in: .whitespaces).isEmpty { return "summary is empty" }
        if verb.timeout <= .zero { return "timeout must be positive" }
        var seen: Set<String> = []
        for argument in verb.arguments {
            guard argument.name.wholeMatch(of: /[a-z][A-Za-z0-9]*/) != nil else {
                return "argument \"\(argument.name)\" must be lowerCamelCase"
            }
            guard seen.insert(argument.name).inserted else { return "argument \"\(argument.name)\" is declared twice" }
        }
        if case .pane(let types) = verb.target, types.isEmpty { return "a pane target names no content types" }
        if case .ownedPane(let types?) = verb.target, types.isEmpty { return "an owned-pane target names no content types" }
        return controlPlaneProblem(with: verb)
    }

    /// The rules of a control-plane verb: `command` and `wireType` together,
    /// spelled right, and nothing that clashes with the wire request's own
    /// fields or with another flag.
    private static func controlPlaneProblem(with verb: ControlVerbContribution) -> String? {
        guard let wireType = verb.wireType else {
            if verb.command != nil { return "a command needs a wireType (the request type it becomes)" }
            if case .ownedPane = verb.target { return "an owned-pane target is for control-plane verbs: declare a command and a wireType" }
            if verb.composition != nil { return "a flag composition is for control-plane verbs: declare a command and a wireType" }
            return nil
        }
        guard let command = verb.command else { return "a wireType needs a command (the CLI name)" }
        guard command.wholeMatch(of: /[a-z][a-z0-9]*(-[a-z0-9]+)*/) != nil else { return "command \"\(command)\" must be kebab-case" }
        guard wireType.wholeMatch(of: /[a-z][A-Za-z0-9]*/) != nil else { return "wireType \"\(wireType)\" must be lowerCamelCase" }
        // The request's own fields.
        var reserved: Set<String> = ["type", "paneId", "targetPaneId"]
        if verb.composition != nil { reserved.insert("target") }
        if let clash = verb.arguments.first(where: { reserved.contains($0.name) }) {
            return "argument \"\(clash.name)\" is a field of the wire request itself"
        }
        var flags: Set<String> = []
        for flag in ControlFlag.of(verb) {
            guard flag.name.wholeMatch(of: /[a-z][a-z0-9]*(-[a-z0-9]+)*/) != nil else {
                return "flag \"\(flag.name)\" must be kebab-case"
            }
            guard flags.insert(flag.name).inserted else { return "flag --\(flag.name) is declared twice (or is one core adds)" }
        }
        return nil
    }

    /// Wire types core's own verbs use.
    package static let coreWireTypes: Set<String> = [
        "ping", "activatePane", "closePane", "listOwnedPanes", "getPaneInfo", "batch", "capabilities", "describe",
    ]

    /// What's wrong with a control capability's declaration.
    package static func problem(with capability: ControlCapabilityContribution) -> String? {
        if capability.displayName.trimmingCharacters(in: .whitespaces).isEmpty { return "displayName is empty" }
        if !capability.limits.values.allSatisfy(\.isRepresentableInJSON) { return "limits must be valid JSON (no NaN or infinity)" }
        return nil
    }

    /// What's wrong with a kind of pane signal's declaration.
    package static func problem(with kind: PaneSignalContribution) -> String? {
        func blank(_ text: String) -> Bool { text.trimmingCharacters(in: .whitespaces).isEmpty }
        if blank(kind.label) { return "label is empty" }
        if case .symbol(let name) = kind.icon {
            if name.isEmpty { return "the icon's symbol name is empty" }
            if NSImage(systemSymbolName: name, accessibilityDescription: nil) == nil { return "there's no SF Symbol named \(name)" }
        }
        if let pulse = kind.pulse, !(pulse > 0 && pulse.isFinite) { return "pulse must be a positive number of seconds" }
        if blank(kind.setting.title) { return "the setting's title is empty" }
        if let tooltip = kind.tooltip, blank(tooltip) { return "tooltip is empty (nil for none)" }
        return nil
    }

    @MainActor
    package static func install(into registry: ContributionRegistry) {
        registry.declareCorePoint(.contentTypes) { id, manifest in
            ContributionRegistry.namespacePolicy(id, manifest)
                ?? (manifest.contentTypes.contains(ContentTypeID(id)) ? nil : "not declared in the manifest's contentTypes")
        }
        registry.declareCorePoint(.commands)
        registry.declareCorePoint(.settingsPages)
        registry.declareCorePoint(.controlVerbs)
        registry.declareCorePoint(.controlCapabilities) { id, manifest in
            id == manifest.id.rawValue ? nil : "must be the plugin's own id, \"\(manifest.id)\""
        }
        registry.declareCorePoint(.paneSignals)
        registry.addValidator(for: .contentTypes) { type, _, _ in
            if type.displayName.trimmingCharacters(in: .whitespaces).isEmpty { return "displayName is empty" }
            if case .symbol(let name) = type.icon {
                if name.isEmpty { return "the icon's symbol name is empty" }
                if NSImage(systemSymbolName: name, accessibilityDescription: nil) == nil { return "there's no SF Symbol named \(name)" }
            }
            if let label = type.creationLabel, label.trimmingCharacters(in: .whitespaces).isEmpty {
                return "creationLabel is empty (nil for \"New \(type.displayName)\")"
            }
            return nil
        }
        registry.addCommitCheck { manifest, staged in
            let registered = Set(
                staged.filter { $0.pointID == ExtensionPoint<ContentTypeContribution>.contentTypes.id }.map(\.contributionID))
            return manifest.contentTypes.filter { !registered.contains($0.rawValue) }.map {
                "tabs.contentTypes \"\($0)\": declared in the manifest but never registered"
            }
        }

        // Commands and verbs may apply only to their own plugin's content types.
        registry.addCommitCheck { manifest, staged in
            staged.compactMap { entry -> String? in
                if entry.pointID == ExtensionPoint<CommandContribution>.commands.id, let command = entry.value as? CommandContribution,
                    let type = command.appliesTo, !manifest.contentTypes.contains(type)
                {
                    return "tabs.commands \"\(command.id)\": appliesTo \"\(type)\" is not one of this plugin's content types"
                }
                if entry.pointID == ExtensionPoint<ControlVerbContribution>.controlVerbs.id,
                    let verb = entry.value as? ControlVerbContribution,
                    let types = verb.target.pluginTypes, let foreign = types.sorted().first(where: { !manifest.contentTypes.contains($0) })
                {
                    return "tabs.controlVerbs \"\(verb.name)\": target type \"\(foreign)\" is not one of this plugin's content types"
                }
                // A plugin with commands for agents says what they are for.
                if entry.pointID == ExtensionPoint<ControlVerbContribution>.controlVerbs.id,
                    let verb = entry.value as? ControlVerbContribution, verb.command != nil,
                    !staged.contains(where: { $0.pointID == ExtensionPoint<ControlCapabilityContribution>.controlCapabilities.id })
                {
                    return
                        "tabs.controlVerbs \"\(verb.name)\": a plugin with control-plane commands must also register a ControlCapabilityContribution (its guide and limits)"
                }
                return nil
            }
        }

        registry.addValidator(for: .commands) { command, _, _ in
            if command.title.trimmingCharacters(in: .whitespaces).isEmpty { return "title is empty" }
            guard let chord = command.defaultChord else { return nil }
            return Shortcuts.problem(with: chord, scope: command.appliesTo).map { "shortcut \(chord): \($0)" }
        }

        registry.addValidator(for: .controlVerbs) { verb, _, others in
            if let problem = problem(with: verb) { return problem }
            guard let wireType = verb.wireType else { return nil }
            if coreWireTypes.contains(wireType) { return "wireType \"\(wireType)\" is one of core's" }
            if let clash = others.first(where: { $0.value.wireType == wireType }) {
                return "wireType \"\(wireType)\" is already \(clash.owner)'s (\(clash.value.name))"
            }
            return nil
        }
        registry.addValidator(for: .controlCapabilities) { capability, _, _ in problem(with: capability) }

        registry.addValidator(for: .settingsPages) { page, _, _ in
            page.title.trimmingCharacters(in: .whitespaces).isEmpty ? "title is empty" : nil
        }

        registry.addValidator(for: .paneSignals) { kind, _, _ in problem(with: kind) }
    }
}

private extension ControlTarget {
    /// The content types a target names (nil: none, or any).
    var pluginTypes: Set<ContentTypeID>? {
        switch self {
        case .none: nil
        case .pane(let types): types
        case .ownedPane(let types): types
        }
    }
}
