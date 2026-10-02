import AppKit
import TabsPluginSDK

/// One browser pane: a web page in a pane, with back, forward, refresh and an
/// address bar in the pane's header. A port of the Electron app's
/// `BrowserRenderer.tsx` (the guest, its focus and its events) and the state
/// half of `BrowserHeaderTitle.tsx`; the views draw what this holds and report
/// what the user does.
///
/// `config.url` is where the pane is, and its whole state: written back on every
/// committed document, in-page navigation and error page, so a duplicated pane
/// or a relaunch resumes at the current page rather than the seed.
///
/// The pane's body is the page's view and nothing else; the nav chrome is the
/// header's title (`headerTitle`). A moved pane keeps its page (an AppKit view
/// keeps its state wherever core puts it), so there is nothing to reattach and
/// no page to reload.
@MainActor
final class BrowserPane: PaneController {
    let pane: any PaneContext
    let page: BrowserPage
    private var config: [String: JSONValue]
    /// The URL last written into `config`.
    private var savedURL: String

    /// The pane that controls this one (an agent created it), if any: what makes
    /// its popups denied and its navigation allowlisted. Integration hands it
    /// core's answer (`PaneContext.controller`), read live: it is set before the
    /// first load resolves, so a controlled pane's guards apply to its first page.
    var controller: () -> PaneID? = { nil }
    /// Whether keyboard focus is owed to the page but couldn't be given yet (the
    /// pane isn't in a window).
    private var pendingFocus = false
    /// The header's nav chrome, built when the header first asks for it.
    private(set) var toolbar: BrowserToolbar?

    init(pane: any PaneContext, dataStore: UUID, openExternal: ((URL) -> Void)? = nil) throws {
        switch pane.initialConfig {
        case .object(let object): config = object
        case .null: config = [:]
        default: throw BrowserConfigError("a browser's config must be an object")
        }
        if let url = config["url"], url != .null, url.stringValue == nil {
            throw BrowserConfigError("a browser's url must be a string")
        }
        // A pane opened with no URL starts on about:blank.
        let url = config["url"]?.stringValue ?? BrowserPage.blank
        self.pane = pane
        savedURL = url
        page = BrowserPage(dataStore: dataStore, url: url)
        if let openExternal { page.openExternal = openExternal }
        controller = { [weak pane] in pane?.controller }
        page.isControlled = { [weak self] in self?.controller() != nil }
        page.onChange = { [weak self] in self?.pageDidChange() }
        page.onTitle = { [weak pane] title in pane?.setTitle(title.isEmpty ? "Browser" : title) }
        page.webView.isAppShortcut = { [weak pane] event in pane?.isAppShortcut(event) ?? false }
        page.webView.setAccessibilityIdentifier("browser-page")
        if !page.title.isEmpty { pane.setTitle(page.title) }
    }

    // MARK: PaneController

    /// The page fills the body, and nothing else does.
    var view: NSView { page.webView }

    /// The nav chrome, in the header's title slot in place of the title text.
    var headerTitle: NSView? {
        if toolbar == nil { toolbar = BrowserToolbar(pane: self) }
        return toolbar
    }

    func currentConfig() -> JSONValue {
        var current = config
        current["url"] = .string(page.url)
        return .object(current)
    }

    /// Activation gives the page the keyboard, unless the keyboard is already in
    /// the pane's own header (the address bar, a nav button): a press there
    /// activates the pane too, and the page must not yank focus off what the user
    /// just chose. Deferred while the pane isn't in a window, to when it is.
    func focus() {
        guard let window = page.webView.window else {
            pendingFocus = true
            return
        }
        pendingFocus = false
        if focusIsInChrome(window) { return }
        window.makeFirstResponder(page.webView)
    }

    func paneDidShow() {
        if pendingFocus { focus() }
    }

    func paneAppearanceDidChange(theme: PaneTheme, depth: Int) {
        toolbar?.theme = theme
    }

    func paneWillClose() {
        page.destroy()
    }

    /// Whether the window's keyboard focus is inside this pane's header toolbar:
    /// a field's shared editor stands in for the field being edited.
    func focusIsInChrome(_ window: NSWindow) -> Bool {
        guard let toolbar else { return false }
        var responder = window.firstResponder
        if let text = responder as? NSText, let owner = text.delegate as? NSResponder { responder = owner }
        guard let view = responder as? NSView else { return false }
        return view === toolbar || view.isDescendant(of: toolbar)
    }

    // MARK: What `list-panes` and `pane-info` say

    var controlSummary: JSONValue? { .object(listSummaryFields()) }

    func controlDescription() async -> PaneControlDescription { .fields(await paneInfoFields()) }

    /// `list-panes`' summary of the pane beyond its id, type and title: the URL, as the
    /// pane's config would save it now (the committed document's, an error page's included),
    /// which works whether or not the pane is mounted.
    func listSummaryFields() -> [String: JSONValue] {
        ["url": currentConfig()["url"] ?? .string("")]
    }

    /// `pane-info`'s live fields, or nil for a pane that isn't mounted (it has no
    /// page on screen to read): `url`, `title`, `isLoading`, `canGoBack`, `canGoForward`,
    /// `pageInstance` (changes exactly when the page is re-created), `showingErrorPage` and
    /// `loadError` only on an error page, and `viewport` (the page's own `innerWidth ×
    /// innerHeight`) or `hidden: true` for a pane not shown: never an invented viewport.
    func paneInfoFields() async -> [String: JSONValue] {
        var fields: [String: JSONValue] = [
            "pageInstance": .string(String(page.pageInstance)),
            "url": .string(page.url),
            "title": .string(page.title),
            "isLoading": .bool(page.isLoading),
            "canGoBack": .bool(page.canGoBack),
            "canGoForward": .bool(page.canGoForward),
        ]
        if let error = page.lastLoadError {
            fields["showingErrorPage"] = true
            fields["loadError"] = .string(error)
        }
        if let viewport = await page.viewport() {
            fields["viewport"] = .object(["width": .double(viewport.width), "height": .double(viewport.height)])
        } else {
            fields["hidden"] = true
        }
        return fields
    }

    // MARK: The header

    /// Return in the address bar: navigates to what the input resolves to (a URL,
    /// a bare domain, or a search); blank does nothing.
    func navigate(toAddress text: String) {
        if let url = resolveAddressInput(text) { page.load(url) }
    }

    private func pageDidChange() {
        if page.url != savedURL {
            savedURL = page.url
            pane.configDidChange()
        }
        toolbar?.sync()
    }
}

/// A saved browser config this build can't read: the pane is kept verbatim,
/// unavailable, rather than replaced by a blank one.
struct BrowserConfigError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}
