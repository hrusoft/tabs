import AppKit
import TabsPluginSDK

/// The browser's external-control surface: every verb `tabs-ctl` can run against a
/// browser pane (`shared/controlSpec.ts`, `main/browserExternalControl.ts`). One
/// file per family registers its own verbs, so the families don't share a table:
///
/// - `NavigationVerbs`: `create-browser-pane`, `navigate`, `reload`, `go-back`, `go-forward`;
/// - `ReadVerbs`: `screenshot`, `get-page-text`, `read-page`, `find`;
/// - `InputVerbs`: `click`, `hover`, `type`, `key`, `scroll`, `form-input`;
/// - `ScriptVerbs`: `read-console`, `execute-js`;
/// - `WaitVerbs`: `wait-for`, `assert`;
/// - `ResourceVerbs`: `save-resource`.
///
/// `read-network` and `capture-bodies` are not ported (BROWSER.md J-23): WKWebView
/// has no request observation. Every verb but `create-browser-pane` acts on a pane
/// the caller owns (`target: .ownedPane(ofTypes: ["browser"])`); core enforces
/// ownership, existence and type before a handler runs (docs/PLUGINS.md).
@MainActor
enum BrowserVerbs {
    /// Declared during `activate`: the capability (guide and limits `describe`
    /// serves) and every verb.
    static func register(in context: any PluginContext, services: BrowserServices) {
        context.register(
            ControlCapabilityContribution(
                id: "browser", displayName: "Browser", guide: BrowserGuide.text(in: context.bundle), limits: BrowserLimits.described))
        let verbs =
            NavigationVerbs.all(services: services) + ReadVerbs.all(services: services) + InputVerbs.all(services: services)
            + ScriptVerbs.all(services: services) + WaitVerbs.all(services: services) + ResourceVerbs.all(services: services)
        for verb in verbs { context.register(verb) }
    }
}

/// The guide `describe --capability browser` prints: the prose that says when and
/// how to use the verbs (`shared/guide.md`), a copy with the network section
/// removed and WebKit's differences corrected (BROWSER.md, Known differences).
enum BrowserGuide {
    static func text(in bundle: Bundle) -> String {
        guard let url = bundle.url(forResource: "guide", withExtension: "md"), let text = try? String(contentsOf: url, encoding: .utf8)
        else { return "" }
        return text
    }
}

extension BrowserLimits {
    /// `describe`'s structured limits, the manifest's `limits` (same key names).
    static var described: [String: JSONValue] {
        [
            "pageTextDefaultMax": .int(Int64(defaultPageTextMax)),
            "pageTextHardMax": .int(Int64(pageTextHardMax)),
            "waitDefaultTimeoutMs": .int(Int64(waitDefaultTimeoutMs)),
            "waitMaxTimeoutMs": .int(Int64(waitMaxTimeoutMs)),
            "waitIdleQuietMs": .int(Int64(waitIdleQuietMs)),
            "waitDefaultPollMs": .int(Int64(waitDefaultPollMs)),
            "executeResultMax": .int(Int64(executeResultMax)),
        ]
    }
}
