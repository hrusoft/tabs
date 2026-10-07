import AppKit
import Foundation
import TabsPluginSDK

@testable import TabsCore

/// A renderer that records what the engine asked of it: no windows.
@MainActor
final class FakeRenderer: LayoutRenderer {
    var rendered = LayoutModel()
    var front: WindowID?
    var broughtToFront: [WindowID] = []
    var answers: [Bool] = []
    var asked: [[String]] = []
    /// Whether each ask was about quitting (else closing).
    var askedToQuit: [Bool] = []
    var titles: [PaneID] = []
    var focused: [PaneID] = []
    /// Windows' content sizes, as a test sets them (nil: not known).
    var viewports: [WindowID: Viewport] = [:]
    /// Windows that have the focus, as a test sets them.
    var focusedWindows: Set<WindowID> = []
    /// Every batch of panes whose signals changed, in order.
    var signalChanges: [Set<PaneID>] = []
    /// For each batch: whether the last render had drawn every pane in it.
    var signalChangesRendered: [Bool] = []
    /// How many times the Dock icon would have bounced.
    var attentionRequests = 0

    func render(_ model: LayoutModel) { rendered = model }
    func focus(_ pane: PaneID) { focused.append(pane) }
    var frontmostWindowID: WindowID? { front }
    func bringToFront(_ window: WindowID) { broughtToFront.append(window) }
    func confirmClose(_ warnings: [String], quitting: Bool) -> Bool {
        asked.append(warnings)
        askedToQuit.append(quitting)
        return answers.isEmpty ? true : answers.removeFirst()
    }
    func titleDidChange(_ pane: PaneID) { titles.append(pane) }
    func viewport(of window: WindowID) -> Viewport? { viewports[window] }
    /// Panes' rects, as a test sets them (nil: not on screen).
    var paneRects: [PaneID: FloatRect] = [:]
    func paneRect(_ pane: PaneID) -> FloatRect? { paneRects[pane] }
    func isFocused(_ window: WindowID) -> Bool { focusedWindows.contains(window) }
    func signalsDidChange(on panes: Set<PaneID>) {
        signalChanges.append(panes)
        signalChangesRendered.append(panes.allSatisfy { rendered.leaf($0) != nil })
    }
    func requestUserAttention() { attentionRequests += 1 }
    /// Every context menu a pane asked for, in order.
    var contextMenus: [(pane: PaneID, items: [PaneMenuItem])] = []
    func showContextMenu(_ items: [PaneMenuItem], at point: NSPoint, in view: NSView, for pane: PaneID) {
        contextMenus.append((pane, items))
    }
    /// Every question a pane asked, in order.
    var dialogs: [(pane: PaneID, dialog: PaneDialog)] = []
    /// How the fake user answers a question; the default button unless a test says otherwise.
    var answerDialog: (PaneDialog) -> PaneDialog.Answer = { $0.defaultAnswer }
    func showDialog(_ dialog: PaneDialog, for pane: PaneID, completion: @escaping @MainActor (PaneDialog.Answer) -> Void) {
        dialogs.append((pane, dialog))
        completion(answerDialog(dialog))
    }
    /// Every file or directory a pane asked for, in order.
    var pickers: [(pane: PaneID, picker: PanePicker)] = []
    /// What the fake user picks: nothing (cancelled) unless a test says otherwise.
    var answerPicker: (PanePicker) -> URL? = { _ in nil }
    func showPicker(_ picker: PanePicker, for pane: PaneID, completion: @escaping @MainActor (URL?) -> Void) {
        pickers.append((pane, picker))
        completion(answerPicker(picker))
    }
}
