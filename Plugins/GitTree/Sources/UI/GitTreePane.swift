import AppKit
import TabsPluginSDK

/// One git tree pane: a repository's commit graph, with the selected commit's
/// details below it. The views only draw what this holds and report what the
/// user does.
///
/// `config.cwd` is the directory the pane looks at, and its whole subject:
/// written back on every change, so a relaunch reopens the same repository.
/// Every git failure is a sentence in place of the list, never a dead end.
@MainActor
final class GitTreePane: PaneController {
    /// Commits per page: most repositories need no second read, and a huge
    /// one stays instant.
    static let pageSize = 500
    /// A held arrow key traverses many rows a second; only the row the
    /// selection settles on is worth two git spawns.
    static let detailDebounce: Duration = .milliseconds(100)

    let pane: any PaneContext
    let settings: PluginSettings<GitTreeSettings>
    private let services: GitTreeServices
    private lazy var source: any GitSource = services.source(for: pane)

    private var config: [String: JSONValue]

    /// The log: nil while the first page is being read ("Reading history…").
    private(set) var log: GitLogResult?
    /// Bumped whenever `log` is replaced, so a Load more can tell whether the
    /// list it appends to is still the one it was asked for.
    private(set) var logVersion = 0
    private(set) var commits: [Commit] = []
    private(set) var graph = CommitGraph(rows: [], laneCount: 0)
    private(set) var selectedHash: String?
    private(set) var detail: CommitDetail?
    /// A divider drag in progress: shown, not saved until release.
    private(set) var draftSplit: DetailSplit?

    /// Every first-page read claims a generation; only the read still current
    /// when it answers may commit, so a refresh and a directory change can't
    /// race.
    private var fetchGeneration = 0
    /// Whether the current generation's first page is still outstanding.
    private(set) var fetchPending = false
    /// Whether anything chose a directory yet; read from inside the default
    /// lookup, which must never overwrite a choice made while it waited.
    private var directoryChosen: Bool
    private var defaultLookup: Task<Void, Never>?
    private var detailTask: Task<Void, Never>?
    private var detailInputs: DetailInputs?
    private var loadInputs: LoadInputs?
    /// One checkout at a time per pane: a second trigger while one runs would
    /// race the first over git's index.lock.
    private(set) var checkoutInFlight = false
    private var settingsObservation: Subscription?

    private struct DetailInputs: Equatable {
        var dir: String?
        var hash: String?
        var key: String?
        var collapsed: Bool
    }

    private struct LoadInputs: Equatable {
        var dir: String
        var scope: GitBranchScope
    }

    /// Redraw after state changes.
    var onChange: (() -> Void)?

    init(pane: any PaneContext, settings: PluginSettings<GitTreeSettings>, services: GitTreeServices) throws {
        self.pane = pane
        self.settings = settings
        self.services = services
        switch pane.initialConfig {
        case .object(let object): config = object
        case .null: config = [:]
        default: throw GitTreeConfigError("a git tree's config must be an object")
        }
        if let cwd = config["cwd"], cwd.stringValue == nil, cwd != .null {
            throw GitTreeConfigError("a git tree's cwd must be a string")
        }
        directoryChosen = config["cwd"]?.stringValue != nil
        offerDirectory()
        settingsObservation = settings.observe { [weak self] _ in self?.changed() }
        start()
    }

    // MARK: Config

    var configuredDir: String? { config["cwd"]?.stringValue }
    /// The branch filter, read straight from config (the select is its only
    /// writer). All branches until chosen.
    var branchScope: GitBranchScope { config["branchScope"]?.stringValue.flatMap(GitBranchScope.init(rawValue:)) ?? .all }
    var savedSplit: DetailSplit { readDetailSplit(.object(config)) }
    var split: DetailSplit { draftSplit ?? savedSplit }
    var showAuthor: Bool { settings.value.showAuthorColumn }
    var showDate: Bool { settings.value.showDateColumn }

    func currentConfig() -> JSONValue { .object(config) }

    private func setConfig(_ changes: [String: JSONValue]) {
        for (key, value) in changes { config[key] = value }
        pane.configDidChange()
        if changes["cwd"] != nil { offerDirectory() }
        reconcile()
    }

    /// The directory this pane shows, for a pane of another type made from it
    /// (a terminal opens there): the configured directory, exact because it
    /// only ever changes through this pane. None while the default is pending.
    private func offerDirectory() {
        pane.offer(.workingDirectory, configuredDir.map { URL(fileURLWithPath: $0, isDirectory: true) })
    }

    // MARK: Lifetime

    private func start() {
        reconcile()
        if configuredDir == nil { adoptDefaultDirectory() }
    }

    /// A pane created with no directory adopts one: the fallback when creation
    /// inherited nothing. Written into config, so it sticks across a relaunch.
    private func adoptDefaultDirectory() {
        defaultLookup = Task { [weak self] in
            guard let source = self?.source else { return }
            let dir = await source.defaultDirectory()
            // Two guards: the task being cancelled (the pane closed, or a
            // directory arrived), and a choice made during the round trip.
            guard let self, !Task.isCancelled, !self.directoryChosen else { return }
            self.directoryChosen = true
            self.setConfig(["cwd": .string(dir)])
        }
    }

    func paneWillClose() {
        defaultLookup?.cancel()
        detailTask?.cancel()
        fetchGeneration += 1
        settingsObservation?.cancel()
        services.forget(self)
    }

    #if DEBUG
    /// Tests and the capture: answer from `next` from now on, re-reading.
    func useSource(_ next: any GitSource) {
        source = next
        loadInputs = nil
        detailInputs = nil
        reconcile()
    }
    #endif

    // MARK: Reading the log

    /// Re-runs what depends on the config, then redraws.
    private func reconcile() {
        if let dir = configuredDir {
            let inputs = LoadInputs(dir: dir, scope: branchScope)
            if inputs != loadInputs {
                loadInputs = inputs
                loadLog(dir, scope: inputs.scope, showLoading: true)
            }
        }
        updateDetail()
        changed()
    }

    private func changed() { onChange?() }

    private func loadLog(_ dir: String, scope: GitBranchScope, showLoading: Bool = false) {
        fetchGeneration += 1
        let generation = fetchGeneration
        fetchPending = true
        if showLoading { setLog(nil) }
        let source = source
        Task { [weak self] in
            let result = await source.log(dir, limit: Self.pageSize, skip: 0, scope: scope)
            guard let self, self.fetchGeneration == generation else { return }
            self.fetchPending = false
            self.setLog(result)
        }
    }

    /// Re-reads the current directory's first page in place, without the
    /// "Reading history…" flash: ⌘R and auto-refresh.
    func refresh() {
        guard let dir = configuredDir else { return }
        loadLog(dir, scope: branchScope)
    }

    /// The next page, appended only onto the exact list the click saw.
    func loadMore() {
        guard let dir = configuredDir, case .success(let current) = log else { return }
        let version = logVersion
        let source = source
        let scope = branchScope
        Task { [weak self] in
            let result = await source.log(dir, limit: Self.pageSize, skip: current.commits.count, scope: scope)
            guard let self, self.logVersion == version else { return }
            switch result {
            case .failure: self.setLog(result)
            case .success(let page):
                var next = current
                next.commits += page.commits
                next.hasMore = page.hasMore
                self.setLog(.success(next))
            }
        }
    }

    private func setLog(_ next: GitLogResult?) {
        log = next
        logVersion += 1
        // The working tree's own state, folded into the list as a synthetic
        // commit whose parent is the newest real one, so the graph connects it
        // and selection, keys and the detail read treat it like any row.
        var list: [Commit] = []
        if case .success(let value) = next {
            list = value.commits
            if value.hasUncommittedChanges {
                let workingTree = Commit(
                    hash: uncommittedChangesHash, parents: value.commits.first.map { [$0.hash] } ?? [], author: "", date: "",
                    refs: [], subject: "Uncommitted changes")
                list.insert(workingTree, at: 0)
            }
        }
        commits = list
        graph = assignLanes(list)
        followSelection()
        updateTitle()
        updateDetail()
        changed()
    }

    /// Selection follows the list: kept where it was if that commit is still
    /// there, else the newest real commit, so the details are never empty
    /// beside a populated list.
    private func followSelection() {
        guard !commits.isEmpty else {
            selectedHash = nil
            return
        }
        if let current = selectedHash, commits.contains(where: { $0.hash == current }) { return }
        selectedHash = (commits.first { $0.hash != uncommittedChangesHash } ?? commits[0]).hash
    }

    /// The tab reads as the repository, or as the directory when it isn't one.
    private func updateTitle() {
        switch log {
        case nil: return
        case .success(let value): pane.setTitle(baseName(value.root))
        case .failure:
            if let dir = configuredDir { pane.setTitle(baseName(dir)) }
        }
    }

    var head: GitHead? {
        if case .success(let value) = log { value.head } else { nil }
    }

    // MARK: The detail

    private func updateDetail() {
        let collapsed = split.collapsed
        // The working-tree row's detail changes between reads though its hash
        // doesn't, so it's keyed on the log as well.
        let key = selectedHash == uncommittedChangesHash ? "log-\(logVersion)" : selectedHash
        let inputs = DetailInputs(dir: configuredDir, hash: selectedHash, key: key, collapsed: collapsed)
        guard inputs != detailInputs else { return }
        detailInputs = inputs
        // A read pending for the old inputs is dropped either way.
        detailTask?.cancel()
        // Collapsed, nothing shows it, so nothing reads it; the detail is kept
        // so reopening on the same row doesn't flash empty.
        if collapsed { return }
        guard let dir = configuredDir, let hash = selectedHash, log != nil else {
            detail = nil
            return
        }
        // Kept while the same row is re-read, so a refresh doesn't flash it.
        if detail?.hash != hash { detail = nil }
        let source = source
        let debounce = services.detailDebounce
        detailTask = Task { [weak self] in
            if debounce > .zero { try? await Task.sleep(for: debounce) }
            guard !Task.isCancelled else { return }
            let result = hash == uncommittedChangesHash ? await source.workingTree(dir) : await source.commit(dir, hash: hash)
            guard !Task.isCancelled, let self else { return }
            self.detail = try? result.get()
            self.changed()
        }
    }

    // MARK: What the user does

    func select(_ hash: String) {
        guard selectedHash != hash else { return }
        selectedHash = hash
        updateDetail()
        changed()
    }

    /// Moves the selection by `delta` rows, clamped to the list. Returns the
    /// row moved to, for the view to scroll into sight.
    @discardableResult
    func moveSelection(_ delta: Int) -> Int? {
        guard !commits.isEmpty else { return nil }
        let index = commits.firstIndex { $0.hash == selectedHash } ?? 0
        let next = min(max(index + delta, 0), commits.count - 1)
        select(commits[next].hash)
        return next
    }

    /// The path bar's commit: a non-empty directory other than the current one.
    func applyPath(_ text: String) {
        let next = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !next.isEmpty, next != configuredDir else { return }
        chooseDirectory(next)
    }

    func chooseDirectory(_ dir: String) {
        directoryChosen = true
        defaultLookup?.cancel()
        setConfig(["cwd": .string(dir)])
    }

    func chooseBranchScope(_ scope: GitBranchScope) {
        setConfig(["branchScope": .string(scope.rawValue)])
    }

    /// A divider drag's frame: shown only.
    func previewSplit(_ next: DetailSplit) {
        draftSplit = next
        updateDetail()
        changed()
    }

    /// The divider's release: clears the draft and saves, and saves nothing
    /// for a press that moved nothing. A collapse keeps the saved fraction.
    func commitSplit(_ next: DetailSplit) {
        draftSplit = nil
        let saved = savedSplit
        let unchanged = next.collapsed ? saved.collapsed : !saved.collapsed && next.fraction == saved.fraction
        if unchanged {
            reconcile()
            return
        }
        setConfig(
            next.collapsed
                ? ["detailCollapsed": .bool(true)] : ["detailFraction": .double(next.fraction), "detailCollapsed": .bool(false)])
    }

    /// The folder button: the system's picker, opened at the current
    /// directory; the pane adopts what's chosen, and does nothing on Cancel.
    func browse() async {
        let start = configuredDir.map { URL(fileURLWithPath: $0, isDirectory: true) }
        guard let chosen = await pane.chooseDirectory(title: "Choose a repository", startingAt: start) else { return }
        chooseDirectory(chosen.path)
    }

    // MARK: Focus and auto-refresh

    /// Core activated the pane. A press in its own toolbar activates it too,
    /// and must keep the keyboard there.
    func focus() {
        guard let view = viewIfLoaded, !view.toolbarHasFocus else { return }
        view.focusList()
    }

    /// The app's theme changed (or this is core's first word): the views
    /// repaint with its tokens. The header paints the bar behind the toolbar,
    /// at the pane's depth, so depth needs nothing of ours.
    func paneAppearanceDidChange(theme: PaneTheme, depth: Int) {
        toolbar.theme = theme
        viewIfLoaded?.theme = theme
    }

    /// The pane is the active one of a focused window (core tells on the
    /// change only: activation, or the window regaining focus): auto-refresh.
    /// Skipped while a first page is in flight (opening an active pane would
    /// read twice); ⌘R goes to `refresh` and never is.
    func paneDidBecomeAttended() {
        if fetchPending { return }
        if settings.value.autoRefreshOnFocus { refresh() }
    }

    // MARK: Checking out

    /// The pane's own view, once built.
    private(set) var viewIfLoaded: GitTreeView?

    /// The path bar, folder button, HEAD label and branch-scope select: the
    /// pane's header title.
    private(set) lazy var toolbar = GitTreeToolbar(pane: self)

    var headerTitle: NSView? { toolbar }

    var view: NSView {
        if let viewIfLoaded { return viewIfLoaded }
        let built = GitTreeView(pane: self)
        viewIfLoaded = built
        return built
    }

    /// Double-click, or the menu's Checkout: reads the refs at the commit
    /// fresh, then checks out. One target goes straight ahead; none asks
    /// whether to detach HEAD; several ask which one. Every failure is
    /// reported in an alert with git's own words. One checkout at a time.
    func checkout(_ hash: String) async {
        guard hash != uncommittedChangesHash, let dir = configuredDir, !checkoutInFlight else { return }
        checkoutInFlight = true
        defer { checkoutInFlight = false }
        switch await source.branchesAtCommit(dir, hash: hash) {
        case .failure(let error):
            await reportCheckoutFailure(failureMessage(error.reason))
        case .success(let refs):
            switch decideCheckout(local: refs.local, remotes: refs.remotes, allLocalBranches: refs.allLocalBranches) {
            case .single(let target):
                await performCheckout(dir, target)
            case .none:
                let confirmed = await pane.confirm(
                    PaneConfirm(
                        title: "Checkout",
                        message: "Checking out \(commitLabel(hash)) will leave HEAD detached — it won't be on any branch. Continue?",
                        confirmLabel: "Checkout"))
                if confirmed { await performCheckout(dir, .commit(hash: hash)) }
            case .choose(let targets):
                // The labels are the options, in the order git listed the refs (refname).
                let picked = await pane.choose(
                    PaneChoose(
                        title: "Checkout", message: "Several branches point at \(commitLabel(hash)). Which one?",
                        options: targets.map(checkoutTargetLabel), confirmLabel: "Checkout"))
                if let picked { await performCheckout(dir, targets[picked]) }
            }
        }
    }

    private func performCheckout(_ dir: String, _ target: CheckoutTarget) async {
        let result = await source.checkout(dir, target)
        // git's full refusal when it has one, else the one-line reason.
        if case .failure(let error) = result { await reportCheckoutFailure(error.detail ?? failureMessage(error.reason)) }
        services.refreshAfterCheckout(from: self, dir: dir)
    }

    private func reportCheckoutFailure(_ message: String) async {
        await pane.alert(PaneAlert(title: "Checkout failed", message: message))
    }

    /// "abc1234 — the subject line": a commit as a checkout dialog names it.
    private func commitLabel(_ hash: String) -> String {
        if let subject = commits.first(where: { $0.hash == hash })?.subject, !subject.isEmpty {
            return "\(shortHash(hash)) — \(subject)"
        }
        return shortHash(hash)
    }

    /// Copy SHA-1: the full hash of the row asked about.
    func copyHash(_ hash: String) {
        services.copyText(hash)
    }
}

struct GitTreeConfigError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

/// Every failure as the sentence the pane shows.
func failureMessage(_ reason: GitFailure) -> String {
    switch reason {
    case .gitMissing: "git isn’t installed, or isn’t on this app’s PATH."
    case .noSuchDirectory(let path): "No directory at \(path)."
    case .notARepo(let path): "No git repository at \(path)."
    case .noCommits(let root): "\(root) is a git repository, but has no commits yet."
    case .failed(let message): message
    }
}
