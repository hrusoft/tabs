import AppKit
import SwiftUI
import TabsCore

/// The Caffeinate dialog's fields: the five `caffeinate(8)` assertions and the
/// timer text. Each new dialog starts from the last Start's, or before any
/// from the defaults.
@MainActor
@Observable
final class CaffeinateDialogModel {
    /// The switches; their `timerSeconds` is unused (`timerText` holds the timer).
    var flags: CaffeinateFlags
    /// Minutes, as typed: `parseTimerMinutes` reads it at Start.
    var timerText: String

    /// - Parameter remembered: what the dialog last started with, nil if it never has.
    init(remembered: CaffeinateFlags? = nil) {
        var flags = remembered ?? CaffeinateFlags.dialogDefaults
        timerText = Self.timerText(forSeconds: flags.timerSeconds)
        flags.timerSeconds = nil
        self.flags = flags
    }

    /// What Start launches: the switches as set, plus the timer when one was given.
    var flagsToStart: CaffeinateFlags {
        var flags = flags
        flags.timerSeconds = Self.parseTimerMinutes(timerText)
        return flags
    }

    /// The minutes the timer field shows and accepts, as whole seconds. Empty
    /// means "run until Decaf" — and so does anything that isn't a positive
    /// whole number of minutes.
    static func parseTimerMinutes(_ text: String) -> Double? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return nil }
        guard let minutes = Double(trimmed), minutes.isFinite, minutes == minutes.rounded(), minutes > 0 else { return nil }
        return minutes * 60
    }

    /// The timer field's text for a timer of `seconds`: its whole minutes, as
    /// `parseTimerMinutes` reads them back. Anything Start can't have given
    /// (none, or not a positive whole number of minutes) is empty.
    static func timerText(forSeconds seconds: Double?) -> String {
        guard let seconds, seconds.isFinite, seconds > 0, seconds.truncatingRemainder(dividingBy: 60) == 0,
            let minutes = Int(exactly: seconds / 60)
        else { return "" }
        return String(minutes)
    }
}

/// The dialog's rows and texts.
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

    /// 360 plus the grouped form's own insets.
    static let width: CGFloat = 440

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    ForEach(CaffeinateCopy.assertions) { assertion in
                        Toggle(isOn: $model.flags[dynamicMember: assertion.flag]) {
                            Text(assertion.title)
                            if let hint = assertion.hint { Text(hint).foregroundStyle(.secondary) }
                        }
                        .accessibilityIdentifier(assertion.id)
                    }
                }
                Section {
                    LabeledContent {
                        HStack(spacing: 6) {
                            // Bordered: a grouped form's plain field draws no box, and an
                            // empty one would vanish.
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
                        Text(CaffeinateCopy.timerHint).foregroundStyle(.secondary)
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
    let model: CaffeinateDialogModel
    private let onFinish: (CaffeinateFlags?) -> Void
    private var finished = false

    /// - Parameter remembered: the fields to start from (`CaffeinateDialogModel.init(remembered:)`).
    /// - Parameter themes: the app's, which the dialog is painted in.
    init(remembered: CaffeinateFlags?, themes: Themes, onFinish: @escaping (CaffeinateFlags?) -> Void) {
        model = CaffeinateDialogModel(remembered: remembered)
        self.onFinish = onFinish
        let window = NSWindow(contentRect: .zero, styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.paint(with: themes)
        window.title = CaffeinateCopy.windowTitle
        window.isReleasedWhenClosed = false
        window.collectionBehavior.insert(.fullScreenNone)
        super.init(window: window)
        window.delegate = self
        let hosting = NSHostingView(
            rootView: ThemedRoot(themes) {
                CaffeinateDialogView(model: model, onCancel: { [weak self] in self?.cancel() }, onStart: { [weak self] in self?.start() })
            })
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
/// forward — with what was typed — if already open, dropped when it closes.
typealias CaffeinateDialogPresenter = WindowPresenter<CaffeinateWindowController>

extension WindowPresenter where Controller == CaffeinateWindowController {
    /// Start records its options in `settings` and starts `caffeinate` with
    /// them, and the next dialog starts from them; a dialog that ends any other
    /// way (a test reset's dismiss too) records and starts nothing.
    convenience init(caffeinate: Caffeinate, settings: SettingsStore, themes: Themes, presentsWindows: Bool) {
        self.init(presentsWindows: presentsWindows) {
            CaffeinateWindowController(remembered: settings.lastCaffeinate, themes: themes) { flags in
                guard let flags else { return }
                settings.setLastCaffeinate(flags)
                caffeinate.start(flags)
            }
        }
    }
}
