import AppKit
import Foundation
import TabsPluginSDK

/// What a pane shows, as the renderer needs it.
@MainActor
package enum PaneBody {
    case empty
    case live(LivePane)
    /// No active plugin provides the type: the leaf is kept verbatim.
    case unavailable(reason: String)
}

/// The view side of the layout (the AppKit shell; a fake in tests). It draws
/// the model and reports what the user does; it decides nothing about where
/// panes go.
@MainActor
package protocol LayoutRenderer: AnyObject {
    /// Makes the windows and views match `model`. Never calls back into the
    /// engine synchronously except to report the frontmost window changing.
    func render(_ model: LayoutModel)
    /// The front-most workspace window by z-order; nil when that isn't known.
    var frontmostWindowID: WindowID? { get }
    /// Brings a window to the front (a plugin focused a pane in it).
    func bringToFront(_ window: WindowID)
    /// Asks the user whether to close panes that would lose work (or, when
    /// `quitting`, to quit with them open); true to go ahead. The wording is
    /// `CloseConfirmation`'s.
    func confirmClose(_ warnings: [String], quitting: Bool) -> Bool
    /// A pane's title changed.
    func titleDidChange(_ pane: PaneID)
    /// Gives a pane keyboard focus (it was focused on purpose).
    func focus(_ pane: PaneID)
    /// A window's content size, which floating panes are kept inside.
    func viewport(of window: WindowID) -> Viewport?
    /// Whether a window has the focus: the key window of the active app
    /// (the Electron app's `document.hasFocus()`).
    func isFocused(_ window: WindowID) -> Bool
    /// The signals on these panes changed: redraw their chrome.
    func signalsDidChange(on panes: Set<PaneID>)
    /// Bounces the Dock icon once (informational); the system ignores it while
    /// the app is active.
    func requestUserAttention()
    /// A pane's rect in its window's content area, when it is on screen.
    func paneRect(_ pane: PaneID) -> FloatRect?
    /// Shows core's context menu for a pane, at `point` in `view`.
    func showContextMenu(_ items: [PaneMenuItem], at point: NSPoint, in view: NSView, for pane: PaneID)
    /// Asks a pane's question in a card over the pane's window, and calls
    /// `completion` once, on the main actor, with the answer. With no window
    /// to ask in it answers `dialog.defaultAnswer` (still through `completion`).
    func showDialog(_ dialog: PaneDialog, for pane: PaneID, completion: @escaping @MainActor (PaneDialog.Answer) -> Void)
    /// Asks for a file or directory in the system's open panel, a sheet on the
    /// pane's window; `completion` gets nil when cancelled, and when there is
    /// no window to sheet on.
    func showPicker(_ picker: PanePicker, for pane: PaneID, completion: @escaping @MainActor (URL?) -> Void)
}

extension LayoutRenderer {
    func paneRect(_ pane: PaneID) -> FloatRect? { nil }
}

/// Where a new pane goes relative to the pane it's made from.
package enum NewPanePlacement: Equatable, Sendable {
    /// A new tab (`openContent`: a tab beside it, or filling it if it's empty).
    case tab
    /// A split beside it.
    case split(SplitDirection)
    /// A floating pane at this rect.
    case floating(FloatRect)
}

/// The workspace: every window's layout (`LayoutModel`), and the only place it
/// changes. It's core's `WorkspaceShell`, so plugins' requests land here, and
/// the AppKit shell renders it and forwards the user's actions.
///
/// Every change is applied to the model first, then `reconcile()` brings
/// everything else in line with it, in a fixed order:
///
/// 1. live panes no longer in the model are closed (`paneWillClose`, `paneClosed`);
/// 2. the renderer draws the model;
/// 3. panes new to a window are announced (`paneOpened`), moved ones too (`paneMoved`);
/// 4. panes hear whether they're on screen;
/// 5. the active pane (the frontmost window's) is announced if it changed;
/// 6. a save is scheduled.
///
/// Plugin code runs only against a model that is already whole. If it changes
/// the layout (focuses, opens, closes a pane), that change is applied to the
/// model and the pass starts over from step 1 — nothing acts on a stale view
/// of the layout. A pane a plugin opens from inside a pass is placed at once
/// and opened (`paneOpened`) by the pass that follows.
@MainActor
package final class LayoutEngine: WorkspaceShell, PaneSignalHost {
    package private(set) var model = LayoutModel()
    package weak var renderer: (any LayoutRenderer)?
    /// Told when the active pane's content type may have changed (the menu
    /// arms that type's shortcuts).
    package var activeContentTypeDidChange: (@MainActor (ContentTypeID?) -> Void)?

    private let runtime: CoreRuntime
    private var panes: PaneRuntime { runtime.panes }
    /// Bodies of leaves with a content type, by pane id.
    private var bodies: [PaneID: PaneBody] = [:]
    /// For an empty pane: the live pane that was active when it was made, the
    /// origin of whatever fills it (a terminal to take the directory from).
    private var creationOrigins: [PaneID: PaneID] = [:]
    private var isReconciling = false
    private var needsReconcile = false
    private var lastActiveType: ContentTypeID??
    private var saveScheduled = false
    private var isTornDown = false
    /// The model when a save was last scheduled: passes that change nothing
    /// (a window coming to the front) don't rewrite layout.json.
    private var lastSavedModel: LayoutModel?
    /// Each window's active pane as the last pass saw it: a pane that becomes
    /// active has been seen.
    private var seenActive: [WindowID: NodeID] = [:]
    /// Panes whose signals changed during a pass, told to the renderer once
    /// it's done: until the pass renders, the views are the old layout's.
    private var signalChanges: Set<PaneID> = []

    package init(runtime: CoreRuntime) {
        self.runtime = runtime
        runtime.panes.shell = self
        runtime.signals.host = self
    }

    package var signals: PaneSignals { runtime.signals }

    // MARK: Reading

    /// How nodes are named: content types by their plugins' display names.
    package var titles: LayoutTitles {
        var names: [ContentTypeID: String] = [:]
        for contribution in runtime.registry.contributions(to: .contentTypes) where names[contribution.value.id] == nil {
            names[contribution.value.id] = contribution.value.displayName
        }
        return LayoutTitles(displayNames: names)
    }

    package func body(of pane: PaneID) -> PaneBody {
        guard model.leaf(pane)?.type != nil else { return .empty }
        return bodies[pane] ?? .unavailable(reason: "Its content isn't available.")
    }

    package func live(_ pane: PaneID) -> LivePane? {
        if case .live(let live) = bodies[pane] { live } else { nil }
    }

    /// A pane header's label: a title the user set, the plugin's live title,
    /// the saved one, or what the pane is.
    package func paneTitle(of node: LayoutNode) -> String {
        if case .leaf(let leaf) = node, !leaf.titleIsManual, let live = live(leaf.id) {
            let trimmed = live.title.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? "Untitled" : trimmed
        }
        return titles.paneTitle(for: node)
    }

    package func paneTitle(of pane: PaneID) -> String {
        guard let window = model.window(holding: pane), let node = window.findNode(pane) else { return "" }
        return paneTitle(of: node)
    }

    package var frontmostWindowID: WindowID? {
        if let front = renderer?.frontmostWindowID, model.window(front) != nil { return front }
        return model.windows.last?.id
    }

    /// The leaf with keyboard focus in the frontmost window.
    package var activePaneID: PaneID? { frontmostWindowID.flatMap { model.window($0)?.activeLeafID } }

    /// The active pane's content type (nil: none, or an empty pane).
    package var activeContentType: ContentTypeID? { activePaneID.flatMap { model.leaf($0)?.type } }

    // MARK: Restoring and saving

    /// Rebuilds the saved windows (or opens a fresh one).
    package func restore(_ saved: SavedLayout?) {
        var restored = LayoutModel(windows: saved?.windows ?? [])
        restored.makeLeafIDsUnique(avoiding: Set(bodies.keys))
        holdingPasses {
            for window in restored.windows {
                build(window)
                model.windows.append(window)
            }
            if model.windows.isEmpty { model.windows.append(freshWindow()) }
        }
        reconcile()
    }

    /// The layout as it should be saved: live panes' current titles and
    /// configs, unavailable ones verbatim, and the last closed window (so the
    /// app reopens to it).
    package func snapshot() -> SavedLayout {
        var windows = model.windows.map(snapshot(of:))
        if let lastClosed = model.lastClosed { windows.append(lastClosed) }
        return SavedLayout(windows: windows)
    }

    /// A window as it would be saved now: live panes asked for their state.
    private func snapshot(of window: WindowLayout) -> WindowLayout {
        func saved(_ node: LayoutNode) -> LayoutNode {
            Tree.mapLeaves(node) { leaf in
                guard let live = live(leaf.id) else { return leaf }
                var saved = panes.snapshot(live)
                if leaf.titleIsManual {
                    saved.title = leaf.title
                    saved.titleIsManual = true
                }
                return saved
            }
        }
        var window = window
        if case .tabs(let root) = saved(window.rootNode) { window.root = root }
        for index in window.floating.indices { window.floating[index].content = saved(window.floating[index].content) }
        return window
    }

    /// Coalesces bursts of changes (typing) into one write.
    package func scheduleSave() {
        guard !saveScheduled, !isTornDown else { return }
        saveScheduled = true
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard let self, self.saveScheduled else { return }
            self.saveNow()
        }
    }

    /// Writes layout.json — unless Restore layout on relaunch is off: then
    /// nothing is written and no pane is asked for its state (Electron keeps its
    /// cwd probe off the quit path the same way). The model stays current
    /// meanwhile, so turning it back on saves the live layout at the next save.
    package func saveNow() {
        saveScheduled = false
        guard !isTornDown, runtime.settings.panes.persistLayoutOnExit else { return }
        runtime.layoutStore.save(snapshot())
    }

    // MARK: What the user does

    /// Runs a layout operation on one window and brings everything in line
    /// with the result. Returns whether it changed anything.
    @discardableResult
    package func perform(in window: WindowID, _ operation: (inout WindowLayout, LayoutTitles) -> Bool) -> Bool {
        guard let index = model.index(of: window) else { return false }
        let names = titles
        var layout = model.windows[index]
        guard operation(&layout, names) else { return false }
        model.windows[index] = layout
        reconcile()
        return true
    }

    /// A new window: the last closed one if it's waiting, else one empty tab.
    @discardableResult
    package func openWindow() -> WindowID {
        let window: WindowLayout
        if let reopened = model.lastClosed {
            model.lastClosed = nil
            var single = LayoutModel(windows: [reopened])
            single.makeLeafIDsUnique(avoiding: Set(model.leaves.map(\.id)).union(bodies.keys))
            window = single.windows.first ?? freshWindow()
            holdingPasses { build(window) }
        } else {
            window = freshWindow()
        }
        model.windows.append(window)
        reconcile()
        return window.id
    }

    /// Content "like" `origin` (its visible leaf): a new pane of the same
    /// type made from it, or — for an empty or unavailable one, or a type the
    /// user can't create — an empty pane. A live pane made here is registered
    /// but not placed; `discard` it if it doesn't get placed.
    private func contentLike(_ origin: LayoutNode?, in window: WindowID) -> LayoutNode {
        guard let origin, case .leaf(let leaf)? = model.window(window)?.findNode(Navigation.entryPaneID(origin)),
            let type = leaf.type, panes.canCreate(type),
            let created = panes.create(PaneRequest(type: type, origin: live(leaf.id) != nil ? leaf.id : nil), in: window)
        else {
            let empty = LayoutLeaf.empty()
            if let origin, let originLeaf = model.window(window)?.findNode(Navigation.entryPaneID(origin))?.leaf,
                live(originLeaf.id) != nil
            {
                creationOrigins[empty.id] = originLeaf.id
            }
            return .leaf(empty)
        }
        bodies[created.id] = .live(created)
        return .leaf(LayoutLeaf(id: created.id, type: type))
    }

    private func discard(_ content: LayoutNode) {
        for leaf in content.leaves {
            creationOrigins[leaf.id] = nil
            if case .live(let live) = bodies.removeValue(forKey: leaf.id) { panes.detach(live.id) }
        }
    }

    /// A new pane like `origin`, placed relative to it: a tab, a split, or a
    /// floating pane. Returns the new pane's id.
    @discardableResult
    package func newPane(like originID: NodeID, in window: WindowID, placement: NewPanePlacement) -> NodeID? {
        guard let layout = model.window(window), let origin = layout.findNode(originID) else { return nil }
        return place(contentLike(origin, in: window), at: originID, in: window, placement: placement)
    }

    /// A new pane of `type` — the one the user chose, not one like `origin` —
    /// made from `origin` (so it can open where that pane is: the Electron
    /// app's `createContentFor`, which runs the created type's `deriveConfig`
    /// on the origin's visible leaf) and placed relative to it. An empty origin
    /// offers nothing to inherit, so the type's own default applies; a tab
    /// placement on an empty origin fills it in place. Nil, with nothing
    /// created, when the origin is gone or the type can't be created.
    @discardableResult
    package func newPane(ofType type: ContentTypeID, from originID: NodeID, in window: WindowID, placement: NewPanePlacement) -> NodeID? {
        guard let layout = model.window(window), let origin = layout.findNode(originID),
            case .leaf(let leaf)? = layout.findNode(Navigation.entryPaneID(origin)),
            let created = panes.create(PaneRequest(type: type, origin: live(leaf.id) != nil ? leaf.id : nil), in: window)
        else { return nil }
        bodies[created.id] = .live(created)
        return place(.leaf(LayoutLeaf(id: created.id, type: type)), at: originID, in: window, placement: placement)
    }

    /// Puts `content` (a live pane made but not placed) at `originID` as a tab,
    /// a split or a floating pane; discards it if nothing took it.
    private func place(_ content: LayoutNode, at originID: NodeID, in window: WindowID, placement: NewPanePlacement) -> NodeID? {
        let viewport = renderer?.viewport(of: window) ?? Viewport(width: 1200, height: 800)
        let placed = perform(in: window) { layout, titles in
            switch placement {
            case .tab: layout.openContent(at: originID, content, titles: titles)
            case .split(let direction): layout.split(originID, direction, with: content, titles: titles)
            case .floating(let rect): layout.openFloatingPane(content, rect: rect, viewport: viewport)
            }
        }
        guard placed else {
            discard(content)
            return nil
        }
        return content.id
    }

    /// Fills an empty pane in place with a new pane of `type`: same id, same
    /// place, created from the pane that was active when the empty one was made.
    @discardableResult
    package func fill(_ pane: PaneID, with type: ContentTypeID) -> Bool {
        guard let leaf = model.leaf(pane), leaf.type == nil, let window = model.window(holding: pane),
            let live = panes.create(PaneRequest(type: type, origin: creationOrigins[pane]), id: pane, in: window.id)
        else { return false }
        creationOrigins[pane] = nil
        guard live.id == pane else {
            // Core minted another id (it can't happen while ids are unique):
            // the model and core must never disagree on one.
            panes.detach(live.id)
            return false
        }
        bodies[pane] = .live(live)
        return perform(in: window.id) { layout, titles in
            layout.replaceLeaf(pane, with: LayoutLeaf(id: pane, type: type), titles: titles) && layout.setActivePaneOrKeep(pane)
        }
    }

    /// Warnings from live panes under `node` that would lose work.
    private func closeWarnings(_ node: LayoutNode?) -> [String] {
        (node?.leaves ?? []).compactMap { live($0.id)?.controller.closeWarning }
    }

    /// Asks before destroying `node` if anything under it would lose work.
    /// The ask is modal (the main actor runs under it): callers look again after.
    private func confirmDestroying(_ node: LayoutNode?) -> Bool {
        let warnings = closeWarnings(node)
        return warnings.isEmpty || renderer?.confirmClose(warnings, quitting: false) != false
    }

    /// Closes a pane (and everything in it), asking first if it would lose
    /// work. The docked root means its shown tab.
    package func close(_ pane: NodeID) {
        guard let window = model.window(holding: pane), confirmDestroying(window.closeTarget(pane)),
            let current = model.window(holding: pane)
        else { return }
        perform(in: current.id) { layout, titles in layout.closePane(pane, titles: titles) }
    }

    /// Empties a pane in place, asking first if it would lose work.
    package func clear(_ pane: NodeID) {
        guard let window = model.window(holding: pane), confirmDestroying(window.closeTarget(pane)),
            let current = model.window(holding: pane)
        else { return }
        perform(in: current.id) { layout, titles in layout.clearPane(pane, titles: titles) }
    }

    /// Closes a tab, asking first if its content would lose work.
    package func closeTab(_ tab: NodeID) {
        guard let window = model.window(holding: tab), let ref = window.trees.lazy.compactMap({ Tree.findTab($0, tab) }).first,
            confirmDestroying(ref.tab.content), let current = model.window(holding: tab)
        else { return }
        perform(in: current.id) { layout, titles in layout.closeTab(tab, titles: titles) }
    }

    /// Whether the app may quit: asks once about every pane that would lose work.
    package func shouldQuit() -> Bool {
        let warnings = model.leaves.compactMap { live($0.id)?.controller.closeWarning }
        return warnings.isEmpty || renderer?.confirmClose(warnings, quitting: true) ?? true
    }

    /// Whether a window may close: asks once about every pane that would lose
    /// work, again for any that appear or start warning meanwhile.
    package func shouldClose(_ window: WindowID) -> Bool {
        var confirmed: Set<PaneID> = []
        while true {
            let pending = (model.window(window)?.leaves ?? []).filter { leaf in
                !confirmed.contains(leaf.id) && live(leaf.id)?.controller.closeWarning != nil
            }
            if pending.isEmpty { return true }
            let warnings = pending.compactMap { live($0.id)?.controller.closeWarning }
            guard renderer?.confirmClose(warnings, quitting: false) ?? true else { return false }
            confirmed.formUnion(pending.map(\.id))
        }
    }

    /// A window closed (the user closed it). If it was the only one, it's
    /// kept to reopen; either way its panes end.
    package func windowDidClose(_ window: WindowID) {
        guard let index = model.index(of: window) else { return }
        if model.windows.count == 1 { model.lastClosed = snapshot(of: model.windows[index]) }
        model.windows.remove(at: index)
        reconcile()
    }

    /// Moves a dragged tab or pane from one window's docked layout into
    /// another's at `target`. All or nothing: a target the destination can't
    /// take leaves both windows as they were.
    @discardableResult
    package func move(_ subject: DragSubject, from source: WindowID, to destination: WindowID, at target: DropTarget) -> Bool {
        guard source != destination, let sourceIndex = model.index(of: source), let destinationIndex = model.index(of: destination),
            model.windows[destinationIndex].accepts(target)
        else { return false }
        let names = titles
        var from = model.windows[sourceIndex]
        var to = model.windows[destinationIndex]
        guard let content = from.extract(subject, titles: names), to.insert(content, at: target, titles: names) else { return false }
        model.windows[sourceIndex] = from
        model.windows[destinationIndex] = to
        reconcile()
        return true
    }

    /// The frontmost window changed (the renderer saw it).
    package func frontmostWindowDidChange() { reconcile() }

    /// A window gained the focus: its active pane has been seen (`bellStore`'s
    /// window `focus` listener). Other panes' signals stay.
    package func windowDidGainFocus(_ window: WindowID) {
        if let active = model.window(window)?.activePaneID { signals.seen(active) }
        syncAttention()
    }

    /// A window lost the focus (it stopped being key, or the app went to the
    /// background): its active pane is no longer looked at.
    package func windowDidLoseFocus(_ window: WindowID) { syncAttention() }

    /// Tells each pane whose attention changed — `isLookedAt` now against what
    /// its plugin was last told — so it hears transitions only.
    private func syncAttention() {
        for window in model.windows {
            for leaf in window.leaves {
                guard let live = live(leaf.id) else { continue }
                panes.attentionDidChange(leaf.id, attended: live.isAttached && isLookedAt(leaf.id))
            }
        }
    }

    // MARK: PaneSignalHost

    package func isLookedAt(_ pane: PaneID) -> Bool {
        guard let window = model.window(holding: pane), window.activePaneID == pane else { return false }
        return renderer?.isFocused(window.id) == true
    }

    package func isWindowFocused(holding pane: PaneID) -> Bool {
        guard let window = model.window(holding: pane) else { return false }
        return renderer?.isFocused(window.id) == true
    }

    package func signalsDidChange(on panes: Set<PaneID>) {
        guard !isReconciling else {
            signalChanges.formUnion(panes)
            return
        }
        renderer?.signalsDidChange(on: panes)
    }

    package func requestUserAttention() { renderer?.requestUserAttention() }

    /// The user moved or resized a window: saved with the layout.
    package func windowFrameDidChange(_ window: WindowID, to frame: WindowFrame) {
        guard let index = model.index(of: window), model.windows[index].frame != frame else { return }
        model.windows[index].frame = frame
        scheduleSave()
    }

    /// Ends every pane (`paneWillClose`, `paneClosed`) and never saves again:
    /// for replacing this workspace wholesale (a test reset).
    package func tearDown() {
        isTornDown = true
        saveScheduled = false
        model = LayoutModel()
        reconcile()
    }

    // MARK: WorkspaceShell (plugins' requests, through core)

    package func place(_ pane: LivePane, placement: PanePlacement) -> Bool {
        let leaf = LayoutNode.leaf(LayoutLeaf(id: pane.id, type: pane.contentType))
        bodies[pane.id] = .live(pane)
        let placed: Bool
        switch placement {
        case .window:
            // Bring back the last closed window first, as `.automatic` would:
            // otherwise closing this one would replace it, and it'd be lost.
            if model.windows.isEmpty, model.lastClosed != nil { openWindow() }
            model.windows.append(WindowLayout(root: leaf, active: pane.id, titles: titles))
            placed = true
            reconcile()
        case .split(let target, let edge) where model.window(holding: target) != nil:
            let window = model.window(holding: target)!.id
            let direction: SplitDirection = edge == .leading || edge == .trailing ? .horizontal : .vertical
            placed = perform(in: window) { layout, titles in
                layout.split(target, direction, with: leaf, before: edge == .leading || edge == .top, titles: titles)
            }
        case .tab(near: let near?) where model.window(holding: near) != nil:
            placed = perform(in: model.window(holding: near)!.id) { layout, titles in layout.openContent(at: near, leaf, titles: titles) }
        case .floating(let near) where floatingOrigin(near: near) != nil:
            // Over the origin, in the section of it the setting names (the
            // Electron app's `placeNewUnpinnedPane`), appended last so the
            // newest window starts on top and active.
            let (window, origin) = floatingOrigin(near: near)!
            let rect =
                renderer?.paneRect(origin).map { Floating.spawnRect(in: $0, at: runtime.settings.panes.spawnPosition) }
                ?? Floating.defaultRect
            let viewport = renderer?.viewport(of: window) ?? Viewport(width: 1200, height: 800)
            placed = perform(in: window) { layout, _ in layout.openFloatingPane(leaf, rect: rect, viewport: viewport) }
        default:
            let window: WindowID
            if let front = frontmostWindowID {
                window = front
            } else if model.lastClosed != nil {
                // With no window open, bring back the last one closed (it's
                // what the user would reopen) rather than a new one that loses it.
                window = openWindow()
            } else {
                model.windows.append(WindowLayout(root: leaf, active: pane.id, titles: titles))
                reconcile()
                return true
            }
            placed = perform(in: window) { layout, titles in layout.openContent(at: layout.activePaneID, leaf, titles: titles) }
        }
        if !placed { bodies[pane.id] = nil }
        return placed
    }

    /// The window and pane a floating pane spawns over: `near` if it is in the
    /// layout, else the frontmost window's active pane.
    private func floatingOrigin(near: PaneID?) -> (window: WindowID, origin: NodeID)? {
        if let near, let window = model.window(holding: near) { return (window.id, near) }
        guard let front = frontmostWindowID, let window = model.window(front) else { return nil }
        return (front, window.activePaneID)
    }

    /// Makes a pane visible — every tab above it shown, its floating window
    /// raised — and nothing else: not the active pane, not the keyboard
    /// (the Electron app's `revealPane`).
    package func reveal(_ pane: PaneID) {
        guard let window = model.window(holding: pane) else { return }
        perform(in: window.id) { layout, titles in layout.showPane(pane, titles: titles) }
    }

    /// A pane's title for control verbs: the user's, else the plugin's live
    /// one, else none (the Electron leaf's `title ?? ''`).
    package func controlTitle(of pane: PaneID) -> String {
        guard let leaf = model.leaf(pane) else { return "" }
        if leaf.titleIsManual { return leaf.title ?? "" }
        guard let live = live(pane) else { return leaf.title ?? "" }
        return live.context.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    /// Every pane, window by window: the docked tree, then the floating panes.
    package func layoutPaneOrder() -> [PaneID]? { model.leaves.map(\.id) }

    /// Reveals a pane (every tab above it, its floating window raised), makes
    /// it active, and gives it the keyboard.
    package func focus(_ pane: PaneID) {
        guard let window = model.window(holding: pane) else { return }
        perform(in: window.id) { layout, titles in layout.reveal(pane, titles: titles) }
        renderer?.bringToFront(window.id)
        renderer?.focus(pane)
    }

    package func requestClose(_ pane: PaneID) { close(pane) }

    package func paneTitleDidChange(_ pane: PaneID) { renderer?.titleDidChange(pane) }

    package func paneStateDidChange(_ pane: PaneID) { scheduleSave() }

    package func paneShowDialog(_ dialog: PaneDialog, for pane: PaneID, completion: @escaping @MainActor (PaneDialog.Answer) -> Void) {
        guard let renderer else { return completion(dialog.defaultAnswer) }
        renderer.showDialog(dialog, for: pane, completion: completion)
    }

    package func paneShowPicker(_ picker: PanePicker, for pane: PaneID, completion: @escaping @MainActor (URL?) -> Void) {
        guard let renderer else { return completion(nil) }
        renderer.showPicker(picker, for: pane, completion: completion)
    }

    package func paneShowContextMenu(_ items: [PaneMenuItem], at point: NSPoint, in view: NSView, for pane: PaneID) {
        renderer?.showContextMenu(items, at: point, in: view, for: pane)
    }

    // MARK: Reconciling

    /// Brings panes, views and events in line with the model (see the type's
    /// documentation). Re-entrant calls are folded into another pass.
    package func reconcile() {
        needsReconcile = true
        guard !isReconciling else { return }
        isReconciling = true
        defer {
            isReconciling = false
            // What changed after the last render (a pane raising as it's attached).
            if !signalChanges.isEmpty {
                let changed = signalChanges
                signalChanges = []
                renderer?.signalsDidChange(on: changed)
            }
        }
        var passCount = 0
        passes: while needsReconcile {
            needsReconcile = false
            passCount += 1
            guard passCount <= Self.maxPasses else {
                // Plugins answering each other's layout changes with more of
                // their own (focusing back and forth) would spin forever.
                Log.core.fault(
                    "layout passes kept starting over (\(Self.maxPasses)); stopped — a plugin keeps changing the layout in reply to changes"
                )
                break
            }
            creationOrigins = creationOrigins.filter { model.leaf($0.key) != nil }
            // 1. Panes that left the layout end, while their views still exist.
            for id in bodies.keys.sorted() where model.leaf(id)?.type == nil {
                if case .live(let live) = bodies.removeValue(forKey: id) { panes.detach(live.id) }
                if needsReconcile { continue passes }
            }
            // Signals end with their panes, and a pane that became its
            // window's active pane has been seen (`PaneFocusFollower`).
            if !signals.panes.isEmpty { signals.retain(only: Set(model.leaves.map(\.id))) }
            seenActive = seenActive.filter { model.window($0.key) != nil }
            for window in model.windows where seenActive[window.id] != window.activePaneID {
                seenActive[window.id] = window.activePaneID
                signals.seen(window.activePaneID)
            }
            // 2. The views follow the model (building a view runs plugin code),
            // signals included.
            signalChanges = []
            renderer?.render(model)
            if needsReconcile { continue passes }
            // 3–4. New panes are announced (and their titles, which building
            // the view may have set), moved ones follow, visibility is told.
            for window in model.windows {
                for leaf in window.leaves {
                    guard let live = live(leaf.id) else { continue }
                    if !live.isAttached {
                        panes.attach(live, in: window.id)
                        renderer?.titleDidChange(live.id)
                    } else if live.windowID != window.id {
                        panes.paneDidMove(live.id, to: window.id)
                    }
                    if needsReconcile { continue passes }
                    panes.visibilityDidChange(live.id, visible: window.isShowing(leaf.id))
                    if needsReconcile { continue passes }
                }
            }
            // 5. The active pane.
            if let front = frontmostWindowID, let active = model.window(front)?.activeLeafID {
                panes.activePaneDidChange(to: active, in: front)
                if needsReconcile { continue passes }
            }
            syncAttention()
            if needsReconcile { continue passes }
            let type = activeContentType
            if lastActiveType != .some(type) {
                lastActiveType = .some(type)
                activeContentTypeDidChange?(type)
            }
            if model != lastSavedModel {
                lastSavedModel = model
                scheduleSave()
            }
        }
    }

    /// More restarts than any real cascade of plugin reactions needs.
    private static let maxPasses = 100

    /// Runs `body` with passes held: whatever it triggers is folded into the
    /// pass that runs after it (a window being built isn't in the model yet,
    /// and a pass meanwhile would take its panes for closed ones).
    private func holdingPasses<T>(_ body: () -> T) -> T {
        let wasReconciling = isReconciling
        isReconciling = true
        defer { isReconciling = wasReconciling }
        return body()
    }

    // MARK: Helpers

    private func freshWindow() -> WindowLayout { WindowLayout(titles: titles) }

    /// Makes the live (or unavailable) panes of a saved window.
    private func build(_ saved: WindowLayout) {
        for leaf in saved.leaves {
            guard leaf.type != nil else { continue }
            switch panes.restore(leaf, in: saved.id) {
            case .live(let live):
                if live.id != leaf.id {
                    // Can't happen while ids are unique; never let them disagree.
                    panes.detach(live.id)
                    bodies[leaf.id] = .unavailable(reason: "Its pane id was already in use.")
                } else {
                    bodies[leaf.id] = .live(live)
                }
            case .unavailable(let reason):
                bodies[leaf.id] = .unavailable(reason: reason)
            case .empty:
                break
            }
        }
    }
}

extension WindowLayout {
    /// Activates every tab above `id`, raises its floating pane, and makes it active.
    @discardableResult
    package mutating func reveal(_ id: NodeID, titles: LayoutTitles) -> Bool {
        let tree = ownerTree(of: id)
        var changed = false
        for step in Navigation.ancestorTabSteps(tree, id) {
            changed = activateTab(step.groupID, step.tabID, titles: titles) || changed
        }
        if let float = floatingPane(holding: id) { changed = raiseFloating(float.id) || changed }
        return setActivePane(id) || changed
    }

    /// Activates every tab above `id` and raises its floating pane, leaving the
    /// active pane alone (`revealPane`).
    @discardableResult
    package mutating func showPane(_ id: NodeID, titles: LayoutTitles) -> Bool {
        let tree = ownerTree(of: id)
        var changed = false
        for step in Navigation.ancestorTabSteps(tree, id) {
            changed = activateTab(step.groupID, step.tabID, titles: titles) || changed
        }
        if let float = floatingPane(holding: id) { changed = raiseFloating(float.id) || changed }
        return changed
    }

    /// `setActivePane`, counting "already active" as success.
    package mutating func setActivePaneOrKeep(_ id: NodeID) -> Bool {
        setActivePane(id)
        return true
    }
}
