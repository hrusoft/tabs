import AppKit

/// One window of its kind (About, the Caffeinate dialog): made when it is first asked for,
/// brought forward while it is open, and dropped when it closes, however it closes, so the next
/// one is fresh.
@MainActor
final class WindowPresenter<Controller: NSWindowController> {
    /// The open window's controller; nil while there is none.
    private(set) var controller: Controller?
    private let make: () -> Controller
    /// False under the end-to-end hidden mode: the window is built but never shown or focused.
    private let presentsWindows: Bool
    /// Hears the open window close.
    private var closing: (any NSObjectProtocol)?

    init(presentsWindows: Bool, make: @escaping () -> Controller) {
        self.presentsWindows = presentsWindows
        self.make = make
    }

    isolated deinit {
        stopListening()
    }

    /// Shows and focuses the window, making it if there isn't one open.
    @discardableResult
    func show() -> Controller {
        let controller = controller ?? open()
        if presentsWindows {
            controller.showWindow(nil)
            controller.window?.makeKeyAndOrderFront(nil)
        }
        return controller
    }

    /// Closes it as its close button would (a test reset).
    func dismiss() {
        controller?.window?.close()
    }

    private func open() -> Controller {
        let controller = make()
        self.controller = controller
        // That window's close only: an older one closing late leaves this one in place.
        stopListening()
        if let window = controller.window {
            closing = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: nil) {
                [weak self] _ in
                MainActor.assumeIsolated {
                    self?.stopListening()
                    self?.controller = nil
                }
            }
        }
        return controller
    }

    private func stopListening() {
        if let closing { NotificationCenter.default.removeObserver(closing) }
        closing = nil
    }
}
