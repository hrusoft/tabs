import AppKit

// Crash on an uncaught Objective-C exception instead of letting AppKit
// swallow it at the run loop and carry on in an inconsistent state (Apple's
// recommendation). Under tests, a swallowed exception looks like a silent hang.
UserDefaults.standard.register(defaults: ["NSApplicationCrashOnExceptions": true])

if let command = HeadlessCommand(arguments: CommandLine.arguments) {
    Task { @MainActor in
        exit(await command.run())
    }
    dispatchMain()
}

#if DEBUG
if let capture = VisualCapture.arguments(CommandLine.arguments) {
    // Views need the app, but nothing is shown and the app never activates.
    _ = NSApplication.shared
    Task { @MainActor in
        exit(await VisualCapture.run(scenarios: capture.scenarios, out: capture.out, names: capture.names))
    }
    NSApplication.shared.run()
}
#endif

let delegate = AppDelegate()
NSApplication.shared.delegate = delegate
NSApplication.shared.run()
