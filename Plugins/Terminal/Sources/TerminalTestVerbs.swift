#if DEBUG
import TabsPluginSDK

/// Debug-only verbs for the end-to-end tests: a terminal's shell, grid and
/// text. Not in Release builds.
@MainActor
enum TerminalTestVerbs {
    static func register(in context: any PluginContext) {
        context.register(
            ControlVerbContribution(
                name: "terminal.test.state",
                summary: "Debug: a terminal pane's shell pid, grid and pty size, screen and buffer text, cwd, focus",
                target: .pane(ofTypes: ["terminal"])
            ) { invocation in
                guard let pane = invocation.pane(as: TerminalPane.self) else { throw ControlVerbError("not a terminal pane") }
                return pane.testState
            })
    }
}
#endif
