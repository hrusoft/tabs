import Foundation
import os

/// A plugin's entry point: the bundle's `NSPrincipalClass`.
///
/// ```swift
/// @MainActor
/// final class TerminalPlugin: NSObject, TabsPlugin {
///     func activate(_ context: any PluginContext) throws {
///         context.register(ContentTypeContribution(...))
///     }
/// }
/// ```
///
/// The contract:
///
/// - **Isolation.** A plugin sees core, never another plugin. Everything it
///   can reach is on its `PluginContext`: contributing to core's extension
///   points, its own settings and data directory, core's events, and the
///   workspace — restricted to its own content types, plus the pane
///   capabilities core defines (e.g. a pane's working directory). There are no
///   plugin-to-plugin APIs, events, extension points or dependencies.
///
/// - **Entry class.** An `NSObject` subclass defined in the plugin's own
///   bundle, named in Info.plist as `$(PRODUCT_MODULE_NAME).ClassName`, with no
///   `init` of its own. Core may instantiate it more than once per process
///   (every test builds its own host), so all state belongs on the instance.
///
/// - **`activate` registers and returns.** It registers contributions and
///   subscriptions, and must be fast and synchronous: it
///   runs on the main thread before any window exists, and also in headless
///   mode (`--plugin-report`, `--control`), so it must not create windows or
///   views. Slow or asynchronous setup goes in `context.spawn`.
///
/// - **All or nothing.** Everything `activate` registers is staged and
///   committed only if it returns without throwing and nothing it registered
///   breaks a rule. Otherwise all of it is rolled back, the plugin's context
///   goes dead (every later call through it is ignored), its spawned tasks are
///   cancelled.
///
/// - **`deactivate` is called exactly once for every plugin whose `activate`
///   returned** — at quit, in reverse activation order, or immediately if its
///   contributions were rejected. It is never called after `activate` threw: a
///   plugin that throws cleans up before throwing. Tasks from `context.spawn`
///   are cancelled right after `deactivate` returns.
///
/// - **Nothing unloads.** A process can't unload an image that registered
///   Objective-C classes or Swift metadata; a disabled plugin stops loading at
///   the next launch.
@MainActor
public protocol TabsPlugin: AnyObject {
    func activate(_ context: any PluginContext) throws
    func deactivate()
}

public extension TabsPlugin {
    func deactivate() {}
}

/// Everything core lends one plugin — and all it can reach. Each plugin gets
/// its own context, bound to its id: it contributes only inside its own
/// namespace, and its workspace handle acts only on its own content types.
/// After the plugin deactivates or fails, the context is dead and every call
/// through it is ignored (and logged).
@MainActor
public protocol PluginContext: AnyObject {
    var manifest: PluginManifest { get }
    /// The plugin's own bundle, for its resources.
    var bundle: Bundle { get }
    var log: Logger { get }
    /// The plugin's own place for data it keeps (created on first access).
    /// These three are the only places a plugin should write: shared
    /// locations (the app's defaults, Application Support, the system temp
    /// directory) are shared with every other plugin.
    var dataDirectory: URL { get }
    /// The plugin's own cache: data it can rebuild, which the system may purge.
    var cacheDirectory: URL { get }
    /// The plugin's own scratch space for this run.
    var temporaryDirectory: URL { get }
    /// The identity of the plugin's own web data (cookies, storage, cache):
    /// `WKWebsiteDataStore(forIdentifier: context.webDataStoreIdentifier)`.
    /// The default store is shared with every other plugin's web views. Stable
    /// across launches.
    var webDataStoreIdentifier: UUID { get }

    /// Adds a contribution to one of core's extension points. Only during
    /// `activate`. Core validates it on the spot — namespace (or the point's
    /// own rule), duplicates, point-specific rules — and any violation fails
    /// the plugin as a whole.
    func contribute<C: Contribution>(_ contribution: C, to point: ExtensionPoint<C>)

    /// The plugin's settings, decoded as `type`. One settings type per plugin.
    func settings<Value: PluginSettingsValue>(_ type: Value.Type) -> PluginSettings<Value>

    /// Runs asynchronous work tied to the plugin's lifetime: cancelled when the
    /// plugin deactivates or its activation is rolled back. The operation runs
    /// off the main actor unless it is itself `@MainActor`. Work must check
    /// `Task.isCancelled` (or use cancellation-aware APIs) to stop promptly.
    @discardableResult
    func spawn(priority: TaskPriority?, _ operation: @escaping @Sendable () async -> Void) -> Task<Void, Never>

    /// Core's events (panes opening, closing, becoming active).
    var events: any EventBus { get }
    /// Layout requests for the plugin's own content types, and core-defined
    /// pane capabilities of any pane.
    var workspace: any Workspace { get }
}

public extension PluginContext {
    var id: PluginID { manifest.id }

    @discardableResult
    func spawn(_ operation: @escaping @Sendable () async -> Void) -> Task<Void, Never> {
        spawn(priority: nil, operation)
    }

    func register(_ contribution: ContentTypeContribution) { contribute(contribution, to: .contentTypes) }
    func register(_ contribution: CommandContribution) { contribute(contribution, to: .commands) }
    func register(_ contribution: SettingsPageContribution) { contribute(contribution, to: .settingsPages) }
    func register(_ contribution: ControlVerbContribution) { contribute(contribution, to: .controlVerbs) }
}
