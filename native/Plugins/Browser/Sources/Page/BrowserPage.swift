import AppKit
import TabsPluginSDK
import WebKit

/// The `WKWebView` behind a browser pane, with the behavior the pane and its
/// verbs rely on that `WKWebView` doesn't have of its own. The Electron app's
/// guest is a `<webview>` that emits events for all of this
/// (`renderer/BrowserRenderer.tsx`, `browserRegistry.ts`); here one object owns
/// the page, hears the delegates and KVO, and records what the events carried:
///
/// - the URL of the last **committed** main-frame document, kept in step with
///   in-page navigations (`url`), and the seed until something commits;
/// - the HTTP status of that document (`documentStatus`), from the navigation
///   response (100 or more; none for `about:blank` or an error page);
/// - the failure of the load in flight (`lastLoadError`), named as Chromium
///   names it and cleared when the next load starts, recorded from the moment
///   the page exists so a failure that lands before anything listens is known;
/// - the console (`console`), cleared on a committed document but not on an
///   in-page navigation, captured by scripts injected at document start;
/// - the pane's starting blank page, which is not a history entry.
///
/// A moved pane keeps its page: the view is an AppKit view and keeps its state
/// wherever core puts it, so nothing here reattaches, and `pageInstance` is
/// stable for as long as the object lives.
@MainActor
final class BrowserPage: NSObject {
    /// The seed URL of a new pane.
    static let blank = "about:blank"

    let webView: BrowserWebView
    let console = RingLog<ConsoleEntry>(capacity: BrowserLimits.consoleCapacity)
    let events = PageEvents()
    /// Changes exactly when the page is re-created: never for a move.
    let pageInstance = UUID().uuidString.prefix(8).lowercased()

    /// Whether another pane controls this one (an agent created it): its
    /// popups are denied, and a navigation the page itself starts is held to
    /// `isAllowedUrl`. Asked at every decision, since ownership is granted
    /// after the pane exists.
    var isControlled: () -> Bool = { false }
    /// Where a popup's URL goes for a user's pane (the OS's browser).
    var openExternal: (URL) -> Void = { NSWorkspace.shared.open($0) }
    /// Something the chrome shows changed (URL, title, history, loading).
    var onChange: (() -> Void)?
    /// The page's title, whenever it changes (live: the pane's title).
    var onTitle: ((String) -> Void)?

    /// The last committed main-frame document's URL (the seed until then).
    private(set) var url: String
    private(set) var documentStatus: DocumentStatus?
    /// Why the load in flight failed, as an `ERR_*` name, or nil.
    fileprivate(set) var lastLoadError: String?
    /// The page's title as the browser shows it: the document's own, else the
    /// URL-derived stand-in Chromium shows.
    private(set) var title = ""
    /// The failed page the view is showing, if it is.
    private(set) var errorPage: (failedURL: String, code: String)?

    /// Whether anything has committed yet. The pane's starting `about:blank` is
    /// never loaded at all, so it is never a history entry: the first real
    /// navigation leaves Back disabled, and a later, deliberate `about:blank`
    /// keeps its history (measured: an explicit `about:blank` load *is* a Back
    /// target on WebKit, so the starting blank must simply not be loaded).
    private(set) var hasCommitted = false
    /// Whether a load was ever issued (the starting blank issues none).
    private var hasLoaded = false
    private var pendingStatus: DocumentStatus?
    private var statusByItem = NSMapTable<WKBackForwardListItem, StatusBox>.weakToStrongObjects()
    private var inProvisional = false
    private var pendingErrorPage = false
    private var lastKnownURL: String?
    private var observations: [NSKeyValueObservation] = []
    private var isDestroyed = false

    private final class StatusBox {
        let status: DocumentStatus?
        init(_ status: DocumentStatus?) { self.status = status }
    }

    /// - Parameters:
    ///   - dataStore: the plugin's own web data (`context.webDataStoreIdentifier`).
    ///   - url: the page to open, `about:blank` for none.
    init(dataStore: UUID, url: String) {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = WKWebsiteDataStore(forIdentifier: dataStore)
        configuration.setURLSchemeHandler(ErrorPageSchemeHandler(), forURLScheme: ErrorPage.scheme)
        let proxy = ConsoleMessageProxy()
        let content = configuration.userContentController
        content.add(proxy, name: ConsoleCapture.pageHandlerName)
        content.addUserScript(WKUserScript(source: ConsoleCapture.pageScript, injectionTime: .atDocumentStart, forMainFrameOnly: false))
        let errorWorld = WKContentWorld.world(name: ConsoleCapture.errorWorldName)
        content.add(proxy, contentWorld: errorWorld, name: ConsoleCapture.errorHandlerName)
        content.addUserScript(
            WKUserScript(source: ConsoleCapture.errorScript, injectionTime: .atDocumentStart, forMainFrameOnly: false, in: errorWorld))
        content.addUserScript(
            WKUserScript(source: InputAcknowledgement.script, injectionTime: .atDocumentStart, forMainFrameOnly: true, in: errorWorld))
        webView = BrowserWebView(frame: NSRect(x: 0, y: 0, width: 400, height: 300), configuration: configuration)
        self.url = url.isEmpty ? Self.blank : url
        super.init()
        proxy.page = self
        webView.navigationDelegate = self
        webView.uiDelegate = self
        // A page that draws no background is white, as the browser's blank page
        // is, in either appearance.
        webView.underPageBackgroundColor = .white
        #if DEBUG
        webView.isInspectable = true
        #endif
        observe()
        title = fallbackTitle(forURL: self.url)
        if self.url != Self.blank { load(self.url) }
    }

    // MARK: State

    /// Whether a load is in flight (an error page counts as part of the load
    /// that failed).
    var isLoading: Bool { webView.isLoading || pendingErrorPage }
    var canGoBack: Bool { webView.canGoBack }
    var canGoForward: Bool { webView.canGoForward }
    var isShowingErrorPage: Bool { errorPage != nil }

    /// Whether the page is on screen: in a window, not hidden, with a size.
    var isVisible: Bool {
        webView.window != nil && !webView.isHiddenOrHasHiddenAncestor && webView.bounds.width > 0 && webView.bounds.height > 0
    }

    private func observe() {
        observations = [
            webView.observe(\.url) { [weak self] _, _ in MainActor.assumeIsolated { self?.urlDidChange() } },
            webView.observe(\.title) { [weak self] _, _ in MainActor.assumeIsolated { self?.updateTitle() } },
            webView.observe(\.isLoading) { [weak self] web, _ in
                MainActor.assumeIsolated { self?.loadingDidChange(web.isLoading) }
            },
            webView.observe(\.canGoBack) { [weak self] _, _ in MainActor.assumeIsolated { self?.onChange?() } },
            webView.observe(\.canGoForward) { [weak self] _, _ in MainActor.assumeIsolated { self?.onChange?() } },
        ]
    }

    private func loadingDidChange(_ loading: Bool) {
        if loading {
            events.emit(.didStartLoading)
        } else {
            // A same-document navigation commits nothing: it ends here.
            syncSameDocumentNavigation()
            // A navigation that ended before committing (in `inProvisional`) is
            // failing or was cancelled: which, and what follows (an error page),
            // the delegate is about to say.
            if !pendingErrorPage && !inProvisional { events.emit(.didStopLoading) }
        }
        onChange?()
    }

    private func urlDidChange() {
        if !webView.isLoading { syncSameDocumentNavigation() }
        onChange?()
    }

    /// A same-document navigation (a `pushState`, a hash, a history step within
    /// one document) commits no document, so no delegate hears of it: the URL
    /// moves while nothing loads. When the web view's URL differs from the last
    /// one committed and no navigation is in flight, that is what happened
    /// (`did-navigate-in-page`).
    private func syncSameDocumentNavigation() {
        guard !inProvisional, hasCommitted, let current = webView.url, ErrorPage.parse(current) == nil else { return }
        let string = current.absoluteString
        guard string != lastKnownURL else { return }
        lastKnownURL = string
        url = string
        // The new entry is the same document's: it answers with the same status,
        // whichever way a later history step reaches it.
        if let item = webView.backForwardList.currentItem { statusByItem.setObject(StatusBox(documentStatus), forKey: item) }
        events.emit(.didNavigateInPage(string))
        onChange?()
    }

    private func updateTitle() {
        let next: String
        if let errorPage {
            next = URL(string: errorPage.failedURL)?.host ?? errorPage.failedURL
        } else {
            let own = webView.title ?? ""
            next = own.isEmpty ? fallbackTitle(forURL: url) : own
        }
        guard next != title else { return }
        title = next
        events.emit(.titleDidChange)
        onTitle?(next)
        onChange?()
    }

    // MARK: Navigating

    /// Loads `raw` (the address bar's Return, a verb). The pane's starting blank
    /// stays where it is for an `about:blank` load, and the failure of the load
    /// before it is forgotten, as `did-start-loading` forgets it.
    func load(_ raw: String) {
        guard !isDestroyed, let target = URL(string: raw) else { return }
        if raw == Self.blank && !hasLoaded { return }
        hasLoaded = true
        lastLoadError = nil
        if target.isFileURL {
            webView.loadFileURL(target, allowingReadAccessTo: target.deletingLastPathComponent())
        } else {
            webView.load(URLRequest(url: target))
        }
    }

    /// Reloads the page. On an error page it tries the failed URL again (a
    /// reload of the error document itself would show the same failure).
    func reload() {
        if let errorPage {
            load(errorPage.failedURL)
        } else if hasLoaded {
            lastLoadError = nil
            webView.reload()
        }
    }

    func goBack() {
        guard webView.canGoBack else { return }
        lastLoadError = nil
        webView.goBack()
    }

    func goForward() {
        guard webView.canGoForward else { return }
        lastLoadError = nil
        webView.goForward()
    }

    /// Ends the page: nothing more is loaded, listeners are told, the console
    /// handlers (which retain their target) are released.
    func destroy() {
        guard !isDestroyed else { return }
        isDestroyed = true
        observations.removeAll()
        webView.stopLoading()
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
        let content = webView.configuration.userContentController
        content.removeAllScriptMessageHandlers()
        content.removeAllUserScripts()
        events.emit(.destroyed)
    }

    #if DEBUG
    /// A load starting forgets the failure of the one before (tests load fixture
    /// HTML directly).
    func lastLoadErrorReset() { lastLoadError = nil }
    #endif

    // MARK: Waiting for a load

    /// Waits for the page to stop loading, capturing a main-frame load failure
    /// along the way. Event-driven on the load ending, with an `isLoading` poll
    /// as the fallback that resolves the cases that emit no loading events at
    /// all (a same-document back/forward, or a load that finished before this
    /// was called).
    func waitForLoadEnd(timeoutMs: Int) async -> LoadOutcome {
        let done = OneShot<Bool>()
        var loadError: String?
        let subscription = events.subscribe { event in
            switch event {
            case .didStopLoading: done.resolve(true)
            case .didFailLoad(let name): loadError = name
            case .destroyed: done.resolve(false)
            default: break
            }
        }
        let poll = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                await delay(milliseconds: 250)
                if self?.isLoading == false { done.resolve(true) }
            }
        }
        let timeout = Task { @MainActor in
            await delay(milliseconds: timeoutMs)
            done.resolve(false)
        }
        let loaded = await done.wait()
        subscription.cancel()
        poll.cancel()
        timeout.cancel()
        return loadError.map { LoadOutcome(loaded: false, loadError: $0) } ?? LoadOutcome(loaded: loaded)
    }

    /// `waitForLoadEnd` for a load a verb asked for, followed through any
    /// navigation the page then starts by itself. Chromium starts a navigation
    /// a page asks for during parse or its load event at once, superseding the
    /// load in flight; WebKit lets the load finish and starts it a moment later
    /// (a zero-delay timer), so the requested load reads as done while the page
    /// is about to leave. A navigation starting within `redirectQuietMs` of
    /// the load ending is that, and is waited out too, within the same budget.
    func waitForLoadSettle(timeoutMs: Int) async -> LoadOutcome {
        let deadline = Date().addingTimeInterval(Double(timeoutMs) / 1000)
        var outcome = await waitForLoadEnd(timeoutMs: timeoutMs)
        while outcome.loaded, outcome.loadError == nil, await loadStarts(withinMs: BrowserLimits.redirectQuietMs) {
            let remainingMs = Int(deadline.timeIntervalSinceNow * 1000)
            guard remainingMs > 0 else { return LoadOutcome(loaded: false) }
            outcome = await waitForLoadEnd(timeoutMs: remainingMs)
            if outcome.loadError != nil { outcome.failedURL = url }
        }
        return outcome
    }

    /// Whether a load is in flight now or starts within `ms`.
    private func loadStarts(withinMs ms: Int) async -> Bool {
        if isLoading { return true }
        let started = OneShot<Bool>()
        let subscription = events.subscribe { event in
            switch event {
            case .didStartLoading: started.resolve(true)
            case .destroyed: started.resolve(false)
            default: break
            }
        }
        let quiet = Task { @MainActor in
            await delay(milliseconds: ms)
            started.resolve(false)
        }
        let result = await started.wait()
        subscription.cancel()
        quiet.cancel()
        return result
    }

    // MARK: Running script

    /// Runs `script` (an expression) in the page's own world and answers with
    /// its value, awaiting a promise. The answer never comes for a promise the
    /// page can't settle (one a navigation orphaned: measured, the same as on
    /// Chromium), so a wait that must survive navigation uses `evaluate(_:completion:)`
    /// and races the answer (`PageWait`).
    func evaluate(_ script: String) async -> Result<JSONValue, PageScriptError> {
        await withCheckedContinuation { continuation in
            evaluate(script) { continuation.resume(returning: $0) }
        }
    }

    func evaluate(_ script: String, completion: @escaping @MainActor (Result<JSONValue, PageScriptError>) -> Void) {
        guard !isDestroyed else { return completion(.failure(.unavailable)) }
        webView.callAsyncJavaScript("return await (\(script))", arguments: [:], in: nil, in: .page) { result in
            switch result {
            case .success(let value): completion(.success(JSONValue(webKitValue: value)))
            case .failure(let error): completion(.failure(Self.scriptError(error)))
            }
        }
    }

    private static func scriptError(_ error: any Error) -> PageScriptError {
        let ns = error as NSError
        guard ns.domain == WKError.errorDomain else { return .unavailable }
        switch WKError.Code(rawValue: ns.code) {
        case .javaScriptExceptionOccurred:
            return .exception(ns.userInfo["WKJavaScriptExceptionMessage"] as? String ?? ns.localizedDescription)
        case .javaScriptResultTypeIsUnsupported:
            return .unsupportedResult
        default:
            return .unavailable
        }
    }

    /// The page's own viewport and scale, read from the page: exact by
    /// definition, where the view's own size is a rounded stand-in. The
    /// fallback (a page that can't run script, or one too busy to answer in
    /// 500 ms) is the view's size and its window's scale. nil for a page that
    /// isn't on screen: never an invented viewport.
    func viewport() async -> PageViewport? {
        guard isVisible else { return nil }
        let answer = OneShot<PageViewport?>()
        evaluate("[window.innerWidth, window.innerHeight, window.devicePixelRatio]") { result in
            if case .success(.array(let numbers)) = result, numbers.count == 3,
                let width = numbers[0].doubleValue, let height = numbers[1].doubleValue, let scale = numbers[2].doubleValue,
                width > 0, height > 0, scale > 0
            {
                answer.resolve(PageViewport(width: width, height: height, scaleFactor: scale))
            } else {
                answer.resolve(nil)
            }
        }
        let budget = Task { @MainActor in
            await delay(milliseconds: 500)
            answer.resolve(nil)
        }
        let read = await answer.wait()
        budget.cancel()
        if let read { return read }
        return PageViewport(
            width: Double(webView.bounds.width).rounded(.up), height: Double(webView.bounds.height).rounded(.up),
            scaleFactor: Double(webView.window?.backingScaleFactor ?? 1))
    }

    /// The page's pixels as a PNG: the whole view, or `rect` (in CSS pixels of
    /// the page). nil when the page isn't on screen, or the engine has nothing to give.
    func snapshot(rect: CGRect? = nil) async -> PageSnapshot? {
        guard webView.window != nil else { return nil }
        let configuration = WKSnapshotConfiguration()
        if let rect { configuration.rect = rect }
        guard let image = try? await webView.takeSnapshot(configuration: configuration),
            let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
            let png = NSBitmapImageRep(cgImage: cgImage).representation(using: .png, properties: [:])
        else { return nil }
        return PageSnapshot(png: png, pixelWidth: cgImage.width, pixelHeight: cgImage.height)
    }

    /// How many input events have completed a gesture in the page's current
    /// document (`InputAcknowledgement`); nil when the page can't say.
    func inputCounts() async -> InputCounts? {
        let seen = InputAcknowledgement.counters
        let script = "return [\(seen).mouseup, \(seen).keyup, \(seen).input, \(seen).mousemove]"
        let world = WKContentWorld.world(name: ConsoleCapture.errorWorldName)
        guard let value = try? await webView.callAsyncJavaScript(script, arguments: [:], in: nil, contentWorld: world),
            case .array(let numbers) = JSONValue(webKitValue: value), numbers.count == 4,
            let mouseup = numbers[0].intValue, let keyup = numbers[1].intValue, let input = numbers[2].intValue,
            let mousemove = numbers[3].intValue
        else { return nil }
        return InputCounts(mouseup: Int(mouseup), keyup: Int(keyup), input: Int(input), mousemove: Int(mousemove))
    }

    // MARK: Console

    fileprivate func consoleMessage(_ body: Any) {
        guard let message = body as? [String: Any], let text = message["text"] as? String else { return }
        let entry = ConsoleEntry(
            level: message["level"] as? String ?? "info", text: text, timestamp: (Date().timeIntervalSince1970 * 1000).rounded(),
            sourceURL: (message["source"] as? String).flatMap { $0.isEmpty ? nil : $0 }, line: (message["line"] as? NSNumber)?.intValue)
        console.add(entry)
    }
}

/// A `WKWebView` for a pane: no context menu of its own (the Electron app's
/// `<webview>` has none), the app's shortcuts kept out of the page's hands,
/// and the first click into an inactive window acting rather than only
/// focusing.
final class BrowserWebView: WKWebView {
    /// Whether `event` is a shortcut the app has bound (`PaneContext.isAppShortcut`).
    var isAppShortcut: (NSEvent) -> Bool = { _ in false }

    /// Every app shortcut reaches the app from a focused page: a `WKWebView`
    /// would otherwise keep the chords it recognizes; the page's own shortcuts
    /// are untouched.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if isAppShortcut(event) { return false }
        return super.performKeyEquivalent(with: event)
    }

    override func menu(for event: NSEvent) -> NSMenu? { nil }

    /// The pane's own undo history (docs/PLUGINS.md: a window's is shared by all its
    /// tabs, and a pane can move to another window). The page registers what typing
    /// and editing commands did with the view's undo manager; Edit ▸ Undo and Redo
    /// are answered here, since the web view itself answers neither.
    private let paneUndoManager = UndoManager()
    override var undoManager: UndoManager? { paneUndoManager }
    @objc func undo(_ sender: Any?) { paneUndoManager.undo() }
    @objc func redo(_ sender: Any?) { paneUndoManager.redo() }

    override func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
        switch item.action {
        case #selector(undo(_:)): paneUndoManager.canUndo
        case #selector(redo(_:)): paneUndoManager.canRedo
        default: super.validateUserInterfaceItem(item)
        }
    }

    override func willOpenMenu(_ menu: NSMenu, with event: NSEvent) {
        menu.removeAllItems()
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// Retains no page: the web view's content controller keeps its handlers for
/// good, and a handler that held the page would keep the page (and so the web
/// view) alive around a cycle.
@MainActor
private final class ConsoleMessageProxy: NSObject, WKScriptMessageHandler {
    weak var page: BrowserPage?

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        page?.consoleMessage(message.body)
    }
}

// MARK: - Navigation

extension BrowserPage: WKNavigationDelegate {
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
        guard navigationAction.targetFrame?.isMainFrame == true, let target = navigationAction.request.url else { return .allow }
        // The page's own way out to the OS: a mail link opens the mail client,
        // for a user's pane only.
        if target.scheme == "mailto" {
            if !isControlled(), isSafeExternalUrl(target.absoluteString) { openExternal(target) }
            return .cancel
        }
        // A pane an agent drives can't be steered outside the scheme allowlist
        // by the page itself (`location.href`, a link): the verbs' own check is
        // the front door, and this is the back one. A user's pane is unconstrained.
        if isControlled(), target.scheme != ErrorPage.scheme, !isAllowedUrl(target.absoluteString) { return .cancel }
        return .allow
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse) async -> WKNavigationResponsePolicy {
        if navigationResponse.isForMainFrame {
            if let http = navigationResponse.response as? HTTPURLResponse, http.statusCode >= 100 {
                pendingStatus = DocumentStatus(status: http.statusCode, statusText: HTTPStatusText.phrase(for: http.statusCode))
            } else {
                pendingStatus = nil
            }
        }
        return .allow
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        inProvisional = true
        // The failure of the load before this one is forgotten, unless this is
        // the error page that failure is showing.
        if !pendingErrorPage { lastLoadError = nil }
    }

    /// A new main-frame document committed: a page, or the error page a failed
    /// load shows. Its console starts empty (safe on commit: the page's own
    /// scripts don't run until after this, so nothing of theirs is captured yet),
    /// and its URL is where a re-created pane returns to.
    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        inProvisional = false
        hasCommitted = true
        console.clear()
        guard let current = webView.url else { return }
        let item = webView.backForwardList.currentItem
        if let parsed = ErrorPage.parse(current) {
            errorPage = parsed
            url = parsed.failedURL
            // A history step onto a failed entry knows why it failed.
            lastLoadError = parsed.code
            documentStatus = nil
        } else {
            errorPage = nil
            url = current.absoluteString
            // A history step served without the network has no response to
            // read: the entry remembers the status it had.
            documentStatus = pendingStatus ?? item.flatMap { statusByItem.object(forKey: $0)?.status }
        }
        pendingStatus = nil
        if let item { statusByItem.setObject(StatusBox(documentStatus), forKey: item) }
        lastKnownURL = current.absoluteString
        updateTitle()
        events.emit(.didNavigate(url))
        onChange?()
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        // A commit clears the title WebKit reports and sets it again once the
        // document has one: this is the settled read.
        let showedErrorPage = pendingErrorPage
        pendingErrorPage = false
        updateTitle()
        // The load a failure started ends with its error page, which the web
        // view's own loading flag (already false by now) didn't wait for.
        if showedErrorPage, !webView.isLoading { events.emit(.didStopLoading) }
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) {
        loadDidFail(error)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
        loadDidFail(error)
    }

    /// A main-frame failure is also a *commit*: Chromium replaces the page with
    /// its own error page, a new document at the failed URL. So the failure is
    /// recorded, and the error page is loaded like any navigation.
    private func loadDidFail(_ error: any Error) {
        inProvisional = false
        let ns = error as NSError
        let failingURL = ns.userInfo[NSURLErrorFailingURLErrorKey] as? URL
        if failingURL?.scheme == ErrorPage.scheme {
            // The error page itself failed to load: nothing more to show.
            pendingErrorPage = false
            events.emit(.didStopLoading)
            return
        }
        guard let code = LoadErrors.name(for: ns) else {
            // Superseded or cancelled: nothing to show, but the load has ended.
            if !webView.isLoading && !pendingErrorPage { events.emit(.didStopLoading) }
            return
        }
        let failing = failingURL?.absoluteString ?? (ns.userInfo[NSURLErrorFailingURLStringErrorKey] as? String) ?? url
        lastLoadError = code
        pendingErrorPage = true
        events.emit(.didFailLoad(code))
        webView.load(URLRequest(url: ErrorPage.url(failedURL: failing, code: code)))
    }
}

// MARK: - Popups

extension BrowserPage: WKUIDelegate {
    /// `target=_blank` and `window.open` never open a window of the app: a
    /// user's pane sends the URL to the OS's browser (`http`, `https` and
    /// `mailto` only: a `file:` or custom scheme is dropped), an agent's pane
    /// drops it, so a page an agent is driving can't reach outside its pane.
    func webView(
        _ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        if !isControlled(), let target = navigationAction.request.url, isSafeExternalUrl(target.absoluteString) {
            openExternal(target)
        }
        return nil
    }
}
