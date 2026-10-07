import AppKit
import TabsPluginSDK
import Testing

@testable import Tabs
@testable import TabsCore

extension UIDriver {
    /// A control verb, as the socket would run it.
    func call(_ command: String, _ arguments: JSONValue = .emptyObject, pane: PaneID? = nil) async throws -> JSONValue {
        let response = await runtime.control.handle(.init(command: command, arguments: arguments, targetPane: pane))
        guard response["ok"] == true else {
            throw CallFailure(description: "\(command): \(response["error"]?.stringValue ?? "\(response)")")
        }
        return response["result"] ?? .null
    }

    struct CallFailure: Error, CustomStringConvertible { let description: String }

    // MARK: Pointer

    /// Drags `view` from `start` (its coordinates) to `end` in `target` — in
    /// the same window or another — then releases, or finishes with `finish`.
    func drag(
        _ view: NSView, from start: NSPoint, to end: NSPoint, in target: NSView, wait: TimeInterval? = nil,
        finish: InputSynthesizer.DragStep = .release
    ) throws {
        let destination = try point(end, of: target, from: view)
        var steps: [InputSynthesizer.DragStep] = [.move(to: destination, steps: 10)]
        if let wait { steps.append(.wait(wait)) }
        steps.append(finish)
        try drag(from: start, in: view, steps)
    }

    /// Where a press picks up a pane: on its header's title (or, for a group, its bar clear of the tabs).
    func grip(_ pane: NodeID, in window: WorkspaceWindowController? = nil) throws -> (view: NSView, point: NSPoint) {
        let view = try paneView(pane, in: window)
        if let header = view.header { return (header, NSPoint(x: header.titleRect.minX + 6, y: header.titleRect.midY)) }
        let bar = try #require(view.tabBar)
        return (bar, NSPoint(x: bar.strip.frame.maxX - 4, y: bar.bounds.height / 2))
    }

    /// Where a press picks up a tab.
    func grip(tab: NodeID, in window: WorkspaceWindowController? = nil) throws -> (view: NSView, point: NSPoint) {
        let view = try tabView(tab, in: window)
        return (view, NSPoint(x: view.titleRect.minX + 4, y: view.titleRect.midY))
    }

    /// A point of a pane, as fractions of its box (0.5, 0.55 is its middle, below the header).
    func spot(
        _ pane: NodeID, _ x: CGFloat, _ y: CGFloat, in window: WorkspaceWindowController? = nil
    ) throws -> (view: NSView, point: NSPoint) {
        let view = try paneView(pane, in: window)
        return (view, NSPoint(x: view.bounds.width * x, y: view.bounds.height * y))
    }

    // MARK: Pane signals

    /// Declares the cues' stand-ins (`SignalFixtures`) and raises `kinds` on `pane`, as core.
    func raise(_ kinds: String..., on pane: PaneID) {
        SignalFixtures.declare(in: runtime.signals)
        for kind in kinds { runtime.signals.raise(PaneSignal(kind), on: pane, by: nil) }
        layoutAll()
    }

    /// The kinds a pane's header shows, left to right.
    func headerSignals(_ pane: NodeID) throws -> [String] {
        try #require(try paneView(pane).header).signalIcons.sorted { $0.frame.minX < $1.frame.minX }.compactMap(\.kindID)
    }

    /// The outline over `pane`, if it shows one.
    func outline(_ pane: NodeID) throws -> SignalOutlineView? {
        try window.trees.lazy.compactMap { $0.overlay.signalOutlines[pane] }.first
    }

    /// The window rendered as the visual comparison renders it (2x), for
    /// sampling — after a turn of the run loop, which gives the layers their
    /// contents.
    func rendering() throws -> NSBitmapImageRep {
        runLoopTurns()
        layoutAll()
        let root = try window.root
        return try #require(NSBitmapImageRep(data: try VisualCapture.render(root)))
    }
}
