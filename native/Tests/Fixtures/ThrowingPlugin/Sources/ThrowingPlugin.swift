import Foundation
import TabsPluginSDK

struct DeliberateFailure: Error, CustomStringConvertible {
    var description: String { "deliberate failure from the fixture" }
}

/// Test fixture: contributes one of everything, then throws. The tests check
/// that none of it survives — across a real image boundary.
@MainActor
final class ThrowingPlugin: NSObject, TabsPlugin {
    func activate(_ context: any PluginContext) throws {
        context.register(CommandContribution(id: "fixture-throws.boom", title: "Boom", menu: .view) { _ in })
        context.register(ControlVerbContribution(name: "fixture-throws.verb", summary: "never visible") { _ in nil })
        context.events.subscribe(EventChannel<PaneEvent>.paneOpened) { _ in }
        throw DeliberateFailure()
    }
}
