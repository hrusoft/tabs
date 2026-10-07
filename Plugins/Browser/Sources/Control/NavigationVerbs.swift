import Foundation
import TabsPluginSDK

/// The Navigation verbs: `create-browser-pane`, `navigate`, `reload`, `go-back`
/// and `go-forward`. The handlers are in `NavigationCreate` and `NavigationPage`;
/// this is what each verb declares.
@MainActor
enum NavigationVerbs {
    static func all(services: BrowserServices) -> [ControlVerbContribution] {
        [createBrowserPane(services), navigate(), reload(), goBack(), goForward()]
    }

    /// Where a navigation left the pane.
    private static let settledPage: [String: JSONValue] = [
        "url": "string", "title": "string", "titleFromUrl": "boolean", "status": "number", "statusText": "string",
    ]

    private static func shape(_ own: [String: JSONValue]) -> JSONValue {
        .object(settledPage.merging(own) { _, own in own })
    }

    /// One load wait, and the headroom the deadline keeps above it, so the verb's own bounded answer beats it.
    private static var loadBudget: Duration { .milliseconds(BrowserLimits.loadWaitMs) + ControlBudget.headroom }

    private static func createBrowserPane(_ services: BrowserServices) -> ControlVerbContribution {
        ControlVerbContribution(
            name: "browser.createBrowserPane",
            summary:
                "Open a browser pane and wait for its first page. Where it appears relative to the pane you are running in — a new tab (the default), a split, or its own unpinned window — is the user's setting (Settings → Browser → \"New pane placement\"), not a per-call choice. The returned paneId is the only pane you may target.",
            arguments: [ControlArgument("url", .string, required: true, summary: "http://, https://, or about:blank.")],
            // Waits for the new pane's page to mount, then for its first load.
            timeout: .milliseconds(BrowserLimits.mountWaitMs + BrowserLimits.loadWaitMs) + ControlBudget.headroom,
            command: "create-browser-pane", wireType: "createBrowserPane",
            // Not inside a batch: this grants a new pane's ownership partway through, so whether
            // a later step may target it would depend on evaluation order.
            batchable: false,
            resultShape: shape(["paneId": "string", "loaded": "boolean", "loadError": "string", "redirected": "boolean"])
        ) { [unowned services] invocation in
            try await NavigationCreate.run(invocation, services: services)
        }
    }

    private static func navigate() -> ControlVerbContribution {
        ControlVerbContribution(
            name: "browser.navigate",
            summary:
                "Load a URL into a pane you own and wait for it to settle. Reports where the pane actually ended up. Fails with the ERR_* code if the page cannot load.",
            arguments: [
                ControlArgument("url", .string, required: true, summary: "http://, https://, or about:blank."),
                ControlArgument(
                    "retryOnRedirect", .bool,
                    summary:
                        "Re-issue the navigation once if it lands somewhere other than the requested URL (an auth bounce). The result then carries retried and firstUrl."
                ),
            ],
            target: .ownedPane(ofTypes: ["browser"]),
            // Two full load waits, not one: `retryOnRedirect` re-issues the navigation once, so the worst
            // case is two bounded attempts, and the deadline must always be the one that fires later.
            timeout: .milliseconds(2 * BrowserLimits.loadWaitMs) + ControlBudget.headroom,
            command: "navigate", wireType: "navigate",
            resultShape: shape(["loaded": "boolean", "redirected": "boolean", "retried": "boolean", "firstUrl": "string"])
        ) { invocation in
            try await NavigationPage.navigate(invocation)
        }
    }

    private static func reload() -> ControlVerbContribution {
        ControlVerbContribution(
            name: "browser.reload", summary: "Reload the current page and wait for it to settle.",
            target: .ownedPane(ofTypes: ["browser"]), timeout: loadBudget, command: "reload", wireType: "reload",
            resultShape: shape(["loaded": "boolean", "loadError": "string"])
        ) { invocation in
            try await NavigationPage.reload(invocation)
        }
    }

    private static func goBack() -> ControlVerbContribution {
        ControlVerbContribution(
            name: "browser.goBack", summary: "Go back one page in the pane’s history and wait for it to settle.",
            target: .ownedPane(ofTypes: ["browser"]), timeout: loadBudget, command: "go-back", wireType: "goBack",
            resultShape: shape(["loaded": "boolean", "loadError": "string"])
        ) { invocation in
            try await NavigationPage.step(.back, invocation)
        }
    }

    private static func goForward() -> ControlVerbContribution {
        ControlVerbContribution(
            name: "browser.goForward", summary: "Go forward one page in the pane’s history and wait for it to settle.",
            target: .ownedPane(ofTypes: ["browser"]), timeout: loadBudget, command: "go-forward", wireType: "goForward",
            resultShape: shape(["loaded": "boolean", "loadError": "string"])
        ) { invocation in
            try await NavigationPage.step(.forward, invocation)
        }
    }
}
