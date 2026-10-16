import AppKit
import TabsCore
import TabsPluginSDK

/// The workspace's app-wide input: pane navigation by keyboard and
/// activating a pane by clicking into its content — which is a plugin's
/// view, so the click never reaches the pane's own chrome.
@MainActor
final class WorkspaceInput {
    private unowned let renderer: WorkspaceRenderer
    private let runtime: CoreRuntime
    private var monitors: [Any] = []

    private static let navigation: [(CoreCommand, NavDirection)] = [
        (CoreCommands.navLeft, .left), (CoreCommands.navRight, .right), (CoreCommands.navUp, .up), (CoreCommands.navDown, .down),
    ]

    init(renderer: WorkspaceRenderer, runtime: CoreRuntime) {
        self.renderer = renderer
        self.runtime = runtime
        if let keys = NSEvent.addLocalMonitorForEvents(
            matching: .keyDown,
            handler: { [weak self] event in
                let handled = MainActor.assumeIsolated { self?.handleKeyDown(event) ?? false }
                return handled ? nil : event
            })
        {
            monitors.append(keys)
        }
        if let clicks = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown],
            handler: { [weak self] event in
                guard let self else { return event }
                MainActor.assumeIsolated { self.handleMouseDown(event) }
                return event
            })
        {
            monitors.append(clicks)
        }
    }

    func stop() {
        for monitor in monitors { NSEvent.removeMonitor(monitor) }
        monitors.removeAll()
    }

    // MARK: Navigation

    /// A navigation chord in a workspace window moves pane focus — unless a
    /// text field has the keyboard (the arrows edit there) or a drag is on.
    func handleKeyDown(_ event: NSEvent) -> Bool {
        guard let chord = KeyChord(event: event),
            let direction = Self.navigation.first(where: { runtime.shortcuts.chord(for: $0.0.id) == chord })?.1,
            let window = event.window, let controller = renderer.windows.first(where: { $0.window === window })
        else { return false }
        if renderer.drag.isDragging { return false }
        if let text = window.firstResponder as? NSTextView, text.isEditable { return false }
        if controller.appearance.showNavFlash { NavFlashView.flash(direction, in: controller) }
        renderer.engine.navigate(direction, in: controller.windowID)
        return true
    }

    // MARK: Activation

    /// A press inside a pane's content (or its header's plugin-provided title) makes that pane active (its chrome
    /// activates on its own click).
    func handleMouseDown(_ event: NSEvent) {
        guard let window = event.window, let controller = renderer.windows.first(where: { $0.window === window }),
            let content = window.contentView,
            let hit = content.hitTest(content.superview?.convert(event.locationInWindow, from: nil) ?? event.locationInWindow)
        else { return }
        var view: NSView? = hit
        var inBody = false
        var below: NSView?
        while let current = view {
            if current is PaneBodyHost { inBody = true }
            // The header's plugin-provided title acts as content: a press on it activates.
            if let header = current as? PaneHeaderView, let title = header.titleView, below === title { inBody = true }
            below = current
            if let pane = current as? PaneView {
                if inBody { controller.activate(pane.nodeID) }
                return
            }
            view = current.superview
        }
    }
}
