import Foundation
import TabsPluginSDK

/// `create-browser-pane`.
@MainActor
enum NavigationCreate {
    /// The one thing that stops a creation the plugin can be told about: the type is
    /// turned off. Core's `openPane` answers nil for that (and for a shell with nowhere to
    /// put a pane, which a running control verb never has), and the message names where to
    /// undo it: this answer becomes the calling agent's context verbatim, and "refused"
    /// without a remedy just makes it retry.
    static let turnedOffError =
        "the Browser plugin is turned off in Tabs ▸ Plugins…; turn it back on to create panes of this kind"

    /// Where the setting puts an agent's new pane, relative to the caller's own pane (which
    /// may itself be floating, in which case the new pane opens inside that window: core
    /// resolves the destination from the caller). `unpinned` spawns its own floating window
    /// near the caller rather than docking into anything.
    static func placement(_ setting: NewPanePlacement, near caller: PaneID) -> PanePlacement {
        switch setting {
        case .tab: .tab(near: caller)
        // `horizontal` puts the panes side by side, the new one after the caller's; `vertical`, one over the other.
        case .splitHorizontal: .split(caller, edge: .trailing)
        case .splitVertical: .split(caller, edge: .bottom)
        case .unpinned: .floating(near: caller)
        }
    }

    static func run(_ invocation: ControlInvocation, services: BrowserServices) async throws -> JSONValue {
        let url = invocation["url"]?.stringValue ?? ""
        guard isAllowedUrl(url) else { throw ControlVerbError("url not allowed: \(url)") }
        guard let caller = invocation.callerPane else { throw ControlVerbError("not running inside a Tabs pane") }

        // `activates: false`: a mount-time focus never yanks the keyboard from the caller's
        // own terminal. `controlledBy` reports the ownership the instant the pane exists, before
        // its page loads a byte: it is what makes the popup-deny and scheme-allowlist guards
        // apply to the pane's very first load rather than only once the wait below has finished.
        // The "controlled by another pane" chrome is core's, raised by the grant.
        let request = PaneRequest(
            type: "browser", config: .object(["url": .string(url)]),
            placement: placement(services.settings.value.controlledPanePlacement, near: caller), activates: false,
            controlledBy: caller)
        guard let id = services.workspace.openPane(request) else { throw ControlVerbError(turnedOffError) }

        // The pane exists in the layout either way from here on: waiting for its page to mount
        // and settle only decides what `loaded` says, never whether the paneId comes back.
        var found: BrowserPane?
        _ = await pollUntil(deadline: Date().addingTimeInterval(Double(BrowserLimits.mountWaitMs) / 1000)) {
            found = services.pane(id)
            return found != nil
        }
        guard let page = found?.page else { return .object(["paneId": .string(id.rawValue), "loaded": false]) }

        // Unlike every other verb here, this one doesn't start the load: the page is created
        // with its URL already set, so it is loading before this can even look. A connection
        // refused to localhost lands within a few milliseconds, well before anything here
        // listens, so a listener attached from here would be far too late. The page's own
        // record of the failure of the load in flight caught it, and a main-frame failure means
        // that navigation is already over: there is nothing left to wait for, beyond the error
        // page it is showing having been committed.
        if let failure = page.lastLoadError {
            if page.isLoading { _ = await page.waitForLoadEnd(timeoutMs: 2_000) }
            var result = await NavigationPage.pageState(page)
            result["paneId"] = .string(id.rawValue)
            result["loaded"] = false
            result["loadError"] = .string(failure)
            return .object(result)
        }
        let outcome = await page.waitForLoadSettle(timeoutMs: BrowserLimits.loadWaitMs)
        var result = await NavigationPage.pageState(page)
        result["paneId"] = .string(id.rawValue)
        result["loaded"] = .bool(outcome.loaded)
        if let error = outcome.loadError { result["loadError"] = .string(error) }
        // Same contract as navigate's flag: only a first load that finished has "ended up"
        // anywhere worth comparing. The failure paths report loadError instead: an error
        // page's URL is not a redirect.
        if outcome.loaded { result["redirected"] = .bool(!isTrivialUrlChange(requested: url, final: page.url)) }
        return .object(result)
    }
}
