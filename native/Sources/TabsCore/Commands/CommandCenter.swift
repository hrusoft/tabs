import Foundation
import TabsPluginSDK

/// Runs plugin commands for the shell's menus (and, later, context menus and
/// header buttons), enforcing the isolation rule every entry point needs: a
/// command gets the active pane's controller only if its own plugin made it.
/// Another plugin's pane is visible only by id and content type.
@MainActor
package final class CommandCenter {
    private let registry: ContributionRegistry
    private let panes: PaneRuntime

    package init(registry: ContributionRegistry, panes: PaneRuntime) {
        self.registry = registry
        self.panes = panes
    }

    package func command(_ id: CommandID) -> Owned<CommandContribution>? {
        registry.contribution(to: .commands, id: id.rawValue)
    }

    /// What `owner`'s command sees, given the frontmost window and its active
    /// pane (and that pane's content type, which the shell knows for panes
    /// core doesn't: empty and unavailable ones).
    package func invocation(for owner: PluginID, window: WindowID?, pane: PaneID?, contentType: ContentTypeID?) -> CommandInvocation {
        let own = pane.flatMap { panes.pane($0) }.flatMap { $0.isAttached && $0.owner == owner ? $0.controller : nil }
        return CommandInvocation(windowID: window, paneID: pane, contentType: contentType, pane: own)
    }

    /// Enabled: it applies to the active pane (if it names a type) and says so.
    package func isEnabled(_ command: Owned<CommandContribution>, _ invocation: CommandInvocation) -> Bool {
        if let type = command.value.appliesTo, invocation.contentType != type || invocation.pane == nil { return false }
        return command.value.isEnabled?(invocation) ?? true
    }

    /// Runs `id` if it's enabled for `invocation`'s context. Returns whether it ran.
    @discardableResult
    package func perform(_ id: CommandID, window: WindowID?, pane: PaneID?, contentType: ContentTypeID?) -> Bool {
        guard let command = command(id) else { return false }
        let invocation = invocation(for: command.owner, window: window, pane: pane, contentType: contentType)
        guard isEnabled(command, invocation) else { return false }
        command.value.perform(invocation)
        return true
    }
}
