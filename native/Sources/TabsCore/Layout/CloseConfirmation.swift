import Foundation

/// The words of the "you would lose work" confirmation — closing panes, a
/// window, or quitting — as the Electron app puts them (`closeDialogs.ts`),
/// for any plugin's warnings: what's at stake as a title, one bullet per
/// warning, and Cancel as the default button, so a stray Return or Escape
/// never destroys anything.
package struct CloseConfirmation: Equatable {
    package let message: String
    package let detail: String
    /// The button that goes ahead; Cancel is the other, and the default.
    package let proceed: String
    package static let cancel = "Cancel"

    package init(warnings: [String], quitting: Bool) {
        let count = warnings.count
        message = count == 1 ? "A pane is still busy" : "\(count) panes are still busy"
        let list = warnings.map { "• \($0)" }.joined(separator: "\n")
        detail = "\(list)\n\nClosing will end \(count == 1 ? "it" : "them") immediately."
        proceed = quitting ? "Quit Anyway" : "Close Anyway"
    }
}
