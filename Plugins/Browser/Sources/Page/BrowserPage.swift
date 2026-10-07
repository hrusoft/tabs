import AppKit
import TabsPluginSDK
import WebKit

/// The `WKWebView` behind a browser pane, with the behavior the pane and its
/// verbs rely on that `WKWebView` doesn't have of its own. One object owns the
/// page, hears the delegates and KVO, and records what they report:
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
/// - the pane's starting blank page, which is not a history entry;
/// - whether its document has the `LoopbackExemption` (C-10), which follows
///   the document through history as its status does.
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
    /// The plugin's `LoopbackExemption`, which this page turns on and off.
    private let loopbackExemption: LoopbackExemption
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
    /// The page's title as the browser shows it: the document's own, else a
    /// URL-derived stand-in (`fallbackTitle`).
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
    /// Whether the document has the `LoopbackExemption`, what the response of
    /// the navigation in flight said, and the list the content controller holds.
    private var exemptsLoopback = false
    private var pendingExemption: Bool?
    private var exemptionList: WKContentRuleList?
    private var inProvisional = false
    /// The navigation the last `load` or `reload` asked for, until it starts.
    /// Meanwhile the navigation it supersedes ends (cancelled), and the loading
    /// flag can drop between the two: neither is this load ending, and the page
    /// is still loading (`isLoading`, which a wait's poll reads).
    private var requested: WKNavigation?
    /// Where `requested` goes, as WebKit spells it (an origin with no path gains
    /// its `/`, scheme and host go lower case), and the document the last commit
    /// put up: a load that only moves the fragment of that document starts no
    /// navigation at all.
    private var requestedURL: URL?
    private var committedDocument: URL?
    private var pendingErrorPage = false
    private var lastKnownURL: String?
    private var observations: [NSKeyValueObservation] = []
    private var isDestroyed = false

    /// What a history entry's document had: its status and its exemption.
    private final class StatusBox {
        let status: DocumentStatus?
        let exemptsLoopback: Bool
        init(_ status: DocumentStatus?, exemptsLoopback: Bool) {
            self.status = status
            self.exemptsLoopback = exemptsLoopback
        }
    }

    /// - Parameters:
    ///   - dataStore: the plugin's own web data (`context.webDataStoreIdentifier`).
    ///   - url: the page to open, `about:blank` for none.
    ///   - loopbackExemption: the plugin's, shared by its pages.
    init(dataStore: UUID, url: String, loopbackExemption: LoopbackExemption) {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = WKWebsiteDataStore(forIdentifier: dataStore)
        configuration.setURLSchemeHandler(ErrorPageSchemeHandler(), forURLScheme: ErrorPage.scheme)
        LoopbackExemption.grant(configuration)
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
        self.loopbackExemption = loopbackExemption
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
    /// that failed, and a load asked for counts from the asking: `requested`).
    var isLoading: Bool { webView.isLoading || pendingErrorPage || requested != nil }
    var canGoBack: Bool { webView.canGoBack }
    var canGoForward: Bool { webView.canGoForward }
    var isShowingErrorPage: Bool { errorPage != nil }

    /// Whether the page is still on its starting blank: no load was ever
    /// issued (the starting `about:blank` issues none) and none is in flight.
    /// Such a page has no document, so no script that could start a
    /// navigation either: a wait for its load has nothing to wait for.
    var isOnStartingBlank: Bool { !hasLoaded && !isLoading }

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
            // A same-document navigation commits nothing: it ends here. One asked
            // for (a new fragment of this document) starts no navigation and no
            // delegate names it (measured): it is the load asked for, ending.
            syncSameDocumentNavigation()
            if requested != nil, !inProvisional, let target = requestedURL, webView.url == target,
                let document = committedDocument, Self.sameDocument(target, document)
            {
                requested = nil
            }
            // A navigation that ended before committing (in `inProvisional`) is
            // failing or was cancelled: which, and what follows (an error page),
            // the delegate is about to say. A load asked for and not yet started
            // is still to come.
            if !pendingErrorPage && !inProvisional && requested == nil { events.emit(.didStopLoading) }
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
    /// one committed and no navigation is in flight, that is what happened.
    private func syncSameDocumentNavigation() {
        guard !inProvisional, hasCommitted, let current = webView.url, ErrorPage.parse(current) == nil else { return }
        let string = current.absoluteString
        guard string != lastKnownURL else { return }
        lastKnownURL = string
        url = string
        // The new entry is the same document's: it answers with the same status,
        // whichever way a later history step reaches it.
        if let item = webView.backForwardList.currentItem {
            statusByItem.setObject(StatusBox(documentStatus, exemptsLoopback: exemptsLoopback), forKey: item)
        }
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
    /// before it is forgotten, as at the start of any load.
    func load(_ raw: String) {
        guard !isDestroyed, let target = URL(string: raw) else { return }
        if raw == Self.blank && !hasLoaded { return }
        hasLoaded = true
        lastLoadError = nil
        // An https loopback URL asked for stays https; the page it lands on decides again.
        exemptLoopback(false)
        if target.isFileURL {
            requested = webView.loadFileURL(target, allowingReadAccessTo: target.deletingLastPathComponent())
        } else {
            requested = webView.load(URLRequest(url: target))
        }
        // The web view shows the load asked for at once, in its own spelling (measured).
        requestedURL = webView.url ?? target
    }

    /// Reloads the page. On an error page it tries the failed URL again (a
    /// reload of the error document itself would show the same failure).
    func reload() {
        if let errorPage {
            load(errorPage.failedURL)
        } else if hasLoaded {
            lastLoadError = nil
            requested = webView.reload()
        }
    }

    func goBack() {
        guard webView.canGoBack else { return }
        lastLoadError = nil
        exemptLoopback(false)
        webView.goBack()
    }

    func goForward() {
        guard webView.canGoForward else { return }
        lastLoadError = nil
        exemptLoopback(false)
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

    /// Turns the `LoopbackExemption` on or off for the page's next requests: off
    /// before a load the app asks for; from a response, before its document is
    /// parsed; on a commit, as its history entry had it.
    private func exemptLoopback(_ exempts: Bool) {
        exemptsLoopback = exempts
        let list = exempts ? loopbackExemption.compiled : nil
        guard list !== exemptionList else { return }
        let content = webView.configuration.userContentController
        if let exemptionList { content.remove(exemptionList) }
        if let list { content.add(list) }
        exemptionList = list
    }

    /// `exemptLoopback`, compiling the list first if this is the first page to want it.
    private func exemptLoopbackCompiling(_ exempts: Bool) async {
        if exempts { _ = await loopbackExemption.ruleList() }
        exemptLoopback(exempts)
    }

    #if DEBUG
    /// A load issued past `load` (tests load fixture HTML directly) starts as
    /// any load does: the failure of the one before forgotten, the page no
    /// longer on its starting blank.
    func directLoadWillStart() {
        lastLoadError = nil
        hasLoaded = true
    }
    #endif

    // MARK: Waiting for a load

    /// Waits for the page to stop loading, capturing a main-frame load failure
    /// along the way. Event-driven on the load ending, with an `isLoading` poll
    /// as the fallback that resolves the cases that emit no loading events at
    /// all (a same-document back/forward, or a load that finished before this
    /// was called). The poll's first look comes a beat late on purpose: a
    /// same-document step raises no loading flag at all, and answering at once
    /// would answer before its URL moved. Only the starting blank, which no
    /// load or step has touched, answers at once.
    func waitForLoadEnd(timeoutMs: Int) async -> LoadOutcome {
        if isOnStartingBlank { return LoadOutcome(loaded: true) }
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
    /// navigation the page then starts by itself. For a navigation a page asks
    /// for during parse or its load event, WebKit lets the load in flight finish
    /// and starts the new one a moment later (a zero-delay timer), so the
    /// requested load reads as done while the page is about to leave. A
    /// navigation starting within `redirectQuietMs` of the load ending is that,
    /// and is waited out too, within the same budget. The starting blank has
    /// no document to start one: it is settled at once.
    ///
    /// A failure is watched for across the whole settle, not only within each
    /// wait: a navigation that fails at once (a refused connection) can fail
    /// between the moment it is seen to start and the next wait listening,
    /// when the main actor is busy, and the error page it shows then loads
    /// like any page.
    func waitForLoadSettle(timeoutMs: Int) async -> LoadOutcome {
        if isOnStartingBlank { return LoadOutcome(loaded: true) }
        let deadline = Date().addingTimeInterval(Double(timeoutMs) / 1000)
        var failure: String?
        let watch = events.subscribe { event in
            if case .didFailLoad(let name) = event { failure = name }
        }
        defer { watch.cancel() }
        var outcome = await waitForLoadEnd(timeoutMs: timeoutMs)
        while outcome.loaded, outcome.loadError == nil, await loadStarts(withinMs: BrowserLimits.redirectQuietMs) {
            let remainingMs = Int(deadline.timeIntervalSinceNow * 1000)
            guard remainingMs > 0 else { return LoadOutcome(loaded: false) }
            outcome = await waitForLoadEnd(timeoutMs: remainingMs)
            if outcome.loadError == nil, let failure { outcome = LoadOutcome(loaded: false, loadError: failure) }
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
    /// page can't settle (one a navigation orphaned: measured), so it is raced:
    /// a main-frame navigation, the page going away or the caller's task being
    /// cancelled answers `.unavailable` instead, and a late answer is ignored.
    /// A wait that must survive navigation uses
    /// `evaluate(_:completion:)` and runs its own race (`PageWait`).
    func evaluate(_ script: String) async -> Result<JSONValue, PageScriptError> {
        await call("return await (\(script))")
    }

    /// Runs a function `body` with `arguments` in `world`, raced as `evaluate`
    /// is: every script the page runs for the plugin goes through here or
    /// through `evaluate(_:completion:)`'s own race (`PageWait`).
    func call(_ body: String, arguments: [String: Any] = [:], in world: WKContentWorld = .page) async -> Result<
        JSONValue, PageScriptError
    > {
        let answer = OneShot<Result<JSONValue, PageScriptError>>()
        let subscription = events.subscribe { event in
            switch event {
            case .didNavigate, .destroyed: answer.resolve(.failure(.unavailable))
            default: break
            }
        }
        defer { subscription.cancel() }
        call(body, arguments: arguments, in: world) { answer.resolve($0) }
        return await withTaskCancellationHandler {
            await answer.wait()
        } onCancel: {
            Task { @MainActor in answer.resolve(.failure(.unavailable)) }
        }
    }

    func evaluate(_ script: String, completion: @escaping @MainActor (Result<JSONValue, PageScriptError>) -> Void) {
        call("return await (\(script))", in: .page, completion: completion)
    }

    private func call(
        _ body: String, arguments: [String: Any] = [:], in world: WKContentWorld,
        completion: @escaping @MainActor (Result<JSONValue, PageScriptError>) -> Void
    ) {
        guard !isDestroyed else { return completion(.failure(.unavailable)) }
        webView.callAsyncJavaScript(body, arguments: arguments, in: nil, in: world) { result in
            switch result {
            case .success(let value): completion(.success(JSONValue(webKitValue: value)))
            case .failure(let error): completion(.failure(Self.scriptError(error)))
            }
        }
    }

    /// Whether two URLs are one document's: equal but for the fragment.
    private static func sameDocument(_ one: URL, _ other: URL) -> Bool {
        func document(_ url: URL) -> String? {
            var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
            components?.fragment = nil
            return components?.string
        }
        return document(one) != nil && document(one) == document(other)
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
    /// document (`InputAcknowledgement`); nil when the page can't say: it runs
    /// no script, it navigated away or went before answering (`call`: a read
    /// a navigation orphaned would otherwise never answer, as after an Enter
    /// that submits a form), or it didn't answer within `timeoutMs` (a page
    /// busy in a script of its own).
    func inputCounts(timeoutMs: Int) async -> InputCounts? {
        let seen = InputAcknowledgement.counters
        let script = "return [\(seen).mouseup, \(seen).keyup, \(seen).input, \(seen).mousemove]"
        let answer = OneShot<InputCounts?>()
        let read = Task { @MainActor in
            let result = await call(script, in: .world(name: ConsoleCapture.errorWorldName))
            guard case .success(.array(let numbers)) = result, numbers.count == 4,
                let mouseup = numbers[0].intValue, let keyup = numbers[1].intValue, let input = numbers[2].intValue,
                let mousemove = numbers[3].intValue
            else { return answer.resolve(nil) }
            answer.resolve(InputCounts(mouseup: Int(mouseup), keyup: Int(keyup), input: Int(input), mousemove: Int(mousemove)))
        }
        let budget = Task { @MainActor in
            await delay(milliseconds: timeoutMs)
            answer.resolve(nil)
        }
        let counts = await answer.wait()
        read.cancel()
        budget.cancel()
        return counts
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

/// A `WKWebView` for a pane: no context menu of its own, the app's shortcuts
/// kept out of the page's hands, and the first click into an inactive window
/// acting rather than only focusing.
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
            return cancel()
        }
        // A pane an agent drives can't be steered outside the scheme allowlist
        // by the page itself (`location.href`, a link): the verbs' own check is
        // the front door, and this is the back one. A user's pane is unconstrained.
        if isControlled(), target.scheme != ErrorPage.scheme, !isAllowedUrl(target.absoluteString) { return cancel() }
        return .allow
    }

    /// A main-frame navigation refused: it never starts, so a load asked for
    /// (this one, most likely) is no longer to come.
    private func cancel() -> WKNavigationActionPolicy {
        requested = nil
        return .cancel
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse) async -> WKNavigationResponsePolicy {
        let http = navigationResponse.response as? HTTPURLResponse
        let exempts = wantsLoopbackExemption(
            url: navigationResponse.response.url, contentSecurityPolicy: http?.value(forHTTPHeaderField: "Content-Security-Policy"))
        if navigationResponse.isForMainFrame {
            if let http, http.statusCode >= 100 {
                pendingStatus = DocumentStatus(status: http.statusCode, statusText: HTTPStatusText.phrase(for: http.statusCode))
            } else {
                pendingStatus = nil
            }
            pendingExemption = exempts
            await exemptLoopbackCompiling(exempts)
        } else if exempts {
            // A frame's document can want it too; the page's next document decides again.
            await exemptLoopbackCompiling(true)
        }
        return .allow
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        inProvisional = true
        if navigation === requested { requested = nil }
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
        committedDocument = current
        let item = webView.backForwardList.currentItem
        if let parsed = ErrorPage.parse(current) {
            errorPage = parsed
            url = parsed.failedURL
            // A history step onto a failed entry knows why it failed.
            lastLoadError = parsed.code
            documentStatus = nil
            exemptLoopback(false)
        } else {
            errorPage = nil
            url = current.absoluteString
            // A history step served without the network has no response to
            // read: the entry remembers the status and exemption it had.
            let entry = item.flatMap { statusByItem.object(forKey: $0) }
            documentStatus = pendingStatus ?? entry?.status
            exemptLoopback(pendingExemption ?? entry?.exemptsLoopback ?? false)
        }
        pendingStatus = nil
        pendingExemption = nil
        if let item { statusByItem.setObject(StatusBox(documentStatus, exemptsLoopback: exemptsLoopback), forKey: item) }
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
        loadDidFail(navigation, error)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
        loadDidFail(navigation, error)
    }

    /// A main-frame failure is also a *commit*: the page is replaced with an
    /// error page, a new document at the failed URL (`ErrorPage`). So the
    /// failure is recorded, and the error page is loaded like any navigation.
    private func loadDidFail(_ navigation: WKNavigation?, _ error: any Error) {
        inProvisional = false
        if navigation === requested { requested = nil }
        let ns = error as NSError
        let failingURL = ns.userInfo[NSURLErrorFailingURLErrorKey] as? URL
        if failingURL?.scheme == ErrorPage.scheme {
            // The error page itself failed to load: nothing more to show.
            pendingErrorPage = false
            events.emit(.didStopLoading)
            return
        }
        guard let code = LoadErrors.name(for: ns) else {
            // Superseded or cancelled: nothing to show, but the load has ended,
            // unless it was superseded by a load asked for and not yet started.
            if !webView.isLoading && !pendingErrorPage && requested == nil { events.emit(.didStopLoading) }
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
