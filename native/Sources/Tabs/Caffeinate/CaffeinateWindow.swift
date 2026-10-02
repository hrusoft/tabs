import AppKit
import SwiftUI
import TabsCore

/// The Caffeinate dialog's fields: the five `caffeinate(8)` assertions and the
/// timer text, as the Electron dialog's `CaffeinateForm` holds them. Each new
/// dialog starts from the defaults.
@MainActor
@Observable
final class CaffeinateDialogModel {
    var flags = CaffeinateFlags.dialogDefaults
    /// Minutes, as typed: `parseTimerMinutes` reads it at Start.
    var timerText = ""

    /// What Start launches: the switches as set, plus the timer when one was given.
    var flagsToStart: CaffeinateFlags {
        var flags = flags
        flags.timerSeconds = Self.parseTimerMinutes(timerText)
        return flags
    }

    /// The minutes the timer field shows and accepts, as whole seconds. Empty
    /// means "run until Decaf" — and so does anything that isn't a positive
    /// whole number of minutes, as in Electron (`CaffeinateDialog.tsx`'s
    /// `parseTimerMinutes`, which reads the text as a JavaScript `Number`).
    static func parseTimerMinutes(_ text: String) -> Double? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return nil }
        guard let minutes = Double(trimmed), minutes.isFinite, minutes == minutes.rounded(), minutes > 0 else { return nil }
        return minutes * 60
    }
}

/// The dialog's rows and texts, in the Electron dialog's order and words.
@MainActor
enum CaffeinateCopy {
    struct Assertion: Identifiable {
        let id: String
        let title: String
        let hint: String?
        let flag: WritableKeyPath<CaffeinateFlags, Bool>
    }

    /// No ellipsis: that belongs to the menu item, which promises a dialog.
    static let windowTitle = "Caffeinate"

    static let assertions: [Assertion] = [
        Assertion(id: "caffeinate-field-display", title: "Prevent display sleep", hint: nil, flag: \.preventDisplaySleep),
        Assertion(id: "caffeinate-field-idle", title: "Prevent idle system sleep", hint: nil, flag: \.preventIdleSleep),
        Assertion(id: "caffeinate-field-disk", title: "Prevent disk idle sleep", hint: nil, flag: \.preventDiskSleep),
        Assertion(
            id: "caffeinate-field-system", title: "Prevent system sleep", hint: "Only applies on AC power.", flag: \.preventSystemSleep),
        Assertion(
            id: "caffeinate-field-active", title: "Declare the user active",
            hint: "Wakes the display; lasts 5 seconds unless a timer is also set below.", flag: \.declareUserActive),
    ]

    static let timerTitle = "Stop after"
    static let timerHint = "Leave empty to run until Decaf."
    static let timerUnit = "minutes"
}

/// The form: the assertions' switches, the timer, then Cancel and Start (the
/// default button). A grouped form like Settings' pages.
struct CaffeinateDialogView: View {
    @Bindable var model: CaffeinateDialogModel
    let onCancel: () -> Void
    let onStart: () -> Void

    /// As wide as the Electron dialog (360) plus the grouped form's own insets.
    static let width: CGFloat = 440

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    ForEach(CaffeinateCopy.assertions) { assertion in
                        Toggle(isOn: $model.flags[dynamicMember: assertion.flag]) {
                            Text(assertion.title)
                            if let hint = assertion.hint { Text(hint) }
                        }
                        .accessibilityIdentifier(assertion.id)
                    }
                }
                Section {
                    LabeledContent {
                        HStack(spacing: 6) {
                            // Bordered, as `.caffeinate-timer-input input` is: a grouped form's
                            // plain field draws no box, and an empty one would vanish.
                            TextField("", text: $model.timerText)
                                .textFieldStyle(.roundedBorder)
                                .labelsHidden()
                                .multilineTextAlignment(.trailing)
                                .frame(width: 56)
                                .accessibilityLabel("Minutes")
                                .accessibilityIdentifier("caffeinate-field-timer")
                            Text(CaffeinateCopy.timerUnit).foregroundStyle(.secondary)
                        }
                    } label: {
                        Text(CaffeinateCopy.timerTitle)
                        Text(CaffeinateCopy.timerHint)
                    }
                }
            }
            .formStyle(.grouped)
            .scrollDisabled(true)
            HStack(spacing: 8) {
                Spacer()
                SettingsButton("Cancel", id: "caffeinate-cancel-button", keyEquivalent: "\u{1b}", action: onCancel)
                SettingsButton("Start", id: "caffeinate-start-button", keyEquivalent: "\r", action: onStart)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 20)
        }
        .frame(width: Self.width)
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// The dialog's window: a standard titled window of its own, fixed in size.
/// Start launches the process with the fields' flags and closes it; Cancel,
/// Escape and the close button close it without starting anything. Whatever
/// ends it, `onFinish` hears once: the flags, or nil.
@MainActor
final class CaffeinateWindowController: NSWindowController, NSWindowDelegate {
    let model = CaffeinateDialogModel()
    private let onFinish: (CaffeinateFlags?) -> Void
    private var finished = false

    init(onFinish: @escaping (CaffeinateFlags?) -> Void) {
        self.onFinish = onFinish
        let window = NSWindow(contentRect: .zero, styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = CaffeinateCopy.windowTitle
        window.isReleasedWhenClosed = false
        window.collectionBehavior.insert(.fullScreenNone)
        super.init(window: window)
        window.delegate = self
        let hosting = NSHostingView(
            rootView: CaffeinateDialogView(
                model: model, onCancel: { [weak self] in self?.cancel() }, onStart: { [weak self] in self?.start() }))
        hosting.setAccessibilityIdentifier("caffeinate-dialog")
        window.contentView = hosting
        window.setContentSize(hosting.fittingSize)
        window.center()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    /// Start: the flags as the fields give them.
    func start() { finish(model.flagsToStart) }

    /// Cancel (and Escape, its key equivalent).
    func cancel() { finish(nil) }

    private func finish(_ flags: CaffeinateFlags?) {
        guard !finished else { return }
        finished = true
        onFinish(flags)
        window?.close()
    }

    func windowWillClose(_ notification: Notification) {
        guard !finished else { return }
        finished = true
        onFinish(nil)
    }
}

/// The one Caffeinate dialog (File ▸ Caffeinate…): opened on demand, brought
/// forward — with what was typed — if already open (Electron refuses a second
/// modal rather than replacing the one on screen), dropped when it closes so
/// the next one starts from the defaults.
@MainActor
final class CaffeinateDialogPresenter {
    private(set) var controller: CaffeinateWindowController?
    private let caffeinate: Caffeinate
    /// False under the end-to-end hidden mode: the window is built but never shown or focused.
    private let presentsWindows: Bool

    init(caffeinate: Caffeinate, presentsWindows: Bool) {
        self.caffeinate = caffeinate
        self.presentsWindows = presentsWindows
    }

    /// Shows and focuses the dialog, creating it if there isn't one open.
    @discardableResult
    func show() -> CaffeinateWindowController {
        let controller = controller ?? make()
        if presentsWindows {
            controller.showWindow(nil)
            controller.window?.makeKeyAndOrderFront(nil)
        }
        return controller
    }

    private func make() -> CaffeinateWindowController {
        let controller = CaffeinateWindowController { [weak self] flags in
            guard let self else { return }
            self.controller = nil
            if let flags { self.caffeinate.start(flags) }
        }
        self.controller = controller
        return controller
    }

    /// Closes it without starting anything (a test reset).
    func dismiss() {
        controller?.cancel()
    }
}
