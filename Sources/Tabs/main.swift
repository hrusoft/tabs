import AppKit

// Crash on an uncaught Objective-C exception instead of letting AppKit
// swallow it at the run loop and carry on in an inconsistent state (Apple's
// recommendation). Under tests, a swallowed exception looks like a silent hang.
UserDefaults.standard.register(defaults: ["NSApplicationCrashOnExceptions": true])

/// A background process from the start: no Dock tile, no menu bar, never
/// frontmost. For the runs nobody sees (headless, hidden, hosting tests, a
/// capture). Before `NSApplication.shared`: it checks in with LaunchServices
/// from the main bundle's Info.plist, so `setActivationPolicy(.prohibited)`
/// after that still flashes a Dock tile (measured: ~0.6s per launch).
func runInBackground() {
    let info = CFBundleGetInfoDictionary(CFBundleGetMainBundle()) as NSDictionary as? NSMutableDictionary
    info?["LSBackgroundOnly"] = true
}

if let command = HeadlessCommand(arguments: CommandLine.arguments) {
    // No NSApplication, but a plugin's SF Symbol icon reaches the window
    // server, and that checks in too.
    runInBackground()
    Task { @MainActor in
        exit(await command.run())
    }
    dispatchMain()
}

#if DEBUG
if let capture = VisualCapture.arguments(CommandLine.arguments) {
    // Views need the app, but nothing is shown and the app never activates.
    runInBackground()
    _ = NSApplication.shared
    Task { @MainActor in
        exit(await VisualCapture.run(scenarios: capture.scenarios, out: capture.out, names: capture.names))
    }
    NSApplication.shared.run()
}
#endif

if AppDelegate.isHidden || AppDelegate.isHostingTests { runInBackground() }
let delegate = AppDelegate()
NSApplication.shared.delegate = delegate
NSApplication.shared.run()
